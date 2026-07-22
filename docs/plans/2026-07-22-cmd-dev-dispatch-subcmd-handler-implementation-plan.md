# cmd_dev dispatch case 拆成 leaf-pure subcommand handler 实施计划

## 目标

把 `cmd_dev` dispatch case（`lib/commands.sh` 的 `cmd_dev` 内，原 1109-1277 行段）的 7 个子命令分支（list/modify/refresh/reset/finish/status/build），抽成 `lib/devtool_subcmd.sh` 的 leaf-pure subcommand handler（`dev_subcmd_*`），由 `dev_dispatch_subcmd` dispatcher 分发。`cmd_dev` 退化为 parse + precondition + TTY guide + dispatch entry。handler 用 `return` 回传 exit-code 契约值（0/1/2/3），`cmd_dev` `exit $?` 收口（ADR-0012）。

## 架构快照

- 分层：`cmd_dev`（L1 exit）→ `dev_dispatch_subcmd`（L3 leaf-pure dispatcher）→ `dev_subcmd_*`（L3 leaf-pure handler）。
- handler 共享入口契约 `(machine, build_dir, recipe, pattern, dry_run) → return 0/1/2/3` + 两段真重复前置 helper（`_dev_dryrun_gate`、`_dev_recipe_precondition`）；run→relay→emit 段**各自保留真实形状**（reset/finish/status 走 relay+emit JSON；modify 走 relay+printf；refresh/build 空输出且 refresh 不调 relay；list 走 read→三态机），**不强求统一模板**。
- 迁移策略 E：Task 1-7 逐个建 handler + unit，并把 `cmd_dev` 对应分支切换为 `dev_subcmd_* ...; exit $?`（过渡期 cmd_dev 直接调 handler）；Task 8 引入 `dev_dispatch_subcmd` 把 7 个内联调用收口为一句。

## 全局约束

- **exit 归属（ADR-0012）**：handler 是 leaf-pure，函数绝不 `exit`，`return 0/1/2/3`；`exit` 只在 `cmd_dev`（L1）。`exit_contract` Y 规则覆盖新 basename。
- **不强求统一模板（D3）**：7 子命令的 run→relay→emit 形状事实分 4 类，保留差异，不造统一骨架。
- **not_mod 冻结（D5）**：build handler 原样保留 `_b_notmod` 绕 relay 路径（显式 cat+rm + error + return 3），不并入 relay；补 unit 锁定；留 rationale 注释。
- **recipe 前置 TOCTOU（D4）**：`_dev_recipe_precondition` 在 handler 内首步调用（非 TTY 路径不经 TTY guide，靠它兜底）。
- **命名（D6）**：`lib/devtool_subcmd.sh` + `dev_dispatch_subcmd` + `dev_subcmd_<name>` + `_dev_dryrun_gate`/`_dev_recipe_precondition`。
- **lib 文件结构**：过 `extract_funcs` 三段（header 注释 + 函数定义 + footer 纯函数定义），参照 `lib/devtool_pick.sh`。
- **dry_run 走入参**：handler 签名含 `dry_run`，不读全局 `$DRY_RUN`（自包含、好测）；`cmd_dev` 切换时传 `"${DRY_RUN:-0}"`。
- **cmd_dev 收口模式（Task 1 实施发现，适配 exit_contract X）**：handler leaf-pure return exit-code(0/1/2/3)，cmd_dev 用**字面 case 映射**收口，**不用 `exit $?`**——exit_contract X 规则禁 dynamic exit（仅 require_path 例外，见 ob_check 实测报 `dynamic exit '$?' outside require_path`）。统一写法：`local _rc=0; dev_subcmd_* ... || _rc=$?; case "$_rc" in 0) exit 0;; 1) exit 1;; 2) exit 2;; 3) exit 3;; *) exit 1;; esac`（`|| _rc=$?` 兼防 set -e 在 handler return 非零时中止）。dispatcher `dev_dispatch_subcmd` 透传用 `return $?`（leaf-pure return，不违反 X——X 只管 `exit`）。
- **scope（D2）**：本次只抽 dispatch case；TTY guide（cmd_dev 内交互引导段）、arg parsing 不动。
- 文案逐字照搬：各 notice / remedy / error 文案从 `cmd_dev` 原分支原样搬到 handler，不改写。

## 输入工件

- 设计决策：`docs/adr/0012-ob-dev-subcmd-handler-leaf-pure-exit.md`（exit 归属）。
- 术语：`CONTEXT.md` 的 `subcommand handler` 词条。
- grill 共识 6 决策（D1-D6，见架构快照与全局约束）。
- 范式参照：`lib/devtool_pick.sh`（leaf-pure handler 写法）、`tests/unit/devtool_pick.sh`（unit 测范式）、`tools/ob_check.sh`（回归门禁）。

## 文件结构与职责

- Create: `lib/devtool_subcmd.sh` — 文件头注释 + `_dev_dryrun_gate` + `_dev_recipe_precondition` + 7 个 `dev_subcmd_*` + `dev_dispatch_subcmd`（Task 8 加）。
- Create: `tests/unit/devtool_subcmd.sh` — 7 handler 的 unit 测（逐 task 累加 case）。
- Modify: `lib/commands.sh` — `cmd_dev` dispatch case 7 分支逐个切换为 handler 调用；Task 8 整段替换为 `dev_dispatch_subcmd ...; exit $?`。
- Modify: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'devtool_subcmd.sh': set()`（Task 1）。
- Regen: `tests/.shellcheck-baseline` — `ob_check` 自动重生成（REGEN 时 `git diff` 确认）。

接口契约（贯穿全任务）：
- `dev_subcmd_<name>(machine, build_dir, recipe, pattern, dry_run) → return 0/1/2/3`
- `_dev_dryrun_gate(dry_run, notice_msg) → return 0`（dry-run 命中，handler 应 return 0）`/ return 1`（非 dry-run，继续）
- `_dev_recipe_precondition(machine, recipe, subcmd) → return 0`（recipe 非空）/ `return 3`（空，已打 error+remedy）
- `dev_dispatch_subcmd(subcmd, machine, build_dir, recipe, pattern, dry_run) → return $?`（透传 handler 返回码；Task 8 引入）

## 任务清单

### Task 1: 建 devtool_subcmd.sh 骨架 + 2 helper + dev_subcmd_status + status unit + exit_contract 注册 + cmd_dev status 分支切换

- 目标：落地 handler 模式样板——文件骨架、两段共享前置 helper、第一个 handler（status，最薄：无 recipe 前置、无 outvar、无特殊路径）、unit 测范式、exit_contract 门禁注册、cmd_dev 该分支切换。
- Files: Create `lib/devtool_subcmd.sh`、Create `tests/unit/devtool_subcmd.sh`、Modify `lib/commands.sh`（cmd_dev 的 `status)` 分支）、Modify `tools/exit_contract.py`。
- 验证范围：`bash tests/unit/devtool_subcmd.sh` PASS；`tools/ob_check.sh` ALL GREEN；cmd_dev status 行为不变（orchestration `cmd_dev.sh` 内 status 路径仍绿）。
- 接口契约：
  - Consumes: `devtool_status_run`、`dev_relay_result`、`dev_emit_status_jsonl`、`notice`/`warn`/`error`（既有 leaf-pure / util）。
  - Produces: `lib/devtool_subcmd.sh`（骨架 + `_dev_dryrun_gate` + `_dev_recipe_precondition` + `dev_subcmd_status`）、exit_contract 注册 `devtool_subcmd.sh`、unit 测 stub 范式。

- [ ] Step 1: 写当前状态检查（handler 未存在 + 未注册）
- Run: `test ! -e lib/devtool_subcmd.sh && ! grep -q 'devtool_subcmd' tools/exit_contract.py`
- Expected: rc=0（lib/devtool_subcmd.sh 不存在 + exit_contract.py 未含 devtool_subcmd）。

- [ ] Step 2: 运行并确认当前失败
- Run: `tools/ob_check.sh`
- Expected: ALL GREEN（当前 baseline；此步确认起点干净，devtool_subcmd.sh 尚未引入）。

- [ ] Step 3: 写最小实现
- Change:
  1. Create `lib/devtool_subcmd.sh`，文件头注释（参照 `devtool_pick.sh`：说明 module 职责 = ob dev 二级子命令 porcelain 生命周期编排、leaf-pure、消费 devtool_*_run/dev_relay_result/dev_emit_*、术语见 CONTEXT.md subcommand handler；Exit 行显式引 ADR-0012，措辞 `Exit: leaf-pure module (ADR-0012); 函数绝不 exit，return 0/1/2/3；exit 归 cmd_dev`（类比 devtool_pick.sh 引 ADR-0010））。写入：
  ```bash
  # _dev_dryrun_gate <dry_run> <notice_msg>
  # dry-run 命中 → notice(stderr) + return 0(handler 应 return 0)；否则 return 1(继续)。
  _dev_dryrun_gate() {
      local dry_run="$1" notice_msg="$2"
      if [[ "$dry_run" == "1" ]]; then
          notice "$notice_msg" >&2
          return 0
      fi
      return 1
  }

  # _dev_recipe_precondition <machine> <recipe> <subcmd>
  # recipe 空 → error + remedy(按 subcmd: modify/reset→list, finish/build→status) + return 3；否则 return 0。
  _dev_recipe_precondition() {
      local machine="$1" recipe="$2" subcmd="$3"
      if [[ -z "$recipe" ]]; then
          error "ob dev $subcmd: no recipe specified." >&2
          case "$subcmd" in
              modify|reset) error "Run 'ob dev --machine $machine list [pattern]' to discover recipes first." >&2 ;;
              finish|build) error "Run 'ob dev --machine $machine status' to list modified recipes first." >&2 ;;
          esac
          return 3
      fi
      return 0
  }

  # dev_subcmd_status <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1
  dev_subcmd_status() {
      local machine="$1" build_dir="$2" recipe="$3" pattern="$4" dry_run="$5"
      _dev_dryrun_gate "$dry_run" "[DRY-RUN] ob dev status: would list modified recipes via devtool status." && return 0
      local _st_entries="" _st_stage="" _st_stderr_file="" _st_rc=0
      devtool_status_run "$machine" "$build_dir" _st_entries _st_stage _st_stderr_file || _st_rc=$?
      dev_relay_result status "$_st_stderr_file" "$_st_stage" "" "${_st_rc:-0}" || return 1
      if [[ -z "$_st_entries" ]]; then
          warn "No modified recipes for $machine." >&2
          return 0
      fi
      dev_emit_status_jsonl "$_st_entries" || { error "ob dev status: failed to encode result JSONL." >&2; return 1; }
      return 0
  }
  ```
  2. Modify `tools/exit_contract.py`：在 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 字典（`devtool_workspace.sh` 行后）加一行 `'devtool_subcmd.sh': set(),`。
  3. Modify `lib/commands.sh` cmd_dev 的 `status)` 分支：整段替换为：
  ```bash
          status)
              local _rc=0
              dev_subcmd_status "$dev_machine" "$dev_build_dir" "$dev_recipe" "$dev_pattern" "${DRY_RUN:-0}" || _rc=$?
              case "$_rc" in 0) exit 0;; 1) exit 1;; 2) exit 2;; 3) exit 3;; *) exit 1;; esac
              ;;
  ```
  4. Create `tests/unit/devtool_subcmd.sh`：source `ob_loader.sh` + `assert.sh` + `assert_reset`；mktemp TMP + trap；头注释补 outvar 形参名（`_st_entries` 等）不与 handler 内 local 同名的免责说明（参考 devtool_pick.sh unit 的 nameref 免责）；用 **stub 下游**（重定义 `devtool_status_run`/`dev_relay_result`/`dev_emit_status_jsonl`）聚焦 handler 编排；关键 case：① dry_run=1 → return 0 + stderr 含 notice；② entries 空 → return 0 + stderr 含 "No modified recipes"；③ relay 返回 1 → handler return 1；④ emit 返回 1 → handler return 1；⑤ 正常 → return 0 + stdout = emit 输出。stub 范式（outvar 经 `printf -v "$3"` 回传，当前 shell 跑，stderr 用文件捕获 `2>"$_err"` 不用 `$()`）：
  ```bash
  devtool_status_run() { printf -v "$3" '%s' "$MOCK_ENTRIES"; printf -v "$4" '%s' "${MOCK_STAGE:-command}"; printf -v "$5" '%s' ""; return "${MOCK_RUN_RC:-0}"; }
  dev_relay_result()   { cat -- "${2:-/dev/null}" 2>/dev/null; return "${MOCK_RELAY_RC:-0}"; }
  dev_emit_status_jsonl() { printf '%s\n' "${MOCK_EMIT_OUT:-[]}"; return "${MOCK_EMIT_RC:-0}"; }
  ```

- [ ] Step 4: 运行并确认通过
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh && bash tests/orchestration/cmd_dev.sh`
- Expected: unit `assert_summary` 全 PASS；`ob_check.sh` ALL GREEN（含 exit_contract Y 对 `devtool_subcmd.sh` 的 leaf-pure 守卫、shellcheck baseline、run_all）；orchestration `cmd_dev.sh` PASS。

- [ ] Step 5: checkpoint commit
- Run: `git add lib/devtool_subcmd.sh tests/unit/devtool_subcmd.sh lib/commands.sh tools/exit_contract.py tests/.shellcheck-baseline && git commit -m "feat(dev): extract dev_subcmd_status leaf-pure handler + dryrun/recipe precondition helpers (ADR-0012)"`
- Expected: commit 成功。

### Task 2: dev_subcmd_refresh + refresh unit + cmd_dev refresh 分支切换

- 目标：迁 refresh（最简单的不调 relay/emit 分支：自己做 cat+rm stderr，空 stdout），验证"不强求模板"——handler 形状可与 status 不同。
- Files: Modify `lib/devtool_subcmd.sh`（加 `dev_subcmd_refresh`）、Modify `tests/unit/devtool_subcmd.sh`（加 refresh case）、Modify `lib/commands.sh`（cmd_dev `refresh)` 分支）。
- 验证范围：unit refresh case PASS；`ob_check` ALL GREEN。
- 接口契约：Consumes `devtool_search_refresh`、`_dev_dryrun_gate`（Task 1）；Produces `dev_subcmd_refresh`。

- [ ] Step 1: 当前状态检查
- Run: `! grep -q 'dev_subcmd_refresh' lib/devtool_subcmd.sh`
- Expected: rc=0（该 handler 尚未定义）。

- [ ] Step 2: 确认失败（unit 加 refresh case 前）
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: 当前 PASS（refresh case 未加，此步确认起点绿；unit 绿 + ob_check ALL GREEN）。

- [ ] Step 3: 实现
- Change：在 `lib/devtool_subcmd.sh` 加（从 cmd_dev `refresh)` 原分支搬，return 化）：
  ```bash
  # dev_subcmd_refresh <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1
  # 不调 relay/emit：自己做 cat+rm stderr，空 stdout（cache 重建无 porcelain 输出）。
  dev_subcmd_refresh() {
      local machine="$1" build_dir="$2" recipe="$3" pattern="$4" dry_run="$5"
      _dev_dryrun_gate "$dry_run" "[DRY-RUN] ob dev refresh: would regenerate recipe cache via tinfoil." && return 0
      local _rstage="" _rstderr="" _rrc=0
      devtool_search_refresh "$machine" "$build_dir" _rstage _rstderr || _rrc=$?
      cat "$_rstderr" >&2 2>/dev/null || true
      rm -f "$_rstderr" 2>/dev/null
      if [[ "$_rrc" -ne 0 ]]; then error "ob dev refresh: failed (stage=$_rstage)." >&2; return 1; fi
      return 0
  }
  ```
  cmd_dev `refresh)` 分支替换为 handler 调用 + 字面 case 收口（全局约束「cmd_dev 收口模式」）。unit 加 stub `devtool_search_refresh` + case：① dry_run → return 0；② refresh rc≠0 → return 1 + stderr 含 "failed"；③ 正常 → return 0 + stdout 空。

- [ ] Step 4: 确认通过
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: unit PASS（含 refresh case）；ob_check ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "feat(dev): extract dev_subcmd_refresh handler (no relay/emit, self cat+rm)"`
- Expected: commit 成功。

### Task 3: dev_subcmd_modify + modify unit + cmd_dev modify 分支切换

- 目标：迁 modify（recipe 前置 → dry_run → modify_run → relay → printf srctree），验证 `_dev_recipe_precondition` + relay + 非 JSON stdout（printf srctree）。
- Files: Modify `lib/devtool_subcmd.sh`、`tests/unit/devtool_subcmd.sh`、`lib/commands.sh`（`modify)` 分支）。
- 验证范围：unit modify case PASS；ob_check ALL GREEN。
- 接口契约：Consumes `devtool_modify_run`、`_dev_recipe_precondition`、`_dev_dryrun_gate`、`dev_relay_result`；Produces `dev_subcmd_modify`。

- [ ] Step 1: 当前状态检查
- Run: `! grep -q 'dev_subcmd_modify' lib/devtool_subcmd.sh`
- Expected: rc=0（该 handler 尚未定义）。

- [ ] Step 2: 确认起点绿
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: PASS（unit 绿 + ob_check ALL GREEN）。

- [ ] Step 3: 实现
- Change：加 `dev_subcmd_modify`（顺序照搬原文 recipe 前置 → dry_run）：
  ```bash
  # dev_subcmd_modify <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1/3
  dev_subcmd_modify() {
      local machine="$1" build_dir="$2" recipe="$3" pattern="$4" dry_run="$5"
      _dev_recipe_precondition "$machine" "$recipe" modify || return 3
      _dev_dryrun_gate "$dry_run" "[DRY-RUN] ob dev modify $recipe: would devtool modify (srctree preview: $build_dir/workspace/sources/$recipe)." && return 0
      local _srctree="" _stage="" _stderr_file="" _mrc=0
      devtool_modify_run "$machine" "$build_dir" "$recipe" _srctree _stage _stderr_file || _mrc=$?
      dev_relay_result modify "$_stderr_file" "$_stage" "" "$_mrc" || return 1
      printf '%s\n' "$_srctree"
      return 0
  }
  ```
  cmd_dev `modify)` 分支替换为 handler 调用 + 字面 case 收口（全局约束「cmd_dev 收口模式」）。unit 加 stub `devtool_modify_run`（outvar `_srctree`/`_stage`/`_stderr_file` 经 `printf -v "$4"` 等）+ case：① recipe 空 → return 3 + stderr 含 remedy "list [pattern]"；② dry_run → return 0；③ relay rc=1 → return 1；④ 正常 → return 0 + stdout = srctree。

- [ ] Step 4: 确认通过
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: PASS；ob_check ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "feat(dev): extract dev_subcmd_modify handler (relay + printf srctree)"`
- Expected: commit 成功。

### Task 4: dev_subcmd_build（冻结 not_mod）+ build unit（锁定 not_mod 路径）+ cmd_dev build 分支切换

- 目标：迁 build，**原样保留 not_mod 绕 relay 路径**（D5 硬约束），补 unit 锁定该路径。
- Files: Modify `lib/devtool_subcmd.sh`、`tests/unit/devtool_subcmd.sh`、`lib/commands.sh`（`build)` 分支）。
- 验证范围：unit build case PASS（**含 not_mod 锁定 case**）；ob_check ALL GREEN。
- 接口契约：Consumes `devtool_build_run`、`_dev_recipe_precondition`、`_dev_dryrun_gate`、`dev_relay_result`；Produces `dev_subcmd_build`。

- [ ] Step 1: 当前状态检查
- Run: `! grep -q 'dev_subcmd_build' lib/devtool_subcmd.sh`
- Expected: rc=0（该 handler 尚未定义）。

- [ ] Step 2: 确认起点绿
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: PASS（unit 绿 + ob_check ALL GREEN）。

- [ ] Step 3: 实现（D5 冻结：not_mod 分支原样保留 + rationale 注释）
- Change：加 `dev_subcmd_build`：
  ```bash
  # dev_subcmd_build <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1/3
  dev_subcmd_build() {
      local machine="$1" build_dir="$2" recipe="$3" pattern="$4" dry_run="$5"
      _dev_recipe_precondition "$machine" "$recipe" build || return 3
      _dev_dryrun_gate "$dry_run" "[DRY-RUN] ob dev build $recipe: would devtool build (do_build)." && return 0
      local _b_stage="" _b_stderr="" _b_notmod="" _b_rc=0
      # devtool_build_run 内 status-first 是选号→build 的 TOCTOU 纵深校验(防 recipe 被并发 reset),
      # 并产 not_modified 信号 + stage/rc 回传; TTY 段 status 只为列 recipe 选号(UX)。
      devtool_build_run "$machine" "$build_dir" "$recipe" _b_stage _b_stderr _b_notmod || _b_rc=$?
      if [[ "$_b_notmod" == "1" ]]; then
          # not_modified: status 成功(stage=command/rc=0)但 recipe 不在 modified 列表。
          # 🔴 显式 cat+rm stderr, 不经 relay(避免依赖"三条件都不触发表"的隐式行为, v2.1)。[D5 冻结: 勿并入 relay]
          cat -- "$_b_stderr" >&2 2>/dev/null || true
          rm -f -- "$_b_stderr" 2>/dev/null || true
          error "Recipe '$recipe' is not modified (not in devtool workspace)." >&2
          error "Run 'ob dev --machine $machine modify $recipe' first." >&2
          return 3
      fi
      dev_relay_result build "$_b_stderr" "$_b_stage" "" "${_b_rc:-0}" || return 1
      return 0   # 空 stdout(exit code 承载成败)
  }
  ```
  cmd_dev `build)` 分支替换为 handler 调用 + 字面 case 收口（全局约束「cmd_dev 收口模式」）。unit 加 stub `devtool_build_run`（outvar `_b_stage`/`_b_stderr`/`_b_notmod`）+ case：① recipe 空 → return 3；② dry_run → return 0；③ **not_mod（stub 设 `_b_notmod=1` + run rc=0）→ return 3 + stderr 含 "not modified" + 走 cat 非 relay**（断言 `dev_relay_result` 未被调用：用计数 stub）；④ relay rc=1 → return 1；⑤ 正常 → return 0 + stdout 空。not_mod case 的回归锁：`dev_relay_result` stub 内 `MOCK_RELAY_CALLED=1`，not_mod case 后断言 `test -z "${MOCK_RELAY_CALLED:-}"`（relay 未被调）。

- [ ] Step 4: 确认通过（重点验 not_mod 锁定）
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: unit PASS（含 not_mod 锁定 case）；ob_check ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "feat(dev): extract dev_subcmd_build handler + freeze not_mod bypass-relay path with unit lock (D5)"`
- Expected: commit 成功。

### Task 5: dev_subcmd_reset + reset unit + cmd_dev reset 分支切换

- 目标：迁 reset（8 outvar + relay + emit_reset_json(6)）。
- Files: Modify `lib/devtool_subcmd.sh`、`tests/unit/devtool_subcmd.sh`、`lib/commands.sh`（`reset)` 分支）。
- 验证范围：unit reset case PASS；ob_check ALL GREEN。
- 接口契约：Consumes `devtool_reset_run`（8 outvar）、`_dev_recipe_precondition`、`_dev_dryrun_gate`、`dev_relay_result`、`dev_emit_reset_json`；Produces `dev_subcmd_reset`。

- [ ] Step 1: 当前状态检查
- Run: `! grep -q 'dev_subcmd_reset' lib/devtool_subcmd.sh`
- Expected: rc=0（该 handler 尚未定义）。

- [ ] Step 2: 确认起点绿
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: PASS（unit 绿 + ob_check ALL GREEN）。

- [ ] Step 3: 实现
- Change：加 `dev_subcmd_reset`（8 outvar 从 cmd_dev `reset)` 原文照搬，return 化）：
  ```bash
  # dev_subcmd_reset <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1/3
  dev_subcmd_reset() {
      local machine="$1" build_dir="$2" recipe="$3" pattern="$4" dry_run="$5"
      _dev_recipe_precondition "$machine" "$recipe" reset || return 3
      _dev_dryrun_gate "$dry_run" "[DRY-RUN] ob dev reset $recipe: would devtool reset (source-preserving, no --remove-work)." && return 0
      local _reset_srctree="" _reset_srctreebase="" _reset_disposition=""
      local _reset_destination_parent="" _reset_cleaned_bbappend="" _reset_phase="" _reset_stage="" _reset_stderr_file=""
      local _reset_rc=0
      devtool_reset_run "$machine" "$build_dir" "$recipe" \
          _reset_srctree _reset_srctreebase _reset_disposition _reset_destination_parent \
          _reset_cleaned_bbappend _reset_phase _reset_stage _reset_stderr_file || _reset_rc=$?
      dev_relay_result reset "$_reset_stderr_file" "$_reset_stage" "$_reset_phase" "$_reset_rc" || return 1
      dev_emit_reset_json "$recipe" "$_reset_srctree" "$_reset_srctreebase" "$_reset_disposition" "$_reset_destination_parent" "$_reset_cleaned_bbappend" || { error "ob dev reset: result JSON malformed." >&2; return 1; }
      return 0
  }
  ```
  cmd_dev `reset)` 分支替换为 handler 调用 + 字面 case 收口（全局约束「cmd_dev 收口模式」）。unit 加 stub `devtool_reset_run`（8 outvar）+ `dev_emit_reset_json` + case：① recipe 空 → return 3；② dry_run → return 0；③ relay rc=1 → return 1；④ emit rc=1 → return 1；⑤ 正常 → return 0 + stdout = emit 输出。

- [ ] Step 4: 确认通过
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: PASS；ob_check ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "feat(dev): extract dev_subcmd_reset handler (8 outvar + emit_reset_json)"`
- Expected: commit 成功。

### Task 6: dev_subcmd_finish + finish unit + cmd_dev finish 分支切换

- 目标：迁 finish（13 outvar + relay + emit_finish_json(11)）。
- Files: Modify `lib/devtool_subcmd.sh`、`tests/unit/devtool_subcmd.sh`、`lib/commands.sh`（`finish)` 分支）。
- 验证范围：unit finish case PASS；ob_check ALL GREEN。
- 接口契约：Consumes `devtool_finish_run`（13 outvar）、`_dev_recipe_precondition`、`_dev_dryrun_gate`、`dev_relay_result`、`dev_emit_finish_json`；Produces `dev_subcmd_finish`。

- [ ] Step 1: 当前状态检查
- Run: `! grep -q 'dev_subcmd_finish' lib/devtool_subcmd.sh`
- Expected: rc=0（该 handler 尚未定义）。

- [ ] Step 2: 确认起点绿
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: PASS（unit 绿 + ob_check ALL GREEN）。

- [ ] Step 3: 实现
- Change：加 `dev_subcmd_finish`（13 outvar 照搬，return 化）：
  ```bash
  # dev_subcmd_finish <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1/3
  dev_subcmd_finish() {
      local machine="$1" build_dir="$2" recipe="$3" pattern="$4" dry_run="$5"
      _dev_recipe_precondition "$machine" "$recipe" finish || return 3
      _dev_dryrun_gate "$dry_run" "[DRY-RUN] ob dev finish $recipe: would devtool finish (land patches to original layer, source-preserving)." && return 0
      local _finish_srctree="" _finish_srctreebase="" _finish_disposition=""
      local _finish_destination_parent="" _finish_cleaned_bbappend=""
      local _finish_landing_mode="" _finish_landing_layer="" _finish_patches="" _finish_recipe_files="" _finish_srcrev=""
      local _finish_phase="" _finish_stage="" _finish_stderr_file=""
      local _finish_rc=0
      devtool_finish_run "$machine" "$build_dir" "$recipe" \
          _finish_srctree _finish_srctreebase _finish_disposition _finish_destination_parent \
          _finish_cleaned_bbappend _finish_landing_mode _finish_landing_layer _finish_patches \
          _finish_recipe_files _finish_srcrev _finish_phase _finish_stage _finish_stderr_file || _finish_rc=$?
      dev_relay_result finish "$_finish_stderr_file" "$_finish_stage" "$_finish_phase" "$_finish_rc" || return 1
      dev_emit_finish_json "$recipe" "$_finish_srctree" "$_finish_srctreebase" "$_finish_disposition" "$_finish_destination_parent" "$_finish_cleaned_bbappend" "$_finish_landing_mode" "$_finish_landing_layer" "$_finish_patches" "$_finish_recipe_files" "$_finish_srcrev" || { error "ob dev finish: result JSON malformed." >&2; return 1; }
      return 0
  }
  ```
  cmd_dev `finish)` 分支替换为 handler 调用 + 字面 case 收口（全局约束「cmd_dev 收口模式」）。unit 加 stub `devtool_finish_run`（13 outvar）+ `dev_emit_finish_json` + case：① recipe 空 → return 3（remedy 含 "status"）；② dry_run → return 0；③ relay rc=1 → return 1；④ emit rc=1 → return 1；⑤ 正常 → return 0 + stdout = emit 输出。

- [ ] Step 4: 确认通过
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: PASS；ob_check ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "feat(dev): extract dev_subcmd_finish handler (13 outvar + emit_finish_json)"`
- Expected: commit 成功。

### Task 7: dev_subcmd_list（三态机）+ list unit + cmd_dev list 分支切换

- 目标：迁 list（最复杂：read→三态机 missing/stale/fresh，missing 段 refresh+重检，自己 cat+rm，search_read 直写 stdout）。收尾最后一个 handler，之后 dispatch case 7 分支全切完。
- Files: Modify `lib/devtool_subcmd.sh`、`tests/unit/devtool_subcmd.sh`、`lib/commands.sh`（`list)` 分支）。
- 验证范围：unit list 三态 case PASS；ob_check ALL GREEN。
- 接口契约：Consumes `devtool_search_read`、`devtool_search_refresh`、`_dev_dryrun_gate`；Produces `dev_subcmd_list`。

- [ ] Step 1: 当前状态检查
- Run: `! grep -q 'dev_subcmd_list' lib/devtool_subcmd.sh`
- Expected: rc=0（该 handler 尚未定义）。

- [ ] Step 2: 确认起点绿
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: PASS（unit 绿 + ob_check ALL GREEN）。

- [ ] Step 3: 实现（三态机照搬，return 化；不调 relay/emit，自己 cat+rm + search_read 直写）
- Change：加 `dev_subcmd_list`：
  ```bash
  # dev_subcmd_list <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1/3
  # 不调 relay/emit：read 失败/refresh 失败自己 cat+rm stderr；list 输出由 devtool_search_read 直写 stdout JSONL。
  dev_subcmd_list() {
      local machine="$1" build_dir="$2" recipe="$3" pattern="$4" dry_run="$5"
      _dev_dryrun_gate "$dry_run" "[DRY-RUN] ob dev list: would read recipe cache + output JSONL (pattern='$pattern')." && return 0
      local _state="" _read_rc=0
      devtool_search_read "$machine" "$build_dir" "$pattern" _state || _read_rc=$?
      if [[ "$_read_rc" -ne 0 ]]; then error "ob dev list: failed to read recipe cache safely." >&2; return 1; fi
      case "$_state" in
          missing)
              local _rstage="" _rstderr="" _rrc=0
              devtool_search_refresh "$machine" "$build_dir" _rstage _rstderr || _rrc=$?
              cat "$_rstderr" >&2 2>/dev/null || true
              rm -f "$_rstderr" 2>/dev/null
              if [[ "$_rrc" -ne 0 ]]; then error "ob dev list: failed to generate recipe cache (stage=$_rstage)." >&2; return 1; fi
              # Refresh 后在同一 shared lock 内重检并读取，避免 state/list 跨代。
              local _post_state=""; _read_rc=0
              devtool_search_read "$machine" "$build_dir" "$pattern" _post_state || _read_rc=$?
              if [[ "$_read_rc" -ne 0 ]]; then error "ob dev list: failed to read generated recipe cache safely." >&2; return 1; fi
              if [[ "$_post_state" != "fresh" ]]; then error "ob dev list: cache not fresh after refresh (state=$_post_state)." >&2; return 1; fi
              ;;
          stale)
              error "Recipe cache is stale (bblayers/commit changed)." >&2
              error "Run 'ob dev --machine $machine refresh' first." >&2
              return 3
              ;;
          fresh) ;;
      esac
      return 0
  }
  ```
  cmd_dev `list)` 分支替换为 handler 调用 + 字面 case 收口（全局约束「cmd_dev 收口模式」）。unit 加 stub `devtool_search_read`（outvar `_state`，可配 `MOCK_READ_STATE`）+ `devtool_search_refresh` + case：① dry_run → return 0；② read rc≠0 → return 1；③ stale → return 3 + stderr 含 "refresh"；④ missing + refresh rc≠0 → return 1；⑤ missing + refresh ok + 重检 fresh → return 0；⑥ missing + 重检 非 fresh → return 1；⑦ fresh → return 0。

- [ ] Step 4: 确认通过
- Run: `bash tests/unit/devtool_subcmd.sh && tools/ob_check.sh`
- Expected: PASS（含 list 三态全 case）；ob_check ALL GREEN。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "feat(dev): extract dev_subcmd_list handler (read→三态机 missing/stale/fresh)"`
- Expected: commit 成功。

### Task 8: dev_dispatch_subcmd dispatcher 收口 + cmd_dev dispatch case 整段替换 + 删 7 内联调用

- 目标：引入 `dev_dispatch_subcmd`（含 7 handler case + `""`/`*` 分支），cmd_dev dispatch case 整段（7 个 `dev_subcmd_* ...; exit $?` 内联 + `""` + `*`）替换为一句 `dev_dispatch_subcmd ...; exit $?`。最终态符合 D6 分层。
- Files: Modify `lib/devtool_subcmd.sh`（加 `dev_dispatch_subcmd`）、Modify `lib/commands.sh`（cmd_dev dispatch case 整段替换）。
- 验证范围：ob_check ALL GREEN；orchestration `cmd_dev.sh` PASS；grep 确认 cmd_dev 无内联 `dev_subcmd_*` 调用、有 `dev_dispatch_subcmd`。
- 接口契约：Consumes 7 个 `dev_subcmd_*`（Task 1-7）；Produces `dev_dispatch_subcmd`（cmd_dev 唯一 dispatch 入口）。

- [ ] Step 1: 当前状态检查（dispatcher 未存在 + cmd_dev 仍有内联调用）
- Run: `! grep -q 'dev_dispatch_subcmd()' lib/devtool_subcmd.sh && grep -q 'dev_subcmd_status "$dev_machine"' lib/commands.sh`
- Expected: rc=0（dev_dispatch_subcmd 未定义 + cmd_dev 仍内联 dev_subcmd_status）。

- [ ] Step 2: 确认起点绿
- Run: `tools/ob_check.sh`
- Expected: ALL GREEN。

- [ ] Step 3: 实现
- Change：
  1. 在 `lib/devtool_subcmd.sh` 加 `dev_dispatch_subcmd`（含 `""`/`*` 分支，按语义照搬（`""` 分支 = `ob dev: no subcommand` 段 → return 3；`*` 分支 = `reserved, not implemented yet` 段 → return 1），return 化）：
  ```bash
  # dev_dispatch_subcmd <subcmd> <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1/2/3
  # leaf-pure dispatcher：按 subcmd 分发到 dev_subcmd_*，透传返回码。exit 归 cmd_dev(ADR-0012)。
  dev_dispatch_subcmd() {
      local subcmd="$1" machine="$2" build_dir="$3" recipe="$4" pattern="$5" dry_run="$6"
      case "$subcmd" in
          list)    dev_subcmd_list    "$machine" "$build_dir" "$recipe" "$pattern" "$dry_run" ;;
          modify)  dev_subcmd_modify  "$machine" "$build_dir" "$recipe" "$pattern" "$dry_run" ;;
          refresh) dev_subcmd_refresh "$machine" "$build_dir" "$recipe" "$pattern" "$dry_run" ;;
          reset)   dev_subcmd_reset   "$machine" "$build_dir" "$recipe" "$pattern" "$dry_run" ;;
          finish)  dev_subcmd_finish  "$machine" "$build_dir" "$recipe" "$pattern" "$dry_run" ;;
          status)  dev_subcmd_status  "$machine" "$build_dir" "$recipe" "$pattern" "$dry_run" ;;
          build)   dev_subcmd_build   "$machine" "$build_dir" "$recipe" "$pattern" "$dry_run" ;;
          "")
              error "ob dev: no subcommand." >&2
              error "Run 'ob dev --machine $machine list [pattern]' to discover recipes first." >&2
              return 3
              ;;
          *)
              error "ob dev $subcmd: reserved, not implemented yet." >&2
              return 1
              ;;
      esac
  }
  ```
  2. Modify `lib/commands.sh` cmd_dev：把整段 dispatch case（Task 1-7 切换后的 7 个 `dev_subcmd_* ...; exit $?` 内联分支 + `""` + `*`）替换为：
  ```bash
      local _rc=0
      dev_dispatch_subcmd "$dev_subcmd" "$dev_machine" "$dev_build_dir" "$dev_recipe" "$dev_pattern" "${DRY_RUN:-0}" || _rc=$?
      # cmd_dev 字面 case 收口（全局约束；exit_contract X 禁 exit $?, || _rc=$? 防 set -e）
      case "$_rc" in 0) exit 0;; 1) exit 1;; 2) exit 2;; 3) exit 3;; *) exit 1;; esac
  ```

- [ ] Step 4: 确认通过（收口验证）
- Run: `tools/ob_check.sh && bash tests/orchestration/cmd_dev.sh && test -z "$(grep -nE 'dev_subcmd_(list|modify|refresh|reset|finish|status|build) ' lib/commands.sh)" && grep -q 'dev_dispatch_subcmd "$dev_subcmd"' lib/commands.sh`
- Expected: rc=0（ob_check ALL GREEN + orchestration cmd_dev.sh PASS + cmd_dev 无内联 dev_subcmd_* + cmd_dev 含 dev_dispatch_subcmd）。

- [ ] Step 5: checkpoint commit
- Run: `git add -A && git commit -m "refactor(dev): introduce dev_dispatch_subcmd dispatcher, slim cmd_dev to dispatch entry (ADR-0012/D6)"`
- Expected: commit 成功。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改任务目标。
- 每完成一个任务，运行该任务的 Step 4 验证；ob_check 必须 ALL GREEN 才进下一任务。
- shellcheck 若 REGEN（良性行号平移），`git diff tests/.shellcheck-baseline` 确认后 commit；若 NEW_ALERT，先修告警。
- 遇到阻塞、重复失败或计划与仓库现实不符（如某 emit/run 签名与计划不一致），立即停下说明，不要猜。
- 当前分支 `feature/devtool-pick-extraction` 已并入 main；本工作应在新建分支（如 `feature/cmd-dev-dispatch-subcmd-handler`）上进行，开始实现前确认分支。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh && bash tests/orchestration/cmd_dev.sh && bash tests/run_all.sh --full`
- Expected: ob_check ALL GREEN；`cmd_dev.sh` PASS；`run_all.sh --full`（含 .exp 交互矩阵）PASS。
- 静态守卫复查（leaf-pure 权威由 exit_contract Y 规则守，不另 grep exit 避免 `grep -c` 无匹配 rc=1 的断链坑）：
  - Run: `python3 tools/exit_contract.py`
  - Expected: rc=0，输出含 `X: PASS` / `Y: PASS` / `Z: PASS`（Y 规则覆盖 devtool_subcmd.sh，守 handler 绝不 exit）。
- 修改摘要：`lib/devtool_subcmd.sh`（新）、`tests/unit/devtool_subcmd.sh`（新）、`lib/commands.sh`（cmd_dev dispatch case → 一句 dispatch）、`tools/exit_contract.py`（+1 basename）、`tests/.shellcheck-baseline`（regen）；cmd_dev 从 ~311 行降至 ~150 行。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-22-cmd-dev-dispatch-subcmd-handler-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
