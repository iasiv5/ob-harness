# bare mirror provisioning 深化实施计划

## 目标

- 把 `ob init` Step 5 的逐 dependency 解析从当前 $2+4N$ 次 Python 进程压缩为恰好 1 次批量 planner；Step 5 的 Python 总调用数必须与 dependency 数量 N 无关。
- 删除 `clone_sub_repos` 循环内的 `git config --global http.postBuffer 536870912`，改用单次 clone 命令作用域的 `git -c http.postBuffer=536870912 clone --bare "$clone_url" "$mirror_path"`，保证 `ob init` 不再写用户全局 Git 配置。
- 先用行为金标和调用次数锁固定现状，再把 provisioning implementation 与每轮状态收进新的 `lib/bare_mirror.sh` deep module。
- 让 `lib/init_pipeline.sh` 只保留 Step 5 的命令级前置、dry-run 与 module 调用，不再读写 `STATUS_MIRROR_NEW`、`STATUS_MIRROR_EXISTING`、`STATUS_FAILED`、`MIRROR_BASE`。
- 保持 `ob init` 8 步顺序、最终报告、individual clone failure 非致命语义、`init-done marker` 写入时机和 exit-code 契约不变。

## 架构快照

现有 `clone_sub_repos` 已经是一个 function module，不能靠把函数搬进新文件证明 depth。本计划采用 `pin -> optimize -> deepen`：

1. **Pin**：测试只观察稳定行为，包括每条 dependency 的展开后 clone URL、BitBake-compatible mirror path、disposition，以及最终报告；不把旧 `STATUS_*` globals 固化成新 interface。
2. **Optimize**：先在现有 `clone_sub_repos` 中落一次性 NUL-framed planning，删除逐条 JSON 解析和逐条 mirror path Python；再把 Git buffer 配置改成 command-scoped。
3. **Deepen**：只有在前两步行为与成本都被锁住后，才把 implementation 收进 `lib/bare_mirror.sh`。新 module 拥有每轮 provisioning 状态和报告渲染，旧 globals 从 `ob` 与 `init_pipeline.sh` 删除。

最终 module interface：

- `bare_mirror_provision DEPS_JSON MIRROR_BASE BUILD_DIR`：重置 module 私有状态，批量 planning，展开 clone URL，应用 URL rewrite，创建缺失 bare mirror，记录 new/existing/failed；individual entry 失败保持非致命。
- `bare_mirror_base`：输出本轮 effective bare mirror 目录，供 Step 8 保持既有 `Mirror dir:` 行位置。
- `bare_mirror_print_status MACHINE`：输出本轮 mirror counts、failure entries 和 troubleshooting block，保持既有 report 文案与顺序。

`clone_sub_repos` 保留为 `init_pipeline` adapter：负责 Step 5 header、dry-run、`deps.json` 前置、effective `DL_DIR` 解析，然后调用 `bare_mirror_provision`。`print_report` 只消费 `bare_mirror_base` 与 `bare_mirror_print_status`，不知道 module 内部数组形状。

依赖分类：Git 与文件系统沿用现有 PATH-injection test adapter，不新增 production port。NUL framing 是 module implementation，不进入外部 interface。

## 全局约束

- **环境**：Linux + Bash；沿用仓库现有 `git`、`python3`、`shellcheck`，不新增第三方依赖。
- **状态格式**：不新增持久化 provisioning status 文件，不给 `workspace/configs/` 增加新格式；状态只在当前 `ob init` 进程内存在。
- **NUL framing**：批量 planner 的 stdout 协议为 `total\0`，随后每条 dependency 输出 `name\0clone_url\0src_uri\0mirror_path\0`。Caller 必须让 planner 通过一个可检查返回码的直接调用写入 `mktemp` 临时文件，再用动态 FD 配合 `read -r -d ''` 消费；禁止用 command substitution 捕获 NUL，也禁止用无法取得 producer 返回码的 process substitution 直接承载 planner。
- **临时 plan 生命周期**：plan 文件只能创建在 `${TMPDIR:-/tmp}`，planner 成功后打开 FD 并立即 unlink，读取通过 FD 继续；planner、mktemp、open 或首字段读取失败时删除临时文件并返回失败。它不是持久化 status 文件。
- **空字段语义**：空 `mirror_path` 必须保留为第四字段，继续表示 malformed/empty `src_uri`，该 entry 不 clone、不进入 new/existing/failed，BitBake 后续自行 fetch。
- **单一 mirror-path implementation**：批量 planner 吸收 `derive_bitbake_git_mirror_path` 的现有 `urlparse` + BitBake `gitsrcname` 算法后，必须删除 `lib/util.sh:derive_bitbake_git_mirror_path`；禁止保留两份算法。
- **进程预算**：N=0、N=2、N=20 使用相同的 comment-only `local.conf`。三个 case 的 Python **总调用数必须完全相等**，证明固定前置开销不随 N 增长；fake adapter 另按参数形状识别 planner，三个 case 的 planner-shaped 调用都必须恰好为 1。当前 implementation 预期总数为 2（`read_local_conf_var` 1 次 + planner 1 次），该数只作为诊断输出，不作为硬断言。
- **Git 全局卫生**：production 路径对 `git config --global http.postBuffer` 的调用数必须恰好为 0。每次实际 clone 使用 `git -c http.postBuffer=536870912 clone --bare "$clone_url" "$mirror_path"`。不得读取、删除或覆盖用户已有的全局 `http.postBuffer`。
- **行为保持**：相同 `deps.json`、effective `DL_DIR`、runtime Git mirror host、`local.conf` 和初始 mirror 状态下，重构前后的 normalized per-entry 结果一致：`(name, expanded clone URL, mirror path, disposition)`；disposition 为 `new`、`existing`、`skipped` 或 `failed`。
- **旧行为映射**：malformed `src_uri` 为 `skipped` 且不进入任何 count；unresolved clone URL 与 clone failure 都为 `failed`；已有目录为 `existing`；成功新 clone 为 `new`。
- **失败语义**：individual unresolved URL / clone failure 继续只记录并告警，`clone_sub_repos` 整体继续成功，让 BitBake 后续 fetch；损坏/不可读 `deps.json`、mktemp 失败或 planner 输出不可读属于整批 planning 失败，继续由 `clone_sub_repos` 的 direct-exit adapter 收口为 exit 1。deep module 只 `return 1`，不直接 exit。
- **跨语言边界**：不修改 `tools/parse_bitbake_deps.py:_detect_runtime_git_host`，不合并 Bash/Python 两套 runtime Git mirror host resolver。
- **领域决策**：保持 ADR-0001 的 8-step completion 与 `init-done marker` 写入时机；保持 ADR-0005 的 `DL_DIR` assignment-state 判定；ADR-0004 PREMIRRORS 与本任务正交，不改。
- **module 分类**：`lib/bare_mirror.sh` 是 leaf-pure module；这里的 pure 仅表示函数不直接 `exit`，不表示无文件、进程或网络副作用。必须登记 `tools/exit_contract.py:LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 为 `set()`。
- **文档路由**：URL rewrite 表迁入 `lib/bare_mirror.sh` 后，必须同步 `rules/skills/workflow_01-obmc_env_init.md`，不能继续指导维护者去 `clone_sub_repos` 内修改。
- **范围外**：不并行 clone，不改变 bare mirror 增量策略，不更新已有 mirror，不改变 URL rewrite 内容，不清理用户现存全局 Git 配置，不重构 `generate_dep_graph` 或 `deps.json` schema。
- **质量门禁**：修改 `ob` / `lib/*.sh` 后必须运行 `tools/ob_check.sh`。coverage radar uncovered baseline 当前为 12；新增函数应由本次测试覆盖，不以抬高 baseline 掩盖漏测。

## 输入工件

- 2026-07-11 架构分析与两轮独立评审共识：性能与回归锁为硬交付，新文件抽取必须通过 interface shrink test。
- 临时可视化报告：`/home/iasi/.vscode-server-insiders/tmp/tmp_vscode_1/architecture-review-20260711-182742.html`。计划不依赖该临时文件长期存在。
- 领域术语：`CONTEXT.md` 的 `bare mirror`、`deps.json`、`runtime Git mirror host`、`state file format`、`function semantic layer`、`test layer`。
- 相关 ADR：`docs/adr/0001-init-done-marker.md`、`docs/adr/0005-local-conf-var-detection-exit-code.md`。
- 相关实践：`rules/skills/bestpractice_09-nonfunctional_regression_locks.md`、`rules/skills/bestpractice_10-deep_module_extraction.md`。
- 无独立设计 spec；本计划记录已批准的实施边界与验收契约。

## 文件结构与职责

- **Create**: `lib/bare_mirror.sh`
  - bare mirror provisioning deep module。
  - 私有实现：状态 reset、一次性 NUL planner、URL expansion/rewrite、per-entry disposition。
  - public interface：`bare_mirror_provision`、`bare_mirror_base`、`bare_mirror_print_status`。
- **Create**: `tests/orchestration/bare_mirror_cost.sh`
  - N=0/N=2/N=20 Python 总调用数相等 + planner 精确 1 次预算。
  - `git config --global` 零调用与 command-scoped clone 断言。
- **Modify**: `lib/init_pipeline.sh`
  - `clone_sub_repos` 收为 Step 5 adapter。
  - `print_report` 改消费 bare mirror module report interface。
- **Modify**: `lib/util.sh`
  - 删除 `derive_bitbake_git_mirror_path`，避免 mirror-path 双 implementation。
  - 把 `resolve_effective_dl_dir` 注释中的旧 `MIRROR_BASE` 表述改为中性的 `effective DL_DIR` caller capture。
- **Modify**: `ob`
  - 删除 `STATUS_MIRROR_NEW`、`STATUS_MIRROR_EXISTING`、`STATUS_FAILED`、`MIRROR_BASE` globals。
- **Modify**: `tests/orchestration/clone_sub_repos.sh`
  - 先改成不依赖旧 globals 的行为金标。
  - 保留 dry-run、成功、失败、runtime Git mirror host 展开覆盖。
- **Modify**: `tests/unit/paths.sh`
  - 删除迁走的 `derive_bitbake_git_mirror_path` helper tests；对应行为由 module interface test 接管。
- **Verify only**: `tests/unit/url_extra.sh`
  - 当前实测无 `derive_bitbake_git_mirror_path` 引用；Task 2 开始前用 grep 再确认，若出现命中则停下修订计划，不临时扩大范围。
- **Verify only**: `tests/protocol/init_machine_state_errors.sh`
  - 保持 `clone_sub_repos` adapter stub 名不变；本计划只复跑，不修改。
- **Modify**: `tools/exit_contract.py`
  - 登记 `'bare_mirror.sh': set()`。
- **Modify**: `tools/ob_check.sh`
  - 增加 legacy mirror globals surface gate，防状态形状回流到任何 production Bash 文件。
- **Modify**: `tools/coverage_matrix.md`
  - init 行登记 module interface 与行为/成本测试。
  - 路径推导行移除 `derive_bitbake_git_mirror_path`。
- **Modify**: `CONTEXT.md`
  - 登记 `bare mirror provisioning`，明确 module ownership、非致命失败语义与 report interface。
  - 更新 `function semantic layer` 的 `lib/*.sh` 列表。
- **Modify**: `rules/03_WORKSPACE.md`
  - 在 `ob` module 路由中登记 `lib/bare_mirror.sh` 及 leaf-pure 属性。
- **Modify**: `rules/skills/workflow_01-obmc_env_init.md`
  - 把 URL rewrite 表维护位置从 `clone_sub_repos` 更新为 `lib/bare_mirror.sh`。
- **May Modify**: `tests/.shellcheck-baseline`
  - 仅当 `tools/ob_check.sh` 因行号平移或告警减少自动重生成时纳入；不得吸收新增告警。
- **不修改**: `tools/parse_bitbake_deps.py`、`docs/adr/*.md`、`docs/specs/*.md`、`workspace/`。

## 任务间接口契约

- Task 1 Produces `bare mirror behavior gold`：后续所有实现任务必须通过的 normalized per-entry + report 行为基线。
- Task 2 Produces `one-shot NUL planning`：`_bare_mirror_emit_plan DEPS_JSON MIRROR_BASE` 的内部输出协议、失败返回语义、N=0/N=2/N=20 总 Python 调用数相等，以及每个 case planner-shaped 调用恰好 1 次的回归锁。
- Task 3 Produces `command-scoped Git clone`：全局 Git 写入 0 次，clone 调用携带 `-c http.postBuffer=536870912`。
- Task 4 Consumes Task 1-3 的行为与成本锁，Produces `lib/bare_mirror.sh` public interface：`bare_mirror_provision`、`bare_mirror_base`、`bare_mirror_print_status`。
- Task 5 Consumes Task 4 public interface，Produces repository surface gate、领域术语和 coverage 声明。
- Task 6 Consumes Task 1-5 全部产出，Produces 最终可执行验证证据；不新增实现。

## 任务清单

### Task 0: 实现前 git preflight

- **目标**：确认执行分支与工作区边界，避免在未获同意的 `main` 上开始实现或卷入无关改动。
- **Files**: 无代码改动。
- **接口契约**:
  - Consumes: 本计划文档。
  - Produces: 用户确认过的实现分支与 path-limited staging 纪律。
- **验证范围**：分支、工作区状态和计划文件状态明确。

- [ ] **Step 1: 检查分支与工作区**
- Run: `git status --short --branch`
- Expected: 明确显示当前分支和已有改动；本计划编写时基线为本地 `main` 跟踪 `origin/main`，代码工作区除本计划外无改动。

- [ ] **Step 2: 在 main/master 上显式停下确认**
- Run: `branch=$(git rev-parse --abbrev-ref HEAD); [[ "$branch" != "main" && "$branch" != "master" ]]`
- Expected: 非 main/master 时退出 0；若退出 1，执行者在任何代码修改前向用户确认是在当前分支实现还是创建新分支，不自行切换或提交。

- [ ] **Step 3: 建立精确暂存纪律**
- Change: 后续 checkpoint 只暂存该 Task 的 Files 列表中实际变化的精确路径；禁止 `git add -A`，commit 前运行 `git diff --cached --name-only`。
- Expected: 每个 checkpoint 不包含用户的无关改动。

### Task 1: clone_sub_repos 行为金标

- **目标**：把现有 Step 5 的 observable behavior 固定成不依赖 `STATUS_*` globals 的 characterization tests，使测试可跨 interface shrink 存活。
- **Files**:
  - Modify: `tests/orchestration/clone_sub_repos.sh`
- **接口契约**:
  - Consumes: 当前 `clone_sub_repos`、`print_report`、PATH fake Git。
  - Produces: `bare mirror behavior gold`，覆盖 `(name, expanded clone URL, mirror path, disposition)` 与最终 report。
- **验证范围**：测试在任何 production 修改前通过；测试不读取 `STATUS_MIRROR_*`、`STATUS_FAILED`、`MIRROR_BASE`。

- [ ] **Step 1: 记录当前测试基线与旧耦合**
- Run: `bash tests/orchestration/clone_sub_repos.sh`
- Expected: `PASS=6 FAIL=0`。
- Run: `grep -nE 'STATUS_MIRROR|STATUS_FAILED|MIRROR_BASE' tests/orchestration/clone_sub_repos.sh`
- Expected: 命中当前通过 globals 统计 NEW/FAILED 的断言，证明测试会阻碍 interface shrink。

- [ ] **Step 2: 把原有三类 case 改成 observable assertions**
- Change:
  1. dry-run case 断言输出含 `[DRY-RUN] Would populate bare mirrors`，并在同一 shell 调用 `print_report`，断言 report 的 `Mirror dir:` 值为空且完全不含 `Mirrors populated:` / `Failed mirrors:`；同时断言 fake Git call file 不存在。
  2. 两条成功 fixture 断言输出含 `Mirrors: 2 new, 0 existing`，不再读取 `STATUS_MIRROR_NEW`。
  3. 两条 clone failure fixture 断言输出含 `2 mirrors failed` 和对应 entry 的 failure 文案，不再读取 `STATUS_FAILED`。
  4. 保留现有 `${GITLAB_IP}` 展开 case，继续断言 fake Git calls 中 URL 已展开且不含字面 `${GITLAB_IP}`。
  5. 删除测试脚本内所有 `STATUS_MIRROR_*`、`STATUS_FAILED`、`MIRROR_BASE` 引用。

- [ ] **Step 3: 增加 mixed five-entry gold fixture**
- Change: 在同一测试文件增加一个独立临时 workspace，写入以下语义等价的五条 dependency，顺序固定为 `existing -> new -> malformed -> unresolved -> failed`：
```json
[
  {"name":"existing","clone_url":"https://example.com/existing.git","src_uri":"git://example.com/existing.git;branch=main"},
  {"name":"new","clone_url":"https://example.com/new.git","src_uri":"git://example.com/new.git;branch=main"},
  {"name":"malformed","clone_url":"https://example.com/malformed.git","src_uri":""},
  {"name":"unresolved","clone_url":"https://${UNSET_HOST}/unresolved.git","src_uri":"git://example.com/unresolved.git"},
  {"name":"failed","clone_url":"https://example.com/fail.git","src_uri":"git://example.com/fail.git"}
]
```
- Change:
  1. 为 mixed case 设 `case_root=$(mktemp -d)`、`WORKSPACE_DIR="$case_root"`、`OPENBMC_DIR="$case_root/openbmc"`、`BUILD_DIR="$OPENBMC_DIR/build/romulus"`、`CONFIGS_DIR="$case_root/configs"`、`MACHINE=romulus`、`DRY_RUN=0`、`VERBOSE=1`，并创建 `"$BUILD_DIR"` 与 `"$CONFIGS_DIR"`。`VERBOSE=1` 是观察 malformed skip 的必要前置，`CONFIGS_DIR` 是 `print_report | tee` 的必要前置。
  2. 预建 `"$case_root/downloads/git2/example.com.existing.git"`。
  3. fake Git 对 URL 含 `/fail.git` 的 clone 返回 128；其他 clone 创建最后一个参数指定的 destination。
  4. fake Git 同时兼容旧 `git clone --bare "$clone_url" "$mirror_path"` 与新 `git -c http.postBuffer=536870912 clone --bare "$clone_url" "$mirror_path"` 参数形状；destination 始终取最后一个参数。
  5. 归一化 fake Git calls 时，只保留 clone 行，并移除可选前缀 `-c http.postBuffer=536870912 `；期望值用当前 `case_root` 动态构造：
```bash
expected_calls=$(printf 'clone --bare https://example.com/new.git %s\nclone --bare https://example.com/fail.git %s' \
    "$case_root/downloads/git2/example.com.new.git" \
    "$case_root/downloads/git2/example.com.fail.git")
assert_eq "normalized clone URL/path/disposition calls" "$normalized_calls" "$expected_calls"
```
  6. 断言 `existing` 没有 clone call 且目录保留；`new` 有精确 URL/path 且目录创建；`malformed` 输出 skip verbose 且无 clone；`unresolved` 无 clone 并进入 failure report；`failed` 有 clone attempt、目标目录被清理并进入 failure report。
  7. 在同一 shell 调用 `print_report`，断言输出/报告含 `Mirrors populated: 1 new, 1 existing`、`Failed mirrors: 2`，并精确包含 `[FAIL] unresolved (unresolved variable in clone URL)` 和 `[FAIL] failed (bare mirror clone failed)`；两条 failure 顺序为 unresolved 后 failed，malformed 不计入 failure。
  8. 增加损坏 `deps.json` case：使用独立 `bash -c` 直接 `OB_NO_MAIN=1 source ob`，保持入口的 `set -e`，调用 `clone_sub_repos` 后断言进程 rc=1；不得通过 `tests/lib/ob_loader.sh` 的 `set +e` 改写这条 CLI 语义。

- [ ] **Step 4: 运行并确认 characterization 全绿**
- Run: `bash tests/orchestration/clone_sub_repos.sh`
- Expected: 所有原 case、mixed gold case、精确 failure 文案与损坏 JSON rc=1 case 均 `ok`，汇总 `FAIL=0`。
- Run: `! grep -nE 'STATUS_MIRROR|STATUS_FAILED|MIRROR_BASE' tests/orchestration/clone_sub_repos.sh`
- Expected: 退出 0，测试已只依赖 observable behavior。

- [ ] **Step 5: 可选 checkpoint commit**
- Run: `git add tests/orchestration/clone_sub_repos.sh && git diff --cached --name-only && git commit -m "test(init): pin bare mirror provisioning behavior"`
- Expected: 暂存区只含该测试文件，commit 成功。

### Task 2: 一次性 NUL planning

- **目标**：用一次 Python 读取整个 `deps.json` 并生成 NUL-framed plan，消除循环内 3 次字段解析与 1 次 mirror-path Python。
- **Files**:
  - Create: `tests/orchestration/bare_mirror_cost.sh`
  - Modify: `lib/init_pipeline.sh`（`clone_sub_repos` 及新增私有 `_bare_mirror_emit_plan`）
  - Modify: `lib/util.sh`（删除 `derive_bitbake_git_mirror_path`；修正 `resolve_effective_dl_dir` 的旧 `MIRROR_BASE` 注释）
  - Modify: `tests/unit/paths.sh`（删除旧 helper tests）
  - Verify only: `tests/unit/url_extra.sh`（当前无旧 helper 引用）
- **接口契约**:
  - Consumes: Task 1 `bare mirror behavior gold`。
  - Produces: `_bare_mirror_emit_plan DEPS_JSON MIRROR_BASE` 内部协议：`total\0` + N 组四字段 NUL records；N=0/N=2/N=20 的 Python 总调用数相等，且每个 case planner-shaped 调用恰好 1 次；损坏 JSON 返回非零。
- **验证范围**：成本锁从红变绿；N=0 协议成立；行为金标保持绿；mirror path 只有一个 implementation；planner 失败仍传播为 CLI rc=1。

- [ ] **Step 1: 写 N=0/N=2/N=20 Python 调用次数失败测试**
- Change: 新建 `tests/orchestration/bare_mirror_cost.sh`：
  1. source `tests/lib/ob_loader.sh`、`assert.sh`、`stub.sh`。
  2. 保存并导出真实 Python 路径：`REAL_PYTHON=$(command -v python3); export REAL_PYTHON`。fake executable 是子进程，未 export 的 shell 变量不可见。
  3. fake `python3` adapter 每次向 `PYTHON_CALLS_LOG` 追加一行；planner-shaped 的**权威谓词**必须同时满足 `$# == 3`、`$1 == -`、`$2 == $PLANNER_DEPS_JSON`、`$3 == $PLANNER_MIRROR_BASE`，满足后向 `PLANNER_CALLS_LOG` 追加一行，再 `exec "$REAL_PYTHON" "$@"`。禁止只用 arity + `$1 == -`，因为 `read_local_conf_var` 也是三参数 stdin-script 调用；可额外断言 `basename "$2" == deps.json` 作为可读诊断，但 basename 不能替代两个完整路径 equality。四个 log/path 变量在每个 case 调用前设置并 export，确保 `python3 - local.conf DL_DIR` 不会被计为 planner。
  4. 用下面的 Bash helper 生成 N=0、N=2、N=20 的合法 JSON fixtures，避免 fixture 生成本身进入 Python 计数：
```bash
write_deps_fixture() {
    local output="$1" count="$2" index
    printf '[' > "$output"
    for ((index = 1; index <= count; index++)); do
        [[ "$index" -eq 1 ]] || printf ',' >> "$output"
        printf '{"name":"repo%s","clone_url":"https://example.com/repo%s.git","src_uri":"git://example.com/repo%s.git;branch=main"}' \
            "$index" "$index" "$index" >> "$output"
    done
    printf ']\n' >> "$output"
}
```
  5. 每个 case 使用独立 workspace，并创建同内容的 `BUILD_DIR/conf/local.conf`（仅一行注释，不含 `DL_DIR` assignment）；这会让 `resolve_effective_dl_dir` 固定调用一次 `read_local_conf_var`，避免成本锁依赖“文件不存在”的隐含前提。
  6. 分别运行 N=0、N=2、N=20，记录 `total_calls_N` 与 `planner_calls_N`；断言三个 total 完全相等，且三个 planner count 都恰好为 1。total 的绝对值只打印诊断，不硬编码。
  7. fake Git 支持旧/新 clone 参数形状并创建 destination；N=0 不发生 clone，N=2/N=20 走完整 provisioning。

- [ ] **Step 2: 运行并确认当前失败**
- Run: `bash tests/orchestration/bare_mirror_cost.sh`
- Expected: 失败；comment-only local.conf 下当前实测 N=0/2/20 的总 Python 调用分别为 3/11/83，三者不相等；planner-shaped count 都为 0。至少 total-equality 与 planner-count 两组断言失败，证明测试既识别 $2+4N$ 回退，也确认新 planner 尚未落地。

- [ ] **Step 3: 实现 `_bare_mirror_emit_plan` 与 checked plan file**
- Change: 在 `lib/init_pipeline.sh` 的 `clone_sub_repos` 之前增加私有 helper：
  - 单次调用 `python3 - "$deps_json" "$mirror_base"`。
  - `json.load` 一次读取 items。
  - 第一字段输出 `len(items)` + NUL。
  - 每条输出 `name`、`clone_url`、`src_uri`、`mirror_path`，每字段后写 NUL。
  - `mirror_path` 完整吸收现有 `derive_bitbake_git_mirror_path` 算法：截掉 `;` 后参数，`urlparse`，host/path 校验，host `:` 转 `.`，path `/`/`*` 转 `.`，空格/括号转 `_`，去掉首个 `.`，最后拼到 `mirror_base`。
  - empty/malformed `src_uri` 输出空 `mirror_path`，但仍输出四个字段。

- Change: `clone_sub_repos` 用以下明确顺序消费 plan：
  1. `plan_file=$(mktemp "${TMPDIR:-/tmp}/ob-bare-mirror-plan.XXXXXX")`；失败时输出 `Failed to create temporary bare mirror plan.` 并 exit 1。
  2. 直接执行 `_bare_mirror_emit_plan "$deps_json" "$MIRROR_BASE" > "$plan_file"`；返回非零时删除文件，输出 `Failed to plan bare mirrors from $deps_json.` 并 exit 1。不得改成 process substitution。
  3. `exec {plan_fd}<"$plan_file"`；open 失败时删除文件并 exit 1。open 成功后立即 `rm -f "$plan_file"`，后续通过 FD 读取。
  4. 第一次 `IFS= read -r -d '' total <&"$plan_fd"` 必须成功，且 `total` 必须匹配 `^[0-9]+$`；否则关闭 FD、输出 planning failure 并 exit 1。
  5. `processed=0`；`while` 条件连续执行四次 `IFS= read -r -d ''`，依次写入 `name`、`clone_url`、`src_uri`、`mirror_path`。loop body 原样保留当前变量展开、URL rewrite、clone、cleanup 与 status 分支，只删除三个逐字段 Python 调用和 `derive_bitbake_git_mirror_path` 调用；每读完一组四字段先递增 `processed`。
  6. 循环结束后 `exec {plan_fd}<&-`，并断言 `processed == total`；不相等时输出 planning failure 并 exit 1。完整 plan 来自成功写完并关闭的临时文件，caller 不会观察 producer 的半写状态。

- [ ] **Step 4: 删除旧 mirror-path helper 与 helper-level tests**
- Change:
  1. 删除 `lib/util.sh:derive_bitbake_git_mirror_path` 整个函数。
  2. 删除 `tests/unit/paths.sh` 的三个 `derive_bitbake_git_mirror_path` assertions，并更新文件头覆盖列表。
  3. 把 `resolve_effective_dl_dir` 注释中的“被 $() 捕获喂给 MIRROR_BASE”改为“stdout 被 caller 捕获为 effective DL_DIR；失败保持静默，避免污染 stdout”。
  4. 不在其他文件复制该算法；此时唯一 implementation 是 `_bare_mirror_emit_plan` 内的批量 planner。

- [ ] **Step 5: 运行并确认通过**
- Run: `bash tests/orchestration/bare_mirror_cost.sh`
- Expected: N=0/N=2/N=20 的 Python 总调用数完全相等，三个 planner-shaped count 均恰好为 1，N=0 无 clone 且 counts 为 0，`FAIL=0`。
- Run: `bash tests/orchestration/clone_sub_repos.sh && bash tests/unit/paths.sh`
- Expected: behavior gold、损坏 JSON rc=1 与剩余 path tests 全绿。
- Run: `! grep -RIn 'derive_bitbake_git_mirror_path' ob lib tests 2>/dev/null && ! grep -n 'MIRROR_BASE' lib/util.sh`
- Expected: 退出 0，production 与 tests 无旧 helper 引用，`util.sh` 无 stale `MIRROR_BASE` 注释。
- Run: `! grep -n 'derive_bitbake_git_mirror_path' tests/unit/url_extra.sh`
- Expected: 退出 0；若失败，说明执行时出现了计划外引用，立即停下更新 Files 与测试迁移步骤，不顺手修改。
- Run: `grep -n 'derive_bitbake_git_mirror_path' tools/coverage_matrix.md`
- Expected: 命中当前一处旧 coverage 声明，明确留给 Task 5 更新。

- [ ] **Step 6: 可选 checkpoint commit**
- Run: `git add lib/init_pipeline.sh lib/util.sh tests/unit/paths.sh tests/orchestration/bare_mirror_cost.sh && git diff --cached --name-only && git commit -m "perf(init): batch bare mirror planning in one Python process"`
- Expected: 暂存区只含列出的四个文件，commit 成功。

### Task 3: command-scoped Git clone 配置

- **目标**：把永久全局 Git 写入改成单次 clone 命令配置，并用精确调用面锁防回退。
- **Files**:
  - Modify: `tests/orchestration/bare_mirror_cost.sh`
  - Modify: `lib/init_pipeline.sh`（`clone_sub_repos` clone 分支）
- **接口契约**:
  - Consumes: Task 2 N=0/N=2/N=20 fixtures 与 fake Git adapter。
  - Produces: `git config --global` 恰好 0 次；每条 clone 都以 `git -c http.postBuffer=536870912 clone --bare "$clone_url" "$mirror_path"` 执行。
- **验证范围**：Git 调用面测试从红变绿；不读取或清理真实 `~/.gitconfig`。

- [ ] **Step 1: 扩展成本测试为 Git 调用面锁**
- Change: 对 N=0、N=2、N=20 每个 case 增加：
  1. `.git.calls` 中含 `config --global http.postBuffer` 的行数恰好为 0。
  2. clone call 总数恰好为 N。
  3. 以 `-c http.postBuffer=536870912 clone --bare` 开头的行数恰好为 N。
  4. fake Git 的 clone 分支不依赖固定 `$1 == clone`；识别 `$1 == clone` 或 `$3 == clone`，destination 取最后一个参数。

- [ ] **Step 2: 运行并确认当前失败**
- Run: `bash tests/orchestration/bare_mirror_cost.sh`
- Expected: Python 预算仍通过；Git 断言失败，当前 global config 次数按 N=0/2/20 分别为 0/2/20，三个 case 的 command-scoped clone 次数均为 0。

- [ ] **Step 3: 写最小实现**
- Change:
  1. 删除循环内 `git config --global http.postBuffer 536870912`。
  2. 将 `git clone --bare "$clone_url" "$mirror_path"` 改为 `git -c http.postBuffer=536870912 clone --bare "$clone_url" "$mirror_path"`。
  3. 更新相邻注释，说明 512 MiB 只作用于本次 clone，不持久化到用户配置。
  4. 不执行 `git config --global --unset`，不触碰用户当前已有值。

- [ ] **Step 4: 运行并确认通过**
- Run: `bash tests/orchestration/bare_mirror_cost.sh && bash tests/orchestration/clone_sub_repos.sh`
- Expected: Python、Git 调用面和 behavior gold 全部 `FAIL=0`。
- Run: `! grep -RIn 'git config --global http.postBuffer' ob lib`
- Expected: 退出 0，production 不再写该全局键。

- [ ] **Step 5: 可选 checkpoint commit**
- Run: `git add lib/init_pipeline.sh tests/orchestration/bare_mirror_cost.sh && git diff --cached --name-only && git commit -m "fix(init): scope http.postBuffer to each mirror clone"`
- Expected: 暂存区只含两个文件，commit 成功。

### Task 4: bare_mirror deep module 抽取

- **目标**：把已经被行为与成本锁钉住的 implementation 收进 leaf-pure `lib/bare_mirror.sh`，删除 init pipeline 对 provisioning 状态形状的知识。
- **Files**:
  - Create: `lib/bare_mirror.sh`
  - Modify: `lib/init_pipeline.sh`
  - Modify: `ob`
  - Modify: `tools/exit_contract.py`
  - Modify: `tests/orchestration/bare_mirror_cost.sh`（增加 initialized state 的 public-interface 断言）
  - Test: `tests/orchestration/clone_sub_repos.sh`（复跑 Task 1 gold，不修改）
  - Test: `tests/protocol/init_machine_state_errors.sh`（保留 `clone_sub_repos` adapter stub 名，不修改）
- **接口契约**:
  - Consumes: Task 1 `bare mirror behavior gold`、Task 2 `one-shot NUL planning`、Task 3 `command-scoped Git clone`。
  - Produces:
    - `bare_mirror_provision DEPS_JSON MIRROR_BASE BUILD_DIR`。
    - `bare_mirror_base`。
    - `bare_mirror_print_status MACHINE`。
    - leaf-pure basename registration `'bare_mirror.sh': set()`。
- **验证范围**：旧 globals 从全部 production Bash 清零；三项 public interface 被 caller 使用；所有行为与成本测试保持绿。

- [ ] **Step 1: 运行抽取前 shrink check 并确认当前不满足**
- Run: `grep -RInE 'STATUS_MIRROR_NEW|STATUS_MIRROR_EXISTING|STATUS_FAILED|MIRROR_BASE' ob lib/*.sh`
- Expected: 命中 `ob` 顶层 globals、`clone_sub_repos` mutations 和 `print_report` consumers，证明 interface 仍泄漏状态形状；Task 2 已清理 `util.sh` stale 注释。

- [ ] **Step 2: 创建 leaf-pure module**
- Change: 新建 `lib/bare_mirror.sh`，文件头明确：
```bash
#!/usr/bin/env bash
# lib/bare_mirror.sh - bare mirror provisioning + per-run report state. See CONTEXT.md.
# Exit: leaf-pure module (functions never exit; file/process/network side effects are allowed).
```
- Change: module 内包含：
  1. 私有 `_bare_mirror_reset`：每次 provision 入口设置 `_BARE_MIRROR_INITIALIZED=0`、清空 `_BARE_MIRROR_BASE`，并重置 `_BARE_MIRROR_NEW`、`_BARE_MIRROR_EXISTING`、`_BARE_MIRROR_FAILED` arrays；私有名不进入 caller。
  2. 私有 `_bare_mirror_emit_plan`：从 Task 2 原样搬入一次性 NUL planner。
  3. `bare_mirror_provision DEPS_JSON MIRROR_BASE BUILD_DIR`：先 reset，再设置 `_BARE_MIRROR_BASE`，使用 `BUILD_DIR/conf/local.conf` 与 `BUILD_DIR/clone-errors.log`，承载现有 URL expansion、runtime Git mirror host、local.conf fallback、URL rewrite、command-scoped clone、cleanup、disposition 和 immediate summary；所有 fatal planning/protocol 检查与完整 entry 遍历成功后，返回前最后一步设置 `_BARE_MIRROR_INITIALIZED=1`。
  4. `bare_mirror_base`：仅当 `[[ "${_BARE_MIRROR_INITIALIZED:-0}" == "1" ]]` 时输出 `${_BARE_MIRROR_BASE:-}`；未初始化、dry-run 或 fatal failure 后输出空行。
  5. `bare_mirror_print_status MACHINE`：仅当 `[[ "${_BARE_MIRROR_INITIALIZED:-0}" == "1" ]]` 时按旧 `print_report` 顺序输出 counts、cache path、failed entries 与 troubleshooting block；未初始化、dry-run 或 fatal failure 后安全无输出。不得要求 caller 传入或读取数组。
  6. `bare_mirror_provision` 的 mktemp、planner、open、首字段读取或 record count 校验失败统一清理临时资源、保持 `_BARE_MIRROR_INITIALIZED=0` 并 `return 1`；individual entry failure 仍记录后继续，完整遍历后设置 initialized flag 并 `return 0`。
  7. 所有 Bash 函数只 `return`，不直接 `exit`。

- [ ] **Step 3: 把 init_pipeline 收为 adapter**
- Change: `lib/init_pipeline.sh:clone_sub_repos` 只保留：
  1. 现有 Step 5 `Populating bare mirrors` header 文案。
  2. `deps_json="$BUILD_DIR/deps.json"`。
  3. 现有 dry-run 文案与 return。
  4. `require_path` 前置。
  5. `resolve_effective_dl_dir` 的 ADR-0005 error/remedy 与 exit 3。
  6. `if ! bare_mirror_provision "$deps_json" "$effective_dl_dir/git2" "$BUILD_DIR"; then error "Failed to provision bare mirrors from $deps_json."; exit 1; fi`。

- Change: 从 `init_pipeline.sh` 删除 `_bare_mirror_emit_plan`、URL expansion、rewrite、clone、status arrays 与 `failed` counter implementation。

- Change: `print_report`：
  1. 把 `echo "Mirror dir:  $MIRROR_BASE"` 改为 `echo "Mirror dir:  $(bare_mirror_base)"`，保持原行位置。
  2. 把 mirror stats / failed mirrors 整块替换为 `bare_mirror_print_status "$MACHINE"`。
  3. 保持 Snapshot、Build conf、Elapsed time、Next steps 与 `tee` 行为不变。

- [ ] **Step 4: 删除旧 globals 并登记 leaf-pure**
- Change:
  1. 从 `ob` 删除 `STATUS_FAILED=()`、`STATUS_MIRROR_NEW=()`、`STATUS_MIRROR_EXISTING=()`、`MIRROR_BASE=""`。
  2. 在 `tools/exit_contract.py:LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 增加 `'bare_mirror.sh': set(),`。
  3. 不在 `ob` 或 `init_pipeline.sh` 引入同义改名 globals 绕过 shrink check。

- [ ] **Step 5: 运行并确认 interface shrink**
- Run: `! grep -RInE '(^|[^[:alnum:]_])(STATUS_MIRROR_NEW|STATUS_MIRROR_EXISTING|STATUS_FAILED|MIRROR_BASE)($|[^[:alnum:]_])' ob lib/*.sh`
- Expected: 退出 0；旧状态形状不再出现在任何 production Bash 文件，`_BARE_MIRROR_*` 私有名不被精确 token 正则误报。
- Run: `grep -nE '^bare_mirror_(provision|base|print_status)\(\)' lib/bare_mirror.sh`
- Expected: 恰好 3 个 public interface 定义。
- Run: `grep -nE 'bare_mirror_provision|bare_mirror_base|bare_mirror_print_status' lib/init_pipeline.sh`
- Expected: `clone_sub_repos` 调 provision，`print_report` 调 base/status；caller 不读私有 `_BARE_MIRROR_*`。
- Run: `! grep -RIn '_BARE_MIRROR_' ob lib/init_pipeline.sh lib/commands.sh`
- Expected: 退出 0，私有状态只存在 `lib/bare_mirror.sh`。
- Run: `grep -nE '_BARE_MIRROR_INITIALIZED=0|_BARE_MIRROR_INITIALIZED=1' lib/bare_mirror.sh`
- Expected: reset 路径与完整成功路径各有明确 assignment；dry-run 不调用 provision，fatal failure 不得置 1。
- Change: 扩展 `tests/orchestration/bare_mirror_cost.sh`：N=0 成功后断言 `bare_mirror_base` 输出 effective mirror base、`bare_mirror_print_status romulus` 输出 `Mirrors populated: 0 new, 0 existing`；损坏 JSON 直接调用 `bare_mirror_provision` 返回 1 后，断言 `bare_mirror_base` 与 `bare_mirror_print_status romulus` 都输出空。测试只跨 public interface，不读取 `_BARE_MIRROR_INITIALIZED`。

- [ ] **Step 6: 运行行为、成本与 exit 验证**
- Run: `bash tests/orchestration/clone_sub_repos.sh && bash tests/orchestration/bare_mirror_cost.sh && bash tests/protocol/init_machine_state_errors.sh`
- Expected: behavior gold、dry-run/fatal failure 后 report 无 mirror status、损坏 JSON rc=1、Python/Git 成本锁、cmd_init adapter stub 全绿。
- Run: `python3 tools/exit_contract.py`
- Expected: X/Y/Z 全 PASS，Y 已覆盖 `bare_mirror.sh` 且无 exit exception。
- Run: `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 tools/ob_check.sh`
- Expected: extract_funcs、shellcheck、exit-contract 等静态段全绿；不修改 baseline。

- [ ] **Step 7: 可选 checkpoint commit**
- Run: `git add lib/bare_mirror.sh lib/init_pipeline.sh ob tools/exit_contract.py tests/orchestration/bare_mirror_cost.sh && git diff --cached --name-only && git commit -m "refactor(init): extract bare mirror provisioning deep module"`
- Expected: 暂存区只含本 Task 实际变化文件，commit 成功。

### Task 5: surface gate 与长期知识同步

- **目标**：让 module ownership、旧 surface 清零和测试归属成为可机器检查、可被后续 agent 找到的长期约束。
- **Files**:
  - Modify: `tools/ob_check.sh`
  - Modify: `tools/coverage_matrix.md`
  - Modify: `CONTEXT.md`
  - Modify: `rules/03_WORKSPACE.md`
  - Modify: `rules/skills/workflow_01-obmc_env_init.md`
- **接口契约**:
  - Consumes: Task 4 public interface 与旧 globals 清零结果。
  - Produces: `bare mirror legacy surface gate`、`bare mirror provisioning` canonical term、更新后的路由与 coverage 声明。
- **验证范围**：surface gate 能对人工注入的旧名报错；文档不再指向旧 implementation 位置；coverage matrix 与 radar 函数全集一致。

- [ ] **Step 1: 增加 persistent surface gate**
- Change: 在 `tools/ob_check.sh` 现有 surface gates 后增加 `bare mirror legacy surface` 检查：
  - 扫描范围为全部 production Bash：`ob` + `lib/*.sh`，不排除 owner。旧公开 token 在 owner 内同样非法。
  - 使用精确 token 正则 `(^|[^[:alnum:]_])(STATUS_MIRROR_NEW|STATUS_MIRROR_EXISTING|STATUS_FAILED|MIRROR_BASE)($|[^[:alnum:]_])`；不能用裸子串，否则会误命中 `_BARE_MIRROR_BASE`。
  - 有命中则 `bad "bare mirror legacy state surface still in use"` 并打印命中；无命中则 `ok "bare mirror state owned by module"`。
  - 精确 token 正则不会命中 `_BARE_MIRROR_*` 私有名，因此不需要 owner 例外；这比仅靠 review 拒绝 owner 回退更强。

- [ ] **Step 2: 验证 gate 能区分通过与退化**
- Run: `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 tools/ob_check.sh`
- Expected: 输出 `✓ bare mirror state owned by module`，最终退出 0。
- Run:
```bash
bash -c '
set -e
probe_root="${TMPDIR:-/tmp}"
backup=$(mktemp "$probe_root/bare_mirror.sh.XXXXXX")
output=$(mktemp "$probe_root/bare-mirror-gate.XXXXXX")
cp lib/bare_mirror.sh "$backup"
restore() { cp "$backup" lib/bare_mirror.sh; rm -f "$backup" "$output"; }
trap restore EXIT
printf "\n# MIRROR_BASE regression probe\n" >> lib/bare_mirror.sh
set +e
OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 tools/ob_check.sh >"$output" 2>&1
rc=$?
set -e
grep -q "bare mirror legacy state surface still in use" "$output"
[[ "$rc" -eq 1 ]]
'
```
- Expected: 命令退出 0，表示 probe 时 `ob_check` 以 rc=1 拒绝 owner 文件重新引入旧 surface；`trap` 在成功或失败时都恢复原文件并删除临时文件。

- [ ] **Step 3: 更新领域模型与文件路由**
- Change:
  1. `CONTEXT.md` 新增 `bare mirror provisioning`：定义其消费 `deps.json`、使用 effective `DL_DIR/git2`、拥有 URL expansion/rewrite/gitsrcname/clone/disposition/report state；individual clone failure 非致命；与 `source manifest`、`machine snapshot` 正交。
  2. `CONTEXT.md:function semantic layer` 的 module 列表加入 `bare_mirror.sh`，标注 leaf-pure no-direct-exit。
  3. `rules/03_WORKSPACE.md` 的 `ob` 模块化主体路由加入 `bare_mirror.sh` 及职责。
  4. 不创建 ADR；本次不改变跨 module 的持久化或 command-level 决策，仅深化已有 Step 5 implementation。

- [ ] **Step 4: 更新维护入口与 coverage matrix**
- Change:
  1. `rules/skills/workflow_01-obmc_env_init.md` 将“在 `clone_sub_repos()` 的 `_url_rewrites` 数组添加条目”改为“在 `lib/bare_mirror.sh:bare_mirror_provision` 拥有的 URL rewrite table 添加条目”。
  2. `tools/coverage_matrix.md` init 的“子仓库克隆”行更新为 `clone_sub_repos;bare_mirror_provision;bare_mirror_base;bare_mirror_print_status;detect_runtime_git_host`，覆盖测试列加入 `orchestration/bare_mirror_cost.sh`。
  3. `tools/coverage_matrix.md` 横切“路径推导”行删除 `derive_bitbake_git_mirror_path`，保留其他函数。

- [ ] **Step 5: 运行长期知识与门禁验证**
- Run: `grep -n 'bare mirror provisioning' CONTEXT.md && grep -n 'bare_mirror.sh' rules/03_WORKSPACE.md rules/skills/workflow_01-obmc_env_init.md tools/coverage_matrix.md`
- Expected: canonical term、路由、rewrite 维护位置和 coverage 声明均命中。
- Run: `! grep -RIn 'clone_sub_repos.*_url_rewrites\|derive_bitbake_git_mirror_path' rules/skills/workflow_01-obmc_env_init.md tools/coverage_matrix.md`
- Expected: 退出 0，无旧维护指引或旧 helper 声明。
- Run: `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 tools/ob_check.sh`
- Expected: 全部静态检查绿，含新 surface gate。

- [ ] **Step 6: 可选 checkpoint commit**
- Run: `git add tools/ob_check.sh tools/coverage_matrix.md CONTEXT.md rules/03_WORKSPACE.md rules/skills/workflow_01-obmc_env_init.md && git diff --cached --name-only && git commit -m "docs(architecture): register bare mirror provisioning module"`
- Expected: 暂存区只含五个文件，commit 成功。

### Task 6: 最终验证与证据收口

- **目标**：运行从聚焦行为到仓库总门禁的完整验证，确认功能、非功能收益、interface shrink、coverage 与文档一致。
- **Files**:
  - May Modify: `tests/.shellcheck-baseline`，仅限 `ob_check.sh` 良性自动重生成。
- **接口契约**:
  - Consumes: Task 1-5 全部产出。
  - Produces: 可供评审复核的命令输出与最终 diff；不新增 production interface。
- **验证范围**：所有 targeted tests、`ob_check`、coverage radar 和 diff audit 通过。

- [ ] **Step 1: 跑聚焦测试**
- Run: `bash tests/orchestration/clone_sub_repos.sh && bash tests/orchestration/bare_mirror_cost.sh && bash tests/unit/paths.sh && bash tests/protocol/init_machine_state_errors.sh`
- Expected: 每个测试 `FAIL=0` 或对应脚本成功退出；损坏 JSON 为 rc=1；N=0/N=2/N=20 的 Python 总调用数相等且 planner-shaped count 各为 1；三个 case 的 global Git config 写入均为 0；initialized public-interface 断言通过。

- [ ] **Step 2: 跑一站式仓库门禁**
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`、rc=0，包含 extract_funcs、surface gates、shellcheck baseline、exit-contract、默认 protocol/unit/orchestration `.sh` tests。

- [ ] **Step 3: 审核 shellcheck baseline**
- Run: `git diff -- tests/.shellcheck-baseline`
- Expected: 无 diff，或仅行号平移/告警减少；若出现新增告警类型或实例，修 code 后重跑，不提交 baseline 来掩盖。

- [ ] **Step 4: 跑 coverage radar 与 matrix cross-check**
- Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py - --cross-check --fail-if-uncovered 12`
- Expected: rc=0，`UNCOVERED` 不大于 12；matrix 不报告 `bare_mirror_*` typo/过期函数名。若新增 module 函数未覆盖，先补测试，不抬高 `.github/workflows/ob-tests.yml` baseline。

- [ ] **Step 5: 重跑 interface 与副作用硬断言**
- Run: `! grep -RInE '(^|[^[:alnum:]_])(STATUS_MIRROR_NEW|STATUS_MIRROR_EXISTING|STATUS_FAILED|MIRROR_BASE)($|[^[:alnum:]_])' ob lib/*.sh && ! grep -RIn 'git config --global http.postBuffer' ob lib && ! grep -RIn 'derive_bitbake_git_mirror_path' ob lib tests tools/coverage_matrix.md`
- Expected: 退出 0，全部 production Bash 的旧状态 surface、全局 Git 写入和重复 mirror-path helper 清零；精确 token 正则不误报 `_BARE_MIRROR_*`。

- [ ] **Step 6: 审核最终 diff 与范围**
- Run: `git status --short && git diff --stat && git diff --check`
- Expected: 只包含“文件结构与职责”列出的实际变更；无 `workspace/`、ADR、spec、`parse_bitbake_deps.py` 改动；`git diff --check` 无 whitespace error。

## 评审焦点

1. **interface shrink 是否真实**：全部 production Bash 是否不再出现旧 provisioning 状态 token，而不是只在 `init_pipeline.sh` 内改名。
2. **NUL protocol 是否安全**：四字段空值是否保持位置；是否错误使用 command substitution 或 process substitution 承载 planner；checked temp file、动态 FD、record count 和失败清理是否完整。
3. **mirror-path locality**：删除 `derive_bitbake_git_mirror_path` 后，是否只有批量 planner 一份 gitsrcname 算法；behavior gold 是否覆盖 branch 参数截断与 empty `src_uri`。
4. **行为金标是否观察 interface**：测试是否比较 normalized URL/path/disposition、精确 `[FAIL]` 文案和最终 report，而不是读取 module 私有数组。
5. **Git fake 是否理解 `git -c`**：测试 adapter 是否按完整参数形状识别 clone、destination 是否取最后参数；零 global write 是否锁在 fake Git calls 上而不是宿主 `~/.gitconfig` 当前值。
6. **warm path 收益是否被硬锁**：N=0/N=2/N=20 的 Python 总调用数是否相等，planner-shaped count 是否各为 1，断言是否使用文件计数以跨 planner 子进程。
7. **失败与状态语义是否漂移**：malformed 仍 skipped，unresolved/clone failure 仍 failed 且非致命；损坏 JSON / planner protocol failure 仍让 CLI rc=1；initialized flag 在 fatal failure 后保持 0、完整遍历后才为 1；existing/new counts、精确 failure 文案与报告顺序不变。
8. **dry-run 与 init completion**：dry-run 无 module 状态时 report 是否安全；正常路径是否仍只在 Step 8 后写 `init-done marker`。
9. **新 module 分类**：`bare_mirror.sh` 是否无直接 Bash `exit` 且登记 leaf-pure；不要把 `sys.exit` 误判为 Bash exit。
10. **范围控制**：是否误改 Python runtime host resolver、PREMIRRORS、parallel clone、已有 mirror 更新策略或用户全局 Git 配置。

## 执行纪律

- 开始实现前，先批判性复查整份计划；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按 Task 0 -> 6 顺序执行，不要无声跳步、合并步骤或改变任务目标。
- Task 1 的行为金标必须先绿；Task 2/3 的非功能测试必须先红后绿；Task 4 不得在前述锁缺失时开始。
- 每完成一个 Task，运行该 Task 定义的验证；只有 Expected 成立才进入下一 Task。
- 遇到 NUL framing、fake Git 参数、coverage baseline、shellcheck baseline 或现状与计划不符时立即停下说明，不猜测、不放宽断言。
- 当前计划编写时在 `main`；用户未明确同意实现前，不在 `main` 开始代码修改。
- 工作区可能在执行期间出现用户改动；只精确暂存本 Task 文件，不回退、不覆盖无关改动。
- checkpoint commit 只在用户允许提交时执行；不 push、不创建 MR。
- 全部任务完成后，运行 Task 6 最终验证并输出：改动摘要、行为金标结果、损坏 JSON rc、N=0/N=2/N=20 总进程计数与 planner-shaped 计数、initialized public-interface 结果、global Git write 计数、coverage radar 与未运行项。

## 最终验证
```bash
bash tests/orchestration/clone_sub_repos.sh
bash tests/orchestration/bare_mirror_cost.sh
bash tests/unit/paths.sh
bash tests/protocol/init_machine_state_errors.sh
tools/ob_check.sh
tools/trace_collect.sh | python3 tools/coverage_radar.py - --cross-check --fail-if-uncovered 12
! grep -RInE '(^|[^[:alnum:]_])(STATUS_MIRROR_NEW|STATUS_MIRROR_EXISTING|STATUS_FAILED|MIRROR_BASE)($|[^[:alnum:]_])' ob lib/*.sh
! grep -RIn 'git config --global http.postBuffer' ob lib
! grep -RIn 'derive_bitbake_git_mirror_path' ob lib tests tools/coverage_matrix.md
! grep -n 'MIRROR_BASE' lib/util.sh
git diff --check
```
Expected：

- behavior gold 全绿；normalized clone URL / mirror path / disposition、精确 failure 文案与旧行为一致。
- N=0/N=2/N=20 的 Python 总调用数完全相等，三个 planner-shaped count 均恰好为 1。
- N=0 成功后 public report 正常；dry-run 与 fatal planner failure 后 public base/status 均为空。
- `git config --global http.postBuffer` production 调用恰好 0；所有实际 clone 使用 command-scoped `git -c`。
- `ob_check.sh` `ALL GREEN`；coverage radar `UNCOVERED <= 12`。
- 全部 production Bash 的旧 mirror globals、旧 mirror-path helper、`util.sh` stale 注释与错误维护指引清零。
- 无范围外文件和 whitespace error。

## 审阅 Checkpoint

- 实施计划正文到此结束。请先审阅这份计划；审阅通过前不进入实现。
- 审阅无阻塞意见后，下一步由普通编码 agent 或人工按 Task 0 -> 6 执行。