# ob test-qemu 前置检查重排与 dry-run 前置集豁免 实施计划

## 目标

- `cmd_test_qemu`（`lib/qemu_commands.sh`）的前置检查按**缺失时用户修复成本**重排：baseline 谱系+目录检查与凭据检查前移到 QEMU liveness 之前，让结构性缺失（baseline 目录不存在）先于重投入前置（编译 image + 启动 QEMU）暴露。
- `--dry-run` 豁免 QEMU 相关前置（liveness + port）与凭据检查：dry-run 只验 baseline 资产（AR 列表 + applicability），runner（`tests/baseline/<machine>/runner/run.sh`）的 `DRY_RUN=0` 分支已原生支持无 host/port/凭据，cmd 层解除不必要的严格化。
- 同步 usage 文案（`ob` 主文件 + `test_qemu_usage`）、protocol 测试、CONTEXT.md `ob test-qemu` 词条。

## 架构快照

重排后的 `cmd_test_qemu` 前置顺序（probe 与 dry-run 共享前缀，虚线后分叉）：

```
前置 1: machine 必填                    （不动，qemu_commands.sh 现状 939-955 区域）
PyYAML                                  （不动，现状 957-962 区域）
前置 2: baseline 谱系+目录               （原"前置 3"整体前移，现状 986-1025 区域）
  ── dry-run 与 probe 共有：planner 输入 ──
前置 3: 凭据解析                         （原 liveness 后段前移，现状 1030-1070 区域）
  套 if [[ $_dry -eq 0 ]]               （dry-run 不 probe，凭据无用）
  ── 仅 probe（[[ $_dry -eq 0 ]]）：──
前置 4: derive_qemu_paths + lifecycle lock + liveness + port 读取
                                        （原"前置 2"整体后移，现状 964-984 + 1027-1028 区域）
runner 调用: _run_args 条件附加 --host/--port; info 文案分叉; lock release 条件化
rc 映射                                  （不动，现状 1090-1100 区域）
```

依赖事实（grilling 阶段已核实）：baseline 段只依赖 `detect_harness_root`（`cmd_test_qemu` 首行已调用）设置的 `SOURCE_MANIFEST_FILE`/`HARNESS_ROOT`；凭据段只依赖 baseline 目录（读 `ar_probes.yaml` auth）；两段均零 QEMU 依赖，前移无损。dry-run 下 `PIDFILE_REDFISH_PORT` 不再被消费（run.sh dry-run 分支不校验 host/port）。

## 全局约束

- **不建 ADR**（grilling 共识 5）：排序原则写在 `cmd_test_qemu` 前置段块注释，一段话；ADR-0025/0026 不动。
- **排序原则注释**：前置段注释把"对齐 cmd_smoke"叙事改为"按缺失时用户修复成本排序（结构性/零成本本地检查在前，QEMU 运行态在后）；liveness 段本身与 cmd_smoke 同构"。
- **remedy line 单步接力契约不变**（CONTEXT.md `remedy line` 词条）：所有 exit 3 复用现有 remedy 文案，不串接多步；不收集式报缺。
- **dry-run 成功语义 = exit 0**，对齐 run.sh usage 的 `-d, --dry-run ... exit 0`；不新增 exit 字面量，exit-contract X 规则无新值。
- **凭据不落 argv 规则不变**（现状评审 🟡2）：凭据仍经 env 注入 runner；dry-run 跳过凭据段时不 export。
- **CONTEXT.md 只补 dry-run 前置集语义**；"按修复成本排序"是实现细节，不进 glossary。
- **不动清单**：`cmd_smoke` 代码；machine 为空且无实例时的提示（qemu_commands.sh 现状 945 区域）；`ob:140-145` dispatch 注释；runner（run.sh 及 planner/probe/report）本体；integration 测试。
- usage heredoc 文案中不新增 "exit code"（带空格）短语，沿用现有 "exits 3" 形态（exit_contract EXIT_RE 不解析 heredoc，纯防御性沿用惯例）。

## 输入工件

- 设计来源：grill-with-docs 两轮共识（本对话，9 项决策全拍板）
- 相关既有文档：`CONTEXT.md` 词条 `ob test-qemu` / `remedy line` / `QEMU lifecycle lock`；`docs/adr/0025`、`docs/adr/0026`、`docs/adr/0024`
- 代码锚点：`lib/qemu_commands.sh` 的 `cmd_test_qemu` / `test_qemu_usage` / `test_qemu_resolve_lineage` / `test_qemu_resolve_baseline_dir`（helper 注释现状 834 行区域含已失真的"需先过 liveness"句，随重排更新）

## 文件结构与职责

- Modify: `lib/qemu_commands.sh` — `cmd_test_qemu` 前置重排 + dry-run 条件化；`test_qemu_usage` 三处文案；`test_qemu_resolve_baseline_dir` 注释更新
- Modify: `ob` — `test-qemu` 概述行（现状 215）+ Options 段 `<machine>` 行（现状 267）+ Boundary 段（现状 275-278）
- Test: `tests/protocol/test_qemu_surface.sh` — 头部注释 (2)(4) 更新、用例 (2) 改名、新增用例 (6) baseline-first hermetic 直测、新增用例 (7) dry-run 无 QEMU/无凭据直测
- Modify: `CONTEXT.md` — `ob test-qemu` 词条（现状 199 行）补 dry-run 前置集语义

无新建文件。四处文件按上述职责独立变化；`lib/qemu_commands.sh` 是行为变更唯一落点，其余三处是配套同步。

## 任务清单

### Task 1: lib/qemu_commands.sh baseline 段前移 + hermetic 用例 (6) baseline-first 直测

- 目标：baseline 谱系+目录检查（现"前置 3"）移到 PyYAML 检查之后；新增 hermetic 直调用例 (6) 锁定"baseline remedy 先于 liveness remedy"。
- Files:
  - Modify: `lib/qemu_commands.sh`（`cmd_test_qemu` 内 `── 前置 3: baseline 目录按谱系路由` 整段，含 lineage 分档 remedy 与 baseline dir 检查）
  - Test: `tests/protocol/test_qemu_surface.sh`（用例 (2) 改名 + 新增用例 (6) + 头部注释 (2)(4)）
- 验证范围: `bash tests/protocol/test_qemu_surface.sh` 全绿（含用例 (6)）；本机无 QEMU 下 `./ob test-qemu romulus` 报 "No baseline dir" 而非 "No QEMU instance"（环境演示，见 Step 4 前提）。
- 接口契约:
  - Consumes: 现有 `test_qemu_resolve_lineage` / `test_qemu_resolve_baseline_dir`（leaf-pure，签名不变）；`detect_harness_root` 已在函数首行调用。
  - Produces: `cmd_test_qemu` 前置顺序变更为 machine→PyYAML→baseline→（后续任务继续插入凭据）；baseline 段块注释含排序原则（Task 3 的 dry-run 条件化建立在此结构上）。

- [ ] Step 1: 写失败测试（用例 (2) 改名 + 新增 hermetic 用例 (6)）
  - Change: `tests/protocol/test_qemu_surface.sh`：
  1. 用例 (2) 断言名 `private flags reach cmd_test_qemu (exit 3 at liveness, no instance)` 改为 `private flags reach cmd_test_qemu (exit 3 at first missing precondition)`——**不**给用例 (2) 追加 baseline 文案断言：它走 `$OB` 全链、消费宿主真实 `openbmc-source.manifest`（`workspace/` 整体 gitignore，干净 checkout / CI 无此文件时 lineage=unknown，remedy 文案因环境而异），rc=3 在任何环境恒成立，是它唯一稳定可断言的信号；
  2. 在用例 (5) 之后、`assert_summary` 之前新增 hermetic 直调用例 (6)（不依赖宿主 manifest——评审 🔴1）：
    ```bash
    # (6) cmd 层 baseline-first hermetic 直测(前置重排): fake 根注入 OB_ENTRY_DIR
    #     (用例 (5) 已验证的全局注入模式), custom label + 无 baseline dir + 无 QEMU →
    #     exit 3 落 baseline remedy 而非 liveness remedy。hermetic: 不依赖宿主真实
    #     openbmc-source.manifest(workspace/ gitignore, 干净 checkout 无此文件,
    #     宿主 label 环境相关 — 用例 (2) 的 remedy 文案因此不可断言)。
    _tq_bf_root="$(mktemp -d)"
    mkdir -p "$_tq_bf_root/workspace/configs"
    printf 'source_label=custom\n' > "$_tq_bf_root/workspace/configs/openbmc-source.manifest"
    rc=0; out=$(MACHINE=fake-m OB_ENTRY_DIR="$_tq_bf_root" cmd_test_qemu 2>&1) || rc=$?
    assert_eq "no-baseline no-QEMU → exit 3" "$rc" "3"
    assert_true "baseline remedy first (reorder)" grep -q "No baseline dir for 'fake-m'" <<<"$out"
    assert_false "liveness remedy not reached" grep -q "No QEMU instance running" <<<"$out"
    rm -rf "$_tq_bf_root"
    ```
  3. 头部注释 (2) 的"到达 cmd_test_qemu 的 liveness 前置 → exit 3"改为"到达 cmd_test_qemu 首个缺失前置 → exit 3（具体落点由 (6) hermetic 锁定为 baseline-first）"；注释 (4) 的"cmd 层的 \"No baseline dir\" remedy 需先过 liveness, 属 integration, 不在此测"改为"重排后 cmd 层 baseline remedy 无 QEMU 即可测，见 (6)；helper 直测保留覆盖路由分支细节"。
- [ ] Step 2: 运行并确认失败
  - Run: `cd /bmc/iasi/ob-harness && bash tests/protocol/test_qemu_surface.sh; echo "rc=$?"`
  - Expected: 用例 (6) 两条断言 FAIL（现状 liveness 在前，stderr 含 "No QEMU instance running" 而非 "No baseline dir"），测试整体非 0 退出。
- [ ] Step 3: baseline 段前移
  - Change: `lib/qemu_commands.sh` `cmd_test_qemu` 内：把 `── 前置 3: baseline 目录按谱系路由 (ADR-0026...)` 整段（lineage 解析、unknown 分档 remedy、`test_qemu_resolve_baseline_dir` + MISSING remedy，至 exit 3 闭包）剪切，插入到 PyYAML 前置检查块之后、`── 前置 2: RUNNING QEMU instance` 之前；段号注释改写：baseline 段标注 `── 前置 2: baseline 谱系+目录`，原 QEMU 段改标 `── 前置 3: RUNNING QEMU instance`（凭据段在 Task 2 插入后再顺延为 4）。段首注释补排序原则：`# 排序原则: 前置按"缺失时用户修复成本"排序 — baseline 是结构性缺失(建目录级投入)且零 QEMU 依赖, 先于 QEMU 运行态检查暴露; liveness 段与 cmd_smoke 同构。`。同步更新 `test_qemu_resolve_baseline_dir` 的 helper 注释（现状 834 行区域）：删除"cmd 层该 remedy 需先过 liveness"句，改为"cmd 层 baseline remedy 无 QEMU 即可测（前置重排后先于 liveness）"。
- [ ] Step 4: 运行并确认通过
  - Run: `cd /bmc/iasi/ob-harness && bash tests/protocol/test_qemu_surface.sh && ./ob test-qemu romulus 2>&1 | grep -q "No baseline dir for 'romulus'" && ! ./ob test-qemu romulus 2>&1 | grep -q "No QEMU instance running" && echo BASELINE-FIRST-OK`
  - Expected: surface 全绿（含用例 (6)）后，输出 `BASELINE-FIRST-OK`——本机 custom 谱系、无 QEMU、contexts/baseline/romulus 不存在，首错误是 baseline remedy 而非 liveness remedy（`!` 对整条 pipeline 取反，两次独立调用避免 head 吞 rc；此步是环境演示，不进 protocol 断言）。
- [ ] Step 5: checkpoint commit
  - Run: `git add lib/qemu_commands.sh tests/protocol/test_qemu_surface.sh && git commit -m "refactor(test-qemu): baseline precondition moves before QEMU liveness"`
  - Expected: commit 成功。

### Task 2: lib/qemu_commands.sh 凭据段前移

- 目标：凭据解析段（env 双源校验 + ar_probes.yaml 补缺）从 liveness 之后移到 baseline 段之后、QEMU 段之前；本任务不做 dry-run 条件化（Task 3 做）。
- Files:
  - Modify: `lib/qemu_commands.sh`（`cmd_test_qemu` 内 `── 凭据解析: env OB_TQ_USER/OB_TQ_PASSWORD 优先...` 整段，现状 1030-1070 区域；`export OB_TQ_USER/OB_TQ_PASSWORD` 行与 `info "test-qemu: probing..."` 行位置调整）
- 验证范围: 结构断言（凭据段位于 liveness 段之前）+ surface 不回归。
- 接口契约:
  - Consumes: Task 1 产出的新前置顺序（baseline 已在 PyYAML 后）。
  - Produces: 顺序 machine→PyYAML→baseline→凭据→QEMU 段；凭据段代码作为 Task 3 条件化 `if [[ $_dry -eq 0 ]]` 的包裹对象（`export` 行一并入段尾）。

- [ ] Step 1: 当前状态检查
  - Run: `cd /bmc/iasi/ob-harness && _body=$(awk '/^cmd_test_qemu\(\)/,/^}$/' lib/qemu_commands.sh); _c=$(grep -n "凭据解析" <<<"$_body" | head -1 | cut -d: -f1); _q=$(grep -n "RUNNING QEMU instance" <<<"$_body" | head -1 | cut -d: -f1); echo "cred-line=$_c qemu-line=$_q"; test -n "$_c" -a -n "$_q" -a "$_c" -lt "$_q"`
  - Expected: 打印 `cred-line` > `qemu-line`（凭据段在 QEMU 段之后），`test` 退出码 1（缺失状态：本地文件可判定的前置尚未聚拢）。awk 先切出 `cmd_test_qemu` 函数体再比对，避开 `cmd_smoke` 注释与 usage 文案的同短语命中。
- [ ] Step 2: 确认当前失败（结构）
  - Run: 同 Step 1
  - Expected: 同上——`test` 退出码 1 证实凭据段在 QEMU 段之后。
- [ ] Step 3: 凭据段前移
  - Change: 剪切凭据解析整段（env/YAML 双源 python 解析 + user/password 缺失 exit 3 ×2，注释保留），插入 baseline 段之后、QEMU 段之前，段标注 `── 前置 3: 凭据解析`，原 QEMU 段注释从 `前置 3` 顺延为 `── 前置 4: RUNNING QEMU instance`；`export OB_TQ_USER="$_auth_user" OB_TQ_PASSWORD="$_auth_pass"` 从 runner 调用前移到凭据段尾（变量 `_auth_user/_auth_pass` 段内已就绪）；`info "test-qemu: probing '$MACHINE' baseline at $_dir (lineage $_lineage, Redfish port $_port)."` 留在 QEMU 段后 runner 调用前（`_port` 此时已知，Task 3 再分叉文案）。段注释补一句：`# 凭据只依赖 baseline dir(读 ar_probes.yaml), 修复成本低但检查零成本 — 与 baseline 同属本地可判定前置, 先于 QEMU 运行态。`
- [ ] Step 4: 运行并确认通过
  - Run: `cd /bmc/iasi/ob-harness && bash -n lib/qemu_commands.sh && _body=$(awk '/^cmd_test_qemu\(\)/,/^}$/' lib/qemu_commands.sh); _c=$(grep -n "凭据解析" <<<"$_body" | head -1 | cut -d: -f1); _q=$(grep -n "RUNNING QEMU instance" <<<"$_body" | head -1 | cut -d: -f1); echo "cred-line=$_c qemu-line=$_q"; test -n "$_c" -a -n "$_q" -a "$_c" -lt "$_q" && bash tests/protocol/test_qemu_surface.sh; echo "rc=$?"`
  - Expected: `bash -n` 无输出；打印 `cred-line` < `qemu-line`，结构 `test` 通过后 surface 全绿，`rc=0`。
- [ ] Step 5: checkpoint commit
  - Run: `git add lib/qemu_commands.sh && git commit -m "refactor(test-qemu): credentials precondition moves before QEMU liveness"`
  - Expected: commit 成功。

### Task 3: dry-run 前置集豁免 + 用例 (7) 无 QEMU/无凭据直测

- 目标：dry-run 跳过凭据段与整个 QEMU 段（derive_qemu_paths/lock/liveness/port），runner argv 不带 `--host/--port`，info 文案分叉；新增 protocol 用例 (7) 用 fake harness 根直调 `cmd_test_qemu --dry-run` 断言 exit 0。
- Files:
  - Modify: `lib/qemu_commands.sh`（凭据段、QEMU 段、runner 调用区）
  - Test: `tests/protocol/test_qemu_surface.sh`（新增用例 (7)，插在用例 (6) 之后、`assert_summary` 之前）
- 验证范围: surface 全绿含用例 (7)；dry-run 路径无 QEMU、无凭据（env 与 YAML 双缺）下 exit 0 并列出 AR。
- 接口契约:
  - Consumes: Task 1/2 产出的顺序 machine→PyYAML→baseline→凭据→QEMU 段 + Task 1 的用例 (6) hermetic 注入模式；runner `run.sh` 既有 dry-run 契约（`DRY_RUN=0` 才校验 host/port/凭据；dry-run 输出 `dry-run: AR list + applicability (no probe)` 后 exit 0）。
  - Produces: dry-run 前置集 = {machine, PyYAML, baseline 谱系+目录}；probe 前置集 = 全集。行为契约：`ob test-qemu <m> --dry-run` 无 QEMU 时 exit 0 列 AR（Task 4 文案、Task 5 词条引用此语义）。

- [ ] Step 1: 写失败用例 (7)
  - Change: `tests/protocol/test_qemu_surface.sh` 用例 (6) 之后插入。注意两点（评审 🔴2/🟡2）：断言库 `assert_true` 直接执行 `"$@"`，否定断言必须用 `assert_false`（`!` 作为参数传入会执行名为 `!` 的命令，必失败）；fake baseline 复制 romulus 后必须删除其 `auth:` 段——romulus `ar_probes.yaml` 自带 `auth.redfish` 凭据，不删则"凭据段未豁免"的实现错误会被 YAML 补齐掩盖，测试失去区分力（planner 不依赖 auth）：
    ```bash
    # (7) cmd 层 dry-run 前置集豁免: 无 QEMU、无凭据(env unset + YAML auth 删除) → exit 0 列 AR。
    #     runner run.sh DRY_RUN 分支原生豁免 host/port/凭据; fake 根同 (6) 注入模式,
    #     community label → tests/baseline/fake-m(复制真实 romulus 基线保 schema 真实,
    #     再删 auth 使凭据豁免可证 — 否则 YAML auth 会掩盖"凭据段未豁免"的实现错误;
    #     planner 不依赖 auth)。cp 在 OB_ENTRY_DIR 覆盖前用真实根取源(env-prefix 只在
    #     cmd_test_qemu 执行期间生效, 不改进程变量)。
    _tq_dry_root="$(mktemp -d)"
    mkdir -p "$_tq_dry_root/workspace/configs" "$_tq_dry_root/tests/baseline"
    printf 'source_label=community\n' > "$_tq_dry_root/workspace/configs/openbmc-source.manifest"
    cp -r "$OB_ENTRY_DIR/tests/baseline/romulus" "$_tq_dry_root/tests/baseline/fake-m"
    python3 - "$_tq_dry_root/tests/baseline/fake-m/ar_probes.yaml" <<'PY'
    import sys, yaml
    p = sys.argv[1]
    d = yaml.safe_load(open(p)) or {}
    d.pop("auth", None)
    yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
    PY
    unset OB_TQ_USER OB_TQ_PASSWORD
    rc=0; out=$(MACHINE=fake-m OB_ENTRY_DIR="$_tq_dry_root" cmd_test_qemu --dry-run 2>&1) || rc=$?
    assert_eq "dry-run without QEMU/creds → exit 0" "$rc" "0"
    assert_true "dry-run lists ARs (runner dry-run banner)" grep -q "dry-run: AR list" <<<"$out"
    assert_false "dry-run touches no liveness" grep -q "No QEMU instance running" <<<"$out"
    assert_false "dry-run touches no credentials gate" grep -q "No Redfish user" <<<"$out"
    rm -rf "$_tq_dry_root"
    ```
- [ ] Step 2: 运行并确认失败
  - Run: `cd /bmc/iasi/ob-harness && bash tests/protocol/test_qemu_surface.sh; echo "rc=$?"`
  - Expected: `dry-run without QEMU/creds → exit 0` 断言 FAIL（现状 cmd 层 liveness 挡住 dry-run，rc=3），测试非 0 退出。
- [ ] Step 3: dry-run 条件化
  - Change: `lib/qemu_commands.sh` `cmd_test_qemu`：
  1. 凭据段整体包 `if [[ $_dry -eq 0 ]]; then ... fi`（含段尾 `export OB_TQ_USER/OB_TQ_PASSWORD`）；
  2. QEMU 段（`derive_qemu_paths`、`_qemu_lifecycle_lock_or_exit`、`local _liv=""`、liveness case、`local _port="$PIDFILE_REDFISH_PORT"`）整体包 `if [[ $_dry -eq 0 ]]; then ... fi`；`_test_lock_fd/_test_lock_owned` 的 `local` 声明留在条件块外（bash local 在块内亦属函数作用域，置外更直观）；
  3. info 行分叉：dry-run 打 `info "test-qemu: dry-run '$MACHINE' baseline at $_dir (lineage $_lineage, no probe, no instance needed)."`；probe 打现有 `info "test-qemu: probing '$MACHINE' baseline at $_dir (lineage $_lineage, Redfish port $_port)."`；
  4. `_run_args` 构造：`local -a _run_args=(bash "$_dir/runner/run.sh")`；`[[ $_dry -eq 0 ]] && _run_args+=(--host 127.0.0.1 --port "$_port")`；其余 `--ar/--suite/--report/-v/-d` 追加逻辑不变；
  5. runner 调用后的 `_qemu_lifecycle_lock_release_if_owned "$_test_lock_fd" "$_test_lock_owned"` 套 `[[ $_dry -eq 0 ]] &&`（dry-run 未拿锁）。`ob` 是 `set -euo pipefail`，但此写法安全且是现状惯例（同函数已有 5 处 `[[ ... ]] && _run_args+=(...)`，`&&` 列表中非最终命令的失败不触发 errexit）——不要改写成 if；
  6. QEMU 段块注释补：`# liveness/lock/port 仅 probe 需要; dry-run 是 baseline 资产检查(planner-only), 不碰 BMC —— 与 run.sh DRY_RUN 分支的前置豁免对齐。`
- [ ] Step 4: 运行并确认通过
  - Run: `cd /bmc/iasi/ob-harness && bash tests/protocol/test_qemu_surface.sh && out=""; rc=0; out=$(env -u OB_TQ_USER -u OB_TQ_PASSWORD ./ob test-qemu romulus --dry-run 2>&1) || rc=$?; head -4 <<<"$out"; [[ $rc -eq 3 ]] && grep -q "No baseline dir for 'romulus'" <<<"$out" && ! grep -q "No QEMU instance running" <<<"$out" && echo DRYRUN-EXEMPT-OK`
  - Expected: surface 全绿含用例 (7)；真实 romulus 输出前 4 行后打印 `DRYRUN-EXEMPT-OK`——本机 manifest `source_label=custom`，romulus 路由到 `contexts/baseline/romulus`（不存在），dry-run 豁免 QEMU/凭据但 baseline 仍是前置 → exit 3 报 baseline remedy、不报 liveness remedy（最初用户场景在新行为下的正确形态；rc 用 `out=$(...)` 捕获避免管道吞掉）。
- [ ] Step 5: checkpoint commit
  - Run: `git add lib/qemu_commands.sh tests/protocol/test_qemu_surface.sh && git commit -m "feat(test-qemu): --dry-run exempts QEMU liveness/credentials preconditions"`
  - Expected: commit 成功。

### Task 4: usage 文案同步（ob 主文件 + test_qemu_usage）

- 目标：六处文案补 dry-run 例外，消除"文案说必需 running instance、行为已豁免"的矛盾。
- Files:
  - Modify: `ob`（概述行现状 215；`<machine>` 行现状 267；Boundary 段现状 275-278）
  - Modify: `lib/qemu_commands.sh`（`test_qemu_usage`：首段现状 857、`-d` 行现状 865、Boundary 段现状 875-878）
- 验证范围: `./ob test-qemu --help` 与 `./ob`（命令列表）输出含 dry-run 例外措辞；surface 用例 (1)(5) 不回归。
- 接口契约:
  - Consumes: Task 3 产出的 dry-run 行为契约（无 QEMU exit 0 列 AR）。
  - Produces: 面向用户的 dry-run 语义说明（Task 5 的 CONTEXT.md 词条措辞与之保持一致）。

- [ ] Step 1: 当前状态检查
  - Run: `cd /bmc/iasi/ob-harness && ./ob test-qemu --help | grep -n "dry-run\|RUNNING\|running"; grep -n "on its running QEMU instance" ob | head -2`
  - Expected: `-d` 行仍带 `(runner-level)` 注记；Boundary/machine 行无 dry-run 例外——缺失状态确认。
- [ ] Step 2: 确认当前缺失（同 Step 1 输出即为缺失证据）
- [ ] Step 3: 六处文案修改
  - Change:（逐处给出目标文案）
  1. `ob` 概述行（现状 215）：`test-qemu    [<machine>]    Run <machine>'s baseline AR probes on its running QEMU instance (probe-only; pass/fail/skip/xfail/xpass; --dry-run lists ARs without an instance)`
  2. `ob` `<machine>` 行（现状 267）：`<machine>               Whose baseline to test (required positional; a RUNNING instance is required unless --dry-run)`
  3. `ob` Boundary 段（现状 275-278）末尾追加一行（缩进对齐段内 12 空格）：`With --dry-run no instance is needed — it lists ARs + applicability only.`
  4. `lib/qemu_commands.sh` `test_qemu_usage` 首段（现状 857-858）：`Run <machine>'s baseline AR probes on its RUNNING QEMU instance (probe mode; --dry-run lists ARs + applicability without an instance). Each AR (需求条目) is probed and verdicted pass/fail/skip/xfail/xpass.`
  5. `test_qemu_usage` 的 `-d` 行（现状 865）：`  -d, --dry-run    List ARs + applicability, no probe (no running instance needed)`
  6. `test_qemu_usage` Boundary 段（现状 875-878）末尾追加：`          With --dry-run no instance is needed — baseline asset check only.`
- [ ] Step 4: 运行并确认通过
  - Run: `cd /bmc/iasi/ob-harness && c1=$(./ob test-qemu --help | grep -c "no running instance needed\|without an instance\|no instance is needed"); c2=$(./ob --help 2>&1 | grep -c "dry-run lists ARs"); echo "c1=$c1 c2=$c2"; [[ $c1 -ge 2 && $c2 -ge 1 ]] && bash tests/protocol/test_qemu_surface.sh; echo "rc=$?"`
  - Expected: 打印 `c1≥2 c2≥1`（计数用 `[[ -ge ]]` 硬断言——`grep -c` 有命中即 exit 0，数量不足不会失败）；通过后 surface 全绿，`rc=0`。注意 c2 用 `./ob --help`（评审二轮 🔴1）：`ob` 无参时 COMMAND 为空走 `cmd_menu`（TTY 进交互菜单、非 TTY 报 "Non-interactive terminal detected" 后退出），不打印命令列表；全局 `--help` 才走 `usage()` 输出含 `test-qemu` 概述行的命令列表。
- [ ] Step 5: checkpoint commit
  - Run: `git add ob lib/qemu_commands.sh && git commit -m "docs(test-qemu): usage copy reflects dry-run precondition exemption"`
  - Expected: commit 成功。

### Task 5: CONTEXT.md ob test-qemu 词条补 dry-run 前置集语义

- 目标：词条（现状 199 行）的"前置是目标 machine 的 QEMU instance 正在跑"句限定为 probe 模式，补 dry-run 前置集分叉。
- Files:
  - Modify: `CONTEXT.md`（词条 `**ob test-qemu**`，现状 199 行）
- 验证范围: grep 词条含新语义句；不新增排序原则相关表述（glossary 边界）。
- 接口契约:
  - Consumes: Task 3 行为契约、Task 4 用户面措辞（`--dry-run` 语义表述保持一致）。
  - Produces: 无（文档终点任务）。

- [ ] Step 1: 当前状态检查
  - Run: `cd /bmc/iasi/ob-harness && grep -Fc "前置集按模式分叉" CONTEXT.md; grep -Fc "无需在跑实例" CONTEXT.md`
  - Expected: 两计数均为 0（缺失状态）。
- [ ] Step 2: 确认当前缺失（同上，两计数 0 即证据）
- [ ] Step 3: 词条更新
  - Change: 199 行 "**probe-only**：不 boot / 不 teardown（无 EXIT trap），前置是目标 machine 的 `QEMU instance` 正在跑——" 改为 "**probe-only**：不 boot / 不 teardown（无 EXIT trap）。前置集按模式分叉：probe 模式前置是目标 machine 的 `QEMU instance` 正在跑（" 后接原文；并在同句号后插入一句："`--dry-run` 是 baseline 资产检查（列 AR + applicability，不 probe），前置集仅 {machine、PyYAML、baseline 谱系+目录}，无需在跑实例、无需凭据（runner `DRY_RUN` 分支同构豁免）。" 保持词条内其余内容（谱系路由、verdict、exit-code 契约段）不动。
- [ ] Step 4: 运行并确认通过
  - Run: `cd /bmc/iasi/ob-harness && grep -Fq "前置集按模式分叉" CONTEXT.md && grep -Fq "无需在跑实例" CONTEXT.md && echo ENTRY-OK`
  - Expected: 输出 `ENTRY-OK`——两个短语各自独立 `grep -Fq` 断言（评审 🟡3：两短语写在同一句，`grep -c` 按行计数必返回 1，用出现计数会假失败）。
- [ ] Step 5: checkpoint commit
  - Run: `git add CONTEXT.md && git commit -m "docs(context): ob test-qemu entry — mode-scoped precondition sets (dry-run needs no instance)"`
  - Expected: commit 成功。

### Task 6: 全量自检收尾

- 目标：跑仓库配套自检，确认重排未破坏结构 gate / 函数登记 / shellcheck baseline / exit-contract / 测试面。
- Files: 无新增改动（若 gate 报错，回到对应任务修复后重跑）。
- 验证范围: `tools/ob_check.sh` 全绿。
- 接口契约:
  - Consumes: Task 1-5 全部产出。
  - Produces: 无。

- [ ] Step 1: 全量自检
  - Run: `cd /bmc/iasi/ob-harness && bash tools/ob_check.sh; echo "rc=$?"`
  - Expected: 全部检查 PASS，`rc=0`。重点关注：exit-contract（X 规则字面量无新增；`cmd_test_qemu` 新增的 `if [[ $_dry -eq 0 ]]` 不引入 exit）、shellcheck baseline（块移动后无新告警）、run_all protocol 层（含用例 (6)(7)）。
- [ ] Step 2: 最终行为验证（最初用户场景）
  - Run: `cd /bmc/iasi/ob-harness && ./ob test-qemu romulus 2>&1 | grep -q "No baseline dir for 'romulus'" && ! ./ob test-qemu romulus 2>&1 | grep -q "No QEMU instance running" && echo REORDER-EFFECTIVE`
  - Expected: 输出 `REORDER-EFFECTIVE`——无 QEMU、无 baseline 的环境下，首错误是 baseline remedy（本机 custom 谱系、contexts/baseline/romulus 不存在；dry-run 形态已在 Task 3 Step 4 验证，此处验证 probe 路径）。
- [ ] Step 3: checkpoint commit（若 Step 1 有修复则提交）
  - Run: `git status --short && git log --oneline -6`
  - Expected: working tree clean（或仅剩本任务修复的已提交内容），提交链含 Task 1-5 的 5 个 commit。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1→6），不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务的验证；验证不过不进下一任务。
- 遇到阻塞、重复失败或计划与仓库现实不符（行号漂移属正常，用注释锚点重定位），立即停下说明，不猜。
- 当前在 `main` 分支：开始实现前与用户确认是否切 feature 分支。
- 全部任务完成后，运行最终验证（Task 6）并输出修改摘要。

## 最终验证

- `bash tools/ob_check.sh` → rc=0 全绿
- `bash tests/protocol/test_qemu_surface.sh` → 全绿（含新用例 (6) baseline-first hermetic 与 (7) dry-run 豁免；用例 (2) 保持环境无关的 flags+rc=3 断言）
- `./ob test-qemu romulus`（无 QEMU、无 baseline 的环境）→ 首错误为 "No baseline dir for 'romulus' (lineage: custom)."，证明重排生效
- 改动摘要：5 个 commit（Task 1-5），Task 6 视修复情况

## 审阅 Checkpoint

- 计划正文结束。请审阅；批准后由普通编码 agent 或人工按任务执行。
