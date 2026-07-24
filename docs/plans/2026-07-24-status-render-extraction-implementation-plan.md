# status presentation module 抽取实施计划

## 目标

把 `lib/commands.sh` 里 4 个 `status_section_*` 渲染函数（`lib/commands.sh:6-193`）抽成独立 leaf-pure 呈现 module `lib/status_render.sh`（函数更名 `status_render_*`），改造成**纯参数注入**（render 只吃已解析数据，不读全局 / 不拉网络 / 不调数据接口），数据采集全部上移到 `cmd_status`。`ob status` 对外输出**字节级不变**。depth 不靠"搬文件"成立，靠 §7 interface-shrink（全局 token 清零）+ 成本锁（网络调用清零）两条 surface gate 证明。

## 架构快照

- 数据 / 呈现 / 编排三分：`machine_state.sh`（数据 module，已有）↔ `status_render.sh`（呈现 module，本次新增，leaf-pure）↔ `cmd_status`（L1 编排，负责 gather → 调 render）。
- 4 个 renderer 签名：`status_render_main_repo` / `status_render_machines` / `status_render_diagnostics` / `status_render_tips`。前三个改吃参数（machines 吃 nameref 数组，每元素 pipe-分隔 raw 记录串），tips 已纯直接搬。
- gather（`machine_state_*` / `qemu_instance_summarize_brief` / `git` upstream / `read_manifest_field`）全部留在 `cmd_status` 内联（单消费者，YAGNI；upstream git fetch v1 留编排层）。
- 与 `qemu_commands.sh`（L1 exit-seam 抽取先例）、`machine_state.sh`（数据 module 先例，ADR-0006）同阵型；`status_render.sh` 是 leaf-pure module，非 exit seam。
- **scope 边界**：只抽 4 个 `status_section_*`。`exit_on_user_cancel`（`commands.sh:200`，build/init/status 共用）留；`cmd_status` 内联的 QEMU Instances 块（`commands.sh:239-256`，调 `qemu_instance_summarize_brief`）**不抽**（编排层允许调数据接口，且非 status_section_*，out of scope，比照 cmd_build python heredoc 处理）；`cmd_build` 内联 python（`commands.sh:355`）不动。

## 全局约束

- **leaf-pure**：`status_render_*` 绝不 `exit`。由 `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 登记 `'status_render.sh': set()`（例外集空）锁定；函数若 exit，Y 规则报「add to leaf-pure exceptions, or remove the exit」。
- **纯参数注入（Design 1）**：renderer 只 `print` stdout，不读全局 `$OPENBMC_DIR`/`$SOURCE_MANIFEST_FILE`、不调 `git`/网络、不调 `machine_state_*`/`qemu_instance_*`/`read_manifest_field`/`read_kv_field`。允许调 `echo`/`printf`/`step_header`/`format_timestamp`/颜色变量/`IFS` 拆分。由 surface gate 静态 grep 锁定（forbidden token 在 `status_render.sh` 内 0 命中）。**颜色变量**（`YELLOW`/`NC`/`CYAN`/`BOLD`，`util.sh` 全局 set-once 常量）作为 renderer 允许的隐式常量继承现状（原 `status_section_*` 即如此用），不纳入 surface gate、不视为 forbidden token——改它需协调整条渲染链，超本次范围。
- **§7 depth 两锁**（bestpractice_10 §7，待抽对象已是 function module）：(a) interface-shrink——forbidden token 清零（renderer 失去对全局/数据接口的知识）；(b) 调用面锁——renderer 对 git/网络的调用面清零。**注意**：系统总网络调用 1→1 不变（`git fetch` 从 renderer 挪到 `cmd_status`），收缩的是 renderer 调用面，**非 bare_mirror 式调用次数压缩**——两类 depth 维度区分见 Task 5。两条合并成 `tests/protocol/status_render_surface.sh` 的静态 grep surface gate。forbidden token 只取 bash 标识符族（`OPENBMC_DIR`/`SOURCE_MANIFEST_FILE`/`machine_state_`/`qemu_instance_`/`read_manifest_field`/`read_kv_field`）+ 完整 git 子命令前缀（`git -C`/`git fetch`/`git remote`/`git rev-`/`git log`）+ `timeout `，**禁用裸英文词**（裸 `fetch`/`git ` 会误伤 renderer 文案，与"strip 注释防误伤"同源问题）。**先红**（Task 2 Step 1 grep 当前 `commands.sh` 的 `status_section_*` body 证明 forbidden token 存在 = 待收缩的违规）**后绿**（抽完 `status_render.sh` 清零）。
- **输出字节不变（golden）**：`cmd_status` 全输出在 fixture 上抽取前后字节级一致（`tests/protocol/status_golden.sh` diff `status_golden.expected` 为空）。这是行为不变量，Task 4 gate。golden 捕获（`>` 重定向落盘）与比对（子壳 `>` 重定向 file-vs-file）**须用同一机制**——**禁用 `$(...)` 命令替换**做捕获/比对（命令替换吞末尾换行，与 `>` 落盘字节不对称，diff 恒非空，N1）。diff 前 **normalize** 抹平 run-specific token（mktemp TMP 目录路径 / recycbox `pid=$$`）——fixture 自带非确定性（TMP 路径出现在 Local path/orphan Path、`$$` PID 出现在 QEMU brief summary），不抹平则 golden 跨 run 永不字节稳定（执行期实测发现，3 轮评审漏抓；R2 误判"golden 稳定"是只看了 `⚠️ stale` 状态词没看 brief summary 里嵌的 PID）。normalize 只抹已知非确定 token，格式/结构/文案变化仍被 diff 抓住。
- **gather 原样透传**：`cmd_status` gather 对 `machine_state_*` 返回值**原样透传**进 record，禁做 `|| echo`/`:-` 兜底或类型转换——否则破坏 golden（如 `machine_state_repo_count` 无 snapshot 时返回 `?`，须以 `?` 进 record；`machine_state.sh:36-44`）。
- **render 形态**：直接 `print` stdout，不返回 string（bash 多行 string 回传 quoting/换行陷阱；stdout 即 render 的合法返回语义）。
- **machine-record 内部契约**：`status_render_machines` 吃 nameref 数组，每元素 pipe-分隔 raw 记录 `name|init_raw|snapshot_state|repo_count|init_time|fw_ready|fw_mtime`（fw_ready 0/1；init_raw ∈ {initialized,partial,<other>}；snapshot_state ∈ {present,<other>}）。字段顺序是 cmd_status(builder)↔renderer(consumer) 内部契约，由 `tests/unit/status_render.sh` 锁往返。emoji/文案映射（✅/⏳/—/📦）在 renderer 内（呈现逻辑归呈现层）。
- **nameref 名约束**：caller 传 renderer 的数组名不得与 renderer 内 nameref local（`_sr_machines_records`/`_sr_diag_records`）同名；caller 用业务名（如 `status_machine_records`）。
- **命名**：snake_case（仓库约定）；`lib/status_render.sh` 遵循 lib 三段结构（header / 函数定义 / 无顶层语句），过 `extract_funcs` 检查。
- **ADR-0006 叙事**：呈现层归宿在该 ADR 留悬（只规定呈现不下沉到 `machine_state` 数据层，未规定呈现落哪个文件），本 module 给归宿——**不**说"刻意推迟"。
- **不立 ADR**：方法论已在 bestpractice_10 §7，本次作为第 2 canonical 实例补进 skill（Task 5），不单立 ADR-0013。
- **upstream git fetch 归属**：v1 留 `cmd_status` 内联（open-question，不进 CONTEXT.md glossary；本计划记录）。

## 输入工件

- 设计：本会话 grill-with-docs 锁定的 10 决策（Q1 纯参数注入 / Q2 单数组+raw 记录串 / Q3 gather 内联 cmd_status / Q4 全静态 grep surface gate / Q5 golden+复用 fixture / Q6 unit+protocol(surface,golden) / Q7 exit_contract set() / Q8 coverage matrix+baseline / Q9 不立 ADR 补 skill §7 / Q10 pin→optimize→deepen）。
- 评审：Approve + 🟡(§7 两锁 / ADR-0006 叙事修正) + 🟢(machines 三态回归 / 术语 status presentation module / F7 全限定名 grep)。
- 术语：`CONTEXT.md` 已落 `status presentation module`（本会话 grill 期间写入）。
- 无独立设计文档（grill 产出即设计）。

## 文件结构与职责

- **Create**: `lib/status_render.sh` — 4 个 `status_render_*`，leaf-pure 呈现 module。
- **Create**: `tests/lib/status_fixtures.sh` — `status_build_fixture <tmp>`，从 `status_machine_state.sh:8-61` 抽出的 workspace + 6 fixture machine + stale QEMU pids 搭建（既有测 + 新 golden 测共享）。
- **Create**: `tests/unit/status_render.sh` — 4 renderer 纯参数单测（喂 params/记录 → 断言 stdout）。
- **Create**: `tests/protocol/status_render_surface.sh` — §7 静态 grep surface gate（forbidden token 清零）。
- **Create**: `tests/protocol/status_golden.sh` + `tests/protocol/status_golden.expected` — `cmd_status` 全输出字节级 golden 回归。
- **Modify**: `lib/commands.sh` — 删 4 个 `status_section_*`（`:6-193`），`cmd_status`（`:210-257`）改为 gather → 调 `status_render_*`。
- **Modify**: `tests/protocol/status_machine_state.sh` — 内联 setup（`:8-61`）改为 source `status_fixtures.sh` + `status_build_fixture`，保留其 assertions + `machine_state_records` override。
- **Modify**: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'status_render.sh': set(),`。
- **Modify（ob_check.sh 自动重生成）**: `tests/.shellcheck-baseline` — 新增 lib 文件触发 flat 合成变化，Task 6 跑 `ob_check.sh` 后 git diff 确认良性。
- **Modify**: `rules/03_WORKSPACE.md`（lib 路由行）+ `tools/coverage_matrix.md`（`## status` 加行）+ `rules/skills/bestpractice_10-deep_module_extraction.md`（§7 第 2 实例）— deferred doc，Task 5。

接口依赖：Task 1 Produces `status_fixtures.sh` + `status_golden.expected`（锁现状）→ Task 4 Consumes；Task 2 Produces `status_render_*` + exit_contract 登记 → Task 3/4 Consumes；Task 3 Produces renderer 单测 → Task 4 验证；Task 4 Produces 接线后全绿 → Task 5 Consumes。

## 任务清单

### Task 1: pin — 抽 fixture 进 status_fixtures.sh + 捕获 golden

- 目标：抽取前先钉死当前 `cmd_status` 输出（字节级 golden）并把 fixture 复用化，作为后续抽取的回归 oracle。**先 pin 再动结构。**
- 涉及文件：Create `tests/lib/status_fixtures.sh`；Create `tests/protocol/status_golden.sh`；Create `tests/protocol/status_golden.expected`；Modify `tests/protocol/status_machine_state.sh`。
- 接口契约
  - Consumes: `status_machine_state.sh:8-61` 的现有 fixture setup（TMP 派生 / `write_snapshot` / `write_marker` / 6 machine / QEMU pids）；`ob_loader.sh`（source ob 函数）。
  - Produces: `status_build_fixture <tmp>`（设 `WORKSPACE_DIR`/`CONFIGS_DIR`/`OPENBMC_DIR`/`SOURCE_MANIFEST_FILE` 全局 + 造 fixture，返回 0）；`status_golden.expected`（当前 `cmd_status` 全输出快照）。
- 验证范围：`status_machine_state.sh` refactor 后仍绿 + `status_golden.sh` 绿（live == committed expected）+ `run_all.sh` 绿。

- [ ] Step 1: 写当前缺失检查
- Run: `test ! -f tests/lib/status_fixtures.sh && ! -f tests/protocol/status_golden.sh`
- Expected: 退出码 0（fixture helper 与 golden 测均不存在，pin 基础设施缺失）。
- [ ] Step 2: 运行并确认当前缺失
- Run: 同上
- Expected: 退出码 0。
- [ ] Step 3: 写最小实现
- Change:
  1. 新建 `tests/lib/status_fixtures.sh`，把 `status_machine_state.sh:8-61` 的 setup 抽成 `status_build_fixture <tmp_root>`（设 4 个全局 dir + mkdir + 造 `legacy.lock`/`snaponly`/`markeronly`/`failm`/`built`/`orphan` 6 machine + `stalebox`/`recycbox` stale QEMU pids）；`write_snapshot`/`write_marker` 作为模块级 helper（保持原签名，供后续 golden 测按需追加 machine）。逐字搬现有 setup 逻辑，不改 fixture 行为。
  2. 改 `tests/protocol/status_machine_state.sh`：删 `:11-61` 的内联 setup，替换为 `source "$(dirname "$0")/../lib/status_fixtures.sh"` + `TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; status_build_fixture "$TMP"`。保留 `:63-66` 的 `machine_state_records` override、`:68+` 的全部 assertion 不动。
  3. 新建 `tests/protocol/status_golden.sh`：source `ob_loader.sh` + `status_fixtures.sh`，`TMP=mktemp; trap 'rm -rf "$TMP"' EXIT; status_build_fixture "$TMP"`。**live 输出用子壳+重定向捕获**（**禁用 `$(...)` 命令替换**——它吞末尾换行，与 Step 4 的 `>` 落盘 expected 字节不对称、diff 恒非空，N1 实测确认）：`( cmd_status ) > "$TMP/live.out" 2>&1`（子壳隔离 `cmd_status` 的 L1 exit 契约，不杀测试 shell）。**diff 前抹平 run-specific token**（fixture 的 mktemp TMP 目录路径出现在 Local path/orphan Path；recycbox `pid=$$` 出现在 QEMU brief summary——不抹平则 golden 跨 run 永不字节稳定，执行期实测发现）：`normalize() { sed -e 's|/tmp/tmp\.[A-Za-z0-9]*|<TMP>|g' -e 's|PID [0-9][0-9]*|PID <pid>|g' "$1"; }`；末命令 `diff -u <(normalize "$(dirname "$0")/status_golden.expected") <(normalize "$TMP/live.out")`（diff 非零即 fail，退出码透传）。先**不**提交 expected——Step 4 生成。
- [ ] Step 4: 生成 golden + 确认通过
- Run: `bash tests/protocol/status_machine_state.sh`（refactor 后须绿）；`bash -c 'set +e; source tests/lib/ob_loader.sh; source tests/lib/status_fixtures.sh; T=$(mktemp -d); status_build_fixture "$T"; cmd_status 2>&1' > tests/protocol/status_golden.expected`（从当前 `cmd_status` 捕获 golden，提交作 oracle）；`bash tests/protocol/status_golden.sh && tests/run_all.sh`
- Expected: refactor 后 `status_machine_state.sh` 绿（assertion 全过）；golden expected 生成后 `status_golden.sh` diff 为空（退出码 0）；`run_all.sh` 绿。**此 expected 即抽取回归 oracle，Task 4 不许改它。**
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add tests/lib/status_fixtures.sh tests/protocol/status_golden.sh tests/protocol/status_golden.expected tests/protocol/status_machine_state.sh && git commit -m "test(status): extract status_fixtures.sh + capture golden output (pin before render extraction)"`
- Expected: commit 成功。

### Task 2: 建 lib/status_render.sh（leaf-pure 参数化 renderer）+ exit_contract 登记 + surface gate

- 目标：创建 4 个纯参数注入的 `status_render_*`（未接线），登记 exit_contract LEAF，写 §7 surface gate（先红 demo 后绿）。
- 涉及文件：Create `lib/status_render.sh`；Create `tests/protocol/status_render_surface.sh`；Modify `tools/exit_contract.py`。
- 接口契约
  - Consumes: `format_timestamp`（`lib/util.sh`，纯字符串格式化）、`step_header`/`YELLOW`/`NC`（`lib/util.sh`）、当前 `status_section_*`（`commands.sh:6-193`）的格式逻辑（作 parameterization 蓝本）。
  - Produces: `status_render_main_repo(repo_exists,origin_url,source_label,branch,commit,upstream_display,first_init,local_path)` / `status_render_machines(records_nameref)` / `status_render_diagnostics(orphan_records_nameref)` / `status_render_tips(repo_exists,has_init,has_init_no_fw)`（均 leaf-pure，恒返回 0）；`'status_render.sh': set()` 进 LEAF dict；surface gate。
- 验证范围：`exit_contract.py` exit 0 + `extract_funcs` 三段合规 + surface gate 绿（forbidden token 0 命中）+ 当前 `commands.sh` 的 `status_section_*` forbidden token 仍存在（先红 demo）。

- [ ] Step 1: 写先红 demo（证明收缩目标真实存在）
- Run: `grep -nE 'OPENBMC_DIR|machine_state_init_state|git fetch|read_manifest_field' lib/commands.sh | head`
- Expected: 命中 `status_section_*` 区域（`:9`/`:31`/`:76` 等附近）——证明当前 renderer body 含 forbidden token（全局/数据接口/网络），是 surface gate 要防的违规。记录命中行作 Step 4 对照。
- [ ] Step 2: 运行并确认当前违规存在
- Run: 同上
- Expected: 命中非空（违规成立，shrink 有意义）。
- [ ] Step 3: 写最小实现
- Change:
  1. `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（`:53-73`）加 `'status_render.sh': set(),`。**插入位置无要求**——Y 规则按 basename 迭代 dict、不校验内部顺序；按可读序（如 `machine_picker.sh` 与 `qemu_instance.sh` 之间）插入即可。
  2. 新建 `lib/status_render.sh`：

```bash
#!/usr/bin/env bash
# lib/status_render.sh — status presentation module(leaf-pure)。
#   ob status 仪表盘呈现层:把 cmd_status 已采集的事实格式化为 stdout(表格/diagnostics 段/tips)。
#   纯参数注入——绝不读全局($OPENBMC_DIR/$SOURCE_MANIFEST_FILE)、绝不拉网络(git/timeout)、
#   绝不调数据接口(machine_state_*/qemu_instance_*/read_manifest_field);数据全由 cmd_status 以参数喂入。
#   呈现逻辑(emoji 映射/列宽/分段)归本 module。术语见 CONTEXT.md status presentation module。
# Exit: leaf-pure module(函数绝不 exit; 只 print stdout); exit-code/remedy/采集归 cmd_status(L1)。

# status_render_main_repo <repo_exists 0/1> <origin_url> <source_label> <branch> <commit> <upstream_display> <first_init> <local_path>
status_render_main_repo() {
    local repo_exists="$1" origin_url="$2" source_label="$3" branch="$4"
    local commit="$5" upstream_display="$6" first_init="$7" local_path="$8"
    step_header "OpenBMC Main Repository"
    if [[ "$repo_exists" -eq 0 ]]; then
        echo "  Status       : missing"
        return 0
    fi
    local source_display="${origin_url:-<no origin>}${source_label:+ ($source_label)}"
    echo "  Status       : present"
    echo "  Source       : $source_display"
    echo "  Local path   : $local_path"
    echo "  Branch       : ${branch:-<unknown>}"
    echo "  Commit       : ${commit:-<unknown>}"
    echo "  Upstream     : ${upstream_display:-⚠️ unreachable (skipped)}"
    echo "  First init   : ${first_init:-<unknown>}"
}

# status_render_machines <records_nameref>
# records 每元素: name|init_raw|snapshot_state|repo_count|init_time|fw_ready(0/1)|fw_path|fw_mtime
status_render_machines() {
    local -n _sr_machines_records="$1"
    step_header "Machines"
    if [[ ${#_sr_machines_records[@]} -eq 0 ]]; then
        echo "  (none)"
        return 0
    fi
    printf "  %-22s %-15s %s\n" "Machine" "Init" "Firmware Image"
    local _rec _name _init_raw _snap _repos _init_time _fw_ready _fw_path _fw_mtime _init_disp _fw_disp _padded
    for _rec in "${_sr_machines_records[@]}"; do
        IFS='|' read -r _name _init_raw _snap _repos _init_time _fw_ready _fw_path _fw_mtime <<< "$_rec"
        case "$_init_raw" in
            initialized) _init_disp="✅ initialized" ;;
            partial)      _init_disp="⏳ partial" ;;
            *)            _init_disp="— uninitialized" ;;
        esac
        if [[ "$_fw_ready" == "1" ]]; then _fw_disp="📦 ready"; else _fw_disp="— missing"; fi
        printf -v _padded "%-22s" "$_name"
        printf "  %b%-15s %s\n" "${YELLOW}${_padded}${NC}" "$_init_disp" "$_fw_disp"
    done
    for _rec in "${_sr_machines_records[@]}"; do
        IFS='|' read -r _name _init_raw _snap _repos _init_time _fw_ready _fw_path _fw_mtime <<< "$_rec"
        [[ "$_snap" == "present" ]] || continue
        echo ""
        echo "  ── $_name ──────────────────────────────────────"
        local _it=""
        [[ -n "$_init_time" ]] && _it=$(format_timestamp "$_init_time")
        echo "    Init time    : ${_it:--}"
        echo "    Repos        : ${_repos:--}"
        if [[ "$_fw_ready" == "1" && -n "$_fw_path" ]]; then
            local _ft="-"
            [[ -n "$_fw_mtime" ]] && _ft=$(format_timestamp "$_fw_mtime")
            echo "    Firmware time: $_ft"
            echo "    Firmware name: $(basename "$_fw_path")"
            echo "    Firmware path: $(dirname "$_fw_path")/"
        fi
    done
}

# status_render_diagnostics <orphan_records_nameref>  每元素: name|path
status_render_diagnostics() {
    local -n _sr_diag_records="$1"
    [[ ${#_sr_diag_records[@]} -gt 0 ]] || return 0
    echo ""
    step_header "Diagnostics"
    echo "  Orphan firmware image artifacts"
    local _rec _name _path
    for _rec in "${_sr_diag_records[@]}"; do
        IFS='|' read -r _name _path <<< "$_rec"
        echo ""
        echo "    $_name"
        echo "      Path      : ${_path:-<unknown>}"
        echo "      Reason    : firmware image artifact exists, but machine init is incomplete"
        echo "      Next step : ob init $_name"
    done
}

# status_render_tips <repo_exists 0/1> <has_init 0/1> <has_init_no_fw 0/1>
status_render_tips() {
    local repo_exists="$1" has_init="$2" has_init_no_fw="$3"
    local tip=""
    if   [[ "$repo_exists"  -eq 0 ]]; then tip="💡 Run 'ob init' to get started."
    elif [[ "$has_init"     -eq 0 ]]; then tip="💡 Run 'ob init' to initialize a machine."
    elif [[ "$has_init_no_fw" -eq 1 ]]; then tip="💡 Run 'ob build <machine>' to produce a firmware image."
    fi
    # 用 if 不用 `[[ -n $tip ]] && {...}`:后者 tip 为空时返回非零,作为函数末句会使 renderer
    # 返回 1,在 cmd_status 的 set -e 上下文触发退出(bestpractice_07 短路 && 陷阱;Task 4 实测发现,
    # unit/golden 用 set +e 测不出,只有真实 ./ob 的 set -e 路径暴露)。
    if [[ -n "$tip" ]]; then
        echo ""
        echo "  $tip"
    fi
}
```

  3. 新建 `tests/protocol/status_render_surface.sh`：

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$ROOT/lib/status_render.sh"
test -f "$RENDER" || { echo "MISSING $RENDER" >&2; exit 1; }
# §7 interface-shrink + 调用面锁:status_render.sh 内 forbidden token 必须 0 命中(渲染器纯格式化层)。
# forbidden 只取 bash 标识符族 + 完整 git 子命令前缀;禁用裸英文词(裸 fetch / git 带空格会误伤
# 将来 renderer 文案如 "fetch latest firmware" / "dig into git log")。命中即真违规,零误报。
forbidden=( 'OPENBMC_DIR' 'SOURCE_MANIFEST_FILE' 'machine_state_' 'qemu_instance_' \
            'read_manifest_field' 'read_kv_field' \
            'git -C' 'git fetch' 'git remote' 'git rev-' 'git log' 'timeout ' )
body="$(grep -v '^[[:space:]]*#' "$RENDER")"   # 只 grep 非注释行:header docstring 列了 forbidden token 作"不读"说明,裸 grep 会误伤
for tok in "${forbidden[@]}"; do
    assert_false "render forbids $tok" grep -Fq "$tok" <<< "$body"
done
assert_summary
```

- [ ] Step 4: 运行并确认通过
- Run: `test -f lib/status_render.sh && grep -q "'status_render.sh': set()," tools/exit_contract.py && python3 tools/exit_contract.py && python3 tools/extract_funcs.py lib/status_render.sh >/dev/null && bash tests/protocol/status_render_surface.sh`
- Expected: 退出码 0（文件存在 + LEAF 登记 + Y 规则覆盖且无真 exit + 三段合规 + surface gate 全过 forbidden token 0 命中）。shellcheck baseline 留 Task 6。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/status_render.sh tools/exit_contract.py tests/protocol/status_render_surface.sh && git commit -m "feat(status): add lib/status_render.sh leaf-pure presentation module + §7 surface gate + exit_contract LEAF"`
- Expected: commit 成功。

### Task 3: tests/unit/status_render.sh 纯参数单测

- 目标：unit 层覆盖 4 renderer 的格式化（emoji 映射 / 表格列 / diagnostics 段 / tips 分支），锁 machine-record 内部契约往返。零依赖（喂参数，无函数 override，radar 友好）。
- 涉及文件：Create `tests/unit/status_render.sh`。
- 接口契约
  - Consumes: Task 2 的 4 个 `status_render_*`。
  - Produces: `tests/unit/status_render.sh`（`run_all.sh` 自动 glob 纳入）。
- 验证范围：`bash tests/unit/status_render.sh` 退出码 0（assert_summary 全过）。

- [ ] Step 1: 写当前缺失检查
- Run: `test ! -f tests/unit/status_render.sh`
- Expected: 退出码 0（单测不存在）。
- [ ] Step 2: 运行并确认当前缺失
- Run: 同上
- Expected: 退出码 0。
- [ ] Step 3: 写最小实现
- Change: 新建 `tests/unit/status_render.sh`，source `ob_loader.sh` + `assert.sh`。镜像 `tests/unit/machine_state.sh` 的 here-string/数组喂法。case：
  - **main_repo**：① `repo_exists=0` → 输出含 `Status       : missing` 且不含 `present`。② `repo_exists=1` + 全参数 → 含 `present`/`Source`/`Branch`/`Upstream` 行；`upstream_display` 透传（喂 `"✅ up-to-date"` 断言输出含它）。
  - **machines**：构造数组 `("romulus|initialized|present|42|2026-06-23T01:02:03Z|1|/tmp/deploy/romulus.static.mtd|2026-06-23T02:00:00Z" "partial1|partial|missing|3||0||")` → 断言 summary 表含 `✅ initialized` + `📦 ready` + `— missing`；断言 expansion 段含 `romulus` 的 `Init time`（`format_timestamp` 后非 `<unknown>`）/`Repos        : 42`/`Firmware name: romulus.static.mtd`，且 `partial1`（snapshot=missing）**不**进 expansion 段（`assert_false` grep `── partial1`）。
  - **record 往返锁**：喂一条全字段记录，断言 8 字段都被正确拆分消费（如 `repo_count` 出现在 `Repos` 行）——钉死字段顺序契约。
  - **diagnostics**：数组 `("orphan1|/tmp/orphan.static.mtd")` → 含 `Diagnostics`/`Orphan firmware image artifacts`/`orphan1`/`Next step : ob init orphan1`；空数组 → 无 Diagnostics 段输出（函数早 return）。
  - **tips**：`(0,*,*)` → `Run 'ob init' to get started`；`(1,0,*)` → `to initialize a machine`；`(1,1,1)` → `to produce a firmware image`；`(1,1,0)` → 无 tip 行。
  - **nameref 业务名自检（F2）**：用**非 `_sr_` 前缀**的数组名（如 `my_machine_recs`）喂 `status_render_machines`，断言正常输出——钉死"caller 数组名不得与 renderer 内 `_sr_*` local nameref 同名"契约（同名触发 bash circular name reference 运行时炸，报错晦涩；header docstring 同步注明此约束）。
  - **leaf-pure 验证**：失败/空态（如 machines 空数组）renderer 恒返回 0（能跑到 assert 即证明 return 非 exit）。
  - 收尾 `assert_summary`。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/status_render.sh && test -z "$(bash tests/unit/status_render.sh 2>&1 | tail -1 | grep -i 'fail')"`
- Expected: 退出码 0（全过 + 无 FAIL 行）。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add tests/unit/status_render.sh && git commit -m "test(status): status_render unit (main_repo/machines/diagnostics/tips + record contract)"`
- Expected: commit 成功。

### Task 4: cmd_status gather→render 接线 + 删旧 status_section_* + golden diff 空

- 目标：把 `cmd_status` 改为 gather 全部数据 → 调 4 个 `status_render_*`；删 `commands.sh` 的 4 个 `status_section_*`。**输出字节级不变**（golden diff 空）。
- 涉及文件：Modify `lib/commands.sh`（删 `status_section_*` `:6-193`；改写 `cmd_status` `:210-257`）。
- 接口契约
  - Consumes: Task 2 的 `status_render_*`；Task 1 的 `status_golden.expected`（oracle）；`machine_state_*`（`machine_state.sh`）、`qemu_instance_list`/`qemu_instance_summarize_brief`（`qemu_instance.sh`）、`read_manifest_field`/`format_timestamp`（`util.sh`）。
  - Produces: `cmd_status` 改为 gather+render 编排（~75 行）；`commands.sh` 内 `status_section_` 计数归 0。
- 验证范围：`commands.sh` 内 `status_section_` grep = 0 + **golden diff 空** + `status_machine_state.sh` 绿 + `run_all.sh` 绿 + `ob_check.sh` 绿。

- [ ] Step 1: 写当前状态检查
- Run: `test "$(grep -c 'status_section_' lib/commands.sh)" -ge 4`
- Expected: 退出码 0（当前 4 个 status_section_* 仍内联在 commands.sh，待删）。
- [ ] Step 2: 运行并确认当前状态
- Run: 同上
- Expected: 退出码 0。
- [ ] Step 3: 写最小实现
- Change: **定位用符号锚点（函数名），行号仅辅助，动手前 `grep -n 'status_section_\|^cmd_status' lib/commands.sh` 重锚**。
  1. 删 `commands.sh:6-193`（4 个 `status_section_*` + 其间空行）。`exit_on_user_cancel`（`:200-208`）**保留**。
  2. 改写 `cmd_status`（当前 `:210-257`）：把原 4 次 section 调用替换为 gather + render。新增 gather：
     - main_repo：`local repo_exists=0; [[ -d "$OPENBMC_DIR/.git" ]] && repo_exists=1`；present 时 gather `origin_url`（`git ... remote get-url origin`）、`source_label`/`first_init`（`read_manifest_field`）、`branch`/`commit`（`git rev-parse`/`git log`）、`upstream_display`（原 `:31-42` 的 `timeout 10 git fetch` + ahead/behind 计算块**整段搬进 cmd_status**）、`local_path=$OPENBMC_DIR`。
     - machines：`local -a status_machine_records=()`；`while read m < <(machine_state_display_machines)` 内对每 machine 调 `machine_state_init_state`/`snapshot_state`/`repo_count`/`init_time`/`is_firmware_image_ready`/`firmware_image_path`/`firmware_image_mtime`，拼成 `name|init_raw|snapshot_state|repo_count|init_time|fw_ready|fw_path|fw_mtime` 压进数组（**字段顺序与 status_render_machines docstring 逐字一致**）。
     - diagnostics：`local -a status_orphan_records=()`；`while read m < <(machine_state_orphan_firmware_image_machines)` 取 `machine_state_firmware_image_path` 拼 `name|path`。
     - tips：`has_init`/`has_init_no_fw` 沿用原 `:226-235` 逻辑（遍历 `machine_state_initialized_machines`）。
     - 调用：`status_render_main_repo "$repo_exists" "$origin_url" "$source_label" "$branch" "$commit" "$upstream_display" "$first_init" "$OPENBMC_DIR"`；`echo ""`；`status_render_machines status_machine_records`；`status_render_diagnostics status_orphan_records`；`status_render_tips "$repo_exists" "$has_init" "$has_init_no_fw"`。
     - **QEMU Instances 块（原 `:239-256`）原样保留在 cmd_status**（out of scope，编排层允许调 `qemu_instance_*`）。
  3. **不改任何文案/emoji/列宽/空行**——render 已在 Task 2 逐字镜像现状，gather 只搬采集不改格式。main_repo 的 `echo ""`（section 间空行，原 `:217`）保留位置。
- [ ] Step 4: 运行并确认通过
- Run: `test "$(grep -c 'status_section_' lib/commands.sh)" -eq 0 && bash tests/protocol/status_golden.sh && bash tests/protocol/status_machine_state.sh && tests/run_all.sh && tools/ob_check.sh`
- Expected: 退出码 0（status_section_ 归 0 + **golden diff 空** + status_machine_state 绿 + run_all 绿 + ob_check 绿）。**若 golden diff 非空**：停下，diff 出的行即 gather/render 与现状的偏差，回 Step 3 对齐（通常是空行/字段顺序/emoji），不改 golden expected。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add lib/commands.sh && git commit -m "refactor(status): cmd_status gather→status_render_*; delete status_section_* (output byte-identical)"`
- Expected: commit 成功。

### Task 5: deferred doc 同步（WORKSPACE + coverage_matrix + skill §7 第 2 实例）

- 目标：登记新 module 进路由表 / 覆盖矩阵 / skill，恢复可观测性并固化 §7 模式。
- 涉及文件：Modify `rules/03_WORKSPACE.md`（lib 路由行）；Modify `tools/coverage_matrix.md`（`## status`）；Modify `rules/skills/bestpractice_10-deep_module_extraction.md`（§7 实例）。
- 接口契约
  - Consumes: Task 1-4（文件真存在 + 测试真写 + 全绿 + surface gate 真锁住 forbidden token）。
  - Produces: 三处 doc 含 `status_render` / `status presentation module`。
- 验证范围：三文件 grep 命中。

- [ ] Step 1: 写当前缺失检查
- Run: `! grep -q "status_render.sh" rules/03_WORKSPACE.md && ! grep -qi "status_render" tools/coverage_matrix.md`
- Expected: 退出码 0（两文件未收录）。
- [ ] Step 2: 运行并确认当前缺失
- Run: 同上
- Expected: 退出码 0。
- [ ] Step 3: 写最小实现
- Change:
  1. `rules/03_WORKSPACE.md` 的 `lib/` 路由行（`:11`），在 `machine_state.sh` 附近按族序插入 `status_render.sh`（status presentation module，`ob status` 仪表盘呈现层 leaf-pure，4 个 status_render_*）。
  2. `tools/coverage_matrix.md` 的 `## status` 章节（`:39`）加两行：(a) `| 仪表盘呈现(表格/diagnostics 段/tips 排版+emoji) | status_render_main_repo;status_render_machines;status_render_diagnostics;status_render_tips | unit/status_render.sh | leaf-pure(status_render.sh);纯参数注入,不采集数据 |`；(b) `| status_render leaf-pure surface 门禁 | (forbidden token 清零) | protocol/status_render_surface.sh | out-of-radar(surface gate 回归锁,cross-check out-of-scope) |`（仿 `:106` machine_state records 门禁写法）。**勿动既有 `machine lifecycle state 展示/诊断` 行**（它记的是数据层 `machine_state_*`，与呈现层正交）。
  3. `rules/skills/bestpractice_10-deep_module_extraction.md` §7（`:26`），把 canonical 实例扩为**两类 depth 维度**的并列实例，明确二者均属 §7 合格的 `optimizable 收益`：(a) **成本量下降**——`bare_mirror.sh`(2026-07-12，NUL 批量 planning 把 $2+4N 次 Python 压成 1 次)；(b) **surface 收缩**——`status_render.sh`(2026-07-24，已是 function module 的 `status_section_*` 抽呈现层，renderer 失去对全局/网络/数据接口的知识，surface gate 证 forbidden token 清零；**系统总网络调用 1→1 不变**，收缩的是 renderer 调用面非调用次数)。避免 future agent 误以为"只有调用次数压缩才算 depth"，漏掉 surface 收缩这条独立 depth 证明路径。
- [ ] Step 4: 运行并确认通过
- Run: `grep -q "status_render.sh" rules/03_WORKSPACE.md && grep -qi "status_render" tools/coverage_matrix.md && grep -q "status_render.sh" rules/skills/bestpractice_10-deep_module_extraction.md && tools/trace_collect.sh | python3 tools/coverage_radar.py - --cross-check`
- Expected: 退出码 0（三处 doc 均收录 + radar cross-check 不报 status_render_* 为 uncovered——它们由 `unit/status_render.sh` 覆盖，matrix 已声明）。**若 radar 报 status_render_* uncovered**（不应发生，已 unit 覆盖）：按 [bestpractice_10:23](../../rules/skills/bestpractice_10-deep_module_extraction.md) 重校 coverage baseline（模块化致 baseline 降是正常，不造假覆盖率），停下说明再继续。
- [ ] Step 5: 可选 checkpoint commit
- Run: `git add rules/03_WORKSPACE.md tools/coverage_matrix.md rules/skills/bestpractice_10-deep_module_extraction.md && git commit -m "docs(status): register status_render.sh in WORKSPACE/coverage_matrix + bestpractice_10 §7 2nd instance"`
- Expected: commit 成功。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 动手前事实核对（行号会漂，事实锚定）：`grep -n 'status_section_\|^cmd_status\|^exit_on_user_cancel' lib/commands.sh`（确认 4 个 section 在 cmd_status 前、exit_on_user_cancel 夹中）；`grep -n 'machine_state_repo_count\|machine_state_display_machines\|machine_state_orphan_firmware_image_machines' lib/machine_state.sh`（确认 gather 依赖接口存在）；`! grep -q 'status_render.sh' tools/exit_contract.py`（避免重复登记）。
- 计划所引行号均为当前快照、会随改动漂移；每个 Task 动手前用 `grep -n` 按符号锚点（函数名 / case 模式 / dict key）重对一遍行段，不把行号当唯一契约。
- 迁移用全限定名 + 调用点双向核对（F7 防 grep 漏，正则用 `[a-z0-9_]+`）：`status_section_*` → `status_render_*` 重命名后，`grep -rn 'status_section_' lib/ tests/ tools/`（排除 `workspace/`）须清零。
- 按任务顺序执行（pin → 建模块+gate → unit → 接线+golden → doc），不无声跳步、合并步或改任务目标。
- 每完成一个任务，运行该任务定义的验证（退出码归位，grep 门禁化）。
- **golden expected 是 oracle，Task 4 不许改它**；diff 非空即 gather/render 偏差，对齐代码不改 expected。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 当前在 `feature/ob-dev-build` 分支（非 main）；继续在此分支提交，working tree commit 是安全迭代手段。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh && tests/run_all.sh --full && git diff --stat`
- Expected: `ob_check.sh` 与 `run_all.sh --full` 均退出码 0（`ALL GREEN`）；`git diff --stat` 显示新增 `lib/status_render.sh` / `tests/lib/status_fixtures.sh` / `tests/unit/status_render.sh` / `tests/protocol/status_render_surface.sh` / `tests/protocol/status_golden.sh` / `tests/protocol/status_golden.expected`，修改 `lib/commands.sh` / `tests/protocol/status_machine_state.sh` / `tools/exit_contract.py` / `rules/03_WORKSPACE.md` / `tools/coverage_matrix.md` / `rules/skills/bestpractice_10-deep_module_extraction.md` / `tests/.shellcheck-baseline` / `CONTEXT.md`。
- 环境：bash + 仓库根目录；`expect` 需已安装（`run_all.sh --full` 的 `.exp` 层，缺失则该层 skip，非失败）。

## 审阅 Checkpoint

- 计划正文结束。请先确认这份计划；如果没问题，下一步可按计划由普通编码 agent 或人工继续执行。
- 审阅通过前，不进入实现。
