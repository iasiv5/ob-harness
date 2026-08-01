# command machine resolution 实施计划

## 目标

把 `cmd_build` / `cmd_dev` / `cmd_deploy_to_qemu` 各自内联的 machine 解析 ritual（given 快路径 verify / empty 路径 guard+pick+verify + exit-3 remedy + rc 映射）收口成单一 leaf-pure module `lib/machine_resolve.sh`（入口 `resolve_command_machine`），按 ADR-0019 路 A（seam own remedy + return `exit-code 契约` 0/1/2/3，`cmd_*` 字面 case 收口）。同步退役 `exit_on_user_cancel`（6 处调用迁 case+warn）。start_qemu / stop_qemu / init 的 resolution 不接 seam。

## 架构快照

- 新 leaf-pure module `lib/machine_resolve.sh`：消费 `machine_selection_guard`（empty/nontty/ok）+ `machine selection`（pick_machine）+ `machine_state_is_initialized`，return 0/1/2/3，set `$MACHINE`。后置条件：return 0 ⟹ `$MACHINE` 已 initialized。
- `cmd_*` 退化为：`local _rc=0; resolve_command_machine ... || _rc=$?` → 字面 `case "$_rc"` 收口 exit（**`local _rc=0` 前置是 ob `set -u` 必需**：成功路径 `|| _rc=$?` 不执行，不预初始化则 `case "$_rc"` 访问未定义变量致 nounset 失败；同仓库既有惯例 `local _irc=0`/`_iarc=0`）→ confirm / repo 显示 / DRY_RUN / 展示块留 caller。
- 边界迁移：`machine selection guard` 术语「exit/remedy归调用方」→ intake 派（resolution module own remedy + return 契约）。guard 本体不变。
- `exit_on_user_cancel` 退役：seam 吞 pick 路径（build/deploy）；confirm 与非 seam 命令（start_qemu/stop_qemu）的 rc 映射迁 inline case+warn（保 cancel warn）。

## 全局约束

- leaf-pure：`machine_resolve.sh` 函数绝不 `exit`，return 契约值；登记 `exit_contract.py` Y 白名单 `'machine_resolve.sh': set()`。
- exit-code 契约：0/1/2/3（0=解析成功 / 2=用户取消，已 warn / 1=读失败 / 3=前置缺失，已打 remedy）。
- 保 cancel warn 文案 `"<verb> cancelled by user."`：seam cancel 分支 `warn`+return 2；caller confirm 迁 case 时亦 `warn`+exit 2。覆盖由 Task 1 seam 单测（pick cancel）+ Task 2 build confirm-cancel orchestration 测试（confirm cancel）承担——**interact.sh 不再覆盖**（Task 5 删其 exit_on_user_cancel 断言，勿按 interact.sh:21 旧锚点找）。
- 两类 remedy 不混用：① **verify remedy**（given 路径、machine 未 initialized）：`Machine '<m>' is not initialized (no completed init-done marker - a previous init may have been interrupted).` + `Run 'ob init <m>' first.`（保留 build 括号诊断，全 stderr、`$MACHINE`）。② **empty remedy**（empty 路径、initialized 集合空）：`No initialized machines found.` + `Run 'ob init <machine>' first.`。两者不同诊断，seam 各自内联、不共用文案；nontty 用传入的 nontty_remedy。
- `$MACHINE` 全局回传（不造 nameref outvar）。
- pick_stream 参数：dev 须 `stderr`（护 `ob dev porcelain stdout` 契约），build/deploy `stdout`。
- start_qemu / stop_qemu / init 的 resolution **不接 seam**；仅 start_qemu/stop_qemu 的 rc 映射随 helper 退役迁移。
- 命令环境：bash（Linux/WSL）；验证沿用 `tools/ob_check.sh` + `tests/run_all.sh`。

## 输入工件

- 设计共识：本会话 `/grill-with-docs` 七项决策（D1–D7）。
- [ADR-0019](../adr/0019-command-machine-resolution-seam.md)（已落盘）。
- [CONTEXT.md](../../CONTEXT.md) `command machine resolution` / `machine selection guard` 术语（已落盘）。

## 文件结构与职责

- Create: `lib/machine_resolve.sh` — leaf-pure resolution module（`resolve_command_machine`）。
- Create: `tests/unit/machine_resolve.sh` — 单测（**function-override stub**：source 后覆盖 `machine_state_is_initialized`/`machine_selection_guard`/`pick_machine` 为同 shell 函数——pick_machine 须在当前 shell set `$MACHINE`+return MOCK rc、guard 须 outvar 写入+return 0，**不可用 PATH executable**：子进程回传不了 `$MACHINE`/nameref，对照 `tests/unit/init_intake.sh:24-27`；覆盖 7 态：given+init / given+noinit / empty+ok / empty+empty / empty+ok+pick-read-fail(`MOCK_PICK_RC=1`→return 1) / nontty / cancel）。
- Create: `tests/protocol/machine_resolve_surface.sh` — surface 回归锁（interface-shrink：production Bash 不再内联 guard-case+pick+verify ritual）。
- Modify: `lib/commands.sh` — `cmd_build`/`cmd_dev` 接 seam；删 `exit_on_user_cancel` 定义（L9-22）。
- Modify: `lib/qemu_commands.sh` — `cmd_deploy_to_qemu` 接 seam；`cmd_start_qemu`/`cmd_stop_qemu` 的 rc 映射迁 case+warn；删 L5 跨文件依赖注释。
- Modify: `tools/exit_contract.py` — Y 白名单加 `'machine_resolve.sh': set()`。
- Modify: `tools/coverage_matrix.md` — 登记 `resolve_command_machine` + 单测。
- Modify: `rules/03_WORKSPACE.md` — `lib/` 列表登记 `machine_resolve.sh`。
- Modify (re-baseline): `tests/protocol/build_noninteractive.sh`、`tests/protocol/deploy_to_qemu_machine_selection.sh`（verify remedy canonical 收敛）。

## 任务清单

### Task 1: 创建 `lib/machine_resolve.sh` leaf-pure module + 单测 + 登记

- 目标：建立 seam 本体与测试网，登记 leaf-pure 纯度门禁。
- Files: Create `lib/machine_resolve.sh`、`tests/unit/machine_resolve.sh`；Modify `tools/exit_contract.py`（L53 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`）、`tools/coverage_matrix.md`、`rules/03_WORKSPACE.md`。
- 接口契约:
  - Consumes: `machine_selection_guard`（`lib/machine_selection_guard.sh`，outvar status）、`pick_machine`（`lib/machine_picker.sh`，set `$MACHINE`）、`machine_state_is_initialized`（`lib/machine_state.sh`）、`error`/`warn`（`lib/util.sh`）。
  - Produces: `resolve_command_machine <list_fn> <verb> <pick_stream> <nontty_remedy>` → return 0/1/2/3，set `$MACHINE`；后置条件 return 0 ⟹ `$MACHINE` 已 initialized。
- 验证范围: `OB_CHECK_SKIP_TESTS=1 bash tools/ob_check.sh` 通过（含 exit_contract Y 白名单生效、extract_funcs 登记、shellcheck baseline）；`bash tests/unit/machine_resolve.sh` 通过。

- [ ] Step 1: 写失败单测 `tests/unit/machine_resolve.sh`（**function-override stub**——`source ob_loader.sh` 后定义同名函数覆盖：`pick_machine(){ MACHINE="${MOCK_PICK_RESULT:-}"; return "${MOCK_PICK_RC:-0}"; }`、`machine_selection_guard(){ local _l="$1"; printf -v "$2" "%s" "${MOCK_GUARD_STAT:-ok}"; return 0; }`、`machine_state_is_initialized(){ return "${MOCK_INIT_RC:-0}"; }`；对照 `tests/unit/init_intake.sh:24-27`，**不可 PATH executable stub**；断言 **7 态** return 值 + `$MACHINE` + cancel warn 含 `<verb> cancelled by user.`：given+init(0)/given+noinit(3,verify remedy)/empty+ok(0,$MACHINE)/empty+empty(3,empty remedy)/empty+ok+pick-read-fail(`MOCK_PICK_RC=1`→return 1，**无** cancel warn)/nontty(3,nontty_remedy)/cancel(`MOCK_PICK_RC=2`→return 2+warn)）。**输出通道**：remedy 走 `error`→stderr、cancel warn 走 `warn`→stdout（util.sh:10 `warn` 无 `>&2`、:12 `error` 有），单测按通道分别捕获（remedy 态断 stderr、cancel 态断 stdout），勿统一捕 stderr 否则 cancel 态假失败。
- Run: `bash tests/unit/machine_resolve.sh`
- Expected: 失败（`resolve_command_machine` 未定义）。
- [ ] Step 2: 确认失败（同上命令，No such function / 非 0 退出）。
- [ ] Step 3: 写 `lib/machine_resolve.sh`：
  - 入口 `resolve_command_machine()`：`local list_fn="$1" verb="$2" pick_stream="$3" nontty_remedy="$4"` + `local _gstat="" _prc=0`；`if [[ -n "$MACHINE" ]]`（given 快路径）→ `machine_state_is_initialized "$MACHINE"` 否则 **verify remedy**（`Machine '$MACHINE' is not initialized (no completed init-done marker - a previous init may have been interrupted).` + `Run 'ob init $MACHINE' first.`）+ `return 3`；else（empty）→ `machine_selection_guard "$list_fn" _gstat` → `case "$_gstat"`：empty → **empty remedy**（`No initialized machines found.` + `Run 'ob init <machine>' first.`）+ `return 3`；nontty → `error "$nontty_remedy"` + `return 3`；ok → `pick_machine "$list_fn" "$verb"`（按 `pick_stream` 决定 `>&2` 与否）`|| _prc=$?` → `_prc==2` 则 `warn "$verb cancelled by user."; return 2`；`_prc!=0` 则 `return 1`（`_prc=0` 前置同 `_rc`，`set -u` 必需）。**verify remedy ≠ empty remedy**（两类诊断，见全局约束）。函数体无 `exit`。
  - 文件头注释引用 ADR-0019 + CONTEXT `command machine resolution`。
- Change: 新建 module；`exit_contract.py` 加 `'machine_resolve.sh': set(),`；`coverage_matrix.md` + `WORKSPACE.md` 登记。
- [ ] Step 4: 确认通过：`bash tests/unit/machine_resolve.sh`（7 态全绿）+ `OB_CHECK_SKIP_TESTS=1 bash tools/ob_check.sh`（exit_contract Y 规则认 machine_resolve.sh 为 leaf-pure、无 `dynamic exit` 告警）。
- [ ] Step 5: checkpoint commit `feat(resolve): add lib/machine_resolve.sh leaf-pure module + unit`。

### Task 2: `cmd_build` 接 seam + confirm 迁 case+warn

- 目标：cmd_build 的 given/empty 解析 ritual 替换为 `resolve_command_machine`；confirm rc 映射迁 inline case（保 warn）；删 build 的 2 处 `exit_on_user_cancel`。
- Files: Modify `lib/commands.sh`（`cmd_build` L121-253）；re-baseline `tests/protocol/build_noninteractive.sh`；Create `tests/orchestration/build_confirm_cancel.sh`。
- 接口契约:
  - Consumes: `resolve_command_machine`（Task 1 Produces）。
  - Produces: 无（cmd_build 是末端 L1）。
- 验证范围: `bash tests/protocol/build_noninteractive.sh` + `bash tests/protocol/status_golden.sh` + `bash tests/orchestration/build_confirm_cancel.sh`（build inline confirm cancel 输出 `Build cancelled by user.` + rc=2）绿。

- [ ] Step 1: 现状检查——`grep -n 'exit_on_user_cancel\|machine_selection_guard\|pick_machine\|is_initialized' lib/commands.sh` 确认 build 段（L121-253）的 ritual 行。
- Run: `grep -n 'exit_on_user_cancel\|machine_selection_guard\|pick_machine\|is_initialized' lib/commands.sh`
- Expected: 命中 build 的 L123/128-133/138-153/168-169/183-184。
- [ ] Step 2: 改 `cmd_build`：
  - **保 interactive_selection（交互选 machine 才 confirm，显式 `ob build <m>` 不 confirm）**：seam 调用前记 `local had_explicit=0; [[ -n "$MACHINE" ]] && had_explicit=1`（seam 内部判 given/empty 与 caller 同源 `$MACHINE`）；seam return 0 后 `[[ "$had_explicit" -eq 0 ]] && interactive_selection=1`，保留后续 `if [[ "$interactive_selection" -eq 1 ]]; then confirm_action ...` 门。
  - 删 L127-173 的 given/empty 解析 ritual，替换为：`local _rc=0; resolve_command_machine machine_state_initialized_machines "Build" stdout "No machine specified and no interactive terminal. Run 'ob status' to list initialized machines. Specify a machine: ob build <machine>" || _rc=$?` → `case "$_rc" in 0);; 1) error "ob build: failed to read machine selection input."; exit 1;; 2) exit 2;; 3) exit 3;; *) exit 1;; esac`（`_rc=0` 前置是 `set -u` 必需）。
  - **build empty-branch 展示块（L137-147 的 step_header "Initialized Machines" + "(none)" + remedy）删除**：empty 分支整段由 seam 接管（seam 打 **empty remedy** + return 3，build 的 case-3 直接 exit 3）；caller 拿不到「是 empty 还是 nontty 还是 verify-fail」的细分，故不保留 empty 专属展示。empty remedy 已表达「无 initialized machine」，信息无损。pin 该展示的 .exp/golden 一并 re-baseline（见 Step 3）。repo-info 块（L156-163）留 caller、移到 ok 分支 seam return 0 之后打印。
  - confirm（L181-185）：`local ca_rc=0; confirm_action "build" "$MACHINE" || ca_rc=$?` → `case "$ca_rc" in 0);; 2) warn "Build cancelled by user."; exit 2;; *) exit 1;; esac`（保 warn，替 `exit_on_user_cancel`；`ca_rc=0` 前置同 `_rc`）。
  - 建 `tests/orchestration/build_confirm_cancel.sh`：function-override stub `resolve_command_machine`（set `$MACHINE` + return 0）、`confirm_action`（return 2）、备 `require_path` 前置（建 tmp `$OPENBMC_DIR/.git` + `$SOURCE_MANIFEST_FILE`），调 `cmd_build`（`out="$(cmd_build 2>&1)" || rc=$?`），断言 rc=2 且 **合并输出（`2>&1`）含** `Build cancelled by user.`（`warn()` 走 **stdout**、非 stderr——util.sh:10 无 `>&2`；只查 stderr 会假失败，故合并或查 stdout）（**不依赖 expect/真实 workspace**，对照 `tests/orchestration/cmd_build_bitbake_handoff.sh` 模式）——钉死 build inline confirm cancel 的 warn，弥补 interact.sh 不再覆盖。
  - DRY_RUN、build body（build_obmc_image + 成败展示）原样保留。
- Change: cmd_build ritual → seam 调用 + case 收口；confirm 迁 case+warn；删 2 处 exit_on_user_cancel。
- [ ] Step 3: re-baseline `tests/protocol/build_noninteractive.sh`（若断言旧 verify remedy 文案「is not initialized (parenthetical)」或 "(none)" 展示，改断 verify/empty remedy / 删展示断言）+ `tools/coverage_matrix.md` build cancel 行（覆盖 test 加 `orchestration/build_confirm_cancel.sh`，与 `protocol/manual_matrix.exp` 并列）。
- [ ] Step 4: 确认通过：`bash tests/protocol/build_noninteractive.sh` + `bash tests/orchestration/build_confirm_cancel.sh`（confirm cancel warn）+ `bash tests/protocol/status_golden.sh`。
- [ ] Step 5: checkpoint commit `refactor(build): wire cmd_build to resolve_command_machine`。

### Task 3: `cmd_dev` 接 seam + 删冗余 post-pick verify

- 目标：cmd_dev 的 inline pick 段（L380-399）替换为 `resolve_command_machine`（pick_stream=stderr）；删冗余 post-pick verify（L402-406，empty 路径 pick 自 initialized_machines 已保证）。
- Files: Modify `lib/commands.sh`（`cmd_dev` L371-422）；re-baseline dev verify-remedy 测试（若存在）。
- 接口契约:
  - Consumes: `resolve_command_machine`（Task 1）。
  - Produces: 无。
- 验证范围: `bash tests/protocol/devtool_intake_surface.sh` + `bash tests/orchestration/cmd_dev.sh`（显式 `--machine <m>` 路径不被当 empty→exit 3）+ dev 相关 protocol/unit 绿；`bash tests/run_all.sh` 不退化。

- [ ] Step 1: 现状检查——`sed -n '380,406p' lib/commands.sh` 确认 dev 的 pick 段 + post-pick verify。
- Run: `sed -n '380,406p' lib/commands.sh`
- Expected: 命中 `machine_selection_guard`(L382)、inline `pick_machine ... >&2`(L395)、`dev_machine="$MACHINE"`(L398)、post-pick `is_initialized`(L402)。
- [ ] Step 2: 改 `cmd_dev`：**先无条件同步全局**——`MACHINE="$dev_machine"`（dev 的 machine 来自 `dev_intake_argv` 回填**局部** `dev_machine`，是 cmd_dev 唯一 machine 入口；seam 只看**全局** `$MACHINE`。**无条件**而非 `[[ -n ]] &&`：显式给定→同步该值、未给定→清空全局，让 seam 正确进 empty/nontty/pick；这是正确不变量（`$MACHINE` 恒等于 `dev_machine`），条件版留 stale `$MACHINE` 是潜在 footgun）；再 `local _rc=0; resolve_command_machine machine_state_initialized_machines "Develop" stderr "No --machine specified and no interactive terminal. Specify a machine: ob dev --machine <machine> ${dev_subcmd:-list}" || _rc=$?` → 字面 case 收口（`_rc=0` 前置，`set -u` 必需）；seam return 0 后 `dev_machine="$MACHINE"`（empty 路径 pick 已 set 全局）；删 L402-406 的 post-pick verify（seam 已保证 given+empty 两路 initialized）。
- Change: dev pick 段 → seam；删冗余 verify。
- [ ] Step 3: 若 dev 有断 verify remedy 的测试（grep `is not initialized` 命中 dev 路径），re-baseline 到 canonical。
- [ ] Step 4: 确认通过：`bash tests/run_all.sh`（dev 全层绿）。
- [ ] Step 5: checkpoint commit `refactor(dev): wire cmd_dev to resolve_command_machine, drop redundant verify`。

### Task 4: `cmd_deploy_to_qemu` 接 seam + 删冗余 verify

- 目标：cmd_deploy 的 resolution ritual（L268-295）替换为 `resolve_command_machine`；删冗余 post-pick verify（L291-295）；deploy 的 `exit_on_user_cancel`（L284）随 seam 消失。
- Files: Modify `lib/qemu_commands.sh`（`cmd_deploy_to_qemu` L265-302）；re-baseline `tests/protocol/deploy_to_qemu_machine_selection.sh`。
- 接口契约:
  - Consumes: `resolve_command_machine`（Task 1）。
  - Produces: 无。
- 验证范围: `bash tests/protocol/deploy_to_qemu_machine_selection.sh` + `bash tests/protocol/qemu_commands_guard_surface.sh` 绿。

- [ ] Step 1: 现状检查——`sed -n '268,295p' lib/qemu_commands.sh`。
- Run: `sed -n '268,295p' lib/qemu_commands.sh`
- Expected: 命中 guard(L271)、pick(L283)、`exit_on_user_cancel`(L284)、post-pick verify(L291)。
- [ ] Step 2: 改 `cmd_deploy_to_qemu`：L268-295 替换为 `local _rc=0; resolve_command_machine machine_state_initialized_machines "Deploy to QEMU" stdout "No interactive terminal. Specify machine: ob deploy-to-qemu <machine>" || _rc=$?` → 字面 case 收口（`_rc=0` 前置，`set -u` 必需）；删 post-pick verify（L291-295）；BUILD_DIR/SOURCE_MANIFEST_FILE 派生 + DRY_RUN + QEMU 探测段原样保留。**同步改 `tests/protocol/qemu_commands_guard_surface.sh` L18**：deploy 段不再直调 `machine_selection_guard`——改断言 deploy 段调 `resolve_command_machine`（或交由 Task 6 新 gate 覆盖、此处删 deploy 断言）；保留 L17（start_qemu 直调 guard，不接 seam）+ L20-21（两段 forbidden `${#machines[@]}`，仍成立）。
- Change: deploy ritual → seam；删冗余 verify + exit_on_user_cancel 调用；旧 guard surface gate 的 deploy 断言切到 resolve_command_machine。
- [ ] Step 3: re-baseline `tests/protocol/deploy_to_qemu_machine_selection.sh`（verify remedy "has not been initialized" → canonical）+ `tools/coverage_matrix.md` deploy 行（L97：函数列加 `resolve_command_machine`、备注改「deploy 经 resolve_command_machine 同 cmd_build」）。
- [ ] Step 4: 确认通过：`bash tests/protocol/deploy_to_qemu_machine_selection.sh && bash tests/protocol/qemu_commands_guard_surface.sh`（含本 task 改的 guard surface gate，勿拖到 Task 6 / ob_check 才暴露）。
- [ ] Step 5: checkpoint commit `refactor(deploy): wire cmd_deploy_to_qemu to resolve_command_machine`。

### Task 5: 退役 `exit_on_user_cancel`（start_qemu/stop_qemu 迁 case+warn + 删函数）

- 目标：非 seam 命令（start_qemu pick L38 / confirm L119、stop_qemu pick L182）的 rc 映射迁 inline case+warn（保 warn）；删 `exit_on_user_cancel` 定义（commands.sh L9-22）+ 跨文件依赖注释（qemu_commands.sh L5）；确认零残留引用。
- Files: Modify `lib/qemu_commands.sh`（L5/L38/L119/L182）、`lib/commands.sh`（删 L9-22）、`tests/unit/interact.sh`（删 L17-22 exit_on_user_cancel 断言 + L3 注释）、`tools/coverage_matrix.md`（L105 交互叶子行删 `exit_on_user_cancel`）。
- 接口契约:
  - Consumes: 无（纯 rc 映射风格迁移）。
  - Produces: `exit_on_user_cancel` 从代码库消失。
- 验证范围: `grep -rn 'exit_on_user_cancel' lib/ ob` 零命中；`bash tests/run_all.sh` 绿（含 start_qemu/stop_qemu protocol）。

- [ ] Step 1: 现状残留检查——`grep -rn 'exit_on_user_cancel' lib/ ob`（应只剩 start_qemu×2、stop_qemu×1、定义×1、注释×3；build/deploy 已在 Task 2/4 清掉）。
- Run: `grep -rn 'exit_on_user_cancel' lib/ ob`
- Expected: 命中 qemu_commands.sh L5/L38/L119/L182 + commands.sh L9-22/L267 注释。
- [ ] Step 2: 迁移 3 处调用为 inline case+warn：
  - L38（start_qemu pick）：`exit_on_user_cancel "$pm_rc" "Start QEMU"` → `case "$pm_rc" in 0);; 2) warn "Start QEMU cancelled by user."; exit 2;; *) exit 1;; esac`。
  - L119（start_qemu confirm）：同形，verb "QEMU start"（保原 warn 文案）。
  - L182（stop_qemu pick）：同形，verb "Stop QEMU"。
  - 迁 `tests/unit/interact.sh`：删 L17-22（exit_on_user_cancel 三断言：rc0/rc2/rc1）+ L3 注释里的 `exit_on_user_cancel`；保留 confirm_action(L13-15)/prompt_for_absolute_path/prompt_for_available_port。**cancel-warn（"Build cancelled by user."）覆盖归属**：pick-cancel 由 Task 1 `tests/unit/machine_resolve.sh` cancel 态断言（seam 内 `warn`）；build confirm-cancel 由 Task 2 `tests/orchestration/build_confirm_cancel.sh` 覆盖（稳定、不依赖 workspace）；`manual_matrix.exp` 作 `run_all --full` 的交互补充。
  - 改 `tools/coverage_matrix.md` L105：交互叶子行函数列删 `exit_on_user_cancel`。
  - 删 `exit_on_user_cancel()` 定义（commands.sh L9-22）+ L5 跨文件注释 + L267 注释里的 "exit_on_user_cancel 2 处" 字样。
- Change: 3 处 rc 映射迁 case+warn；删函数 + 注释。
- [ ] Step 3: 残留再检——`grep -rn 'exit_on_user_cancel' lib/ ob`。
- Run: `grep -rn 'exit_on_user_cancel' lib/ ob`
- Expected: 零命中（return 1）。
- [ ] Step 4: 确认通过：`bash tests/run_all.sh`（start_qemu/stop_qemu protocol 绿，cancel 路径行为不变）。
- [ ] Step 5: checkpoint commit `refactor: retire exit_on_user_cancel, migrate rc-mapping to case+warn`。

### Task 6: surface 回归锁 + CONTEXT 对齐 + coverage 基线 + 全量验证

- 目标：钉死 interface-shrink（build/dev/deploy 不再内联 ritual）；reconcile CONTEXT.md guard 术语消费方措辞；更新 coverage radar 基线（若下降）；全量 ob_check + run_all --full 收口。
- Files: Create `tests/protocol/machine_resolve_surface.sh`；Modify `CONTEXT.md`（`machine selection guard` 术语消费方句）、coverage radar 基线（若需）。
- 接口契约:
  - Consumes: Task 1-5 产物。
  - Produces: surface gate 防回潮；CONTEXT guard 术语消费方与现状一致。
- 验证范围: 新 gate 绿；`grep` 确认 CONTEXT guard 术语消费方已更新；`bash tools/ob_check.sh` + `bash tests/run_all.sh --full` 全绿。

- [ ] Step 1: reconcile `CONTEXT.md` `machine selection guard` 术语——其消费方句「消费方现为 cmd_build / cmd_dev / cmd_start_qemu / cmd_deploy_to_qemu 共享」更新为：build/dev/deploy 经 `resolve_command_machine`（`command machine resolution`）间接消费 guard，cmd_start_qemu 仍直接消费（cmd_stop_qemu 选 running instance、不经 guard）。`machine selection guard` 本体契约（恒返回 0、outvar status、不 exit/remedy/展示）不变。同步 `tools/coverage_matrix.md` L107 guard 行消费方措辞（build/dev/deploy 经 `resolve_command_machine`、cmd_start_qemu 直接）。
- Run: `grep -n '消费方现为\|resolve_command_machine' CONTEXT.md`
- Expected: guard 术语消费方句含 `resolve_command_machine`（build/dev/deploy 经它）+ cmd_start_qemu 直接。
- [ ] Step 2: 写 surface gate `tests/protocol/machine_resolve_surface.sh`——断言 production Bash（`lib/commands.sh` cmd_build/cmd_dev 段、`lib/qemu_commands.sh` cmd_deploy 段）**不再内联** `machine_selection_guard` + `pick_machine` + `is_initialized` 的组合 ritual（grep 这三个符号在 cmd_build/cmd_dev/cmd_deploy 函数体内同时出现 = 失败），且 `resolve_command_machine` 在三处各被调一次。（对照既有 `tests/protocol/qemu_launch_profile_structure.sh` 的 surface gate 写法。）
- Run: `bash tests/protocol/machine_resolve_surface.sh`
- Expected: 改前会失败（cmd_build 等仍含 ritual）/ 改后绿。
- [ ] Step 3: 跑 coverage radar——`tools/trace_collect.sh | python3 tools/coverage_radar.py -`，记录 UNCOVERED 数值（machine_resolve 被 unit 覆盖应计入、不上升）。CI 阈值落点为 `.github/workflows/ob-tests.yml:28` 的 `--fail-if-uncovered 7`——若 UNCOVERED 上升（新函数未覆盖），先补测试到不上升；确需放宽阈值时改 ob-tests.yml:28 该值（不空写「更新阈值」无落点动作）。
- Run: `tools/trace_collect.sh | python3 tools/coverage_radar.py -`
- Expected: UNCOVERED ≤ 7（machine_resolve 已被 unit 覆盖、不应上升）。
- [ ] Step 4: 全量——`bash tools/ob_check.sh`（含 exit_contract/extract_funcs/shellcheck/surface gates/run_all）。
- Run: `bash tools/ob_check.sh`
- Expected: 全绿。
- [ ] Step 5: `bash tests/run_all.sh --full`（加 .exp 交互矩阵）。
- Run: `bash tests/run_all.sh --full`
- Expected: 全绿。
- [ ] Step 6: checkpoint commit `test(resolve): add machine_resolve surface gate + CONTEXT reconcile + coverage baseline`。

## 执行纪律

- 开始实现前先复查本计划；发现缺项/矛盾/命名不一致/验证命令无效，先修计划。
- 按任务顺序执行（Task 1 是其余的 Consumes 前提）；不无声跳步、合并步。
- 每任务完成跑该任务验证命令；遇阻塞或计划与现实不符立即停下说明，不猜。
- 若当前在 `main`/`master` 且用户未明确同意，开始实现前先确认（建议开 `feat/command-machine-resolution` 分支）。
- 改动 `lib/*.sh` 后必跑 `tools/ob_check.sh`（AGENTS.md Working Mode）。

## 最终验证

- `bash tools/ob_check.sh` 全绿（exit_contract 认 machine_resolve.sh leaf-pure、无 dynamic exit；shellcheck baseline 不退化；surface gate 绿；run_all 绿）。
- `bash tests/run_all.sh --full` 全绿（含 build_noninteractive / deploy_to_qemu_machine_selection / build_confirm_cancel（cancel warn） / qemu_commands_guard_surface / start_qemu·stop_qemu cancel 路径 re-baseline 后）。
- `grep -rn 'exit_on_user_cancel' lib/ ob` 零命中。
- 定义恰 1：`grep -nE '^resolve_command_machine\(\)' lib/machine_resolve.sh` 命中 1。
- 调用恰 3：`grep -nE '^[[:space:]]*resolve_command_machine[[:space:]]' lib/commands.sh lib/qemu_commands.sh` 命中 3（cmd_build/cmd_dev 在 commands.sh、cmd_deploy_to_qemu 在 qemu_commands.sh）。
- coverage radar UNCOVERED 不上升。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-08-01-command-machine-resolution-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可按计划由普通编码 agent 或人工继续执行（建议先开 `feat/command-machine-resolution` 分支）。
