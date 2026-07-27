# machine selection guard 抽取实施计划（cmd_build/cmd_dev machine 前置 guard 收口）

## 目标

把 `cmd_build`（[lib/commands.sh:137-180](../../lib/commands.sh)）与 `cmd_dev`（[lib/commands.sh:411-433](../../lib/commands.sh)）各自内联的「无 `--machine` → 枚举 initialized machine 集合 → 空 guard `exit 3` → 非 TTY guard `exit 3`」前置 guard 编排，抽成 `lib/machine_selection_guard.sh` 的 leaf-pure L3 module（术语 `machine selection guard`，见 `CONTEXT.md`）。module 检测 `pick_machine` 的两条前提（集合非空 + 交互终端），以 outvar status 回传 `empty`/`nontty`/`ok`，恒返回 0；exit/remedy/展示/选号归调用方。`cmd_build`/`cmd_dev` 的 guard 段切换为 module 调用，`pick_machine` 与 repo 展示位置不动。

## 架构快照

- 分层：`cmd_build`/`cmd_dev`（L1 exit seam）→ `machine_selection_guard`（L3 leaf-pure，前提检测）→ `pick_machine`（L3 leaf-pure 选号原语，已有，[machine_picker.sh](../../lib/machine_picker.sh)）。guard 检测前提，selection 在 ok 后选号；`cmd_*` 编排两者。
- **边界 A'（grilling 边界 A 的修正）**：module 只做「枚举 `list_fn` + empty 检测 + non-tty 检测」→ outvar `empty`/`nontty`/`ok`，**不含选号**（`pick_machine` 留调用方）。修正理由：`cmd_build` 的 machine 前置段中间夹了 repo 信息展示（[commands.sh:155-165](../../lib/commands.sh)，在 empty guard 与 `pick_machine` 之间），若 module 包 pick 则 repo 展示无处插入（要么 repo 移位=行为变化 + .exp 风险，要么 module 退化）；只包 guard 则 `cmd_build` empty/ok 路径行为完全不变。
- 接口：`machine_selection_guard <list_fn> <status_outvar>` → 恒 return 0；`status_outvar` 经 `printf -v` 写 `empty`（集合空）/ `nontty`（非空但非交互终端）/ `ok`（非空且交互终端）。
- **行为不变性**：`cmd_dev` 完全不变（纯线性，无 repo 夹层）；`cmd_build` empty/ok 路径不变，**唯一差异**是 nontty 路径不再展示 repo（原 nontty 路径在 `exit 3` 前展示了 repo；A' 下 module 把 empty+nontty 一起检测，repo 展示在 case 之后=仅 ok 路径展示）。nontty 是错误路径（`exit 3`），对 agent 无影响（agent 看 `remedy line`）；**已核实 `tests/` 无任何断言断言 repo 展示**（`grep -r 'OpenBMC Repository\|Source :' tests/` 空），故零测试风险。

## 全局约束

- **exit 归属（leaf-pure 横切 module 惯例）**：guard 是 leaf-pure，函数绝不 exit，恒 return 0；exit 只在 `cmd_build`/`cmd_dev`（L1）。法理锚点是仓库横切 leaf-pure 既例（[machine_picker.sh](../../lib/machine_picker.sh)/[machine_state.sh](../../lib/machine_state.sh)/[image_build.sh](../../lib/image_build.sh)/bitbake_env.sh/build_env.sh/status_render.sh 等非 dev 链 module 在 [exit_contract.py:53-74](../../tools/exit_contract.py) `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 登记为 `set()`），由 exit_contract Y 规则守。ADR-0010/0012 是参照**范式**（leaf-pure + return 契约值 + cmd_* 字面 case 收口），但其范畴限定 ob dev dispatch/emit/handler（`lib/devtool_*.sh`，见 [ADR-0010](../../docs/adr/0010-ob-dev-dispatch-leaf-pure-exit.md) Consequences 末段"只锁定 dev dispatch/emit 这两族"），**不覆盖本 module**——勿误读为"ADR-0010/0012 覆盖所有 leaf-pure"。
- **门禁职责分层（普适原则，适用未来所有 leaf-pure module 抽取）**：exit_contract Y 规则守 leaf-pure「函数绝不 exit」核心不变量（权威）；surface gate 守「不越层」（选号/execute/state 写不下沉，表层回归锁）。两者互补不重叠——新 module 的 leaf-pure 核心不变量要锁，进 exit_contract 字典；要锁「不该做某类副作用」，加 surface gate。
- **outvar 走名字字符串 + `printf -v`**（学 [devtool_pick.sh](../../lib/devtool_pick.sh)：`status_outvar` 是名字字符串非 nameref，`printf -v "$status_outvar"`）。本范式无 nameref，故无 nameref circular 风险；若改用 nameref，circular 陷阱另见 [machine_picker.sh `read_list_choice`](../../lib/machine_picker.sh) 注释（caller nameref 名不得与内部 nameref 同名）。
- **顺序约束（防 exit_contract Y 假绿，跨 task 硬约束）**：新增任何 leaf-pure module，`exit_contract.py` 字典登记与 lib 文件创建必须在同一 commit；登记前的 lib 落盘态，Y 规则对该 basename 静默不检查（既不报错也不守卫——`check_Y` 只遍历字典里的 basename，未登记的跳过），不可在此中间态拿 `ob_check` 当门禁。
- **list_fn 参数化**：module 接受 `list_fn` 名字字符串，内部 `"$list_fn"` 调用枚举。本次 `cmd_build`/`cmd_dev` 都传 `machine_state_initialized_machines`；参数化预留未来 `cmd_init`（`list_available_machines`）。
- **双枚举是已知取舍**：module 枚举 `list_fn` 一次（判空+nontty），调用方 `pick_machine` 内部又枚举一次（[machine_picker.sh:45-47](../../lib/machine_picker.sh)）。`list_fn`（`machine_state_initialized_machines` 读 configs）轻量、纯查询，两次输出一致；不为消除双枚举扩大范围改 `pick_machine`。（已评估：`machine_state_initialized_machines` 在 `OPENBMC_DIR/build` 存在时会 glob build artifacts 补全集合，2 次 glob 累积 I/O 仍亚秒级，不构成反对理由。）
- **文案逐字照搬**：`empty`/`nontty` 的 remedy 文案从 `cmd_build`/`cmd_dev` 原段原样留调用方 case，不改写。
- **lib 文件结构**：过 `extract_funcs` 三段（header 注释 + 函数定义 + footer 纯函数定义），参照 `lib/devtool_pick.sh`。
- **不写新 ADR**：三条件不满足（可逆 / 不 surprising——延续横切 leaf-pure 既例，非新决策 / 真分叉被 `machine_picker.sh` 等先例覆盖）。术语 `machine selection guard` 落 `CONTEXT.md`，本计划归档即可。
- **术语修正（writing-plans 阶段已做）**：grilling 时落的 `CONTEXT.md` `machine resolution` 词条（边界 A）已改为 `machine selection guard`（边界 A'，module 只检测前提不做完整解析）。

## 输入工件

- grill 共识 + A' 修正（writing-plans 发现 `cmd_build` repo 夹层 → 边界 A→A'）。
- 术语：`CONTEXT.md` `machine selection guard` 词条（已落）。
- exit 归属范式：[ADR-0010](../../docs/adr/0010-ob-dev-dispatch-leaf-pure-exit.md)、[ADR-0012](../../docs/adr/0012-ob-dev-subcmd-handler-leaf-pure-exit.md)（范式参照：leaf-pure + return 契约值 + cmd_* 字面 case 收口；范畴限 dev helper，不覆盖本 module——本 module 法理锚横切 leaf-pure 既例，见全局约束·exit 归属）。
- 范式参照：`lib/devtool_pick.sh`（leaf-pure + outvar + 头注释引 ADR）、`tests/unit/devtool_pick.sh`（unit 范式：`ob_loader.sh`+`assert.sh`+here-string/`</dev/null` 喂 stdin+outvar 当前 shell+`2>"$_err"` 捕 stderr）、`tests/protocol/devtool_intake_surface.sh`（surface gate 范式：`forbidden=()`+`grep -v '^[[:space:]]*#'`+`assert_false`）、`tools/ob_check.sh`（回归门禁）。

## 文件结构与职责

- Create: `lib/machine_selection_guard.sh` — 文件头注释 + `machine_selection_guard`。
- Create: `tests/unit/machine_selection_guard.sh` — unit 测（empty/nontty 态；ok 态靠 protocol/manual_matrix.exp 真实 tty，unit 不测）。
- Create: `tests/protocol/machine_selection_guard_surface.sh` — forbidden-token 回归锁（锁 module 不选号/不 exit/不 execute/不写 state）。
- Modify: `lib/commands.sh` — `cmd_dev` guard 段（Task 2）+ `cmd_build` guard 段（Task 3）切换为 `machine_selection_guard` 调用 + case 收口；pick/repo 段不动。
- Modify: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'machine_selection_guard.sh': set(),`。
- Modify: `tools/coverage_matrix.md` — 横切段 +1 行。
- Modify: `rules/03_WORKSPACE.md` — lib 路由表 +1 条目。
- Regen: `tests/.shellcheck-baseline` — `ob_check` 自动重生成（REGEN 时 `git diff` 确认）。

接口契约（贯穿全任务）：
- `machine_selection_guard(list_fn, status_outvar) → return 0`。`status_outvar` 经 `printf -v "$status_outvar"` 写 `empty`/`nontty`/`ok`。`list_fn` 是产出 machine 列表（每行一名）的命令名。

## 任务清单

### Task 1: 建 machine_selection_guard.sh 骨架 + machine_selection_guard + exit_contract 注册 + unit

- 目标：落地 guard module 样板——文件骨架、`machine_selection_guard`、exit_contract 门禁注册、unit 测范式。`cmd_*` 本任务不动。
- Files: Create `lib/machine_selection_guard.sh`、Create `tests/unit/machine_selection_guard.sh`、Modify `tools/exit_contract.py`。
- 验证范围：`bash tests/unit/machine_selection_guard.sh` PASS；`tools/ob_check.sh` ALL GREEN。

- [ ] Step 1: 写当前状态检查（module 未存在 + 未注册 + cmd_* 仍内联 guard）
- Run: `test ! -e lib/machine_selection_guard.sh && ! grep -q 'machine_selection_guard' tools/exit_contract.py && grep -q 'No initialized machines found' lib/commands.sh`
- Expected: rc=0（module 未存在 + exit_contract 未含 + `commands.sh` 仍有内联 empty guard 文案，`grep` 命中 cmd_build+cmd_dev 两处）。

- [ ] Step 2: 确认起点绿
- Run: `tools/ob_check.sh`
- Expected: ALL GREEN（当前 baseline；module 尚未引入）。

- [ ] Step 3: 写最小实现
- Change:
  - **⚠️ 顺序约束（防 exit_contract Y 假绿）**：先做第 1 点（`exit_contract.py` 登记），再创建 `lib/machine_selection_guard.sh`（第 2 点），再写 unit（第 3 点），三处同 commit。Y 规则只查 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 字典里登记的 basename——module 已创建但未登记的中间态，里面误写 `exit` 不会被 Y 报。禁止在该中间态跑 `ob_check` 当门禁。
  1. Modify `tools/exit_contract.py`：在 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（`devtool_pick.sh` 行附近）加一行 `'machine_selection_guard.sh': set(),`。
  2. Create `lib/machine_selection_guard.sh`，文件头注释（参照 `devtool_pick.sh`：职责 = `machine selection` 前提检测、leaf-pure、消费 `list_fn`、术语见 `CONTEXT.md` `machine selection guard`）。Exit 行锚横切 leaf-pure 既例，措辞 `Exit: leaf-pure module（横切惯例，同 machine_picker.sh/image_build.sh）；函数绝不 exit，恒 return 0；exit 归 cmd_build/cmd_dev（exit_contract Y 规则守）`。写入 `machine_selection_guard`：
  ```bash
  # machine_selection_guard <list_fn> <status_outvar>
  # 检测 pick_machine 的两条前提: list_fn 产出的 machine 集合非空 + 当前为交互终端。
  # 结果经 status_outvar 回传(恒返回 0):
  #   empty   集合空(无 initialized machine)
  #   nontty  集合非空但非交互终端
  #   ok      集合非空 + 交互终端 → 调用方可 pick_machine
  # leaf-pure: 绝不 exit, 不打印 remedy/展示, 不选号(pick 留调用方)。术语见 CONTEXT.md machine selection guard。
  # 前提(调用者保证): status_outvar 名不与本函数 local 同名(本函数无 nameref, 用 printf -v, 无此风险; 沿用 devtool_pick 范式)。
  machine_selection_guard() {
      local list_fn="$1" status_outvar="$2"
      local -a _machines=()
      local _line
      while IFS= read -r _line; do
          [[ -n "$_line" ]] && _machines+=("$_line")
      done < <("$list_fn")
      if [[ ${#_machines[@]} -eq 0 ]]; then
          printf -v "$status_outvar" '%s' "empty"
          return 0
      fi
      if [[ ! -t 0 ]]; then
          printf -v "$status_outvar" '%s' "nontty"
          return 0
      fi
      printf -v "$status_outvar" '%s' "ok"
      return 0
  }
  ```
  3. Create `tests/unit/machine_selection_guard.sh`（参照 `devtool_pick.sh` unit：`source ../lib/ob_loader.sh` + `assert.sh` + `assert_reset`；mktemp TMP + trap）。outvar 当前 shell 跑（直接 `_st=""` 赋值，helper `printf -v` 写它）。case：
  ```bash
  # mock list_fn(命令名, module 内部 "$list_fn" 调用)
  _list_empty() { :; }              # 无输出 = 集合空
  _list_two()   { printf 'm1\nm2\n'; }  # 两个 machine

  _st=""
  # ① empty: list_fn 空 → empty(空优先, 不查 tty)
  machine_selection_guard _list_empty _st </dev/null
  assert_eq "① empty: status=empty" "$_st" "empty"

  # ② nontty: list_fn 非空 + stdin 非tty(</dev/null) → nontty
  machine_selection_guard _list_two _st </dev/null
  assert_eq "② nontty: status=nontty" "$_st" "nontty"

  # ok 态需真实 tty(交互终端), unit 环境无法 mock [[ -t 0 ]]; 靠 protocol/manual_matrix.exp
  # (cmd_dev/cmd_build 交互路径)覆盖。ok 是 empty/nontty 之后的 else 分支, 逻辑极简。
  assert_summary
  ```

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/machine_selection_guard.sh && python3 tools/exit_contract.py && tools/ob_check.sh`
- Expected: unit `assert_summary` 全 PASS（empty/nontty 两态）；exit_contract 输出 `Y: PASS` 且覆盖 `machine_selection_guard.sh`（leaf-pure「绝不 exit」不变量在 module 落地即被门禁锁；职责分层——exit_contract 守「不 exit」，surface gate 守「不越层」）；`ob_check.sh` ALL GREEN。
- nontty 语义锁（诚实标注未实测项）：guard unit ② nontty 态依赖 `</dev/null` 重定向贯穿函数使 `[[ -t 0 ]]` 退 false（while 循环外的 fd0 仍 = /dev/null）。终端可用环境先跑 `bash -c 'f(){ local x; while IFS= read -r x; do :; done < <(printf "a\n"); [[ -t 0 ]]; echo $?; }; f </dev/null'`，期望输出 `1`（fd0=/dev/null → 非 tty），锁死语义。

- [ ] Step 5: checkpoint commit
- Run: `git add lib/machine_selection_guard.sh tests/unit/machine_selection_guard.sh tools/exit_contract.py tests/.shellcheck-baseline && git commit -m "feat(guard): extract machine_selection_guard leaf-pure precondition detector + exit_contract gate"`
- Expected: commit 成功。

### Task 2: cmd_dev guard 段切换（纯线性，行为不变）

- 目标：把 `cmd_dev` 的 guard 段（枚举 [412-417](../../lib/commands.sh) + empty [418-422](../../lib/commands.sh) + nontty [423-427](../../lib/commands.sh)）替换为 `machine_selection_guard` 调用 + case 收口。pick 段（[428-433](../../lib/commands.sh)）不动。
- Files: Modify `lib/commands.sh`（`cmd_dev` guard 段）。
- 验证范围：`bash tests/orchestration/cmd_dev.sh` PASS（测 `--machine` 路径，不碰 guard 段，故行为不变即过）；`ob_check` ALL GREEN。

- [ ] Step 1: 当前状态检查
- Run: `! grep -q 'machine_selection_guard' lib/commands.sh`
- Expected: rc=0（`cmd_dev` 仍内联 guard，未切换）。

- [ ] Step 2: 确认起点绿
- Run: `bash tests/unit/machine_selection_guard.sh && tools/ob_check.sh`
- Expected: PASS。

- [ ] Step 3: 切换 cmd_dev guard 段
- Change: Modify `lib/commands.sh` `cmd_dev`：把 guard 段（从 `local -a _machines=()` 到 nontty guard 的 `fi`，即原 `if [[ -z "$dev_machine" ]]; then` 内的枚举+empty+nontty 三段）替换为：
  ```bash
      if [[ -z "$dev_machine" ]]; then
          local _msg=""
          machine_selection_guard machine_state_initialized_machines _msg
          case "$_msg" in
              empty)
                  error "No initialized machines found." >&2
                  error "Run 'ob init <machine>' first." >&2
                  exit 3 ;;
              nontty)
                  error "No --machine specified and no interactive terminal." >&2
                  error "Specify a machine: ob dev --machine <machine> ${dev_subcmd:-list}" >&2
                  exit 3 ;;
              ok) ;;
          esac
          local _pm_rc=0
          pick_machine machine_state_initialized_machines "Develop" >&2 || _pm_rc=$?
          if [[ "$_pm_rc" -eq 2 ]]; then exit 2; fi
          if [[ "$_pm_rc" -ne 0 ]]; then exit 1; fi
          dev_machine="$MACHINE"
      fi
  ```
  （注：文案从原段逐字照搬；`>&2` porcelain 重定向保留；pick 段逻辑不变。`machine_state_initialized_machines` 文案原段已有，module 内部双枚举一次。）

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/orchestration/cmd_dev.sh && tools/ob_check.sh`
- Expected: `cmd_dev.sh` PASS（`--machine` 路径不碰 guard 段，行为不变）；`ob_check` ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add lib/commands.sh && git commit -m "refactor(dev): wire cmd_dev machine guard to machine_selection_guard (behavior unchanged)"`
- Expected: commit 成功。

### Task 3: cmd_build guard 段切换（repo/pick 位置不动，nontty 路径 repo 展示变化）

- 目标：把 `cmd_build` 的 guard 段（枚举 [138-143](../../lib/commands.sh) + empty [145-153](../../lib/commands.sh) + nontty [167-172](../../lib/commands.sh)）替换为 `machine_selection_guard` 调用 + case 收口。repo 展示（[155-166](../../lib/commands.sh)）与 pick（[174-179](../../lib/commands.sh)）位置不动。
- Files: Modify `lib/commands.sh`（`cmd_build` else 分支）。
- 验证范围：`bash tests/protocol/smoke_ob.sh` PASS（测 empty 路径 rc=3，不断言输出）；`ob_check` ALL GREEN。
- **行为变化标注**：empty/ok 路径完全不变；nontty 路径不再展示 repo（原 nontty 在 repo 之后，A' 下 nontty 在 case=repo 之前）。nontty 是 `exit 3` 错误路径，对 agent 无影响；`tests/` 已核实无 repo 展示断言。

- [ ] Step 1: 当前状态检查
- Run: `test "$(grep -c 'machine_selection_guard' lib/commands.sh)" -eq 1`
- Expected: rc=0（Task 2 后只有 `cmd_dev` 切换=1 处调用，`cmd_build` 未切换）。

- [ ] Step 2: 确认起点绿
- Run: `tools/ob_check.sh`
- Expected: ALL GREEN。

- [ ] Step 3: 切换 cmd_build guard 段
- Change: Modify `lib/commands.sh` `cmd_build` else 分支（无 `--machine`）：把枚举+empty guard（`local -a machines=()` 到 empty guard `fi`）与 nontty guard（`if [[ ! -t 0 ]]; then ... fi`）合并替换为 `machine_selection_guard` 调用 + case（repo 展示块 + pick 块保留原位、原样）：
  ```bash
      else
          local _msg=""
          machine_selection_guard machine_state_initialized_machines _msg
          case "$_msg" in
              empty)
                  step_header "Initialized Machines"
                  echo ""
                  echo "  (none)"
                  echo ""
                  error "No initialized machines found."
                  error "Run 'ob init <machine>' first."
                  exit 3 ;;
              nontty)
                  error "No machine specified and no interactive terminal. Run 'ob status' to list initialized machines."
                  error "Specify a machine: ob build <machine>"
                  exit 3 ;;
              ok) ;;
          esac

          # === Read main repo info（仓库信息块；原位不动，仅 ok 路径展示）===
          local manifest_origin_url manifest_source_label
          manifest_origin_url=$(read_manifest_field origin_url || echo "<unknown>")
          manifest_source_label=$(read_manifest_field source_label || echo "")
          step_header "OpenBMC Repository"
          echo "  Source : $manifest_origin_url${manifest_source_label:+ ($manifest_source_label)}"
          echo "  Path   : $OPENBMC_DIR"
          echo ""
          step_header "Initialized Machines"

          local pm_rc=0
          pick_machine machine_state_initialized_machines "Build" || pm_rc=$?
          exit_on_user_cancel "$pm_rc" "Build"

          BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
          interactive_selection=1
      fi
  ```
  （注：empty 段 step_header+`(none)`+文案逐字照搬原 [145-153](../../lib/commands.sh)；nontty 文案逐字照搬原 [168-171](../../lib/commands.sh)；repo 展示 + pick 块原样保留，只是从「empty guard 之后」移到「case ok 之后」=ok 路径才执行——empty/nontty 路径 exit 3 不执行 repo 展示，与原 empty 路径一致；原 nontty 路径会执行 repo 展示，A' 下不执行=本任务已知行为变化。）

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/protocol/smoke_ob.sh && tools/ob_check.sh`
- Expected: `smoke_ob.sh` PASS（`ob build` 空 workspace → empty → `exit 3`，rc=3 不变，[smoke_ob.sh:38-39](../../tests/protocol/smoke_ob.sh) 不断言输出）；`ob_check` ALL GREEN。
- 额外核实（零测试风险确认）：Run `! grep -rq 'OpenBMC Repository\|manifest_origin_url\|Source :' tests/`，Expected：rc=0（无测试断言 repo 展示，nontty 路径 repo 变化零测试风险）。

- [ ] Step 5: checkpoint commit
- Run: `git add lib/commands.sh && git commit -m "refactor(build): wire cmd_build machine guard to machine_selection_guard (nontty error-path repo display dropped)"`
- Expected: commit 成功。

### Task 4: surface gate + coverage_matrix + WORKSPACE 同步

- 目标：加 guard forbidden-token 回归锁（锁 module 不选号/不 exit/不 execute/不写 state），同步覆盖矩阵与 lib 路由表。
- Files: Create `tests/protocol/machine_selection_guard_surface.sh`、Modify `tools/coverage_matrix.md`、Modify `rules/03_WORKSPACE.md`。
- 验证范围：surface gate PASS；`ob_check` ALL GREEN；`run_all.sh --full` PASS。

- [ ] Step 1: 当前状态检查
- Run: `test ! -e tests/protocol/machine_selection_guard_surface.sh && ! grep -q 'machine_selection_guard' tools/coverage_matrix.md`
- Expected: rc=0（surface gate 未存在 + coverage_matrix 未含）。

- [ ] Step 2: 确认起点绿
- Run: `tools/ob_check.sh`
- Expected: ALL GREEN。

- [ ] Step 3: 实现
- Change：
  1. Create `tests/protocol/machine_selection_guard_surface.sh`（参照 `devtool_intake_surface.sh`：`set -uo pipefail` + source `assert.sh` + `assert_reset`；`ROOT`+`RENDER="$ROOT/lib/machine_selection_guard.sh"`）。forbidden 取 guard **不该直接做**的（选号 / exit / execute / 写 state）；guard 合法调用的 `list_fn`（`"$list_fn"` 形式）、`printf -v`、`[[ -t 0 ]]`、`return` **不禁**：
  ```bash
  forbidden=( 'pick_machine' 'read_machine_choice' 'read_list_choice' \
              'devtool_modify_run' 'devtool_build_run' 'devtool_reset_run' \
              'devtool_finish_run' 'devtool_search_refresh' 'dev_dispatch_subcmd' \
              'machine_state_write' 'machine_state_mark' 'machine_state_clear' \
              'tput ' )
  body="$(grep -v '^[[:space:]]*#' "$RENDER")"
  for tok in "${forbidden[@]}"; do
      assert_false "guard forbids $tok" grep -Fq "$tok" <<< "$body"
  done
  assert_summary
  ```
  （设计依据：guard 是前提检测层；选号归调用方调 `pick_machine`、execute 归 handler、state 写归 init/build 动作；`tput` 是 `pick_machine` 的列宽自适应职责（见 [machine_picker.sh](../../lib/machine_picker.sh) `pick_machine` 内 `tput cols`），前提检测者不该有。guard 只调 `list_fn`（参数化命令名）做枚举 + 检测。**实测**：对 `machine_selection_guard` body，上述 token 全 0 命中。）
  2. Modify `tools/coverage_matrix.md` 横切段（`machine 交互选择` 行后）加一行：
  ```
  | machine selection guard(枚举+empty/nontty 检测) | machine_selection_guard | unit/machine_selection_guard.sh;protocol/machine_selection_guard_surface.sh | leaf-pure(横切惯例,同 machine_picker.sh);恒返回0+outvar empty/nontty/ok;cmd_build/cmd_dev 共享, pick 留调用方 |
  ```
  3. Modify `rules/03_WORKSPACE.md` lib 路由表（`machine_picker.sh` 条目后）加：`machine_selection_guard.sh`（`machine selection` 前提检测：`machine_selection_guard` 检测集合非空+交互终端，leaf-pure（横切惯例，同 `machine_picker.sh`））。

- [ ] Step 4: 确认通过
- Run: `bash tests/protocol/machine_selection_guard_surface.sh && tools/ob_check.sh`
- Expected: surface gate `assert_summary` 全 PASS（forbidden 零命中）；`ob_check` ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "feat(guard): add machine_selection_guard surface gate + register coverage_matrix/WORKSPACE"`
- Expected: commit 成功。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改任务目标。
- 每完成一个任务，运行该任务的 Step 4 验证；`ob_check` 必须 ALL GREEN 才进下一任务。
- shellcheck 若 REGEN（良性行号平移），`git diff tests/.shellcheck-baseline` 确认后 commit；若 NEW_ALERT，先修告警。
- outvar 防护：`machine_selection_guard` 用名字字符串 + `printf -v`（非 nameref），无 nameref circular 风险（沿用 devtool_pick 范式）；但调用方传入的 `status_outvar` 名（`_msg`）不得与 `machine_selection_guard` 内部 local（`list_fn`/`status_outvar`/`_machines`/`_line`）碰撞——`_msg` 不撞，安全。
- 遇到阻塞、重复失败或计划与仓库现实不符（如 `cmd_dev`/`cmd_build` 行段边界与计划不一致），立即停下说明，不要猜。
- 当前分支 `main`；本工作应在新建分支（如 `feature/machine-selection-guard`）上进行，开始实现前确认分支并切出。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh && bash tests/unit/machine_selection_guard.sh && bash tests/protocol/machine_selection_guard_surface.sh && bash tests/orchestration/cmd_dev.sh && bash tests/protocol/smoke_ob.sh && bash tests/run_all.sh --full`
- Expected: `ob_check` ALL GREEN；guard unit + surface gate PASS；`cmd_dev.sh` PASS（`--machine` 路径不变）；`smoke_ob.sh` PASS（empty 路径 rc=3 不变）；`run_all.sh --full`（含 .exp 交互矩阵）PASS。
- 静态守卫复查（leaf-pure 权威由 exit_contract Y 规则守）：
  - Run: `python3 tools/exit_contract.py`
  - Expected: rc=0，输出含 `X: PASS` / `Y: PASS` / `Z: PASS`（Y 规则覆盖 `machine_selection_guard.sh`，守 guard 函数绝不 exit）。
- 修改摘要：`lib/machine_selection_guard.sh`（新）、`tests/unit/machine_selection_guard.sh`（新）、`tests/protocol/machine_selection_guard_surface.sh`（新）、`lib/commands.sh`（`cmd_dev` + `cmd_build` guard 段 → `machine_selection_guard` 调用 + case）、`tools/exit_contract.py`（+1 basename）、`tools/coverage_matrix.md`（+1 行）、`rules/03_WORKSPACE.md`（+1 路由条目）、`CONTEXT.md`（`machine resolution` → `machine selection guard`，已落）、`tests/.shellcheck-baseline`（regen）。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-27-machine-selection-guard-extraction-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
