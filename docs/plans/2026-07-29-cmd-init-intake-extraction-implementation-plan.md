# cmd_init intake 抽取实施计划

## 目标

把 `cmd_init`（[commands.sh:255-394](../../lib/commands.sh)）内联的机器解析决策树（L266-306：empty 前置 / arg 校验快路径 / 非 TTY 拦截 / `pick_machine` + `confirm_action`）抽成独立 leaf-pure module `lib/init_intake.sh`，与 [devtool_intake.sh](../../lib/devtool_intake.sh) 同构。cmd_init 退化为 intake → clear → rerun 探测 → 8 步 → marker 的干净编排。**本体收益（Phase 1）**：init 选择矩阵的 empty/arg-fastpath/nontty 三态从 `.exp`/PTY 升级到 unit（毫秒级、here-string）。**Phase 2**（让 init 成为 `machine_selection_guard` 第 3 消费者）不在本次范围，暂缓见 [ADR-0016](../adr/0016-defer-init-intake-guard-reuse.md)。

## 架构快照

- 新建 `lib/init_intake.sh`，单一函数 `init_intake`，封装 cmd_init 现状 L266-306 的决策树，**原样保留控制流**（empty 前置 + nontty 后置于 else），不调 `machine_selection_guard`。
- `init_intake` return `exit-code 契约`值 0/1/2/3，沿用 `$MACHINE` 既有全局（fastpath 给定值 / pick 路径 `pick_machine` 设值），exit 收口独占留 cmd_init（字面 case 映射，对齐 [cmd_dev L435-446](../../lib/commands.sh#L435)）。
- `confirm_action` 划进 intake（"何时 confirm"由解析路径决定）；`exit_on_user_cancel` 是 L1 exit helper（体内 `exit 2/1`），intake 绝不调——退役 cmd_init 内现有的 2 处 `exit_on_user_cancel "... "init"` 调用（L299/L303），改字面 case。

## 全局约束

- **leaf-pure**：`init_intake` 绝不 `exit`，return 契约值 0/1/2/3；登记 `exit_contract.py` `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 的 `'init_intake.sh': set()`（Y-c 反向门禁：set{} 干净，跑 exit_contract 验证不报）。
- **exit 只在 cmd_init L1**：intake return，cmd_init 字面 `case "$_rc" in 0);;1)exit 1;;2)exit 2;;3)exit 3;;*)exit 1;;esac` 收口（对齐 cmd_dev，符合 `exit_contract` X 规则禁 dynamic exit）。
- **两条 remedy 文案不合并**：intake 的 empty remedy = `No machines found in $OPENBMC_DIR / re-clone`（独立保留），不与 cmd_build/cmd_dev 的 `No initialized machines / Run 'ob init'` 合并。
- **empty/nontty 控制流原样**：empty 前置（无条件）+ nontty 后置（仅 else 分支），不重塑成 guard 三态（ADR-0016）。
- **边界**：intake 落在 `confirm_action` 通过 + `info "Init confirmed"` 之后；`BUILD_DIR/SRC_DIR` 重派生、`machine_state_clear_init_progress`、`devtool_recipes_clear_cache`、rerun 探测全留 cmd_init（副作用 + exit 1 路径属 L1）。
- **testability 收益边界（诚实）**：unit 覆盖 empty/arg-fastpath/nontty 三态（不依赖 PTY）；pick+confirm 的 cancel/ok 两态留 `.exp`（依赖真交互，[manual_matrix.exp](../tests/protocol/manual_matrix.exp) 已覆盖）。
- **ob 改 lib 后跑 ob_check**（AGENTS.md Working Mode）：改动 `lib/*.sh` 后 `tools/ob_check.sh` 是配套自检。
- 命名规则：文件 `lib/init_intake.sh`，函数 `init_intake`，术语见 [CONTEXT.md `ob init command intake`](../../CONTEXT.md)。

## 输入工件

- 设计共识：`/pick-one-arch-task` + 独立评审 + `/grill-with-docs` 锁定的 5 决策 + 7 约束（本会话）。
- [ADR-0016](../adr/0016-defer-init-intake-guard-reuse.md)（Phase 2 暂缓 + 触发条件）。
- [CONTEXT.md `ob init command intake`](../../CONTEXT.md) + [`ob dev command intake`](../../CONTEXT.md)（同构术语）。
- 同构参照：[devtool_intake.sh](../../lib/devtool_intake.sh) + [tests/unit/devtool_intake.sh](../../tests/unit/devtool_intake.sh) + [tests/protocol/devtool_intake_surface.sh](../../tests/protocol/devtool_intake_surface.sh)。

## 文件结构与职责

- Create: `lib/init_intake.sh` — `init_intake` leaf-pure module（ob init 命令入口解析+确认层）。
- Create: `tests/unit/init_intake.sh` — unit 层，empty/arg-fastpath/nontty 三态选择矩阵。
- Create: `tests/protocol/init_intake_surface.sh` — surface gate，forbidden-token 回归锁（防 intake 越界调执行 step / clear / guard）。
- Modify: `lib/commands.sh` — `cmd_init` L266-306 替换为 `init_intake` 调用 + 字面 case；退役 L299/L303 的 `exit_on_user_cancel "..." "init"`。
- Modify: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'init_intake.sh': set()`。
- Modify: `rules/03_WORKSPACE.md` — lib 路由表登记 `init_intake.sh`。
- Modify: `tools/coverage_matrix.md` — init 段登记 `init_intake`。

接口契约：
- `init_intake`（无参）→ return 0/1/2/3；副作用：pick 路径设 `$MACHINE` 全局。Consumes: `$MACHINE` 全局、`list_available_machines`（[repo.sh:385](../../lib/repo.sh#L385)）、`print_previously_initialized`（[repo.sh:402](../../lib/repo.sh#L402)）、`pick_machine`（[machine_picker.sh:41](../../lib/machine_picker.sh#L41)）、`confirm_action`（util.sh）。Produces: `$MACHINE` 就绪状态（给 cmd_init 后续 L308+ Re-derive paths）。

## 任务清单

### Task 1: 写 init_intake unit + surface gate 测试（RED）

- 目标：在 `init_intake` 实现不存在时，先落 unit 三态测试 + surface gate，确认它们当前失败。
- Files
  - Create: `tests/unit/init_intake.sh`
  - Create: `tests/protocol/init_intake_surface.sh`
- 接口契约
  - Consumes: `init_intake` 接口契约（无参 / return 0/1/2/3 / 设 `$MACHINE`）—— 本 task 先于实现声明，Task 2 兑现。
  - Produces: `tests/unit/init_intake.sh`、`tests/protocol/init_intake_surface.sh`（Task 2/4 依赖）。
- 验证范围：两个测试文件存在且当前因 `init_intake` 未定义而失败（RED）。

- [ ] Step 1: 写失败检查（init_intake 尚不存在）
  - 写 `tests/unit/init_intake.sh`：
    ```bash
    #!/usr/bin/env bash
    # tests/unit/init_intake.sh — init_intake 单测(unit 层)。
    # 覆盖 init 机器解析决策树三态(不依赖 PTY): ① empty 列表→3 / ② arg-fastpath(给定合法 machine,不 confirm)→0 /
    #   ③ nontty(给定非法/空 machine + 非 TTY)→3。pick+confirm 的 cancel/ok 两态依赖真交互, 留 .exp(manual_matrix.exp)。
    # mock 策略: 覆盖 list_available_machines/pick_machine/confirm_action/print_previously_initialized 为可控 stub;
    #   nontty 态用 </dev/null(非 TTY) 触发 intake 内 [[ ! -t 0 ]]。
    # leaf-pure: 函数 return 0/1/2/3(不 exit); exit_contract Y 静态守卫。
    source "$(dirname "$0")/../lib/ob_loader.sh"
    source "$(dirname "$0")/../lib/assert.sh"
    assert_reset

    OPENBMC_DIR="$(mktemp -d)/openbmc"; mkdir -p "$OPENBMC_DIR"; export OPENBMC_DIR
    _err="$(mktemp)"
    rc=0

    # mock 依赖(intake 消费的原语): 覆盖 ob_loader source 的同名函数。
    # 安全边界: print_previously_initialized 必须 mock 为 no-op——真函数(repo.sh:402)走 nameref 且内部
    #   调 machine_state_init_time/format_timestamp/machine_state_initialized_machines 等次级依赖(需真 workspace),
    #   不 mock 会触达它们致 unit 失败; 同理 mock pick_machine/confirm_action 隔离交互与全局写入。
    list_available_machines()      { printf '%s\n' "${MOCK_MACHINES[@]}"; }
    print_previously_initialized() { :; }
    pick_machine()                 { MACHINE="${MOCK_PICK_RESULT:-}"; return "${MOCK_PICK_RC:-0}"; }
    confirm_action()               { return "${MOCK_CONFIRM_RC:-0}"; }

    # ① empty: 列表空 → 3 + stderr 含 "No machines found"
    MOCK_MACHINES=(); MACHINE=""; rc=0
    init_intake 2>"$_err" || rc=$?
    assert_eq "① empty rc=3" "$rc" "3"
    assert_contains "① empty remedy" "$(cat "$_err")" "No machines found"

    # ② arg-fastpath: 给定合法 machine → 0, 不调 pick/confirm(MOCK_PICK_RC 默认 0 但 fastpath 不应触达)
    MOCK_MACHINES=(romulus witherspoon); MACHINE="romulus"; MOCK_PICK_RC=99 MOCK_CONFIRM_RC=99; rc=0
    init_intake 2>"$_err" >/dev/null || rc=$?
    assert_eq "② fastpath rc=0" "$rc" "0"
    assert_eq "② MACHINE 保持 romulus" "$MACHINE" "romulus"

    # ③ nontty: 给定非法 machine + 非 TTY(stdin=/dev/null) → 3 + stderr 含 "interactive terminal"
    MOCK_MACHINES=(romulus); MACHINE="bogus"; rc=0
    init_intake </dev/null 2>"$_err" || rc=$?
    assert_eq "③ nontty rc=3" "$rc" "3"
    assert_contains "③ nontty remedy" "$(cat "$_err")" "interactive terminal"

    assert_summary
    ```
  - 写 `tests/protocol/init_intake_surface.sh`：
    ```bash
    #!/usr/bin/env bash
    set -uo pipefail
    source "$(dirname "$0")/../lib/assert.sh"
    assert_reset
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    RENDER="$ROOT/lib/init_intake.sh"
    test -f "$RENDER" || { echo "MISSING $RENDER" >&2; exit 1; }

    # intake forbidden-token 回归锁: intake 是命令入口解析+确认层(leaf-pure), 不该 execute init step /
    # clear state / 写 marker / 调 guard(Phase 2 暂缓 ADR-0016)/调 exit_on_user_cancel(本抽取退役点,
    # 从 cmd_init 直接搬出、build/qemu 仍在用——最易回潮成"能 exit 的伪 leaf")——那些归 cmd_init L1。
    # 合法调用(list_available_machines/print_previously_initialized/pick_machine/confirm_action/error/warn/info)不禁。
    forbidden=( 'exit_on_user_cancel' \
                'generate_dep_graph' 'clone_sub_repos' 'generate_machine_snapshot' \
                'generate_build_config' 'print_report' 'machine_state_clear_init_progress' \
                'devtool_recipes_clear_cache' 'machine_state_mark_init_done' 'machine_selection_guard' )
    body="$(grep -v '^[[:space:]]*#' "$RENDER")"
    for tok in "${forbidden[@]}"; do
        assert_false "intake forbids $tok" grep -Fq "$tok" <<< "$body"
    done
    assert_summary
    ```
- [ ] Step 2: 运行并确认失败（RED）
  - Run: `! bash tests/unit/init_intake.sh >/dev/null 2>&1 && ! bash tests/protocol/init_intake_surface.sh >/dev/null 2>&1 && echo RED-confirmed`
  - Expected: `RED-confirmed`（unit 因 `init_intake: command not found` 非零退出、surface 因 `MISSING $RENDER` exit 1，两者均如预期失败，`!` 反转使链路 rc=0）。

### Task 2: 建 lib/init_intake.sh + exit_contract 登记（GREEN）

- 目标：实现 `init_intake`（搬 cmd_init L266-306 决策树，原样控制流，return 0/1/2/3），登记 leaf-pure，让 Task 1 测试转绿。
- Files
  - Create: `lib/init_intake.sh`
  - Modify: `tools/exit_contract.py`（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME`，[L53-75](../../tools/exit_contract.py#L53) 字典）
- 接口契约
  - Consumes: Task 1 声明的 `init_intake` 接口（无参 / return 0/1/2/3 / 设 `$MACHINE`）。
  - Produces: `init_intake` 函数（Task 3 wire 依赖）、`'init_intake.sh': set()` 登记（Task 4 验证依赖）。
- 验证范围：Task 1 两个测试转绿 + `exit_contract.py` 通过（init_intake.sh leaf-pure set{} 不报）。

- [ ] Step 1: 写当前状态检查（init_intake 仍不存在）
  - Run: `test ! -f lib/init_intake.sh && echo "not-exists" || echo "exists"`
  - Expected: `not-exists`
- [ ] Step 2: 确认当前缺失
  - Run: `bash tests/unit/init_intake.sh >/dev/null 2>&1; echo "rc=$?"`
  - Expected: 非零（init_intake 未定义）
- [ ] Step 3: 写最小实现
  - Create `lib/init_intake.sh`：
    ```bash
    #!/usr/bin/env bash
    # lib/init_intake.sh — ob init 命令入口的解析+引导+确认层 module(leaf-pure)。
    #   init_intake: 消费 $MACHINE(全局) + list_available_machines, 把 ob init 的机器解析决策树
    #   (empty 前置 / arg 校验快路径 / 非 TTY 拦截 / pick_machine + confirm) 封装为一个入口。
    #   return 0/1/2/3; $MACHINE 沿用全局(fastpath 给定值 / pick 路径 pick_machine 设值)。
    #   消费 list_available_machines / print_previously_initialized / pick_machine / confirm_action / error / warn / info。
    #   术语见 CONTEXT.md ob init command intake; guard 第 3 消费暂缓见 ADR-0016。
    # Exit: leaf-pure module(横切惯例, 同 devtool_intake.sh); 函数绝不 exit, return 契约值; exit 归 cmd_init。

    # init_intake
    # ob init 机器解析决策树(原样保留 cmd_init 既有控制流, 不调 machine_selection_guard——ADR-0016):
    #   empty 前置 → arg 校验快路径(给定合法 machine 不 confirm) → (未给定/非法) 非 TTY 拦截 → pick_machine + confirm。
    # return 0(解析+确认成功, $MACHINE 就绪) / 1(读失败) / 2(用户取消, pick 或 confirm) / 3(前置缺失: 空列表/非TTY/arg非法且非TTY)。
    # remedy 文案(empty="No machines found/re-clone")独立保留, 不与 build/dev 合并。
    # print_previously_initialized 两处调用复刻既有 L281/L298 双语义: fastpath 走 nameref 直印(_machines
    # 数组名)、pick 路径走 $(...) stdout 捕获作 post_list_msg——两者语义不同, 勿合并/勿改写法。
    init_intake() {
        local -a _machines=()
        local _m
        while IFS= read -r _m; do
            [[ -n "$_m" ]] && _machines+=("$_m")
        done < <(list_available_machines)

        if [[ ${#_machines[@]} -eq 0 ]]; then
            error "No machines found in $OPENBMC_DIR."
            error "Check the OpenBMC main repository, or re-clone: cd $OPENBMC_DIR && git pull"
            return 3
        fi

        if [[ -n "$MACHINE" ]] && printf '%s\n' "${_machines[@]}" | grep -qx -- "$MACHINE"; then
            print_previously_initialized _machines
            info "Machine '$MACHINE' confirmed."
            return 0
        fi

        if [[ -n "$MACHINE" ]]; then
            warn "Machine '$MACHINE' is not in the available list."
        else
            warn "No machine specified."
        fi

        if [[ ! -t 0 ]]; then
            error "No valid machine and no interactive terminal. Pass a valid machine: ob init <machine>"
            return 3
        fi

        local _pm_rc=0
        pick_machine list_available_machines "init" "$(print_previously_initialized _machines)" || _pm_rc=$?
        case "$_pm_rc" in
            0) ;;
            2) warn "init cancelled by user."; return 2 ;;
            *) return 1 ;;
        esac

        local _ca_rc=0
        confirm_action "init" "$MACHINE" || _ca_rc=$?
        case "$_ca_rc" in
            0) ;;
            2) warn "init cancelled by user."; return 2 ;;
            *) return 1 ;;
        esac

        echo ""
        info "Init confirmed for machine '$MACHINE'."
        return 0
    }
    ```
  - Modify `tools/exit_contract.py`：在 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 字典内（紧邻 `'devtool_intake.sh': set(),` 之后）加一行：
    ```python
        'init_intake.sh': set(),
    ```
- [ ] Step 4: 运行并确认通过（GREEN）
  - Run: `bash tests/unit/init_intake.sh && bash tests/protocol/init_intake_surface.sh && python3 tools/exit_contract.py >/dev/null && echo ALL-GREEN`
  - Expected: unit `PASS=... FAIL=0`、surface `PASS=10 FAIL=0`（9 越界 token + exit_on_user_cancel）、exit_contract 退出 0、结尾 `ALL-GREEN`。

### Task 3: wire cmd_init 调用 init_intake

- 目标：把 cmd_init 的内联机器解析段（L266-306）替换为 `init_intake` 调用 + 字面 case 收口。该段内的 2 处 `exit_on_user_cancel "..." "init"`（L299/L303）随段替换自然退役（副产物），行为字节级不变（既有 `.exp` 回归锁）。
- Files
  - Modify: `lib/commands.sh`（`cmd_init` 函数，[L255-394](../../lib/commands.sh#L255)）
- 接口契约
  - Consumes: `init_intake`（Task 2 产出）。
  - Produces: cmd_init 退化为 intake → clear → rerun → 8 步 → marker 的编排（Task 4 登记依赖）。
- 验证范围：cmd_init 已 wire（含 `init_intake` 调用）+ cmd_init 段不再含 `exit_on_user_cancel`/`pick_machine`/`confirm_action`（搬进 intake）+ init 路径 `.exp` 行为不回归。

- [ ] Step 1: 写当前状态检查（cmd_init 尚未 wire）
  - Run: `sed -n '/^cmd_init()/,/^cmd_dev()/p' lib/commands.sh | grep -c 'init_intake'`
  - Expected: `0`（cmd_init 段还没调 init_intake）
- [ ] Step 2: 确认当前状态
  - Run: `sed -n '/^cmd_init()/,/^cmd_dev()/p' lib/commands.sh | grep -cE 'exit_on_user_cancel .*"init"'`
  - Expected: `2`（L299/L303 两处 init 的 exit_on_user_cancel 仍在）
- [ ] Step 3: 写最小实现
  - 把 `cmd_init` 内从注释 `# 解析 machine（Step 2 的一部分，交互选择或确认命令行参数）。`（约 L266）到 `info "Init confirmed for machine '$MACHINE'."` 后的 `fi`（约 L306）整段替换为：
    ```bash
        # 解析+确认 machine(经 ob init command intake module: empty/arg 校验/pick/confirm, return 0/1/2/3)。
        # 原 L266-306 内联决策树(含 exit_on_user_cancel 2 处)已抽进 lib/init_intake.sh; exit 由本 L1 字面 case 收口。
        local _irc=0
        init_intake || _irc=$?
        case "$_irc" in
            0) ;;
            1) exit 1 ;;
            2) exit 2 ;;
            3) exit 3 ;;
            *) exit 1 ;;
        esac
    ```
  - Change: 删除该段内全部内联逻辑（list 枚举 / empty exit / arg 校验 fastpath / nontty exit / `pick_machine` / 2 处 `exit_on_user_cancel "... "init"` / `confirm_action`），替换为上述 intake 调用 + 字面 case。`# Re-derive paths`（L308 起）及之后不动。
- [ ] Step 4: 运行并确认通过
  - Run: `sed -n '/^cmd_init()/,/^cmd_dev()/p' lib/commands.sh | grep -q 'init_intake' && ! sed -n '/^cmd_init()/,/^cmd_dev()/p' lib/commands.sh | grep -qE 'exit_on_user_cancel|pick_machine|confirm_action' && echo "wire-clean" && tests/run_all.sh --full >/dev/null 2>&1 && echo "behavior-unchanged"`
  - Expected: `wire-clean`（cmd_init 段已含 init_intake、且不再含 exit_on_user_cancel/pick_machine/confirm_action）+ `behavior-unchanged`（`run_all.sh --full` 退出 0）。
  - 注（行为锁覆盖面）: manual_matrix.exp 的 `init non-TTY`(exit 3, L51)无条件跑; 但 `init cancel`(TTY 取消 exit 2, L74)条件依赖 has_ws(workspace 有 init+build machine 才跑, 否则 `incr SKIP 3`, L112)——bare 环境下行为不变回归锁实际只锁 non-TTY 路径, init cancel 的 TTY 路径需有 workspace 的环境才真正施加约束。

### Task 4: 登记 WORKSPACE / coverage_matrix + 最终验证

- 目标：把新 module 登记进路由表与覆盖矩阵，跑全套配套自检收口。
- Files
  - Modify: `rules/03_WORKSPACE.md`（lib 路由表，[L11](../../rules/03_WORKSPACE.md#L11)）
  - Modify: `tools/coverage_matrix.md`（init 段，[L15-28](../../tools/coverage_matrix.md#L15)）
- 接口契约
  - Consumes: Task 2/3 产出的 `init_intake` + wired cmd_init。
  - Produces: 无（登记 + 验证收口）。
- 验证范围：WORKSPACE/coverage_matrix 已登记 + ob_check + exit_contract + run_all 全过。

- [ ] Step 1: 写当前状态检查（尚未登记）
  - Run: `! grep -q 'init_intake.sh' rules/03_WORKSPACE.md && ! grep -q 'init_intake' tools/coverage_matrix.md && echo "not-registered"`
  - Expected: `not-registered`
- [ ] Step 2: 确认当前缺失
  - Run: `grep -c 'init_intake' rules/03_WORKSPACE.md tools/coverage_matrix.md`
  - Expected: `0`（两文件都未登记）
- [ ] Step 3: 写登记
  - Modify `rules/03_WORKSPACE.md` lib 路由表（L11 的 `lib/` 条目内）：在 `devtool_intake.sh` 条目后追加 ` / \`init_intake.sh\` ob init 命令入口解析+确认(机器解析决策树 empty/arg校验/pick/confirm, leaf-pure, return 0/1/2/3; 同 devtool_intake 同构; guard 第3消费暂缓 ADR-0016) `。
  - Modify `tools/coverage_matrix.md` 的 `## init` 段：新增一行登记——
    `| 命令入口机器解析+确认(intake module) | init_intake | unit/init_intake.sh;protocol/init_intake_surface.sh | leaf-pure(同 devtool_intake);return 0/1/2/3,exit 由 cmd_init 字面 case 收口;empty/arg-fastpath/nontty 三态 unit 覆盖,pick+confirm cancel/ok 留 .exp |`
- [ ] Step 4: 运行并确认通过
  - Run: `grep -q 'init_intake.sh' rules/03_WORKSPACE.md && grep -q 'init_intake' tools/coverage_matrix.md && python3 tools/exit_contract.py >/dev/null && tools/ob_check.sh >/dev/null 2>&1 && tests/run_all.sh >/dev/null 2>&1 && echo "FINAL-PASS"`
  - Expected: `FINAL-PASS`（登记就位 + exit_contract leaf-pure + ob_check 配套自检 + run_all 快速三层全过）。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效先修计划。
- 按任务顺序执行，不无声跳步、合并步或改任务目标。
- 每完成一个任务，运行该任务定义的验证（Run 命令以 `test`/`grep -q`/`! grep -q`/测试脚本退出码收口，不让 echo 吞 rc）。
- 遇阻塞、重复失败或计划与仓库现实不符立即停下说明，不猜。
- 当前在 `main` 分支：开始实现前与用户确认是否切特性分支。
- 全部任务完成后运行最终验证并输出修改摘要。

## 最终验证

- Run: `python3 tools/exit_contract.py >/dev/null && tools/ob_check.sh >/dev/null 2>&1 && tests/run_all.sh >/dev/null 2>&1 && tests/run_all.sh --full >/dev/null 2>&1 && echo "ALL-FINAL-PASS"`
- coverage 实测（bestpractice_10 #4，非阻塞）: `tools/trace_collect.sh | python3 tools/coverage_radar.py - --cross-check` —— 确认 `init_intake` 出现在 COVERED 集（被 unit/init_intake.sh 的 xtrace 命中）。若报 uncovered 但 unit 已覆盖，属 xtrace 子 shell 低估（同 bare_mirror 先例，[coverage_matrix L25](../../tools/coverage_matrix.md) 已记"顶层调用补偿"），按 bestpractice_10 §6 校准 baseline 或补 trace 采集，非真盲区。CI 阻断阈值维持 `--fail-if-uncovered 7`（init_intake 被覆盖，预期不增 uncovered）。
- Expected: `ALL-FINAL-PASS`（exit_contract leaf-pure / ob_check 配套自检 / run_all 快速三层 / run_all --full 含 .exp 行为不回归 全过）。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-29-cmd-init-intake-extraction-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
