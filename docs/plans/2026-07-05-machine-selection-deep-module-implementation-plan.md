# machine selection 深 module 实施计划

## 目标

把"machine 选择"这个被复制 4 遍、且带一个 exit-code 契约 bug 的浅模式，深化成单一深 module `pick_machine`（`lib/machine_picker.sh`）。4 个 `cmd_*` 调用点（`cmd_build` / `cmd_start_qemu` / `cmd_stop_qemu` / `cmd_init`）统一走它；退役 `resolve_machine`（init 旧函数）与 `select_from_list`（零调用者的旧数字原语）；元数据移出选择表；附带修 `cmd_menu` 非交互终端 `exit 1`→`exit 3` 的契约 bug（ADR-0003 回归修正）。过程中先建测试网锁行为，再抽 module 迁移调用点，最后上结构锁清零旧 surface。

设计来源：本仓 grill-with-docs 会话定稿的 Q1-Q8 八条决策。**不新增 ADR**（Q8 决策：machine selection 的"为什么"全可被 `CONTEXT.md` + surface gate 替代，属 ADR 边际价值最低的"部分可替代型"；与 ADR-0006 协同、强化 ADR-0003）。

## 架构快照

- **新 module**：`lib/machine_picker.sh` 的 `pick_machine <list-source> <verb>`——leaf-pure L3，渲染纯序号+名字选择表，读输入（数字或名字），设 `$MACHINE`，`return 0`/`2`（`1`=read 失败），**绝不 exit**。前提（caller 保证）：`<list-source>` 产出非空 machine 列表 + 交互终端。`ob` 的 `for f in lib/*.sh` glob source、`ob_check.sh` 的 `OB_SOURCES+=(lib/*.sh)`、`exit_contract.py`、`coverage_radar.py`、`extract_funcs.py` 均按 basename/glob 工作 → 新增文件零 source/import 配置；**但** `exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 必须登记 `'machine_picker.sh': set()`（见 Task 1.1）——这不是负担而是让 `check_Y` 守护 leaf-pure 不变量的必要登记（类比 `machine_state.sh`，已读源码确认未登记则 check_Y 跳过该 basename）。
- **exit 归属**：`pick_machine` 不 exit（leaf-pure）；空集合 / 非 TTY / arg 合法性 / remedy / exit 码全留 caller（命令前置，因命令而异：`cmd_stop_qemu` 空实例=exit 0 良性，`cmd_build`/`cmd_start_qemu` 空列表=exit 3 前置缺失）；cancel（rc 2）由 caller 复用现有 `exit_on_user_cancel <rc> <verb>`（`commands.sh:200`，rc 2→exit 2）翻译。
- **元数据归属**：选择表只管"选"（纯序号+名字），machine 元数据（init_time/repo_count/running 状态）移出——`ob status`（`status_section_machines`）已完整展示且更全。
- **测试网**：extract→pin→deepen 顺序。`pick_machine` 是 leaf-pure，here-string 喂 stdin 即可单测（先例 `tests/unit/interact.sh`）。
- **scope 边界**：本 pass 只碰 machine 选择 4 调用点 + `cmd_menu` exit bug；off-path（`PIDFILE_*` 收口、git-mirror-url 去重、`exit_on_user_cancel` 三段式、status 多实例呈现）**不碰**，留下一 pass。

## 输入工件

- 设计：grill-with-docs 会话（本仓当前会话上下文）Q1-Q8 结晶决策。
- 术语：`CONTEXT.md`（`machine selection` 条目已落盘，与 `machine lifecycle state` 正交）。
- 协同 ADR：ADR-0006（`machine_state` 提供 machine-name list interface，`pick_machine` 消费它）；ADR-0003（exit-code 契约，`cmd_menu` 修正回归它）。
- 先例：`docs/plans/2026-07-04-qemu-sh-deepening-implementation-plan.md`（同范式：行为锁→抽 module→结构锁）。

## 文件结构与职责

- Create: `lib/machine_picker.sh` — `pick_machine <list-source> <verb>`（leaf-pure L3，渲染+选择+设 `$MACHINE`/cancel，不 exit）。
- Create: `tests/unit/pick_machine.sh` — `pick_machine` 契约单测（数字/名字/cancel/越界重试 + return 码 + `$MACHINE`）。
- Modify: `lib/commands.sh` — `cmd_build` / `cmd_start_qemu` / `cmd_stop_qemu` 三处 `select_from_list`+`SELECT_FROM_LIST_CHOICE` 改调 `pick_machine` + `exit_on_user_cancel`；`cmd_init` 改调 `pick_machine`（不再调 `resolve_machine`）；`cmd_menu` 非交互 guard `exit 1`→`exit 3`。
- Modify: `lib/repo.sh` — 删 `resolve_machine`（377-466）；保留 `list_available_machines` / `print_available_machines` / `print_previously_initialized`（init 专用展示，`cmd_init` 直调）。
- Modify: `lib/util.sh` — 删 `select_from_list`（478-494）与其上 `SELECT_FROM_LIST_CHOICE` 全局（零调用者后）。
- Modify: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'machine_picker.sh': set()`（类比 `machine_state.sh`，让 `check_Y` 守护 `pick_machine` 绝不 exit；未登记则 `check_Y` 跳过该 basename，留守护缺口）。
- Modify: `tools/ob_check.sh` — 加 machine selection surface gate（照搬 46-53 的 `machine_state_records` gate 模式）。
- Modify: `tests/protocol/exit_codes.sh` — 补 machine 选择 exit 码现状锁（回归基线）+ `cmd_menu` 非TTY=exit 3。
- Modify: `tests/unit/interact.sh` — 删 `select_from_list` 单测段（12-16）+ 文件头注释。
- Modify: `rules/03_WORKSPACE.md` — `lib/` 路由行加 `machine_picker.sh`。
- Modify: `CONTEXT.md` — 已落盘 `machine selection` 条目（本计划执行前已修正 `select_from_list` 措辞矛盾）。

## 任务清单

### Task 0.1: 切 feature 分支 + 首个 commit

- 目标：在独立分支上开工，首个 commit 落下已完成的 `CONTEXT.md` 修订 + 本计划文档。
- Files: 已 Modify `CONTEXT.md`；已 Create 本计划。
- 验证范围：分支存在；首个 commit 含两文件。

- [ ] Step 1: 写当前状态检查
- Run: `git status --short; git branch --show-current`
- Expected: 当前在 `main`，`CONTEXT.md` 与 `docs/plans/2026-07-05-machine-selection-deep-module-implementation-plan.md` 显示为变更/新增。
- [ ] Step 2: 确认未在 main 直接动实现
- Run: 同上。
- Expected: `main`，尚未开始 Task 1.1 的代码改动。
- [ ] Step 3: 切分支 + 首个 commit
- Change: `git checkout -b feature/machine-selection-deepening`；`git add CONTEXT.md docs/plans/2026-07-05-machine-selection-deep-module-implementation-plan.md && git commit`。
- [ ] Step 4: 运行并确认通过
- Run: `git branch --show-current; git log --oneline -1`
- Expected: `feature/machine-selection-deepening`；首 commit 为 CONTEXT+计划文档。

### Task 1.1: 写 pick_machine 单测 + 实现 lib/machine_picker.sh（TDD）

- 目标：用 here-string 喂 stdin 的单测锁住 `pick_machine` 契约（数字/名字/cancel/越界重试 + return 码 + `$MACHINE`），再实现 leaf-pure 的 `pick_machine`。
- Files: Create `lib/machine_picker.sh`；Create `tests/unit/pick_machine.sh`；Modify `tools/exit_contract.py`（白名单登记）。
- 验证范围：`tests/unit/pick_machine.sh` rc=0；`exit_contract` 的 X/Y/Z 全 PASS；`tools/ob_check.sh` 全绿（新文件被 `lib/*.sh` glob 自动纳入）。

- [ ] Step 1: 写失败测试
- Change: 建 `tests/unit/pick_machine.sh`，骨架（`source tests/lib/{ob_loader,assert}.sh` → `assert_reset` → 定义 `__pick_test_list()` 印 `romulus`/`witherspoon` → 5 组断言）：

```bash
#!/usr/bin/env bash
# tests/unit/pick_machine.sh — pick_machine 契约单测(unit 层,here-string 喂 stdin)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

__pick_test_list() { printf '%s\n' romulus witherspoon; }

# 数字选择
MACHINE=""; pick_machine __pick_test_list Build <<< $'1\n' >/dev/null 2>&1; assert_eq "number 1 rc" "$?" 0
assert_eq "number 1 MACHINE" "$MACHINE" "romulus"
MACHINE=""; pick_machine __pick_test_list Build <<< $'2\n' >/dev/null 2>&1; assert_eq "number 2 rc" "$?" 0
assert_eq "number 2 MACHINE" "$MACHINE" "witherspoon"
# 名字选择(exact match)
MACHINE=""; pick_machine __pick_test_list Build <<< $'witherspoon\n' >/dev/null 2>&1; assert_eq "name rc" "$?" 0
assert_eq "name MACHINE" "$MACHINE" "witherspoon"
# cancel(0)
MACHINE=""; pick_machine __pick_test_list Build <<< $'0\n' >/dev/null 2>&1; assert_eq "cancel rc" "$?" 2
# read 失败(EOF/非TTY) → 打印 error + return 1（遵 select_from_list 旧约定：L3 helper 自打 read-fail error，exit_on_user_cancel 只 exit）
MACHINE=""; pick_machine __pick_test_list Build </dev/null >/dev/null 2>&1; assert_eq "eof read-fail rc" "$?" 1
# 越界/非法 → 重试后有效
MACHINE=""; pick_machine __pick_test_list Build <<< $'9\nfoo\nromulus\n' >/dev/null 2>&1; assert_eq "invalid then valid rc" "$?" 0
assert_eq "invalid then valid MACHINE" "$MACHINE" "romulus"

assert_summary
```

- Run: `bash tests/unit/pick_machine.sh; echo rc=$?`
- Expected: rc≠0（`pick_machine` 未定义，ob_loader source ob 时 `lib/machine_picker.sh` 不存在）。
- [ ] Step 2: 运行并确认失败
- Run: 同上。
- Expected: rc≠0。
- [ ] Step 3: 写最小实现
- Change: 建 `lib/machine_picker.sh`：

```bash
#!/usr/bin/env bash
# lib/machine_picker.sh — machine selection 交互选择 module。术语见 CONTEXT.md machine selection.
# Exit: leaf-no-exit（leaf-pure module）; return 0(设 $MACHINE)/2(cancel)/1(read 失败), 绝不 exit.


# pick_machine <list-source-cmd> <verb>
# 前提(调用者保证): <list-source-cmd> 产出非空 machine 列表(每行一名) + 交互终端。
# 渲染纯序号+名字选择表 → 读输入(数字或名字) → 设 $MACHINE / return 2(cancel)。
# 不判空/不判 TTY/不做 arg 校验/不 exit — 这些是调用者命令前置。
pick_machine() {
    local list_source="$1" verb="$2"
    local -a machines=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && machines+=("$line")
    done < <("$list_source")

    local total=${#machines[@]}
    local idx_width=${#total}
    local i
    for (( i=0; i<total; i++ )); do
        printf "  %${idx_width}d) %s\n" "$((i + 1))" "${machines[$i]}"
    done

    local selected m
    while true; do
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Select a machine for ${verb} [1-${total}] (number or name, 0 to cancel): ")" selected; then
            error "Unable to read machine selection from stdin."
            return 1
        fi
        [[ "$selected" == "0" ]] && return 2
        if [[ "$selected" =~ ^[0-9]+$ ]] && [[ "$selected" -ge 1 && "$selected" -le "$total" ]]; then
            MACHINE="${machines[$((selected - 1))]}"
            return 0
        fi
        for m in "${machines[@]}"; do
            if [[ "$m" == "$selected" ]]; then
                MACHINE="$m"
                return 0
            fi
        done
        warn "Invalid selection '$selected'. Enter a number (1-${total}) or a machine name."
    done
}
```

- Change（白名单登记）：在 `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（53-58 行字典）加 `'machine_picker.sh': set(),`（置于 `'machine_state.sh': set(),` 之后）——未登记则 `check_Y` 跳过该 basename、不守护 leaf-pure（已读源码确认 182 行仅迭代已登记 basename）。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/pick_machine.sh; echo rc=$?`
- Expected: rc=0（`PASS=... FAIL=0`）。
- Run: `python3 tools/exit_contract.py 2>&1 | grep -E '^[XYZ]:'`
- Expected: `X: PASS` / `Y: PASS` / `Z: PASS`（`machine_picker.sh` 已登记；`pick_machine` 无 exit，Y 通过）。
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/machine_picker.sh tests/unit/pick_machine.sh tools/exit_contract.py && git commit -m "feat(machine_picker): pick_machine 深 module + 契约单测 + leaf-pure 白名单登记"`
- Expected: commit 成功。

### Task 1.2: 扩 exit_codes.sh 锁机器选择 exit 码现状（回归基线）

- 目标：在动调用点前，先用 `assert_ob_rc` 锁住 4 个机器选择命令的空/非TTY exit 码现状，作为迁移期间的回归基线（不含 cancel——cancel 走 TTY，由 `manual_matrix.exp` 覆盖，protocol 层测不了）。
- Files: Modify `tests/protocol/exit_codes.sh`。
- 验证范围：本 task 测试 rc=0（锁的是现状，应全绿）；后续迁移 task 以它为回归门。

- [ ] Step 1: 写当前状态检查
- Run: `grep -nE 'build empty|start-qemu missing|stop-qemu no instances' tests/protocol/exit_codes.sh`
- Expected: 命中现有 3 条（build empty=3、start-qemu missing init-done=3、stop-qemu no instances=0）——确认基线已部分存在，本 task 只补差额。
- [ ] Step 2: 运行并确认现状
- Run: `bash tests/protocol/exit_codes.sh; echo rc=$?`
- Expected: rc=0（现状绿）。
- [ ] Step 3: 补差额断言
- Change: 扩展 `assert_ob_rc` 支持 per-case setup hook + 补 4 个「有候选 + 非 TTY = exit 3」case。
  - **(a) 扩展 assert_ob_rc（测试基建）**：在子进程的 `detect_harness_root` 之后、`case "$COMMAND"` 之前插入 `if [[ -n "${OB_RC_SETUP:-}" ]] && declare -F "$OB_RC_SETUP" >/dev/null; then "$OB_RC_SETUP" "$tmp"; fi`。setup 函数在 exit_codes.sh 顶层定义（`( )` 子 shell 继承父函数定义），通过环境变量 `OB_RC_SETUP=...` 触发——不破坏现有 `assert_ob_rc <exp> <label> <args...>` 调用签名。
  - **(b) 4 个 setup 函数 + case（关键回归门：防 caller 漏 `[[ -t 0 ]]` guard）**——每条都必须把命令在选择前的**全部前置**（`require_path`/`require_openbmc_repo`/`verify_source`）造齐，否则前置提前 exit 3 会假绿（F1/F2）：
    - `_setup_build_candidates`：`mkdir -p $tmp/workspace/openbmc/.git`（过 `require_path $OPENBMC_DIR/.git`，`-e` 认目录）+ 写 `$tmp/workspace/configs/openbmc-source.manifest`（`origin_url=...`/`source_label=community`，过 `require_path $SOURCE_MANIFEST_FILE` + `read_manifest_field`）+ `: > romulus.init-done` + `: > romulus.snapshot`；case `OB_RC_SETUP=_setup_build_candidates assert_ob_rc 3 "build candidates but non-TTY" build`。
    - `_setup_start_qemu_candidates`：init-done + `$tmp/workspace/openbmc/build/romulus/tmp/deploy/images/romulus/romulus.static.mtd`；case `... assert_ob_rc 3 "start-qemu candidates but non-TTY" start-qemu`。
    - `_setup_stop_qemu_candidates`：`mkdir -p .../qemu-bin/.pids && : > romulus.pid`；case `... assert_ob_rc 3 "stop-qemu candidates but non-TTY" stop-qemu`。
    - `_setup_init_candidates`：`mkdir -p $tmp/workspace/openbmc/.git`（过 `require_openbmc_repo` 的 `-d` 判定，跳过 clone）+ 写 `openbmc-source.manifest`（过 `.git` 存在时 `require_openbmc_repo` 内部调的 `verify_source`）+ **override `list_available_machines(){ printf 'romulus\n'; }`**（setup 函数在子 shell 内被 hook 调用，重定义对后续 dispatch 生效——F2 已实测可行）；case `OB_RC_SETUP=_setup_init_candidates assert_ob_rc 3 "init candidates but non-TTY" init`。
  - **空 workspace 基线**保留（`start-qemu empty workspace`=3，与 missing-init-done 区分）。
  - 4 条「候选+非TTY」锁的是「caller 在调 pick_machine 前必须有 `[[ -t 0 ]] guard」——迁移时若某 caller 漏 guard，pick_machine 在非 TTY 下 read fail → exit_on_user_cancel exit 1，基线变红。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/protocol/exit_codes.sh; echo rc=$?`
- Expected: rc=0（基线锁住，含新增条目）。
- [ ] Step 5: checkpoint commit
- Run: `git add tests/protocol/exit_codes.sh && git commit -m "test(protocol): 锁 machine 选择 exit 码现状基线"`
- Expected: commit 成功。

### Task 2.1: 迁移 cmd_start_qemu 调 pick_machine

- 目标：`cmd_start_qemu` 的 machine 选择段（`commands.sh:470-514`）从 `select_from_list`+`SELECT_FROM_LIST_CHOICE` 改调 `pick_machine`+`exit_on_user_cancel`。选它作首个——今天就是纯序号表，无元数据融合，是 `pick_machine` 最干净的消费者。
- Files: Modify `lib/commands.sh`（`cmd_start_qemu`）。
- 验证范围：`tools/ob_check.sh` 全绿；`tests/protocol/exit_codes.sh` 绿（含 Task 1.2 基线）；`tests/protocol/start_qemu_remedy.sh` 绿。

- [ ] Step 1: 写当前状态检查
- Run: `grep -nE 'select_from_list|SELECT_FROM_LIST_CHOICE' lib/commands.sh | grep -E 'cmd_start_qemu|511|513' || sed -n '510,514p' lib/commands.sh`
- Expected: 命中 `cmd_start_qemu` 内的 `select_from_list`(511) 与 `SELECT_FROM_LIST_CHOICE`(513)。
- [ ] Step 2: 运行并确认现状
- Run: 同上。
- Expected: 确认旧调用点存在。
- [ ] Step 3: 写最小实现
- Change: 把 `cmd_start_qemu` 选择段（渲染纯序号表 505-507 + `select_from_list`(511) + `exit_on_user_cancel`(512) + `MACHINE=...[$((SELECT_FROM_LIST_CHOICE - 1))]`(513)）替换为：保留非空/非TTY 前置（479-498，不动）→ 删自渲染序号表（`pick_machine` 自己印）→ `local pm_rc=0; pick_machine machine_state_firmware_image_ready_machines "Start QEMU" || pm_rc=$?; exit_on_user_cancel "$pm_rc" "Start QEMU"`。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`（`cmd_start_qemu` 已不直调 `select_from_list`；但 `cmd_build`/`cmd_stop_qemu` 仍调——surface gate 本 task 未上，故 ob_check 不拦）。
- Run: `bash tests/protocol/exit_codes.sh; echo rc=$?`；`bash tests/protocol/start_qemu_remedy.sh; echo rc=$?`
- Expected: rc=0 / rc=0。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/commands.sh && git commit -m "refactor(start-qemu): machine 选择改调 pick_machine"`
- Expected: commit 成功。

### Task 2.2: 迁移 cmd_stop_qemu + 消除全局篡改 + 状态移到选择后

- 目标：`cmd_stop_qemu` 选择段（`commands.sh:631-672`）改调 `pick_machine`；消除循环里对全局 `MACHINE`/`QEMU_PID_FILE` 的临时篡改（656-657，原为渲染 running/stale 状态）；running/stale 状态改为选择后、执行 stop 前的单行提示（Q3 决策）。
- Files: Modify `lib/commands.sh`（`cmd_stop_qemu`）。
- 验证范围：`tools/ob_check.sh` 全绿；`tests/protocol/exit_codes.sh` 绿（stop-qemu no instances=0 特例不破）；`tests/protocol/stop_qemu_dryrun.sh` 绿。

- [ ] Step 1: 写当前状态检查
- Run: `sed -n '650,671p' lib/commands.sh`
- Expected: 看到选择循环内 `MACHINE="$m"`(656)、`QEMU_PID_FILE=...`(657)、`read_pid_file && validate_pid`(659) 渲染 `status_str`，以及 `select_from_list`(669)+`SELECT_FROM_LIST_CHOICE`(671)。
- [ ] Step 2: 运行并确认现状
- Run: 同上。
- Expected: 确认全局篡改点 + 旧选择调用。
- [ ] Step 3: 写最小实现
- Change: 把 `*.pid` 收集逻辑提成 module 级函数 `__stop_qemu_running_machines()`（定义在 `commands.sh` 顶层，**非** `cmd_stop_qemu` 内的 local——bash 函数名作 `pick_machine` 的 list-source 间接调用须在 module 级可见），印 `"$WORKSPACE_DIR/qemu-bin/.pids/"*.pid` 对应的 machine 名（每行一个）。选择段改为：`available=( $(__stop_qemu_running_machines) )` → 空实例 `exit 0`(638-641 逻辑保留，基于 `available`) → 非TTY `exit 3`(643-647 不动）→ 删自渲染带状态表（650-665）→ `local pm_rc=0; pick_machine __stop_qemu_running_machines "Stop QEMU" || pm_rc=$?; exit_on_user_cancel "$pm_rc" "Stop QEMU"`。删 656-657 选择循环内对 `MACHINE`/`QEMU_PID_FILE` 的全局篡改。选中后（`$MACHINE` 已设）在 stop 循环内执行前补一行状态提示：`read_pid_file && validate_pid ... && info "stopping running instance (PID $PIDFILE_PID)" || warn "stale PID file, cleaning up"`。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`。
- Run: `bash tests/protocol/exit_codes.sh; echo rc=$?`；`bash tests/protocol/stop_qemu_dryrun.sh; echo rc=$?`
- Expected: rc=0 / rc=0（stop_qemu no instances=0 不破）。
- Run: `grep -nE 'MACHINE="\$m"|QEMU_PID_FILE="\$WORKSPACE' lib/commands.sh | grep -A0 -B0 '6[0-9][0-9]' || echo NONE`
- Expected: `NONE`（选择循环内的全局篡改已消除）。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/commands.sh && git commit -m "refactor(stop-qemu): pick_machine + 消除选择循环全局篡改 + 状态移到选择后"`
- Expected: commit 成功。

### Task 2.3: 迁移 cmd_build（融合表元数据移出）

- 目标：`cmd_build` 选择段（`commands.sh:285-363`）改调 `pick_machine`；按 Q3 移除融合表里的 machine 元数据（init_time/repo_count，`ob status` 已有且更全），选择表交给 `pick_machine` 印纯序号。
- Files: Modify `lib/commands.sh`（`cmd_build`）。
- 验证范围：`tools/ob_check.sh` 全绿；`tests/protocol/exit_codes.sh` 绿。

- [ ] Step 1: 写当前状态检查
- Run: `sed -n '324,362p' lib/commands.sh`
- Expected: 看到 `Initialized Machines` 展示块（325-345，含 manifest 信息 + 序号+init_time+repo_count 融合表）+ 非TTY guard(349-353) + `select_from_list`(356)+`exit_on_user_cancel`(357)+`SELECT_FROM_LIST_CHOICE`(358)。
- [ ] Step 2: 运行并确认现状
- Run: 同上。
- Expected: 确认融合表 + 旧选择调用。
- [ ] Step 3: 写最小实现
- Change: 保留 arg 快路径（285-292，不动）+ 空列表 `exit 3`(309-317，不动) + 非TTY `exit 3`(349-353，不动）。删 machine 融合表渲染（`init_time_by_machine`/`repo_count_by_machine` 收集 298-307 + 打印循环 332-342 + 元数据列）。manifest 仓库信息块（325-328，`Source`/`Path`）保留（非 machine 选择元数据）。替换为：`local pm_rc=0; pick_machine machine_state_initialized_machines "Build" || pm_rc=$?; exit_on_user_cancel "$pm_rc" "Build"`，后接 `BUILD_DIR=...`/`interactive_selection=1`（360-362 保留）。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`。
- Run: `bash tests/protocol/exit_codes.sh; echo rc=$?`
- Expected: rc=0。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/commands.sh && git commit -m "refactor(build): pick_machine + 选择表元数据移出 (看 ob status)"`
- Expected: commit 成功。

### Task 2.4: 迁移 cmd_init + 退役 resolve_machine

- 目标：`cmd_init` 不再调 `resolve_machine`，改为前置（arg 快路径 + 非TTY）+ 选择前展示（`print_available_machines`/`print_previously_initialized`，留 repo.sh）+ `pick_machine` + `confirm_action`；从 `repo.sh` 删 `resolve_machine`（377-466）。
- Files: Modify `lib/commands.sh`（`cmd_init` 753-848）；Modify `lib/repo.sh`（删 `resolve_machine`）。
- 验证范围：`tools/ob_check.sh` 全绿；`tests/protocol/exit_codes.sh` 绿（init non-TTY=3 不破）。

- [ ] Step 1: 写当前状态检查
- Run: `grep -n 'resolve_machine' lib/commands.sh lib/repo.sh`
- Expected: `commands.sh:765`（调用）、`commands.sh:767`（注释）、`repo.sh:377`（定义）。
- [ ] Step 2: 运行并确认现状
- Run: 同上。
- Expected: 确认 3 处 `resolve_machine`。
- [ ] Step 3: 写最小实现
- Change: (a) `cmd_init`：把 `resolve_machine`(765) 调用替换为**显式**编排——先 `mapfile -t _init_machines < <(list_available_machines)`；**显式空列表 guard（resolve_machine 旧版缺这条，TTY+空会进 `[1-0]` 无效循环——F4）**：`[[ ${#_init_machines[@]} -eq 0 ]] → error "No machines found in $OPENBMC_DIR." + error "Run 'git clone ...' or check the OpenBMC main repo." + exit 3`；arg 快路径（`$MACHINE` 非空且在 `_init_machines` 内 → 直接用）；非TTY guard `[[ ! -t 0 ]] → exit 3`；选择前 `print_available_machines` + `print_previously_initialized`（展示留 caller）；`local pm_rc=0; pick_machine list_available_machines "init" || pm_rc=$?; exit_on_user_cancel "$pm_rc" "init"`；`confirm_action "init" "$MACHINE"`（原 456，留 caller）。**改 767 注释（F1）**：`Re-derive paths (machine may have changed via interactive resolve_machine)` → 把 `resolve_machine` 换成 `pick_machine`（否则 surface gate 命中注释）。路径重导（768-769）保留。(b) 从 `lib/repo.sh` 删 `resolve_machine` 整个函数（377-466）。
- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`。
- Run: `grep -rn 'resolve_machine' lib/`
- Expected: 仅可能的 `resolve_machine_conf_include`（qemu_launch_profile 的无关函数）——**不得**有 `resolve_machine`（无 `_conf_include` 后缀）的残留定义或调用。
- Run: `bash tests/protocol/exit_codes.sh; echo rc=$?`
- Expected: rc=0（init non-TTY=3 不破）。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/commands.sh lib/repo.sh && git commit -m "refactor(init): pick_machine + 退役 resolve_machine"`
- Expected: commit 成功。

### Task 3.1: 删 select_from_list + 清 interact.sh 单测

- 目标：4 调用点已全迁，`select_from_list` 零调用者，从 `util.sh` 删定义；清 `tests/unit/interact.sh` 里它的单测段。
- Files: Modify `lib/util.sh`；Modify `tests/unit/interact.sh`。
- 验证范围：`tools/ob_check.sh` 全绿；`tests/unit/interact.sh` rc=0（删段后其余单测仍绿）。

- [ ] Step 1: 写当前状态检查
- Run: `grep -rn 'select_from_list' lib/`
- Expected: 仅 `lib/util.sh:474`(注释)/`478`(定义)——确认无生产调用者（4 调用点已迁）。
- [ ] Step 2: 运行并确认现状
- Run: 同上。
- Expected: 确认零调用者。
- [ ] Step 3: 写最小实现
- Change: (a) 从 `lib/util.sh` 删 `select_from_list` 函数（474-494，含其上注释）；（b)`tests/unit/interact.sh` 删 `--- select_from_list ---` 段（12-16），文件头注释（3）去掉 `select_from_list`；（c）**清 `commands.sh` 的 `exit_on_user_cancel` 注释（F1）**——196 行 `消费 select_from_list / confirm_action 的 rc` → `消费 pick_machine / confirm_action 的 rc`；198 行 `read-fail 的 error 已由 L3 调用方 select_from_list/confirm_action 打印` → `... pick_machine/confirm_action 打印`（深化后 exit_on_user_cancel 消费 pick_machine 的 rc，注释不能再提已退役的 select_from_list，否则 surface gate 命中注释）。
- [ ] Step 4: 运行并确认通过
- Run: `grep -rn 'select_from_list' lib/ || echo NONE`
- Expected: `NONE`（util.sh 已无定义）。
- Run: `bash tests/unit/interact.sh; echo rc=$?`；`tools/ob_check.sh`
- Expected: rc=0（confirm_action/exit_on_user_cancel/prompt 单测仍绿）+ `ALL GREEN`。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/util.sh tests/unit/interact.sh && git commit -m "refactor(util): 退役 select_from_list (零调用者) + 清单测"`
- Expected: commit 成功。

### Task 3.2: ob_check.sh 加 machine selection surface gate

- 目标：在 `ob_check.sh` 的 `machine_state_records` gate（46-53）之后，加 machine selection 旧 surface 清零 gate，防止旧路径回流。
- Files: Modify `tools/ob_check.sh`。
- 验证范围：`tools/ob_check.sh` 全绿（新 gate 命中 0，因 Task 2.x/3.1 已清零）；人为注入一行旧调用应使 gate 红（可选手测）。

- [ ] Step 1: 写当前状态检查
- Run: `grep -nE 'select_from_list|SELECT_FROM_LIST_CHOICE|(^|[^[:alnum:]_])resolve_machine($|[^[:alnum:]_])' lib/*.sh || echo NONE`
- Expected: `NONE`。**注意（F1）**：gate 正则扫注释——若命中非空，先确认是不是 Task 2.4（767 注释）/ Task 3.1（196/198 注释）漏清的旧 surface 注释；注释也算命中，必须清到 `NONE` 才能上 gate。`resolve_machine_conf_include` 不被误命中（正则用词边界且要求 `resolve_machine` 后非 `_`）。
- [ ] Step 2: 运行并确认现状
- Run: 同上。
- Expected: `NONE`。
- [ ] Step 3: 写最小实现
- Change: 在 `ob_check.sh` 的 `machine_state_surface` gate 块（53 行 `ok` 之后）插入：

```bash
# ── 1c. machine selection 旧 surface 清零门禁 ──
# 生产代码不得内联机器选择：commands.sh 不直接调 select_from_list / 不引用
# SELECT_FROM_LIST_CHOICE（机器选择走 pick_machine）；repo.sh 不定义 resolve_machine。
machine_select_legacy_re='select_from_list|SELECT_FROM_LIST_CHOICE|(^|[^[:alnum:]_])resolve_machine($|[^[:alnum:]_])'
machine_select_legacy_hits=$(grep -RInE "$machine_select_legacy_re" lib/*.sh 2>/dev/null || true)
if [[ -n "$machine_select_legacy_hits" ]]; then
    bad "machine selection legacy surface still in use (must go through pick_machine)"
    printf '%s\n' "$machine_select_legacy_hits"
else
    ok "machine selection legacy surface removed"
fi
```

- [ ] Step 4: 运行并确认通过
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`，含 `machine selection legacy surface removed`。
- Run（手测 gate 有效，可选）：`echo 'select_from_list x 2' >> /tmp/_gate_probe && cp lib/util.sh /tmp/_util.bak && echo 'select_from_list(){ :; }' >> lib/util.sh && (tools/ob_check.sh 2>&1 | grep -q 'machine selection legacy surface still in use' && echo GATE_WORKS || echo GATE_BROKEN); cp /tmp/_util.bak lib/util.sh`
- Expected: `GATE_WORKS`（注入旧调用后 gate 红）；恢复后回到 `ALL GREEN`。
- [ ] Step 5: checkpoint commit
- Run: `git add tools/ob_check.sh && git commit -m "test(ob_check): machine selection surface gate (防 select_from_list/resolve_machine 回流)"`
- Expected: commit 成功。

### Task 3.3: cmd_menu exit 1→3 修正 + protocol 锁

- 目标：修 `cmd_menu` 非交互终端 guard 的 exit-code 契约 bug（`commands.sh:854` `exit 1`→`exit 3`，ADR-0003 回归），加 protocol 锁。**正交于 picker**——`cmd_menu` 是命令菜单不选 machine，不在 surface gate 覆盖范围。
- Files: Modify `lib/commands.sh`（`cmd_menu` 852-855）；Modify `tests/protocol/exit_codes.sh`。
- 验证范围：`tests/protocol/exit_codes.sh` 的 menu 非TTY 断言 =exit 3；`tools/ob_check.sh` 全绿。

- [ ] Step 1: 写当前状态检查 + 定位 menu dispatch（已核验 ob:242-243）
- Run: `sed -n '850,855p' lib/commands.sh`；`grep -nE 'cmd_menu|-z "\$COMMAND"' ob`
- Expected: `cmd_menu` 内 `[[ ! -t 0 ]] ... exit 1`(854)；`ob` 的 dispatch 是 `if [[ -z "$COMMAND" ]]; then cmd_menu`（**无参触发**，不是 `menu` 参数——parse_args 无 menu 子命令，传 `menu` 会撞 `Unknown command` exit 1）。
- [ ] Step 2: 写失败测试（TDD）
- Change: 在 `tests/protocol/exit_codes.sh` 的 `assert_ob_rc` case 列加空命令分支 `"" ) cmd_menu ;;`（与 init/build 同级），并加断言 **无参触发**：`assert_ob_rc 3 "menu non-TTY exits 3"`（args 为空 → `parse_args` 无参 → `COMMAND=""` → `cmd_menu` → 非TTY exit）。**不要**写 `assert_ob_rc ... menu`（那会 dispatch 到 unknown command）。
- Run: `bash tests/protocol/exit_codes.sh; echo rc=$?`
- Expected: rc≠0（menu 断言红——现状 exit 1，期望 3）。
- [ ] Step 3: 写最小实现
- Change: `lib/commands.sh` `cmd_menu` 的 `exit 1`(854) → `exit 3`。
- [ ] Step 4: 运行并确认通过
- Run: `bash tests/protocol/exit_codes.sh; echo rc=$?`
- Expected: rc=0（menu 非TTY=3 绿）。
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`。
- [ ] Step 5: checkpoint commit
- Run: `git add lib/commands.sh tests/protocol/exit_codes.sh && git commit -m "fix(cmd_menu): 非交互终端 exit 1→3 (ADR-0003 回归) + protocol 锁"`
- Expected: commit 成功。

### Task 4.1: WORKSPACE.md lib/ 路由同步

- 目标：`lib/` 路由行加入 `machine_picker.sh`（文件此刻已存在）。
- Files: Modify `rules/03_WORKSPACE.md`（`lib/` 路由行）。
- 验证范围：路由行与 `ls lib/*.sh` 一致。

- [ ] Step 1: 写当前状态检查
- Run: `ls -1 lib/*.sh | sed 's#lib/##'`
- Expected: 含 `machine_picker.sh`。
- [ ] Step 2: 确认路由行滞后
- Run: `grep -c 'machine_picker.sh' rules/03_WORKSPACE.md`
- Expected: `0`（尚未同步）。
- [ ] Step 3: 写最小实现
- Change: `lib/` 路由行追加 `machine_picker.sh machine 选择 (pick_machine, leaf-pure L3)`，置于 `machine_state.sh` 之后（与 state 并列，体现 selection/state 正交）。
- [ ] Step 4: 运行并确认通过
- Run: `grep -c 'machine_picker.sh' rules/03_WORKSPACE.md`
- Expected: ≥1。
- [ ] Step 5: checkpoint commit
- Run: `git add rules/03_WORKSPACE.md && git commit -m "docs(workspace): lib/ 路由同步 machine_picker.sh"`
- Expected: commit 成功。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动。
- **首个 commit**（Task 0.1）：切 `feature/machine-selection-deepening` 分支后，把 main 上已 staged 的 `CONTEXT.md` 修订 + 本计划文档作为首个 commit 落下，再开始 Task 1.1。`main` 不直接动实现。
- 按任务顺序执行，不无声跳步、合并步或改目标；**extract→pin→deepen 顺序不可乱**：Task 1.x（锁行为/抽 module）→ Task 2.x（迁移调用点）→ Task 3.x（退役+结构锁）。
- 每完成一个任务运行其验证；`tools/ob_check.sh` 是改 `ob`/`lib/*.sh` 后的统一配套自检，多数任务以它收尾。
- 遇阻塞、重复失败或计划与仓库现实不符（行段漂移、函数名对不上），立即停下说明，**用 grep 重新枚举符号**，不要猜路径或猜命令。
- 每个 Step 5 的 checkpoint commit 是回滚点；某 Phase 整体退废可 `git reset --hard <该 Phase 前 commit>`。
- **`exit_contract` 白名单登记**是硬约束：`machine_picker.sh` 登记进 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（`set()`，无例外），类比 `machine_state.sh`，让 `check_Y` 守护 `pick_machine` 绝不 exit；若 exit-contract Y 段报 `pick_machine` 误 exit，回 lib 修，**不加例外**到该 set。
- **surface gate 是硬约束**（Task 3.2 后）：任何后续改动若使 `select_from_list`/`SELECT_FROM_LIST_CHOICE`/`resolve_machine` 在 `lib/*.sh` 复现，gate 立即红，回滚该改动。
- **不新增 ADR**（Q8 决策，已论证：machine selection 的"为什么"全可被 `CONTEXT.md` + gate 替代）。若执行中冒出"代码无法表达的非显而易见坑"（类比 ADR-0001 的 tee 截断），才考虑补 ADR，否则维持不新增。
- off-path（`PIDFILE_*` 收口、git-mirror-url 三处去重、`exit_on_user_cancel` 三段式、status 多实例单行呈现）严禁顺手改。

## 最终验证

- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`，含 `extract_funcs lib 三段全清`（11 个 lib 文件，新增 `machine_picker.sh`）、`exit-contract ok`（`machine_picker.sh` 已登记 `set()`，Y 规则覆盖且无 exit 例外）、`machine selection legacy surface removed`、`run_all ALL GREEN`。
- Run: `bash tests/unit/pick_machine.sh; echo rc=$?`
- Expected: rc=0（`pick_machine` 契约：数字/名字/cancel/越界）。
- Run: `bash tests/unit/interact.sh; echo rc=$?`
- Expected: rc=0（`select_from_list` 段已删，其余单测绿）。
- Run: `bash tests/protocol/exit_codes.sh; echo rc=$?`
- Expected: rc=0（4 cmd 选择 exit 码基线 + `cmd_menu` 非TTY=3）。
- Run: `bash tests/run_all.sh --full`
- Expected: 通过。**注意（F7）**：`manual_matrix.exp` 在 workspace 缺 init/build machine 时会 skip cancel 分支——`--full` 通过只代表套件全绿，**不保证** cancel→exit 2 动态协议端到端覆盖。若需强证 cancel 分支，单独跑 `manual_matrix.exp` 并确认对应 case `SKIP=0`；否则接受「full 绿 + unit pick_machine cancel 单测」作为间接证据。
- Run: `grep -rnE 'select_from_list|SELECT_FROM_LIST_CHOICE|(^|[^[:alnum:]_])resolve_machine($|[^[:alnum:]_])' lib/ || echo NONE`
- Expected: `NONE`（旧 surface 全清零；`resolve_machine_conf_include` 不被词边界正则误命中）。
- Run: `git log --oneline feature/machine-selection-deepening ^main`
- Expected: 见 Task 0.1-4.1 各 checkpoint commit（首个为 CONTEXT+计划文档）。
- 观察: `wc -l lib/commands.sh` —— 较 943 行下降（4 调用点的选择段各收窄到一行 `pick_machine` 调用）；`lib/repo.sh` 较 467 行下降（删 `resolve_machine` 90 行）。

## 审阅 Checkpoint

- 计划正文到此结束。
- 审阅通过前不进入实现；本计划默认执行方是普通编码 agent 或人工执行者。
- 若要调整，先改计划再跑同一轮 inline 自检。
