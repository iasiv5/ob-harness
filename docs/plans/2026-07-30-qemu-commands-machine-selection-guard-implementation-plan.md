# cmd_start_qemu / cmd_deploy_to_qemu machine-selection 走 guard 收口实施计划

## 目标

把 [cmd_start_qemu](../../lib/qemu_commands.sh#L7) 与 [cmd_deploy_to_qemu](../../lib/qemu_commands.sh#L271) 内联的 machine-selection 序言（empty/nontty 手写检测 + remedy 串 + `exit 3`）收口为调用已有的 leaf-pure `machine_selection_guard`（[machine_selection_guard.sh:18](../../lib/machine_selection_guard.sh#L18)）+ 字面 `case "$_msg" in empty|nontty|ok)` 收口，与 [cmd_build](../../lib/commands.sh#L121) / [cmd_dev](../../lib/commands.sh#L371) 同构。消除范式刚立好（07-12 PR#31）就在同族 QEMU 命令里漂移的手写副本。**cmd_stop_qemu 不在本次范围**（其 empty 是良性的 exit 0 + `read_machine_choice` 自渲染，与 guard 的 exit-3 empty 语义不兼容，D1）。**init 不顺带**（control-flow 不同形，ADR-0016，D4）。

## 架构快照

- **不改 guard**——`machine_selection_guard` 已泛化消费任意 `list_fn`（三态判定与 list_fn 语义无关），start 喂 `machine_state_firmware_image_ready_machines`、deploy 喂 `machine_state_initialized_machines` 都正确（D3）。
- **deploy 干净 1:1**：list_fn = `initialized_machines`（同 build/dev），empty 分支 generic remedy，结构与 cmd_build:138-161 完全同构。
- **start 带子分类**：list_fn = `firmware_image_ready_machines`，empty 分支保留 any_initdone 子分类（image-ready 空 → 再查 initialized 区分 remedy "先 build" vs "先 init"）**留 cmd 层**（D2，guard 是横切检测原语不承载 image-ready 领域逻辑）。
- **qemu_commands.sh 仍是 L1 exit seam**：改造后 `case "$_msg"` 的 empty/nontty 分支仍直接 `exit 3`（同 build/dev），不走 leaf-pure return；exit 前有 `error` remedy（满足 exit_contract Z）。
- **exit_on_user_cancel 不动**：start/deploy 的 `pick_machine` rc 处理仍走 `exit_on_user_cancel`（qemu_commands.sh:44/294），本次只收口 empty/nontty 检测。

## 全局约束

- **exit seam 不变**：qemu_commands.sh 是 L1 exit seam（不在 exit_contract `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`，Y 规则不管它）；改造后 `exit 3` 仍字面值 ∈ {0,1,2,3}（X 规则）、exit 3 前有 `error`（Z 规则）。
- **不改 guard interface**：`machine_selection_guard <list_fn> <status_outvar>` 签名、empty/nontty/ok 三态、恒 return 0、leaf-pure 全部不动。
- **start 子分类留 cmd（D2）**：any_initdone 查询（`[[ -n "$(machine_state_initialized_machines)" ]]`）与两条 remedy 文案原样从手写 empty 块搬到 `case "$_msg" in empty)` 的 cmd 层处理，行为字节级不变。
- **stop 不碰（D1）**、**init 不顺带（D4，两条 control-flow 障碍已记 ADR-0016）**。
- **行为不变是硬约束**：改造前后 [start_qemu_remedy.sh](../tests/protocol/start_qemu_remedy.sh)（start empty+子分类）+ 新增 deploy empty pin 必须同态 PASS。
- **ob 改 lib 后跑 ob_check**（AGENTS.md Working Mode）：改动 `lib/qemu_commands.sh` 后 `tools/ob_check.sh` 是配套自检。
- 命名：函数 `cmd_start_qemu` / `cmd_deploy_to_qemu` / `machine_selection_guard` 均沿用；术语见 [CONTEXT.md `machine selection guard`](../../CONTEXT.md)。

## 输入工件

- 设计共识：`/pick-one-arch-task` + `/grill-with-docs` 锁定的 D1-D5（本会话）。
- [ADR-0016](../adr/0016-defer-init-intake-guard-reuse.md)：init 暂缓 + 两条 control-flow 障碍（grilling 阶段已补）。
- [CONTEXT.md `machine selection guard`](../../CONTEXT.md)：消费方当前记 build/dev 两处（本次扩到四处）。
- 同构参照：[cmd_build:138-161](../../lib/commands.sh#L138) / [cmd_dev:382-396](../../lib/commands.sh#L382) 的 guard + case 收口。
- 行为 pin 范式：[start_qemu_remedy.sh](../tests/protocol/start_qemu_remedy.sh) 的 `detect_harness_root` mock + setup_fn + subshell。

## 文件结构与职责

- Create: `tests/protocol/deploy_to_qemu_machine_selection.sh` — deploy empty 行为 pin（无 MACHINE + 无 initialized → exit 3 + remedy），改造前后同态 PASS。
- Create: `tests/protocol/qemu_commands_guard_surface.sh` — 结构回归锁：`cmd_start_qemu` / `cmd_deploy_to_qemu` 段必须调 `machine_selection_guard`，且不再手写 `${#machines[@]}` empty 检测（防回潮）。
- Modify: `lib/qemu_commands.sh` — `cmd_start_qemu`(:11-45) + `cmd_deploy_to_qemu`(:277-295) 的 resolve-machine 序言改走 guard + case 收口。
- Modify: `CONTEXT.md` — `machine selection guard` 条目消费方 build/dev → build/dev/start/deploy + start 子分类留 cmd 注记。
- Modify: `docs/adr/0016-defer-init-intake-guard-reuse.md` — Consequences 消费方状态 2→4 + 条件 4 已满足标注（init 两条障碍已在前一步补入，不动）。
- Modify: `tools/coverage_matrix.md` — 横切 guard 行消费方更新 + start-qemu/deploy-to-qemu 段补 machine-selection 走 guard 备注。

接口契约：
- `machine_selection_guard <list_fn> <status_outvar>`（既有，不改）→ 恒 return 0；`status_outvar` 经 printf -v 回传 empty/nontty/ok。Consumes: 任意输出 machine 列表的函数名。Produces: 三态字符串。cmd_start_qemu / cmd_deploy_to_qemu 改造后成为其第 3/4 个消费方。

## 任务清单

### Task 1: 补 deploy empty+nontty pin + start nontty pin + 结构锁骨架

- 目标：补齐 machine-selection 序言的行为 pin——deploy 的 empty+nontty（均缺失）、start 的 nontty（empty+子分类已由既有 [start_qemu_remedy.sh:88-99](../tests/protocol/start_qemu_remedy.sh#L88) 覆盖，nontty 缺失），并落结构锁骨架（此刻 RED）。nontty 是 agent/CI 非交互活路径，文案漂移会误导 agent，须独立 pin（评审 N1：三既有锁全命中 empty，nontty 从不触发）。
- Files
  - Create: `tests/protocol/deploy_to_qemu_machine_selection.sh`（empty + nontty 用例）
  - Modify: `tests/protocol/start_qemu_remedy.sh`（加 start nontty 用例）
  - Create: `tests/protocol/qemu_commands_guard_surface.sh`
- 接口契约
  - Consumes: `cmd_deploy_to_qemu` / `cmd_start_qemu` 既有 empty+nontty 行为（empty: 无 MACHINE + 候选空 → exit 3；nontty: 有候选 + 无 MACHINE + 非 TTY → exit 3 + "No interactive terminal. Specify machine: ob <cmd> <machine>"）。
  - Produces: deploy empty+nontty pin + start nontty pin（Task 2/3 改造后验证依赖）+ 结构锁（Task 2/3 GREEN 依赖）。
- 验证范围：deploy pin（empty+nontty）+ start_qemu_remedy.sh（含新 nontty）当前 PASS（钉死现状）；结构锁当前 FAIL（RED）。

- [ ] Step 1: 写 deploy empty pin
  - Create `tests/protocol/deploy_to_qemu_machine_selection.sh`：
    ```bash
    #!/usr/bin/env bash
    # tests/protocol/deploy_to_qemu_machine_selection.sh — cmd_deploy_to_qemu machine-selection 序言行为 pin。
    # 锁 deploy 的 empty 路径(无 MACHINE + 无 initialized machine → exit 3 + remedy), 改造走 guard 前后同态。
    # 仿 start_qemu_remedy.sh 的 detect_harness_root mock + setup_fn + subshell 范式;
    #   parse_args 在 `source "$OB"` 后可见、对无 machine 子命令设 MACHINE 空——由 start_qemu_remedy.sh:88-99
    #   同模式已验证(同构先例), 非假设。empty 路径在 guard 第一关(initialized 集合空)就 exit 3, 不到
    #   image-ready 判定, 故 mock 不含 image 路径。
    set -uo pipefail
    source "$(dirname "$0")/../lib/ob_loader.sh"
    source "$(dirname "$0")/../lib/assert.sh"
    assert_reset

    run_deploy_case() {
        local setup_fn="$1"; shift
        local tmp output="" rc=0
        tmp="$(mktemp -d)"
        output=$(
            (
                OB_NO_MAIN=1 source "$OB"
                set +e
                detect_harness_root() {
                    HARNESS_ROOT="$tmp"
                    WORKSPACE_DIR="$HARNESS_ROOT/workspace"
                    OPENBMC_DIR="$WORKSPACE_DIR/openbmc"
                    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
                    SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"
                    CONFIGS_DIR="$WORKSPACE_DIR/configs"
                    SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
                    QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
                    QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
                }
                mkdir -p "$tmp/workspace/configs"
                "$setup_fn" "$tmp"
                parse_args "$@"
                detect_harness_root
                cmd_deploy_to_qemu
            ) </dev/null 2>&1
        ) || rc=$?
        DEPLOY_CASE_OUTPUT="$output"; DEPLOY_CASE_RC="$rc"
        rm -rf "$tmp"
    }

    setup_no_initialized() { :; }   # 空 configs(无 init-done) → machine_state_initialized_machines 空
    setup_has_initialized() {       # 有 initialized(init-done) + 无 MACHINE + 非 TTY → 命中 nontty(N1)
        local tmp_root="$1"
        : > "$tmp_root/workspace/configs/romulus.init-done"
    }

    # empty: 无 MACHINE + 无 initialized → exit 3 + remedy
    run_deploy_case setup_no_initialized deploy-to-qemu
    assert_eq "deploy empty rc=3" "$DEPLOY_CASE_RC" "3"
    assert_contains "deploy empty diagnosis" "$DEPLOY_CASE_OUTPUT" "No initialized machines found."
    assert_contains "deploy empty remedy" "$DEPLOY_CASE_OUTPUT" "Run 'ob init <machine>' first."

    # nontty: 有 initialized + 无 MACHINE + 非 TTY(run_deploy_case 内 </dev/null) → exit 3 + terminal remedy
    run_deploy_case setup_has_initialized deploy-to-qemu
    assert_eq "deploy nontty rc=3" "$DEPLOY_CASE_RC" "3"
    assert_contains "deploy nontty diagnosis" "$DEPLOY_CASE_OUTPUT" "No interactive terminal"
    assert_contains "deploy nontty remedy" "$DEPLOY_CASE_OUTPUT" "ob deploy-to-qemu <machine>"

    assert_summary
    ```
- [ ] Step 2: 给 start_qemu_remedy.sh 补 nontty 用例
  - Modify `tests/protocol/start_qemu_remedy.sh`：在 setup 函数群（`setup_orphan_artifact` 后）加 `setup_firmware_image_ready`，并在既有 start empty 用例后、`assert_summary` 前加 nontty 用例：
    ```bash
    setup_firmware_image_ready() {
        local tmp_root="$1"
        local deploy_dir="$tmp_root/workspace/openbmc/build/romulus/tmp/deploy/images/romulus"
        mkdir -p "$deploy_dir"
        : > "$tmp_root/workspace/configs/romulus.init-done"
        touch "$deploy_dir/romulus.static.mtd"
    }

    # nontty: 有 firmware-image-ready + 无 MACHINE + 非 TTY → exit 3 + terminal remedy(N1)
    run_start_qemu_case setup_firmware_image_ready start-qemu
    assert_eq "start-qemu nontty rc=3" "$START_QEMU_CASE_RC" "3"
    assert_contains "start-qemu nontty diagnosis" "$START_QEMU_CASE_OUTPUT" "No interactive terminal"
    assert_contains "start-qemu nontty remedy" "$START_QEMU_CASE_OUTPUT" "ob start-qemu <machine>"
    ```
  - 注：`setup_firmware_image_ready`（init-done + image artifact）使 `machine_state_firmware_image_ready_machines` 返回 romulus → guard 集合非空 + subshell `</dev/null` 非 TTY → 命中 nontty（非 empty）。改造前后均走 nontty；若 setup 误使集合空（落 empty），"No interactive terminal" 断言 FAIL——pin 自验证 setup 正确性。
- [ ] Step 3: 写结构锁骨架
  - Create `tests/protocol/qemu_commands_guard_surface.sh`：
    ```bash
    #!/usr/bin/env bash
    # tests/protocol/qemu_commands_guard_surface.sh — cmd_start_qemu/cmd_deploy_to_qemu 走 guard 结构回归锁。
    # 防回潮: 两命令的 machine-selection 序言必须经 machine_selection_guard(empty/nontty/ok 三态),
    # 不再手写 ${#machines[@]} empty 检测。cmd_stop_qemu 不在此锁(语义不兼容, D1)。
    set -uo pipefail
    source "$(dirname "$0")/../lib/assert.sh"
    assert_reset
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    QCMDS="$ROOT/lib/qemu_commands.sh"
    test -f "$QCMDS" || { echo "MISSING $QCMDS" >&2; exit 1; }

    # 取函数段(cmd_start_qemu 到 cmd_stop_qemu; cmd_deploy_to_qemu 到文件尾)
    start_seg="$(sed -n '/^cmd_start_qemu()/,/^cmd_stop_qemu()/p' "$QCMDS")"
    deploy_seg="$(sed -n '/^cmd_deploy_to_qemu()/,$p' "$QCMDS")"

    # required: 两段都调 machine_selection_guard
    assert_true "cmd_start_qemu calls machine_selection_guard"   grep -Fq 'machine_selection_guard' <<< "$start_seg"
    assert_true "cmd_deploy_to_qemu calls machine_selection_guard" grep -Fq 'machine_selection_guard' <<< "$deploy_seg"
    # forbidden: 两段不再手写 ${#machines[@]} empty 检测(empty 判定已归 guard)
    assert_false "cmd_start_qemu drops handwritten empty check"   grep -Fq '${#machines[@]}' <<< "$start_seg"
    assert_false "cmd_deploy_to_qemu drops handwritten empty check" grep -Fq '${#machines[@]}' <<< "$deploy_seg"
    assert_summary
    ```
- [ ] Step 4: 运行并确认现状（三 pin PASS / 结构锁 RED）—— 独立硬门禁，rc 各自归位
  - Run: `bash tests/protocol/deploy_to_qemu_machine_selection.sh >/dev/null 2>&1 && echo "deploy-pin-PASS"`
  - Run: `bash tests/protocol/start_qemu_remedy.sh >/dev/null 2>&1 && echo "start-remedy-PASS"`
  - Run: `! bash tests/protocol/qemu_commands_guard_surface.sh >/dev/null 2>&1 && echo "surface-RED-expected"`
  - Expected: 三行均打印——`deploy-pin-PASS`（empty+nontty 钉死当前手写行为，改造前即 PASS）；`start-remedy-PASS`（含本 Task 新增 nontty 用例）；`surface-RED-expected`（结构锁当前 FAIL，`!` 反转使其 rc=0 确认 RED：两段当前不含 `machine_selection_guard`、仍含 `${#machines[@]}`）。

### Task 2: 改造 cmd_deploy_to_qemu 走 guard（干净 1:1）

- 目标：把 [cmd_deploy_to_qemu:277-295](../../lib/qemu_commands.sh#L277) 的 resolve-machine 序言替换为 `machine_selection_guard` + 字面 case 收口（与 cmd_build 同构），行为字节级不变。
- Files
  - Modify: `lib/qemu_commands.sh`（`cmd_deploy_to_qemu` 函数内 resolve-machine 段）
- 接口契约
  - Consumes: `machine_selection_guard`（既有）；Task 1 的 deploy pin + 结构锁。
  - Produces: cmd_deploy_to_qemu 走 guard（Task 4 登记依赖；结构锁 deploy 段转 GREEN）。
- 验证范围：deploy pin 仍 PASS + 结构锁 deploy required/forbidden 转 GREEN + exit_contract 通过 + deploy orchestration 不回归。

- [ ] Step 1: 写当前状态检查（deploy 段尚未走 guard）
  - Run: `sed -n '/^cmd_deploy_to_qemu()/,$p' lib/qemu_commands.sh | grep -c 'machine_selection_guard'`
  - Expected: `0`
- [ ] Step 2: 写最小实现
  - 把 `cmd_deploy_to_qemu` 内从注释 `# ── Resolve machine(...)` 到 `exit_on_user_cancel "$pm_rc" "Deploy to QEMU"` 的整段 `if [[ -z "$MACHINE" ]]; then ... fi` 替换为：
    ```bash
        # ── Resolve machine(经 machine_selection_guard: empty/nontty/ok, 同 cmd_build/cmd_dev) ──
        if [[ -z "$MACHINE" ]]; then
            local _msg=""
            machine_selection_guard machine_state_initialized_machines _msg
            case "$_msg" in
                empty)
                    error "No initialized machines found."
                    error "Run 'ob init <machine>' first."
                    exit 3 ;;
                nontty)
                    error "No interactive terminal. Specify machine: ob deploy-to-qemu <machine>"
                    exit 3 ;;
                ok) ;;
            esac
            local pm_rc=0
            pick_machine machine_state_initialized_machines "Deploy to QEMU" || pm_rc=$?
            exit_on_user_cancel "$pm_rc" "Deploy to QEMU"
        fi
    ```
  - Change: 删除该段全部手写逻辑（`while read` 装数组 / `${#machines[@]}` empty 判定 / `[[ ! -t 0 ]]` nontty 判定），由 guard + case 替代。`BUILD_DIR`/`SOURCE_MANIFEST_FILE` 重派生（:297-298）及之后不动。
- [ ] Step 3: 运行并确认通过
  - Run: `sed -n '/^cmd_deploy_to_qemu()/,$p' lib/qemu_commands.sh | grep -q 'machine_selection_guard' && ! sed -n '/^cmd_deploy_to_qemu()/,$p' lib/qemu_commands.sh | grep -q '${#machines[@]}' && bash tests/protocol/deploy_to_qemu_machine_selection.sh >/dev/null 2>&1 && bash tests/orchestration/deploy_to_qemu.sh >/dev/null 2>&1 && python3 tools/exit_contract.py >/dev/null && echo "deploy-GREEN"`
  - Expected: `deploy-GREEN`（deploy 段已含 guard 且无手写 empty；deploy empty pin 行为不变；exit_contract 通过）。注（保护面）: deploy orchestration 7 场景全用 MACHINE=romulus 走 explicit-machine 路径（`[[ -z "$MACHINE" ]]` 为假，不进 resolve 序言），**仅锁 explicit 路径不回归**——empty/nontty 改造路径的真正行为锁是 Task 1 的 deploy pin，非 orchestration。

### Task 3: 改造 cmd_start_qemu 走 guard（empty 子分类留 cmd）

- 目标：把 [cmd_start_qemu:11-45](../../lib/qemu_commands.sh#L11) 的 resolve-machine 序言替换为 `machine_selection_guard` + 字面 case 收口，**empty 分支保留 any_initdone 子分类**（D2）。
- Files
  - Modify: `lib/qemu_commands.sh`（`cmd_start_qemu` 函数内 resolve-machine 段）
- 接口契约
  - Consumes: `machine_selection_guard`（既有）；Task 1 结构锁；既有 [start_qemu_remedy.sh](../tests/protocol/start_qemu_remedy.sh)（empty+子分类行为锁）。
  - Produces: cmd_start_qemu 走 guard（Task 4 登记依赖；结构锁 start 段转 GREEN）。
- 验证范围：start_qemu_remedy.sh 仍 PASS（empty+子分类 remedy 字节不变）+ 结构锁 start 段 GREEN + exit_contract 通过。

- [ ] Step 1: 写当前状态检查（start 段尚未走 guard）
  - Run: `sed -n '/^cmd_start_qemu()/,/^cmd_stop_qemu()/p' lib/qemu_commands.sh | grep -c 'machine_selection_guard'`
  - Expected: `0`
- [ ] Step 2: 写最小实现
  - 把 `cmd_start_qemu` 内从注释 `# ── Resolve machine ──` 到 `exit_on_user_cancel "$pm_rc" "Start QEMU"` 的整段 `if [[ -z "$MACHINE" ]]; then ... fi` 替换为：
    ```bash
        # ── Resolve machine(经 machine_selection_guard: empty/nontty/ok, 同 cmd_build/cmd_dev) ──
        if [[ -z "$MACHINE" ]]; then
            local _msg=""
            machine_selection_guard machine_state_firmware_image_ready_machines _msg
            case "$_msg" in
                empty)
                    # any_initdone 子分类留 cmd(D2): guard 是横切检测原语, 不承载 image-ready 领域逻辑。
                    # image-ready 空 → 再查 initialized 区分 remedy("先 build" vs "先 init")。
                    # 注: guard 拉 firmware_image_ready 判 empty + 本处拉 initialized 分 remedy, 是两个不同
                    # list_fn 各求值一次(非同一函数两次), 同改造前手写代码的两次查询, 非新引入冗余;
                    # 且仅在 empty 异常路径, 非 hot path(同 deploy qemu_commands.sh:278-280 的判空前置模式)。
                    if [[ -n "$(machine_state_initialized_machines)" ]]; then
                        error "No firmware-image-ready machines found."
                        error "Run 'ob build <machine>' first."
                    else
                        error "No initialized machines found."
                        error "Run 'ob init <machine>' first."
                    fi
                    exit 3 ;;
                nontty)
                    error "No interactive terminal. Specify machine: ob start-qemu <machine>"
                    exit 3 ;;
                ok) ;;
            esac
            echo ""
            step_header "Select Machine"
            local pm_rc=0
            pick_machine machine_state_firmware_image_ready_machines "Start QEMU" || pm_rc=$?
            exit_on_user_cancel "$pm_rc" "Start QEMU"
        fi
    ```
  - Change: 删除该段全部手写逻辑（`while read` 装数组 / `${#machines[@]}` empty 判定 / any_initdone 局部变量声明 / `[[ ! -t 0 ]]` nontty 判定）；any_initnone 的**判定与两条 remedy 原样搬进** `case empty)` 的 cmd 层（去掉中间 `any_initdone` 局部，直接 `if [[ -n "$(machine_state_initialized_machines)" ]]`）。`pick_machine` 的 `echo ""; step_header "Select Machine"` 展示行原样保留（在 ok 分支后）。Re-derive paths（:47-49）及之后不动。
- [ ] Step 3: 运行并确认通过
  - Run: `sed -n '/^cmd_start_qemu()/,/^cmd_stop_qemu()/p' lib/qemu_commands.sh | grep -q 'machine_selection_guard' && ! sed -n '/^cmd_start_qemu()/,/^cmd_stop_qemu()/p' lib/qemu_commands.sh | grep -q '${#machines[@]}' && bash tests/protocol/start_qemu_remedy.sh >/dev/null 2>&1 && bash tests/protocol/qemu_commands_guard_surface.sh >/dev/null 2>&1 && python3 tools/exit_contract.py >/dev/null && echo "start-GREEN"`
  - Expected: `start-GREEN`（start 段已含 guard 且无手写 empty；start_qemu_remedy.sh empty+子分类行为不变；结构锁全 GREEN；exit_contract 通过）。
  - 注（行为锁覆盖面）: start_qemu_remedy.sh 锁住 empty 段两个子分类（`setup_init_done_only` → any_initdone=1 子分支 "No firmware-image-ready" + "Run ob build" + 避 "No built"；`setup_no_marker` → any_initdone=0 子分支 "No initialized machines" + "Run ob init"）**+ Task 1 新增的 nontty 用例**（`setup_firmware_image_ready` → "No interactive terminal" + "ob start-qemu <machine>"）。改造后 empty 两子分类 + nontty remedy 字节级不变。（`setup_legacy_lock_only`/`setup_orphan_artifact` 用 MACHINE=romulus，走 explicit-machine 的 is_initialized 前置，非本次 resolve 段，不受改造影响。）

### Task 4: 登记 CONTEXT / ADR-0016 / coverage_matrix + 最终验证

- 目标：把 guard 消费方扩到四处登记进领域模型与覆盖矩阵，跑全套配套自检收口。
- Files
  - Modify: `CONTEXT.md`（`machine selection guard` 条目）
  - Modify: `docs/adr/0016-defer-init-intake-guard-reuse.md`（Consequences 消费方状态）
  - Modify: `tools/coverage_matrix.md`（横切 guard 行 + start-qemu/deploy-to-qemu 段）
- 接口契约
  - Consumes: Task 2/3 产出的 cmd_deploy_to_qemu / cmd_start_qemu 走 guard。
  - Produces: 无（登记 + 验证收口）。
- 验证范围：CONTEXT/ADR/coverage_matrix 已登记 + ob_check + exit_contract + run_all（含 --full）全过。

- [ ] Step 1: 写当前状态检查（尚未登记四处消费）
  - Run: `grep -c 'cmd_start_qemu' CONTEXT.md; grep -c 'cmd_build / cmd_dev / cmd_start_qemu / cmd_deploy_to_qemu' CONTEXT.md`
  - Expected: 第一条 ≥1（条目存在）；第二条 `0`（消费方四方表述尚未落）。
- [ ] Step 2: 写登记
  - Modify `CONTEXT.md` 的 `**machine selection guard**` 条目：把"cmd_build/cmd_dev 共享"（及同类两处表述）改为"cmd_build / cmd_dev / cmd_start_qemu / cmd_deploy_to_qemu 共享"；补一句注：`cmd_start_qemu` 的 empty 分支带 any_initdone 子分类（image-ready vs initialized 的 remedy 区分），留 cmd 层（guard 是横切检测原语，不承载 image-ready 领域逻辑，D2）。
  - Modify `docs/adr/0016-defer-init-intake-guard-reuse.md` 的 Consequences：把"`machine_selection_guard` 消费方维持 cmd_build / cmd_dev 两处"改为"消费方自本次起为 build / dev / start / deploy 四处（重评估条件 4 已满足）"；init 仍暂缓（两条 control-flow 障碍已在前文，不动）。
  - Modify `tools/coverage_matrix.md`：横切表 `machine selection guard` 行的"备注"把"cmd_build/cmd_dev 共享"更新为"cmd_build/cmd_dev/cmd_start_qemu/cmd_deploy_to_qemu 共享"；`## start-qemu` 与 `## deploy-to-qemu` 段各补一行登记 machine-selection 走 guard（涉及函数 `cmd_start_qemu`/`cmd_deploy_to_qemu` + `machine_selection_guard`，覆盖 test `protocol/start_qemu_remedy.sh` + `protocol/deploy_to_qemu_machine_selection.sh` + `protocol/qemu_commands_guard_surface.sh`）。
- [ ] Step 3: 运行并确认通过
  - Run: `grep -q 'cmd_start_qemu / cmd_deploy_to_qemu 共享' CONTEXT.md && grep -q 'start / deploy 四处' docs/adr/0016-defer-init-intake-guard-reuse.md && grep -q 'qemu_commands_guard_surface' tools/coverage_matrix.md && python3 tools/exit_contract.py >/dev/null && tools/ob_check.sh >/dev/null 2>&1 && tests/run_all.sh >/dev/null 2>&1 && echo "FINAL-PASS"`
  - Expected: `FINAL-PASS`（登记就位 + exit_contract + ob_check 配套自检 + run_all 快速三层全过）。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效先修计划。
- 按任务顺序执行，不无声跳步、合并步或改任务目标。
- 每完成一个任务，运行该任务定义的验证（Run 命令以 `grep -q`/`! grep -q`/测试脚本退出码收口，`echo` 仅前置打印标签、末尾 `&&` 链测试退出码，不让 echo 吞 rc）。
- 遇阻塞、重复失败或计划与仓库现实不符立即停下说明，不猜。
- 当前在 `main` 分支：开始实现前与用户确认是否切特性分支。
- 全部任务完成后运行最终验证并输出修改摘要。

## 最终验证

- Run: `python3 tools/exit_contract.py >/dev/null && tools/ob_check.sh >/dev/null 2>&1 && tests/run_all.sh >/dev/null 2>&1 && tests/run_all.sh --full >/dev/null 2>&1 && echo "ALL-FINAL-PASS"`
- Expected: `ALL-FINAL-PASS`（exit_contract / ob_check 配套自检 / run_all 快速三层 / run_all --full 含 .exp 行为不回归 全过）。
- 行为不变交叉确认：`bash tests/protocol/start_qemu_remedy.sh >/dev/null 2>&1 && bash tests/protocol/deploy_to_qemu_machine_selection.sh >/dev/null 2>&1 && bash tests/protocol/qemu_commands_guard_surface.sh >/dev/null 2>&1 && echo "behavior-locked"` —— start empty+子分类 / deploy empty / 结构 三锁全 GREEN。
- coverage 实测（bestpractice_10 #4，非阻断）: `tools/trace_collect.sh | python3 tools/coverage_radar.py - --cross-check` —— 改造不新增 leaf-pure 函数（cmd_* 仍 exit seam），uncovered 计数预期不变，CI 阈值维持 `--fail-if-uncovered 7`。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-30-qemu-commands-machine-selection-guard-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
