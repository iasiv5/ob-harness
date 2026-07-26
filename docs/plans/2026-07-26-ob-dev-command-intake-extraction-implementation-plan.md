# cmd_dev 命令级 argv 解析 + TTY 菜单抽成 leaf-pure intake module 实施计划

## 目标

把 `cmd_dev`（`lib/commands.sh` 的 `cmd_dev` 内，argv 解析段 + TTY 菜单段）抽成 `lib/devtool_intake.sh` 的 leaf-pure intake module（`ob dev command intake`，见 `CONTEXT.md`），含两个函数：`dev_intake_argv`（确定性 argv 解析，return 0/1）与 `dev_intake_tty`（TTY 子命令引导，读 stdin，return 0/1/2/3）。`cmd_dev` 收缩为 intake → machine 前置 → init-done 前置 → (条件) intake_tty → dispatch → exit 的 L1 编排，exit 收口独占留 `cmd_dev`（ADR-0010/0012）。状态走 return-code（0/1/2/3 契约值），parsed fields 经 nameref outvar 回传（不污染全局）。

## 架构快照

- 分层：`cmd_dev`（L1 exit seam）→ `dev_intake_argv` / `dev_intake_tty`（L3 leaf-pure，命令入口解析+引导）→ `dev_dispatch_subcmd`（L3 leaf-pure，子命令编排，已有）→ `dev_subcmd_*`（L3 leaf-pure handler，已有）。intake 是 `subcommand handler` 之上、cmd_dev 之下的入口层；三层都是 L3 leaf-pure 领域化。
- intake 两函数职责边界：`dev_intake_argv` 消费 `"$@"` 把 `ob dev` argv 补全成 `(machine, subcmd, pattern, recipe)` 四元组（含 token 合法性守卫）；`dev_intake_tty` 仅当 `dev_subcmd` 空 + 交互终端时进入，做 7 项子命令菜单引导 + 各子命令位置参数补齐 + reset/finish/build 衔接 `devtool_pick_modified_recipe`。
- 迁移策略：Task 1 抽纯 argv parser（最确定性、风险最低、先建 module 样板 + exit_contract 门禁）；Task 2 抽 TTY 菜单（出血点集中在此，here-string 喂 stdin 测）；Task 3 surface gate + 文档同步 + 最终验证。中间态（Task 1 后 argv 走 intake、TTY 仍内联）每步绿，可接受。

## 全局约束

- **exit 归属（ADR-0010/0012）**：intake 是 leaf-pure，函数绝不 `exit`，`return` 契约值；`exit` 只在 `cmd_dev`（L1）。`exit_contract` Y 规则覆盖新 basename `'devtool_intake.sh'`。
- **状态走 return-code（i 决策）**：`dev_intake_argv` return 0/1（1=usage-error）；`dev_intake_tty` return 0/1/2/3。`cmd_dev` 复用现成 `\|\| _rc=$?; case "$_rc" in 0)...` 字面 case 收口（不用 `exit $?`——exit_contract X 规则禁 dynamic exit）。
- **fields 走 nameref outvar**：`(machine, subcmd, pattern, recipe)` 经调用方声明的 local + nameref 回填，不污染全局（区别于历史 `pick_machine` 设全局 `$MACHINE`）。outvar 形参名不得与函数内 local 同名（bash nameref 循环引用陷阱，参见 `devtool_pick.sh` unit 注释）。
- **return-code 不落多态返回码坑**：这是契约值 0/1/2/3（`dev_dispatch_subcmd` 已用、ADR-0012 背书），用 `\|\| _rc=$?` 捕获；非 `pick_machine` 式 0/1/2 多态存活探测码（`CONTEXT.md` `modified recipe selection` 条警告的那种）。论证留作 design note，不另起 ADR。
- **dry_run 设全局**：`dev_intake_argv` 解析到 `-d|-D|--dry-run` 时设全局 `DRY_RUN=1`（跟 `ob` 入口 `parse_args` 对称、跟现状一致）；`cmd_dev` 末端仍读 `"${DRY_RUN:-0}"` 传给 dispatch。intake 是"解析全局选项"的层，设全局选项变量属其职责（leaf-pure 允许副作用，`CONTEXT.md` `function semantic layer` 条：pure 仅指 no-direct-exit）。
- **machine 前置 + init-done 前置留 cmd_dev**：`dev_machine` 空 → 枚举 initialized + 非 TTY guard + `pick_machine` + cancel 映射（440-462），以及 `machine_state_is_initialized` 前置（464-469），都留 `cmd_dev`——它们是 machine 生命周期前置，不是命令语法解析。intake 不调 `machine_state_*`。
- **文案逐字照搬**：菜单文案、notice/error/remedy 从 `cmd_dev` 原段原样搬进 intake 函数，不改写。
- **`_positional_count` 不照搬（dead variable）**：`cmd_dev` 原 argv 段的 `_positional_count`（L405 声明 + L420/L430 递增）全程无读取点、dispatch 不传它，是死代码。抽取进 `dev_intake_argv` 时丢弃，不固化进新 module。
- **lib 文件结构**：过 `extract_funcs` 三段（header 注释 + 函数定义 + footer 纯函数定义），参照 `lib/devtool_pick.sh`。
- **不写新 ADR**：三条件不满足（可逆 / 不 surprising——照搬 ADR-0010/0012 模式 / 真分叉已被先例覆盖）；intake 术语已落 `CONTEXT.md`，本计划归档即可。

## 输入工件

- grill 共识（5 决策）：YAGNI 闸门通过（零单测 + 5+ bug-fix 史 + `ob dev` 命令面还会变）；范围选项 C（argv + TTY 同 module 两函数）；接口 (i)（return-code + nameref）；命名 `ob dev command intake`；不写新 ADR。
- 术语：`CONTEXT.md` 的 `ob dev command intake` 词条（本计划前置已落）。
- exit 归属：`docs/adr/0010-ob-dev-dispatch-leaf-pure-exit.md`、`docs/adr/0012-ob-dev-subcmd-handler-leaf-pure-exit.md`。
- 范式参照：`lib/devtool_pick.sh`（leaf-pure + nameref outvar + 头注释引 ADR）、`tests/unit/devtool_pick.sh`（unit 范式：`ob_loader.sh` + here-string 喂 stdin + outvar 当前 shell 跑 + `2>"$_err"` 捕 stderr）、`tests/protocol/status_render_surface.sh`（surface gate forbidden-token 范式）、`tools/ob_check.sh`（回归门禁）。

## 文件结构与职责

- Create: `lib/devtool_intake.sh` — 文件头注释 + `dev_intake_argv`（Task 1）+ `dev_intake_tty`（Task 2）。
- Create: `tests/unit/devtool_intake.sh` — 两函数 unit 测（Task 1 累加 argv case，Task 2 累加 tty case）。
- Create: `tests/protocol/devtool_intake_surface.sh` — intake forbidden-token 回归锁（Task 3）。
- Modify: `lib/commands.sh` — `cmd_dev` argv 段切换为 `dev_intake_argv` 调用（Task 1）；TTY 段切换为 `dev_intake_tty` 调用（Task 2）。
- Modify: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'devtool_intake.sh': set(),`（Task 1）。
- Modify: `tools/coverage_matrix.md` — dev 段加 intake 行（Task 3）。
- Modify: `rules/03_WORKSPACE.md` — lib 路由表加 `devtool_intake.sh` 条目（Task 3）。
- Regen: `tests/.shellcheck-baseline` — `ob_check` 自动重生成（REGEN 时 `git diff` 确认）。

接口契约（贯穿全任务）：
- `dev_intake_argv(out_machine, out_subcmd, out_pattern, out_recipe, <args...>) → return 0`（ok，outvars 填，`-d` 设全局 `DRY_RUN=1`）/ `return 1`（usage-error：unknown option / missing value / `--machine` 非法 / too-many positional）。前 4 参为 nameref 形参名，其余为 ob dev argv。
- `dev_intake_tty(machine, build_dir, out_subcmd, out_pattern, out_recipe) → return 0`（ok，outvars 补全）/ `1`（read-fail·invalid selection）/ `2`（cancel）/ `3`（empty-modified-recipes，来自 `devtool_pick_modified_recipe` 的 `empty`）。前提：调用者保证 `dev_subcmd` 空 + `-t 0` + machine initialized。

## 任务清单

### Task 1: 建 devtool_intake.sh 骨架 + dev_intake_argv（纯 argv 解析）+ exit_contract 注册 + cmd_dev argv 段切换 + unit

- 目标：落地 intake module 样板——文件骨架、`dev_intake_argv`（最确定性、最好测）、exit_contract 门禁注册、`cmd_dev` argv 段切换、unit 测范式。建立 `-d` 设全局 `DRY_RUN` + nameref outvar 回填 + return 0/1 的写法。
- Files: Create `lib/devtool_intake.sh`、Create `tests/unit/devtool_intake.sh`、Modify `lib/commands.sh`（`cmd_dev` argv 段）、Modify `tools/exit_contract.py`。
- 验证范围：`bash tests/unit/devtool_intake.sh` PASS；`tools/ob_check.sh` ALL GREEN；`cmd_dev` 行为不变（`bash tests/orchestration/cmd_dev.sh` PASS）。
- 接口契约：
  - Produces: `lib/devtool_intake.sh`（骨架 + `dev_intake_argv`）、exit_contract 注册 `devtool_intake.sh`、unit stub/范式。
  - Consumes（实现内）: 无下游 module（纯 argv 字符串处理 + nameref `printf -v`）。

- [ ] Step 1: 写当前状态检查（intake 未存在 + 未注册 + cmd_dev 仍内联 argv 解析）
- Run: `test ! -e lib/devtool_intake.sh && ! grep -q 'devtool_intake' tools/exit_contract.py && grep -q 'while \[\[ $# -gt 0 \]\]' lib/commands.sh`
- Expected: rc=0（module 未存在 + exit_contract 未含 + cmd_dev 仍有内联 argv while 循环）。

- [ ] Step 2: 确认起点绿
- Run: `tools/ob_check.sh`
- Expected: ALL GREEN（当前 baseline；devtool_intake.sh 尚未引入）。

- [ ] Step 3: 写最小实现
- Change:
  - **⚠️ 顺序约束（防 exit_contract Y 假绿）**：先做第 2 点（`exit_contract.py` 登记 `devtool_intake.sh`），再创建 `lib/devtool_intake.sh`（第 1 点），再改 `cmd_dev`（第 3 点），三处同 commit。Y 规则只查 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 字典里登记的 basename——intake.sh 已创建但未登记的中间态，里面误写 `exit` 不会被 Y 报。禁止在该中间态跑 `ob_check` 当门禁。
  1. Create `lib/devtool_intake.sh`，文件头注释（参照 `devtool_pick.sh`：职责 = `ob dev` 命令入口的解析+引导层、leaf-pure、消费 `"$@"`/`devtool_pick_modified_recipe`/`read`、术语见 `CONTEXT.md` `ob dev command intake`）。Exit 行显式引 ADR-0010/0012，措辞 `Exit: leaf-pure module (ADR-0010/0012); 函数绝不 exit，return 契约值；exit 归 cmd_dev`。写入 `dev_intake_argv`（从 `cmd_dev` argv 段照搬 case 逻辑，return 化 + nameref outvar 回填；`-d|-D|--dry-run` 设全局 `DRY_RUN=1`）：
  签名定为 **nameref 在前 4 位、args 在后**（函数内 `shift 4` 后 `$@` 即 ob dev argv，最干净；nameref 可直接赋值，不用 `printf -v`）。从 `cmd_dev` argv 段原样搬 case 逻辑，仅 `exit 1` → `return 1`：
  ```bash
  # dev_intake_argv <out_machine> <out_subcmd> <out_pattern> <out_recipe> <args...>
  # 消费 ob dev 的 argv(--machine/二级子命令/pattern·recipe/全局选项), 解析为四元组经 nameref outvar 回填。
  # -d|-D|--dry-run 设全局 DRY_RUN=1(跟 ob 入口 parse_args 对称)。return 0(ok) / 1(usage-error)。
  # 前提(调用者保证): 4 个 outvar 名不与本函数 local 同名(nameref 循环引用陷阱)。
  dev_intake_argv() {
      local -n _ia_machine="$1" _ia_subcmd="$2" _ia_pattern="$3" _ia_recipe="$4"
      shift 4
      _ia_machine=""; _ia_subcmd=""; _ia_pattern=""; _ia_recipe=""
      while [[ $# -gt 0 ]]; do
          case "$1" in
              --machine)
                  [[ $# -ge 2 ]] || { error "Missing value for --machine" >&2; return 1; }
                  _ia_machine="$2"; shift 2
                  [[ -z "$_ia_machine" || "$_ia_machine" == -* ]] && { error "ob dev: invalid --machine value '$_ia_machine'" >&2; return 1; } ;;
              --machine=*)
                  _ia_machine="${1#--machine=}"; shift
                  [[ -z "$_ia_machine" || "$_ia_machine" == -* ]] && { error "ob dev: invalid --machine value '$_ia_machine'" >&2; return 1; } ;;
              -d|-D|--dry-run) DRY_RUN=1; shift ;;
              list|modify|refresh|build|finish|reset|status)
                  if [[ -z "$_ia_subcmd" ]]; then
                      _ia_subcmd="$1"
                  else
                      case "$_ia_subcmd" in
                          list)   [[ -z "$_ia_pattern" ]] || { error "ob dev list: too many patterns" >&2; return 1; }; _ia_pattern="$1" ;;
                          modify|reset|finish|build) [[ -z "$_ia_recipe" ]] || { error "ob dev $_ia_subcmd: too many recipes" >&2; return 1; }; _ia_recipe="$1" ;;
                          *)      error "ob dev $_ia_subcmd: unexpected argument '$1'" >&2; return 1 ;;
                      esac
                  fi
                  shift ;;
              -*) error "ob dev: unknown option '$1'" >&2; return 1 ;;
              *)
                  case "$_ia_subcmd" in
                      list)   [[ -z "$_ia_pattern" ]] || { error "ob dev list: too many patterns" >&2; return 1; }; _ia_pattern="$1" ;;
                      modify|reset|finish|build) [[ -z "$_ia_recipe" ]] || { error "ob dev $_ia_subcmd: too many recipes" >&2; return 1; }; _ia_recipe="$1" ;;
                      *)      error "ob dev: unexpected positional '$1' (need subcommand first)" >&2; return 1 ;;
                  esac
                  shift ;;
          esac
      done
      return 0
  }
  ```
  2. Modify `tools/exit_contract.py`：在 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（`devtool_subcmd.sh` 行后）加一行 `'devtool_intake.sh': set(),`。
  3. Modify `lib/commands.sh` `cmd_dev`：把 argv 段（L405 local 声明 + L406-438 while 循环，即从 `local dev_machine="" dev_subcmd="" dev_pattern="" dev_recipe="" _positional_count=0` 到 `done`）替换为：
  ```bash
      local dev_machine="" dev_subcmd="" dev_pattern="" dev_recipe=""
      local _iarc=0
      dev_intake_argv dev_machine dev_subcmd dev_pattern dev_recipe "$@" || _iarc=$?
      # cmd_dev 字面 case 收口（exit_contract X 禁 exit $?, || _rc=$? 防 set -e）
      case "$_iarc" in 0) ;; *) exit 1;; esac
  ```
  （注：machine 前置段、init-done 前置、TTY 段、dispatch 段本任务**不动**。）
  4. Create `tests/unit/devtool_intake.sh`（参照 `devtool_pick.sh` unit：`source ../lib/ob_loader.sh` + `assert.sh` + `assert_reset`；mktemp TMP + trap）。outvar 当前 shell 跑，stderr 用 `2>"$_err"` 捕（不用 `$()`）。case：① 合法 `--machine m list pat` → return 0 + outvar 各字段正确；② `--machine=m modify r` 等号形式 → return 0；③ `-d` → return 0 + `$DRY_RUN == 1`（每 case 前 `DRY_RUN=0` 重置）；④ unknown option `--bogus` → return 1 + stderr 含 "unknown option"；⑤ `--machine` 缺值 → return 1；⑥ `--machine ""` 或 `--machine -x`（非法值）→ return 1；⑦ list 两 pattern → return 1（too-many）；⑧ modify 两 recipe → return 1；⑨ 无 subcmd 无位置参 → return 0（subcmd 空，留 TTY/dispatch 处理）。

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/devtool_intake.sh && tools/ob_check.sh && bash tests/orchestration/cmd_dev.sh`
- Expected: unit `assert_summary` 全 PASS；`ob_check.sh` ALL GREEN（含 exit_contract Y 对 `devtool_intake.sh` 的 leaf-pure 守卫、shellcheck baseline、run_all）；orchestration `cmd_dev.sh` PASS（argv 路径行为不变）。

- [ ] Step 5: checkpoint commit
- Run: `git add lib/devtool_intake.sh tests/unit/devtool_intake.sh lib/commands.sh tools/exit_contract.py tests/.shellcheck-baseline && git commit -m "feat(dev): extract dev_intake_argv leaf-pure argv parser + exit_contract gate (ADR-0010/0012)"`
- Expected: commit 成功。

### Task 2: dev_intake_tty（TTY 菜单引导）+ cmd_dev TTY 段切换 + unit

- 目标：抽 TTY 菜单（出血点集中段：cf3e8b2/3af20f5/e715ae8/b8f670d 多次改这），7 项菜单 + per-subcmd 位置参数补齐 + reset/finish/build 衔接 `devtool_pick_modified_recipe`。读 stdin，return 0/1/2/3。
- Files: Modify `lib/devtool_intake.sh`（加 `dev_intake_tty`）、Modify `tests/unit/devtool_intake.sh`（加 tty case）、Modify `lib/commands.sh`（`cmd_dev` TTY 段）。
- 验证范围：unit tty case PASS；`ob_check` ALL GREEN；`cmd_dev` TTY 路径行为不变。
- 接口契约：
  - Produces: `dev_intake_tty`。
  - Consumes: `devtool_pick_modified_recipe`（selection 层，leaf-pure）、`read`（stdin）、`error`/`warn`（util）。不直接调 execute-run / dispatch / machine_state。

- [ ] Step 1: 当前状态检查
- Run: `! grep -q 'dev_intake_tty()' lib/devtool_intake.sh && grep -q 'Select subcommand \[1-7\]' lib/commands.sh`
- Expected: rc=0（函数未定义 + cmd_dev 仍有内联 TTY 菜单）。

- [ ] Step 2: 确认起点绿
- Run: `bash tests/unit/devtool_intake.sh && tools/ob_check.sh`
- Expected: PASS（unit 绿 + ob_check ALL GREEN）。

- [ ] Step 3: 实现
- Change：
  1. 在 `lib/devtool_intake.sh` 加 `dev_intake_tty`（从 `cmd_dev` TTY 段照搬，return 化 + nameref outvar 回填 subcmd/pattern/recipe）：
  ```bash
  # dev_intake_tty <machine> <build_dir> <out_subcmd> <out_pattern> <out_recipe>
  # 前提(调用者保证): dev_subcmd 空 + 交互终端(-t 0) + machine initialized。
  # 7 项子命令菜单引导 + 各子命令位置参数补齐 + reset/finish/build 衔接 devtool_pick_modified_recipe。
  # 读 stdin; return 0(ok, outvars 补全) / 1(read-fail·invalid) / 2(cancel) / 3(empty-modified-recipes)。
  dev_intake_tty() {
      local machine="$1" build_dir="$2"
      local -n _it_subcmd="$3" _it_pattern="$4" _it_recipe="$5"
      # 1) 7 项菜单 + read 选号(文案照搬 cmd_dev 475-499)
      echo "  ob dev subcommands:" >&2
      # ... 7 行菜单文案原样搬 ...
      local _choice=""
      if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Select subcommand [1-7] (0 to cancel): ")" _choice; then
          error "Unable to read subcommand selection from stdin." >&2; return 1
      fi
      case "$_choice" in
          0) warn "ob dev cancelled by user." >&2; return 2 ;;
          1) _it_subcmd="list" ;; 2) _it_subcmd="modify" ;; 3) _it_subcmd="refresh" ;;
          4) _it_subcmd="reset" ;; 5) _it_subcmd="status" ;; 6) _it_subcmd="finish" ;;
          7) _it_subcmd="build" ;;
          *) error "ob dev: invalid subcommand selection '$_choice'." >&2; return 1 ;;
      esac
      # 2) 按子命令补位置参数(文案 + 逻辑照搬 cmd_dev 501-541)
      case "$_it_subcmd" in
          list)
              if ! read -r -p "$(echo -e "${PROMPT_PREFIX} pattern (Enter = all recipes): ")" _it_pattern; then
                  error "Unable to read pattern." >&2; return 1
              fi ;;
          modify)
              if ! read -r -p "$(echo -e "${PROMPT_PREFIX} recipe name: ")" _it_recipe; then
                  error "Unable to read recipe name." >&2; return 1
              fi
              if [[ -z "$_it_recipe" ]]; then
                  error "ob dev modify: no recipe specified." >&2
                  error "Run 'ob dev --machine $machine list [pattern]' to discover recipes first." >&2
                  return 3
              fi ;;
          reset|finish|build)
              local _pick_st=""
              devtool_pick_modified_recipe "$machine" "$build_dir" "$_it_subcmd" _pick_st
              case "$_pick_st" in
                  ok:*)    _it_recipe="${_pick_st#ok:}" ;;
                  empty)   warn "No modified recipes for $machine." >&2
                           error "Run 'ob dev --machine $machine modify <recipe>' first." >&2
                           return 3 ;;
                  cancel)  return 2 ;;
                  read-fail|status-failed) return 1 ;;
              esac ;;
          refresh|status) ;;
      esac
      return 0
  }
  ```
  （注：菜单 7 行文案、prompt 文案、notice/remedy 从 `cmd_dev` 475-541 原样搬，不浓缩。`_pick_st` 等本函数 local 不得与 nameref 形参 `$_it_*` 同名。）
  2. Modify `lib/commands.sh` `cmd_dev`：把 TTY 段（L474-542，从 `if [[ -z "$dev_subcmd" && -t 0 ]]; then` 到对应 `fi`；L472-473 两行前置注释一并替换）替换为：
  ```bash
      if [[ -z "$dev_subcmd" && -t 0 ]]; then
          local _trc=0
          dev_intake_tty "$dev_machine" "$dev_build_dir" dev_subcmd dev_pattern dev_recipe || _trc=$?
          case "$_trc" in 0) ;; 1) exit 1;; 2) exit 2;; 3) exit 3;; *) exit 1;; esac
      fi
  ```
  3. `tests/unit/devtool_intake.sh` 加 `dev_intake_tty` case（参照 `devtool_pick.sh` 的 here-string 喂 stdin：`<<< $'1\n'` 选 1、`<<< $'0\n'` 取消、`</dev/null` read-fail）。前置 mock：`MACHINE`/`OPENBMC_DIR`/`BUILD_DIR`/mock devtool（照搬 `devtool_pick.sh` 的 mock setup，因 `devtool_pick_modified_recipe` 经 `devtool_status_run` 调 devtool）。case：① stdin `1`（选 list）+ 第二行 `ipmi`（pattern）→ return 0 + subcmd=list + pattern=ipmi；② stdin `2`（modify）+ `phosphor-ipmi-host` → return 0 + subcmd=modify + recipe 正确；③ stdin `0` → return 2（cancel）；④ stdin `9`（invalid）→ return 1 + stderr 含 "invalid subcommand selection"；⑤ stdin `</dev/null`（read 失败）→ return 1；⑥ stdin `4`（reset）+ mock devtool state 写 modified recipe + 选 `1` → return 0 + recipe 正确（经 `devtool_pick_modified_recipe` ok 路径）；⑦ stdin `4` + mock state 空 → return 3（empty-modified-recipes）；⑧ stdin `4` + 选 `0` → return 2（cancel 经 pick）；⑨ modify + recipe 空（直接 Enter）→ return 3。

- [ ] Step 4: 确认通过
- Run: `bash tests/unit/devtool_intake.sh && tools/ob_check.sh`
- Expected: unit PASS（含全 tty case）；ob_check ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "feat(dev): extract dev_intake_tty TTY subcommand guidance (here-string stdin tested)"`
- Expected: commit 成功。

### Task 3: surface gate + coverage_matrix + WORKSPACE 路由同步

- 目标：加 intake forbidden-token 回归锁（锁 intake 不越权直接 execute/dispatch/查 machine 生命周期），同步覆盖矩阵与 lib 路由表，跑最终验证。
- Files: Create `tests/protocol/devtool_intake_surface.sh`、Modify `tools/coverage_matrix.md`、Modify `rules/03_WORKSPACE.md`。
- 验证范围：surface gate PASS；ob_check ALL GREEN；`run_all.sh --full` PASS。
- 接口契约：Produces surface gate + 文档同步；无新函数。

- [ ] Step 1: 当前状态检查
- Run: `test ! -e tests/protocol/devtool_intake_surface.sh && ! grep -q 'dev_intake' tools/coverage_matrix.md`
- Expected: rc=0（surface gate 未存在 + coverage_matrix 未含 intake）。

- [ ] Step 2: 确认起点绿
- Run: `tools/ob_check.sh`
- Expected: ALL GREEN。

- [ ] Step 3: 实现
- Change：
  1. Create `tests/protocol/devtool_intake_surface.sh`（参照 `status_render_surface.sh`：source `assert.sh` + `assert_reset`；`RENDER="$ROOT/lib/devtool_intake.sh"`；`body="$(grep -v '^[[:space:]]*#' "$RENDER")"`）。forbidden 取 intake **不该直接做**的（execute-run 直接调用 / dispatch / machine 生命周期查询）；intake 合法调用的 `devtool_pick_modified_recipe`、`read`、`printf -v`、`error`/`warn` **不禁**：
  ```bash
  forbidden=( 'devtool_modify_run' 'devtool_reset_run' 'devtool_finish_run' \
              'devtool_build_run' 'devtool_search_refresh' 'devtool_search_read' \
              'dev_dispatch_subcmd' 'machine_state_' )
  body="$(grep -v '^[[:space:]]*#' "$RENDER")"
  for tok in "${forbidden[@]}"; do
      assert_false "intake forbids $tok" grep -Fq "$tok" <<< "$body"
  done
  assert_summary
  ```
  （设计依据：intake 是入口解析+引导层；execute 由 handler 层做、dispatch 由 cmd_dev 做、machine 生命周期前置由 cmd_dev 做。intake 只经 `devtool_pick_modified_recipe` 间接碰 status_run，不直接 execute。forbidden 集不含裸英文词，避免误伤菜单文案。**实测**：对 `cmd_dev` 当前 argv+TTY 段 body，上述 8 个 forbidden token 全 0 命中——`machine_state_` 在 cmd_dev 全段命中 3 次但全属"留 cmd_dev"的 machine 前置/init-done 前置段，不进 intake body；合法调用 `devtool_pick_modified_recipe` 不在 forbidden 列表。）
  2. Modify `tools/coverage_matrix.md` dev 段（`cmd_dev dispatch 非 TTY 路径` 行后）加一行：
  ```
  | 命令入口 argv 解析 + TTY 子命令引导(intake module) | dev_intake_argv;dev_intake_tty | unit/devtool_intake.sh;protocol/devtool_intake_surface.sh | leaf-pure(ADR-0010/0012);argv return 0/1, tty return 0/1/2/3;nameref outvar 回填;-d 设全局 DRY_RUN |
  ```
  3. Modify `rules/03_WORKSPACE.md` lib 路由表（`devtool_subcmd.sh` 条目后）加：`devtool_intake.sh`（`ob dev` 命令入口解析+引导：`dev_intake_argv` 纯 argv 解析 + `dev_intake_tty` TTY 菜单引导，leaf-pure，ADR-0010/0012）。

- [ ] Step 4: 确认通过
- Run: `bash tests/protocol/devtool_intake_surface.sh && tools/ob_check.sh`
- Expected: surface gate `assert_summary` 全 PASS（forbidden 零命中）；ob_check ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "feat(dev): add devtool_intake surface gate + register coverage_matrix/WORKSPACE"`
- Expected: commit 成功。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改任务目标。
- 每完成一个任务，运行该任务的 Step 4 验证；`ob_check` 必须 ALL GREEN 才进下一任务。
- shellcheck 若 REGEN（良性行号平移），`git diff tests/.shellcheck-baseline` 确认后 commit；若 NEW_ALERT，先修告警。
- nameref 撞名防护：`dev_intake_argv` 的 nameref（`_ia_machine`/`_ia_subcmd`/`_ia_pattern`/`_ia_recipe`）与 `dev_intake_tty` 的 nameref（`_it_subcmd`/`_it_pattern`/`_it_recipe`）+ 普通 local（`_choice`/`_pick_st`）都不得与 `cmd_dev` 传入的 outvar 名（`dev_machine`/`dev_subcmd`/`dev_pattern`/`dev_recipe`）撞名——bash nameref 循环引用静默失败（不报错但不回填），参见 `devtool_pick.sh` unit 注释。
- 遇到阻塞、重复失败或计划与仓库现实不符（如 cmd_dev 行段边界与计划不一致、nameref 形参与某 local 撞名），立即停下说明，不要猜。
- 当前分支 `main`；本工作应在新建分支（如 `feature/ob-dev-command-intake`）上进行，开始实现前确认分支并切出。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh && bash tests/unit/devtool_intake.sh && bash tests/protocol/devtool_intake_surface.sh && bash tests/orchestration/cmd_dev.sh && bash tests/run_all.sh --full`
- Expected: ob_check ALL GREEN；intake unit + surface gate PASS；`cmd_dev.sh` PASS；`run_all.sh --full`（含 .exp 交互矩阵）PASS。
- 静态守卫复查（leaf-pure 权威由 exit_contract Y 规则守）：
  - Run: `python3 tools/exit_contract.py`
  - Expected: rc=0，输出含 `X: PASS` / `Y: PASS` / `Z: PASS`（Y 规则覆盖 `devtool_intake.sh`，守 intake 函数绝不 exit）。
- 修改摘要：`lib/devtool_intake.sh`（新）、`tests/unit/devtool_intake.sh`（新）、`tests/protocol/devtool_intake_surface.sh`（新）、`lib/commands.sh`（cmd_dev argv 段 + TTY 段 → 两句 intake 调用）、`tools/exit_contract.py`（+1 basename）、`tools/coverage_matrix.md`（+1 行）、`rules/03_WORKSPACE.md`（+1 路由条目）、`tests/.shellcheck-baseline`（regen）；cmd_dev 从 ~146 行（403-548）降至 ~50 行编排。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-26-ob-dev-command-intake-extraction-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
