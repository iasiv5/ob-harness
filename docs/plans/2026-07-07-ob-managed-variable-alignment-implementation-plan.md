# ob-managed variable assignment-state 对齐实施计划

> 修订 r4（吸收评审 round 3 的 4 条 finding：generate_build_config 的 resolver preflight 提前到 backup 之前、结构锁精确到 DL_DIR=3/SSTATE_DIR=2、resolver 措辞改为"leaf-pure path resolver（有受控文件系统探测副作用）"对齐 CONTEXT.md `function semantic layer` 术语、Task 1 Step 2 expected failure 文案修正）。r3 对 round 2 的吸收保留。评审结论：修完 finding 1、2 即可进入实现。

## 目标

本计划分两层，不要混说：

1. **判定对齐（消除漂移，核心成果）**：`ob-managed variable`（DL_DIR / SSTATE_DIR / PREMIRRORS）的 assignment-state 判定，从 `resolve_effective_dl_dir` / `resolve_effective_sstate_dir`（[lib/util.sh:143](../../lib/util.sh)、[lib/util.sh:170](../../lib/util.sh)）自搞的值判定 `-z`，对齐到 `generate_build_config`（[lib/init_pipeline.sh:414](../../lib/init_pipeline.sh)）已用的 `read_local_conf_var` exit code seam。**不新增 module**——`read_local_conf_var` 已是该 seam（generic local.conf reader，不专属 ob-managed variable 集合）。
2. **effective-path 失败语义（仅路径类变量 DL_DIR/SSTATE_DIR，避免 mirror 白填）**：路径变量 `set 但空` 或 `路径不可用（unwritable）` → `resolve_effective_*` 静默 `return 1`（不 fallback 默认、不打印）；3 个调用点转 `exit 3` + 两段式 remedy。**PREMIRRORS="" 不在此列**——它是 ADR-0004/0005 明确支持的合法禁用，不进路径 resolver、不触发 exit 3。

理由：`generate_build_config` 对 `DL_DIR=""`/`DL_DIR="/unwritable"` 不注入 → bitbake 用用户的空/无效路径（破坏 fetch / sstate 不可用），而 `resolve_effective_*` 若 fallback ob 默认会让 `ob init` 把大成本 bare mirror population（clone ~570 repo）填到 bitbake 不会用的 `$WORKSPACE_DIR/downloads/git2`（[init_pipeline.sh:233](../../lib/init_pipeline.sh)）。空值与不可写是**同构**的 white-fill 问题，必须统一失败而非假装能工作。

## 架构快照

- **Seam 选择**：`read_local_conf_var`（[lib/util.sh:99](../../lib/util.sh)）是 generic local.conf reader，承载 assignment-state 底层事实。本次只把两个 resolver 对齐到它，**不**把 `ob-managed variable` 落成完整领域 module（明确非目标）。
- **resolver 形态**：leaf-pure path resolver（按 CONTEXT.md `function semantic layer`，leaf-pure 仅指 no-direct-exit，**不指无副作用**——它有受控文件系统可用性探测副作用 `mkdir`/`touch`/`rm`）。成功 → stdout 路径、return 0；失败（set 但空 / 路径不可 mkdir 或不可写 / 默认路径不可用）→ 静默 `return 1`、不输出。**不打印、不 fallback**——所有诊断与 remedy 归调用点（保证 exit 3 输出仍是两段式，见 round 2 finding 3）。
- **调用点形态**：`if ! var=$(resolve_effective_*); then error "..."; echo "<remedy>" >&2; exit 3; fi`。DL_DIR / SSTATE_DIR 分别 `if`（精确诊断，SSTATE_DIR 不带 "fetch"）。码 = `exit 3`（前置 = 有效 cache path 未满足；remedy 友好、不让 agent 误走 exit 1 手动 fallback）。`error`（[util.sh:12](../../lib/util.sh)，stderr）满足 `exit_contract` 对 direct `exit 3` 的静态检查（同函数内有 error）。
- **preflight 时机（round 3 finding 1）**：`generate_build_config` 的 resolver preflight 必须在 **backup 旧 .inc（[init_pipeline.sh:389](../../lib/init_pipeline.sh)）之前**——因 backup（389）在 `_user_*_set` 检测（409）之前，preflight 必须比 backup 更早，才能让 exit 3 不产生任何 inc 副作用（r3 放在 508 会先 backup + 重写 inc 再 exit 3）。`init_bitbake_env`（138）与 `clone_sub_repos`（232）的 preflight 本就在各自副作用（mkdir / mirror population）之前，无需调整。
- **set -e 安全**：ob 入口 `set -euo pipefail`（[ob:4](../../ob)）。mkdir/touch 在 resolver 内用 `if ! ... || ! ...` 受控条件（现状 [util.sh:158](../../lib/util.sh) 单独行是 set -e 隐患，本次修）。
- **输出流**：resolver 被 `$()` 捕获喂给 `MIRROR_BASE`，故成功只 echo 路径、失败静默（无 warn 污染 stdout）。

## 全局约束

- 命名规则：snake_case（`rules/03_WORKSPACE.md`）。
- `ob-managed variable` 术语口径以 `CONTEXT.md` 为准（当前 DL_DIR、SSTATE_DIR、PREMIRRORS）。effective-path 失败语义**只适用 DL_DIR/SSTATE_DIR**（路径类）；PREMIRRORS="" 合法禁用。
- exit-code 契约：0=成功，1=真实失败/用法错，2=取消，3=前置缺失。本次路径变量无效用 **exit 3**。util.sh 是 leaf-pure basename，`resolve_effective_*` 只 `return`、不直接 `exit`。
- ADR-0005（exit code 判定，不用 `-n`/`-z`）、ADR-0004（PREMIRRORS="" 合法禁用）：本计划强化一致性，不改结论。
- set -e 安全：受控条件内 mkdir/touch。
- 验证命令以 `test` / grep 门禁收尾，rc 归位，不被 `echo`/`cat` 吞。
- **不默认 commit**：实现后报告 diff 和验证结果。

## 输入工件

- grilling 共识（Q1-Q4）+ 评审 round 1（6 finding）+ round 2（7 finding）+ round 3（4 finding，已全盘吸收）。
- 相关 ADR：[ADR-0005](../adr/0005-local-conf-var-detection-exit-code.md)、[ADR-0004](../adr/0004-gnu-mirror-via-premirrors.md)。
- 受影响现有测试已逐一核实：[premirrors_injection.sh](../../tests/protocol/premirrors_injection.sh) 场景 4 需改；[generate_config.sh](../../tests/orchestration/generate_config.sh) 与 [init_machine_state_errors.sh](../../tests/protocol/init_machine_state_errors.sh) 不受影响。
- generate_build_config 执行顺序已核实（[init_pipeline.sh:373-511](../../lib/init_pipeline.sh)）：DRY_RUN 检查（380-384）→ backup（389-395）→ WSL 检测（397-404）→ `_user_*_set` 检测（406-432）→ 写 inc（438-506）→ mkdir（508）。

## 文件结构与职责

- Modify: `lib/util.sh` — `resolve_effective_dl_dir`、`resolve_effective_sstate_dir`（判定对齐 + 静默 return 1 + set -e 受控 mkdir/touch + 可写性检查）。
- Modify: `lib/init_pipeline.sh` — 3 个调用点：[init_pipeline.sh:138](../../lib/init_pipeline.sh) `init_bitbake_env`、[init_pipeline.sh:232](../../lib/init_pipeline.sh) `clone_sub_repos`、`generate_build_config`（preflight 提前到 backup 前 [init_pipeline.sh:384 后](../../lib/init_pipeline.sh) + 末尾 [508](../../lib/init_pipeline.sh) mkdir 复用变量）。
- Modify: `tests/unit/conf_read.sh` — assignment-state 三态 + 可写性失败 case（printf 写 conf）。
- Modify: `tests/protocol/premirrors_injection.sh` — 场景 4 改子 shell 断言 rc=3 + remedy + `$INC` 不存在。
- Modify: `CONTEXT.md` — `ob-managed variable` 条目追加 existing-seam 说明 + effective-path 失败语义（区分 PREMIRRORS）。
- 不新建文件（不新增 module）。

## 任务清单

### Task 1: resolve_effective_dl_dir 对齐 + 静默 return 1 + set -e 受控 mkdir/touch

- 目标：把 `resolve_effective_dl_dir` 判定从 `-z` 改为 `read_local_conf_var` exit code；set 但空 / 路径不可用 / 默认不可用 → 静默 `return 1`（不 fallback、不 warn）；mkdir/touch 合并进受控条件。
- Files
  - Modify: `lib/util.sh`（函数 `resolve_effective_dl_dir`，当前 [util.sh:143-168](../../lib/util.sh)）
  - Test: `tests/unit/conf_read.sh`
- 验证范围：`bash tests/unit/conf_read.sh` 退出码 0（含新增 dl set 非空 / set 但空 return 1 / 非空不可写 return 1 case）。
- 接口契约
  - Consumes: `read_local_conf_var`（[util.sh:99](../../lib/util.sh)）；`trim_whitespace`；`assert_eq`/`assert_match`/`assert_true`（[tests/lib/assert.sh:7-10](../../tests/lib/assert.sh)）。
  - Produces: `resolve_effective_dl_dir` 新契约——set 非空且可用→stdout 用户值、return 0；set 但空 / set 非空不可用 / unset 默认不可用→return 1（静默，stdout 空、stderr 空）；unset 默认可用→stdout 默认、return 0。**Task 3 调用点依赖此 return 1 契约。**

- [ ] Step 1: 在 `tests/unit/conf_read.sh` 现有 resolve_effective case（[conf_read.sh:34-38](../../tests/unit/conf_read.sh)）之后追加 dl 三态 case。用 `printf` 写 conf（不用 heredoc）。
  ```bash
  # --- resolve_effective_dl_dir: assignment-state 对齐 read_local_conf_var exit code ---
  # set 非空可用 → 用户值(rc 0); set 但空 → rc 1 静默; 非空不可用 → rc 1 静默(不 fallback);
  # unset → 默认(rc 0, 上组 case 已覆盖)

  printf 'DL_DIR = "%s"\n' "$TMP/custom-dl" > "$BUILD_DIR/conf/local.conf"
  assert_eq "dl_dir set non-empty → user value" "$(resolve_effective_dl_dir)" "$TMP/custom-dl"

  printf 'DL_DIR = ""\n' > "$BUILD_DIR/conf/local.conf"
  dl_out=$(resolve_effective_dl_dir 2>"$TMP/dl_err") && dl_rc=0 || dl_rc=$?
  assert_eq "dl_dir set empty → rc 1" "$dl_rc" 1
  assert_eq "dl_dir set empty → empty stdout" "$dl_out" ""
  assert_true "dl_dir set empty → silent (no warn)" test ! -s "$TMP/dl_err"

  : > "$TMP/not-a-dir"   # 占位文件, 使 child 路径无法 mkdir
  printf 'DL_DIR = "%s"\n' "$TMP/not-a-dir/child" > "$BUILD_DIR/conf/local.conf"
  dl_out=$(resolve_effective_dl_dir 2>"$TMP/dl_err2") && dl_rc=0 || dl_rc=$?
  assert_eq "dl_dir unwritable → rc 1 (no fallback)" "$dl_rc" 1
  assert_eq "dl_dir unwritable → empty stdout" "$dl_out" ""
  assert_true "dl_dir unwritable → silent" test ! -s "$TMP/dl_err2"
  ```
- [ ] Step 2: 运行确认新断言失败。真正红灯是 rc/stdout 断言（现状 `-z` 把空当 unset 回落默认 rc 0、不可写 fallback 默认 rc 0）。
  - Run: `bash tests/unit/conf_read.sh; rc=$?; test "$rc" -eq 0`
  - Expected: 脚本非 0 退出，至少含：`FAIL dl_dir set empty → rc 1`（现状 rc 0）、`FAIL dl_dir set empty → empty stdout`（现状输出默认）、`FAIL dl_dir unwritable → rc 1 (no fallback)`（现状 rc 0）、`FAIL dl_dir unwritable → empty stdout`（现状 fallback 默认）。两个 `silent` 断言现状也会通过（空值分支无 warn、不可写分支 warn 走 stdout，stderr 均为空），故不列为红灯。`set non-empty → user value` 通过。
- [ ] Step 3: 替换 `resolve_effective_dl_dir` 整个函数体为下面的实现。
  ```bash
  resolve_effective_dl_dir() {
      local local_conf="$BUILD_DIR/conf/local.conf"
      local default_dl_dir="$WORKSPACE_DIR/downloads"
      local dl_dir=""

      # assignment-state via read_local_conf_var exit code (ADR-0005): 有赋值行=set(接管,含空),
      # 无赋值行=unset(ob 写默认)。与 generate_build_config 共用同一判定,消除 -z 双轨。
      if read_local_conf_var "$local_conf" "DL_DIR" >/dev/null 2>&1; then
          dl_dir=$(read_local_conf_var "$local_conf" "DL_DIR" 2>/dev/null || true)
          dl_dir=$(trim_whitespace "$dl_dir")
          # set 但空 = 配置错误: 静默 return 1 (诊断 + remedy 由调用点出, 两段式)。
          if [[ -z "$dl_dir" ]]; then
              return 1
          fi
      else
          dl_dir="$default_dl_dir"
      fi

      # 可用性检查 (set -e-safe): mkdir/touch 在受控条件内, 失败不提前中止。
      # 任何不可用(set 非空路径不可写 / unset 默认不可写)都 return 1, 不 fallback 默认 ——
      # 否则 bare mirror 会被填到 bitbake 不会用的位置 (white-fill)。
      # 本函数被 $() 捕获喂给 MIRROR_BASE, 故失败静默 (无 warn 污染 stdout)。
      if ! mkdir -p "$dl_dir" 2>/dev/null || ! touch "$dl_dir/.ob-init-writable-test" 2>/dev/null; then
          rm -f "$dl_dir/.ob-init-writable-test" 2>/dev/null
          return 1
      fi
      rm -f "$dl_dir/.ob-init-writable-test"
      echo "$dl_dir"
  }
  ```
  - Change: 判定从 `if [[ -z ]]` 改为 exit code 先判 set/unset；set 但空 → return 1；mkdir/touch 合并 `if ! ... || ! ...`（修现状 [util.sh:158](../../lib/util.sh) set -e 隐患）；不可用 → return 1（不再 fallback 默认）；删除所有 `warn`（静默，诊断归调用点）。
- [ ] Step 4: 运行确认全过。
  - Run: `bash tests/unit/conf_read.sh; rc=$?; test "$rc" -eq 0`
  - Expected: 退出码 0，`PASS=N FAIL=0`，dl 三态 case 全 ok。

### Task 2: resolve_effective_sstate_dir 对齐 + 静默 return 1 + 可用性检查

- 目标：把 `resolve_effective_sstate_dir` 对齐到 exit code，set 但空 / 不可用 → 静默 return 1，与 dl_dir 对称（含可用性检查，防 508 mkdir 在 set -e 下崩）。
- Files
  - Modify: `lib/util.sh`（函数 `resolve_effective_sstate_dir`，当前 [util.sh:170-185](../../lib/util.sh)）
  - Test: `tests/unit/conf_read.sh`
- 验证范围：`bash tests/unit/conf_read.sh` 退出码 0（含新增 sstate 三态 case）。
- 接口契约
  - Consumes: `read_local_conf_var`、`trim_whitespace`、`assert_eq`/`assert_true`（同 Task 1）。
  - Produces: `resolve_effective_sstate_dir` 新契约（与 dl_dir 对称）。**Task 3 调用点依赖此 return 1 契约。**

- [ ] Step 1: 在 Task 1 追加的 dl case 之后，追加 sstate 三态 case。
  ```bash
  # --- resolve_effective_sstate_dir: assignment-state 对齐(与 dl_dir 对称) ---

  printf 'SSTATE_DIR = "%s"\n' "$TMP/custom-sstate" > "$BUILD_DIR/conf/local.conf"
  assert_eq "sstate_dir set non-empty → user value" "$(resolve_effective_sstate_dir)" "$TMP/custom-sstate"

  printf 'SSTATE_DIR = ""\n' > "$BUILD_DIR/conf/local.conf"
  ss_out=$(resolve_effective_sstate_dir 2>"$TMP/ss_err") && ss_rc=0 || ss_rc=$?
  assert_eq "sstate_dir set empty → rc 1" "$ss_rc" 1
  assert_eq "sstate_dir set empty → empty stdout" "$ss_out" ""
  assert_true "sstate_dir set empty → silent" test ! -s "$TMP/ss_err"

  : > "$TMP/not-a-dir2"
  printf 'SSTATE_DIR = "%s"\n' "$TMP/not-a-dir2/child" > "$BUILD_DIR/conf/local.conf"
  ss_out=$(resolve_effective_sstate_dir 2>"$TMP/ss_err2") && ss_rc=0 || ss_rc=$?
  assert_eq "sstate_dir unwritable → rc 1 (no fallback)" "$ss_rc" 1
  assert_eq "sstate_dir unwritable → empty stdout" "$ss_out" ""
  assert_true "sstate_dir unwritable → silent" test ! -s "$TMP/ss_err2"
  ```
- [ ] Step 2: 运行确认新断言失败（现状 sstate `-z` 把空当 unset rc 0、无可用性检查故不可写时 echo 无效路径 rc 0）。
  - Run: `bash tests/unit/conf_read.sh; rc=$?; test "$rc" -eq 0`
  - Expected: 非 0 退出，含 `FAIL sstate_dir set empty → rc 1`、`FAIL sstate_dir unwritable → rc 1 (no fallback)`（现状 rc 0）等 rc/stdout 红灯。
- [ ] Step 3: 替换 `resolve_effective_sstate_dir` 整个函数体为下面的实现（与 dl_dir 对称，含可用性检查）。
  ```bash
  resolve_effective_sstate_dir() {
      local local_conf="$BUILD_DIR/conf/local.conf"
      local default_sstate_dir="$WORKSPACE_DIR/sstate-cache"
      local sstate_dir=""

      # assignment-state via read_local_conf_var exit code (ADR-0005), 与 dl_dir 对称。
      if read_local_conf_var "$local_conf" "SSTATE_DIR" >/dev/null 2>&1; then
          sstate_dir=$(read_local_conf_var "$local_conf" "SSTATE_DIR" 2>/dev/null || true)
          sstate_dir=$(trim_whitespace "$sstate_dir")
          if [[ -z "$sstate_dir" ]]; then
              return 1
          fi
      else
          sstate_dir="$default_sstate_dir"
      fi

      # 可用性检查 (与 dl_dir 对称): 不可用 → 静默 return 1, 不 fallback。
      if ! mkdir -p "$sstate_dir" 2>/dev/null || ! touch "$sstate_dir/.ob-init-writable-test" 2>/dev/null; then
          rm -f "$sstate_dir/.ob-init-writable-test" 2>/dev/null
          return 1
      fi
      rm -f "$sstate_dir/.ob-init-writable-test"
      echo "$sstate_dir"
  }
  ```
  - Change: 判定从 `-z` 改为 exit code；set 但空 → return 1；新增可用性检查（对称 dl_dir，防 508 set -e 崩）；删除 warn（静默）。
- [ ] Step 4: 运行确认全过。
  - Run: `bash tests/unit/conf_read.sh; rc=$?; test "$rc" -eq 0`
  - Expected: 退出码 0，`PASS=N FAIL=0`，dl + sstate 全 case ok。

### Task 3: init_pipeline.sh 3 个调用点转 exit 3 + remedy（generate_build_config 的 preflight 提前到 backup 前）

- 目标：3 个 `resolve_effective_*` 调用点从"`$()` 吞 rc"改为"分别 `if ! var=$(...); then error + remedy + exit 3; fi`"。`generate_build_config` 的 preflight 提前到 backup 之前（exit 3 不产生 inc 副作用），末尾 mkdir 复用 preflight 变量。
- Files
  - Modify: `lib/init_pipeline.sh`（[init_pipeline.sh:137-138](../../lib/init_pipeline.sh) `init_bitbake_env`、[init_pipeline.sh:231-234](../../lib/init_pipeline.sh) `clone_sub_repos`、`generate_build_config` [init_pipeline.sh:384 后](../../lib/init_pipeline.sh) + [508](../../lib/init_pipeline.sh)）
- 验证范围：grep 结构锁确认 DL_DIR protected call = 3、SSTATE_DIR protected call = 2、无旧吞 rc / 旧 assignment 残留；`ob_check` 不破坏。
- 接口契约
  - Consumes: Task 1 `resolve_effective_dl_dir` 的 return 1 契约；Task 2 `resolve_effective_sstate_dir` 的 return 1 契约；`error`（[util.sh:12](../../lib/util.sh)，满足 exit_contract Z 规则）。
  - Produces: 3 个调用点对路径变量无效输出"诊断行（error）+ 恰好一行 remedy（echo >&2）+ `exit 3`"；`generate_build_config` 的 exit 3 在 backup 之前（无 inc 副作用）。

- [ ] Step 1: 当前状态检查——3 个调用点都直接用 `$()` 吞 rc，且 generate_build_config 的 mkdir 在 backup/写 inc 之后。
  - Run: `grep -nE 'mkdir -p .*\$\(resolve_effective|effective_dl_dir=\$\(resolve_effective' lib/init_pipeline.sh`
  - Expected: 输出 3 行（138、232、508 旧形态），证明 rc 被吞、未转 exit 3、且 508 在 backup 后。
- [ ] Step 2: 确认缺失（同 Step 1）。
- [ ] Step 3: 改造 3 个调用点。
  - **138（`init_bitbake_env`，[init_pipeline.sh:137-138](../../lib/init_pipeline.sh)）**：把
    ```bash
    if [[ -f "$BUILD_DIR/conf/externalsrc-$MACHINE.inc" ]]; then
        mkdir -p "$(resolve_effective_dl_dir)" "$(resolve_effective_sstate_dir)"
    ```
    改为
    ```bash
    if [[ -f "$BUILD_DIR/conf/externalsrc-$MACHINE.inc" ]]; then
        local _dl_dir _sstate_dir
        if ! _dl_dir=$(resolve_effective_dl_dir); then
            error "DL_DIR is empty or unusable in local.conf."
            echo "Set DL_DIR to a valid absolute path, or remove the assignment line." >&2
            exit 3
        fi
        if ! _sstate_dir=$(resolve_effective_sstate_dir); then
            error "SSTATE_DIR is empty or unusable in local.conf."
            echo "Set SSTATE_DIR to a valid absolute path, or remove the assignment line." >&2
            exit 3
        fi
        mkdir -p "$_dl_dir" "$_sstate_dir"
    ```
  - **232（`clone_sub_repos`，[init_pipeline.sh:231-234](../../lib/init_pipeline.sh)）**：把
    ```bash
    local effective_dl_dir=""
    effective_dl_dir=$(resolve_effective_dl_dir)
    MIRROR_BASE="$effective_dl_dir/git2"
    mkdir -p "$MIRROR_BASE"
    ```
    改为
    ```bash
    local effective_dl_dir=""
    if ! effective_dl_dir=$(resolve_effective_dl_dir); then
        error "DL_DIR is empty or unusable in local.conf."
        echo "Set DL_DIR to a valid absolute path, or remove the assignment line." >&2
        exit 3
    fi
    MIRROR_BASE="$effective_dl_dir/git2"
    mkdir -p "$MIRROR_BASE"
    ```
  - **generate_build_config（preflight 提前到 backup 前 + 末尾 mkdir 复用变量）**：r3 把 preflight 放在 508（写 inc + backup 之后），exit 3 前会已 backup 并重写 inc。改为：
    - 在 DRY_RUN `return 0`（[init_pipeline.sh:383](../../lib/init_pipeline.sh)）之后、`timestamp`（386）/ backup（[init_pipeline.sh:389](../../lib/init_pipeline.sh)）**之前**插入 preflight（backup 389 在 `_user_*_set` 检测 409 之前，故 preflight 必须比 backup 更早，exit 3 才不产生任何 inc 副作用）：
      ```bash
      local _dl_dir _sstate_dir
      if ! _dl_dir=$(resolve_effective_dl_dir); then
          error "DL_DIR is empty or unusable in local.conf."
          echo "Set DL_DIR to a valid absolute path, or remove the assignment line." >&2
          exit 3
      fi
      if ! _sstate_dir=$(resolve_effective_sstate_dir); then
          error "SSTATE_DIR is empty or unusable in local.conf."
          echo "Set SSTATE_DIR to a valid absolute path, or remove the assignment line." >&2
          exit 3
      fi
      ```
    - 把末尾 [init_pipeline.sh:508](../../lib/init_pipeline.sh) 的 `mkdir -p "$(resolve_effective_dl_dir)" "$(resolve_effective_sstate_dir)"` 改为复用 preflight 变量（不再二次解析）：
      ```bash
      mkdir -p "$_dl_dir" "$_sstate_dir"
      ```
  - Change: 3 处分别 `if ! var=$(resolve_effective_*); then error + echo remedy >&2 + exit 3; fi`。DL_DIR/SSTATE_DIR 分别 if（精确诊断，SSTATE_DIR 不带 fetch）。`generate_build_config` preflight 提前到 backup 前；末尾 mkdir 复用 preflight 变量。`local` 声明与赋值分开（避免 `local _x=$(...)` 吞 rc）。码 = exit 3，文案"empty or unusable"。
- [ ] Step 4: grep 结构锁确认改造完成、无旧形态残留（精确计数）。
  - Run: `n=$(grep -cE 'if ! .*\$\(resolve_effective_dl_dir\)' lib/init_pipeline.sh); test "$n" -eq 3`
  - Expected: `test` 退出码 0（DL_DIR protected call = 3：init_bitbake_env / clone_sub_repos / generate_build_config）。
  - Run: `n=$(grep -cE 'if ! .*\$\(resolve_effective_sstate_dir\)' lib/init_pipeline.sh); test "$n" -eq 2`
  - Expected: `test` 退出码 0（SSTATE_DIR protected call = 2：init_bitbake_env / generate_build_config；clone_sub_repos 只用 DL_DIR/MIRROR_BASE）。
  - Run: `n=$(grep -cE 'mkdir -p .*\$\(resolve_effective' lib/init_pipeline.sh); test "$n" -eq 0`
  - Expected: `test` 退出码 0（旧 `mkdir -p "...$(resolve_effective_*)"` 吞 rc 形态消失）。
  - Run: `n=$(grep -cE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$\(resolve_effective_' lib/init_pipeline.sh); test "$n" -eq 0`
  - Expected: `test` 退出码 0（旧 `var=$(resolve_effective_*)` 裸赋值残留为 0；`if ! var=$(...)` 不以赋值开头，不误伤）。

### Task 4: premirrors_injection.sh 场景 4 改子 shell 断言 rc=3 + remedy + $INC 不存在

- 目标：场景 4 现期望"`DL_DIR=""` → generate_build_config 继续生成 inc"，与 Task 3 的 exit 3 冲突。改为子 shell 调 generate_build_config，断言 rc=3 + remedy + `$INC` 不存在（端到端验证 Task 3 在 generate_build_config 的 exit 3 行为 + preflight 在 backup 前零副作用）。
- Files
  - Modify: `tests/protocol/premirrors_injection.sh`（场景 4，当前 [premirrors_injection.sh:39-42](../../tests/protocol/premirrors_injection.sh)）
- 验证范围：`bash tests/protocol/premirrors_injection.sh` 退出码 0（场景 4 断言 rc=3 + remedy + $INC 不存在）。
- 接口契约
  - Consumes: Task 3 在 `generate_build_config` 的 preflight（backup 前）exit 3 + remedy 输出。
  - Produces: 场景 4 端到端锁（DL_DIR="" → generate_build_config rc=3 + remedy + 无 inc 副作用）。

- [ ] Step 1: 当前状态检查——场景 4 现期望 generate_build_config 继续（与 Task 3 冲突）。
  - Run: `grep -n "s4 空DL_DIR" tests/protocol/premirrors_injection.sh`
  - Expected: 输出现有场景 4 行（期望"尊重、继续"）。
- [ ] Step 2: 确认冲突（场景 4 期望继续，Task 3 让它 exit 3）。
- [ ] Step 3: 把场景 4（[premirrors_injection.sh:39-42](../../tests/protocol/premirrors_injection.sh)）：
  ```bash
  # 场景4: local.conf DL_DIR="" (空) → ob 不写默认(exit code 判定, 验证三变量统一)
  printf 'MACHINE ??= "t"\nDL_DIR = ""\n' > "$BUILD_DIR/conf/local.conf"
  inc=$(gen_inc)
  if [[ "$inc" == *"$WORKSPACE_DIR/downloads"* ]]; then _assert_bad "s4 空DL_DIR应被尊重(不补默认)"; else _assert_ok "s4 空DL_DIR尊重"; fi
  ```
  改为
  ```bash
  # 场景4: local.conf DL_DIR="" (空) → generate_build_config exit 3 (配置前置缺失)
  # 空值不再是"尊重、继续",而是无效 cache path → exit 3 + remedy (ADR-0005 + resolver 对齐)。
  # 必须在子 shell 调用: generate_build_config 是 source 的函数, exit 3 会杀当前 shell。
  # preflight 在 backup 前 (Task 3), 故 exit 3 不产生 inc 副作用 → $INC 不存在。
  printf 'MACHINE ??= "t"\nDL_DIR = ""\n' > "$BUILD_DIR/conf/local.conf"
  rm -f "$INC"
  s4_out=$(DRY_RUN=0 generate_build_config 2>&1); s4_rc=$?
  assert_eq "s4 empty DL_DIR → exit 3" "$s4_rc" 3
  assert_match "s4 empty DL_DIR → remedy line" "$s4_out" "Set DL_DIR to a valid absolute path"
  assert_false "s4 no inc written on failure" test -f "$INC"
  ```
  - Change: 场景 4 从"期望继续、检查 inc 不含默认"改为"子 shell 调用、断言 rc=3 + remedy + `$INC` 不存在"。`$(...)` 子 shell 吸收 generate_build_config 的 exit 3，不杀主 shell；`$INC` 不存在锁住 preflight 在 backup 前。
- [ ] Step 4: 运行确认 premirrors_injection 全过（Task 1-3 已完成后）。
  - Run: `bash tests/protocol/premirrors_injection.sh; rc=$?; test "$rc" -eq 0`
  - Expected: 退出码 0，`PASS=N FAIL=0`，场景 4 断言 rc=3 + remedy + $INC 不存在全通过；场景 1-3 不受影响（PREMIRRORS="" 合法禁用，不进路径 resolver，场景 3 仍通过）。

### Task 5: CONTEXT.md ob-managed variable 条目（existing-seam + 区分 PREMIRRORS）

- 目标：把"assignment-state 由 read_local_conf_var 承载、两个 resolver 对齐它、effective-path 失败语义（区分 PREMIRRORS）"写进 `CONTEXT.md`，明确 existing seam alignment（非完整 module）。
- Files
  - Modify: `CONTEXT.md`（`ob-managed variable` 条目，当前 [CONTEXT.md:115-117](../../CONTEXT.md)）
- 验证范围：grep 确认条目含新增关键词；`ob_check` 不破坏。
- 接口契约
  - Consumes: Task 1-4 的对齐语义与 exit 3 行为。
  - Produces: `CONTEXT.md` 条目更新（无后续任务依赖，本计划终点）。

- [ ] Step 1: 确认当前条目未提及 `resolve_effective_*` 对齐 / effective-path 失败语义。
  - Run: `n=$(grep -c "resolve_effective" CONTEXT.md); test "$n" -eq 0`
  - Expected: `test` 退出码 0（当前条目只描述注入规则）。
- [ ] Step 2: 确认缺失（同 Step 1）。
- [ ] Step 3: 在 `ob-managed variable` 条目现有正文末尾（`-n` 判定理由句之后、`_Avoid_` 行之前）追加下面这段；`_Avoid_` 行追加 `-z` 判定。
  追加正文段落：
  ```
  assignment-state 判定（"用户是否接管某 ob-managed variable"）的底层事实由 `read_local_conf_var` 的 exit code 承载（generic local.conf reader，不专属 ob-managed variable 集合）：`generate_build_config`（注入决策）与 `resolve_effective_dl_dir` / `resolve_effective_sstate_dir`（缓存目录 effective 路径解析 + mkdir）共用这一 exit code 判定，**不**用值判定（`-z` / `-n`）。本次只做 existing seam alignment，**未**把 `ob-managed variable` 落成完整领域 module。**effective-path 失败语义只适用路径类变量 DL_DIR / SSTATE_DIR**：有赋值行但值为空、或路径不可用（unwritable）→ `resolve_effective_*` 静默 `return 1`，调用点 `exit 3` + remedy（因 bitbake 会用空/无效路径破坏 fetch / sstate，且 ob 会把 bare mirror 填到 bitbake 不会用的位置）。`PREMIRRORS = ""` 仍是 ADR-0004 / ADR-0005 明确支持的合法禁用语义，不进路径 resolver、不触发 exit 3。
  ```
  `_Avoid_` 行追加：`, \`-z\` 判定（resolve_effective_* 已对齐 exit code）`（接在现有 `` `-n` 判定（已统一为 exit code） `` 之后）。
  - Change: 条目从"只描述注入规则"扩展为"两侧共用 assignment-state seam + effective-path 失败语义（区分 PREMIRRORS 合法禁用）"，明确非完整 module 抽取。
- [ ] Step 4: 验证条目更新。
  - Run: `n=$(grep -c "resolve_effective" CONTEXT.md); test "$n" -ge 1`
  - Expected: `test` 退出码 0（条目已含 `resolve_effective`）。文档改动不影响 `ob_check`。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1 → 2 → 3 → 4 → 5），不无声跳步、合并步或改变目标。Task 4 必须在 Task 3 之后（依赖 exit 3 行为 + preflight 位置）。
- 每完成一个任务，运行该任务 Step 4 的验证命令。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不要猜。
- **不默认 commit**：实现完成后报告 diff 和验证结果，除非用户明确要求提交。
- 分支：本仓库惯例在 main/feature 分支开发；需新建分支时按用户指示，不因此阻塞。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- 改 `lib/util.sh` + `lib/init_pipeline.sh` 后的一站式配套自检（`AGENTS.md` Working Mode 要求）。
  - Run: `bash tools/ob_check.sh; rc=$?; test "$rc" -eq 0`
  - Expected: 退出码 0。`ob_check` 固定顺序跑 extract_funcs → machine_state surface gate → shellcheck baseline → exit-contract → run_all（含 protocol/unit/orchestration）。
  - 预期：util.sh / init_pipeline.sh 改动不引入顶层语句；util.sh（leaf-pure）的 `resolve_effective_*` 只 `return`、不 `exit`；3 个调用点的 direct `exit 3` 前均有 `error`（满足 exit_contract Z 规则）；`if !` 与 `>&2` 是标准 bash 不引入 SC 告警；`generate_build_config` 的 preflight 提前不改变函数三段结构。故 shellcheck baseline 与 exit-contract 应无变化；run_all 因 conf_read.sh 新 case + premirrors_injection 场景 4 改造而通过。
  - 若 `ob_check` 报 shellcheck baseline 新增告警或 exit-contract 违规：审查 diff——若是真问题则修，若良性则不重生成；任何不确定立即停下说明，不静默吸收。
- 结构回归（Task 3）：DL_DIR protected call=3、SSTATE_DIR=2、无旧吞 rc / 旧 assignment 残留，由 Task 3 Step 4 的四条 grep 门禁保证。
- 端到端（Task 4）：`DL_DIR="" → generate_build_config exit 3 + remedy + 无 inc 副作用` 由 premirrors_injection 场景 4 锁定（rc=3 + remedy + `$INC` 不存在）。
- 不受影响回归：generate_config.sh（local.conf 非空可写）、init_machine_state_errors.sh（generate_build_config 被 stub）继续通过，由 run_all 覆盖。

## 审阅 Checkpoint

- 计划正文到此结束。
- 请先确认这份计划（含评审 round 4 反馈）；如无问题，下一步可按计划由普通编码 agent 或人工执行。
- 码选择已定为 exit 3（评审 round 2 结论）；文案"empty or unusable"。preflight 位置已按 round 3 finding 1 提前到 backup 前。若 round 4 仍有调整，据此修订后再开工。
