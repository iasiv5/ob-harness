#!/usr/bin/env bash
# tests/unit/devtool_intake.sh — dev_intake_argv 单测(unit 层)。
# 覆盖 argv 解析: 合法四元组(--machine/subcmd/pattern/recipe) + 等号形式 + -d 设全局 DRY_RUN +
#   usage-error(unknown option / missing value / 非法 --machine / too-many pattern·recipe) + 空入参。
# outvar 回填: 经 nameref 写 caller 作用域, 必须当前 shell 跑; stderr 用 2>"$_err" 捕(不用 $() 子 shell)。
# leaf-pure: 函数 return 0/1(不 exit); exit_contract Y 静态守卫。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
_err="$TMP/err"

m=""; s=""; p=""; r=""; rc=0

# ① 合法: --machine romulus list ipmi → 0 + 四元组
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine romulus list ipmi 2>"$_err" >/dev/null || rc=$?
assert_eq "① 合法 rc=0" "$rc" "0"
assert_eq "① machine=romulus" "$m" "romulus"
assert_eq "① subcmd=list" "$s" "list"
assert_eq "① pattern=ipmi" "$p" "ipmi"
assert_eq "① recipe 空(list 不收 recipe)" "$r" ""

# ② 等号形式: --machine=romulus modify phosphor-ipmi-host → 0
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine=romulus modify phosphor-ipmi-host 2>"$_err" >/dev/null || rc=$?
assert_eq "② 等号 rc=0" "$rc" "0"
assert_eq "② machine=romulus" "$m" "romulus"
assert_eq "② subcmd=modify" "$s" "modify"
assert_eq "② recipe=phosphor-ipmi-host" "$r" "phosphor-ipmi-host"

# ③ -d 设全局 DRY_RUN=1
DRY_RUN=0
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r -d --machine romulus status 2>"$_err" >/dev/null || rc=$?
assert_eq "③ -d rc=0" "$rc" "0"
assert_eq "③ DRY_RUN=1(全局副作用)" "$DRY_RUN" "1"

# ④ unknown option --bogus → 1 + stderr 含 "unknown option"
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --bogus 2>"$_err" >/dev/null || rc=$?
assert_eq "④ unknown option rc=1" "$rc" "1"
assert_contains "④ stderr 含 unknown option" "$(cat "$_err")" "unknown option"

# ⑤ --machine 缺值 → 1
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine 2>"$_err" >/dev/null || rc=$?
assert_eq "⑤ --machine 缺值 rc=1" "$rc" "1"

# ⑥a --machine 空值 → 1
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine "" 2>"$_err" >/dev/null || rc=$?
assert_eq "⑥a --machine 空值 rc=1" "$rc" "1"

# ⑥b --machine=-x 非法值(以 - 开头) → 1
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine=-x list 2>"$_err" >/dev/null || rc=$?
assert_eq "⑥b --machine=-x rc=1" "$rc" "1"

# ⑦ list 两 pattern → 1 (too-many)
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r list ipmi foo 2>"$_err" >/dev/null || rc=$?
assert_eq "⑦ list too-many rc=1" "$rc" "1"
assert_contains "⑦ stderr too many patterns" "$(cat "$_err")" "too many patterns"

# ⑧ modify 两 recipe → 1 (too-many)
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r modify a b 2>"$_err" >/dev/null || rc=$?
assert_eq "⑧ modify too-many rc=1" "$rc" "1"

# ⑨ 无 subcmd 无位置参 → 0 (subcmd 空, 留 TTY/dispatch 处理)
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r 2>"$_err" >/dev/null || rc=$?
assert_eq "⑨ 空入参 rc=0" "$rc" "0"
assert_eq "⑨ subcmd 空(留 TTY/dispatch)" "$s" ""

# === mock build env (dev_intake_tty 的 reset/finish/build 经 devtool_pick_modified_recipe 调 devtool) ===
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$TMP/build"
export OPENBMC_DIR BUILD_DIR
MOCK_DEVTOOL_STATE="$TMP/devtool_state"
export MOCK_DEVTOOL_STATE
mkdir -p "$OPENBMC_DIR" "$BUILD_DIR/conf" "$TMP/bin" "$TMP/workspace/sources"
printf '#!/usr/bin/env bash\nexport SETUP_DONE=1\n' > "$OPENBMC_DIR/setup"; chmod +x "$OPENBMC_DIR/setup"
cat > "$TMP/bin/devtool" <<'MOCKDTOOL'
#!/usr/bin/env bash
case "$1" in
  status)
    [[ -f "$MOCK_DEVTOOL_STATE" ]] && cat "$MOCK_DEVTOOL_STATE"
    exit "${MOCK_STATUS_RC:-0}"
    ;;
esac
MOCKDTOOL
chmod +x "$TMP/bin/devtool"
printf '#!/usr/bin/env bash\necho mock-bitbake-layers\n' > "$TMP/bin/bitbake-layers"; chmod +x "$TMP/bin/bitbake-layers"
export PATH="$TMP/bin:$PATH"
MACHINE="testm"
touch "$BUILD_DIR/conf/local.conf" "$BUILD_DIR/conf/bblayers.conf"
RECIPE="phosphor-ipmi-host"

# === dev_intake_tty case (here-string 喂 stdin; dev_intake_tty 不自查 -t 0, 由 caller 保证) ===
# t① list + pattern: 选 1 + pattern ipmi → 0, subcmd=list, pattern=ipmi
s=""; p=""; r=""; rc=0
dev_intake_tty "$MACHINE" "$BUILD_DIR" s p r <<< $'1\nipmi\n' 2>"$_err" >/dev/null || rc=$?
assert_eq "t① list+pattern rc=0" "$rc" "0"
assert_eq "t① subcmd=list" "$s" "list"
assert_eq "t① pattern=ipmi" "$p" "ipmi"

# t② modify + recipe: 选 2 + recipe → 0
s=""; p=""; r=""; rc=0
dev_intake_tty "$MACHINE" "$BUILD_DIR" s p r <<< $'2\nphosphor-ipmi-host\n' 2>"$_err" >/dev/null || rc=$?
assert_eq "t② modify rc=0" "$rc" "0"
assert_eq "t② subcmd=modify" "$s" "modify"
assert_eq "t② recipe=phosphor-ipmi-host" "$r" "phosphor-ipmi-host"

# t③ cancel: 选 0 → 2
s=""; p=""; r=""; rc=0
dev_intake_tty "$MACHINE" "$BUILD_DIR" s p r <<< $'0\n' 2>"$_err" >/dev/null || rc=$?
assert_eq "t③ cancel rc=2" "$rc" "2"

# t④ invalid: 选 9 → 1 + stderr 含 invalid
s=""; p=""; r=""; rc=0
dev_intake_tty "$MACHINE" "$BUILD_DIR" s p r <<< $'9\n' 2>"$_err" >/dev/null || rc=$?
assert_eq "t④ invalid rc=1" "$rc" "1"
assert_contains "t④ stderr invalid selection" "$(cat "$_err")" "invalid subcommand selection"

# t⑤ read-fail: stdin EOF → 1
s=""; p=""; r=""; rc=0
dev_intake_tty "$MACHINE" "$BUILD_DIR" s p r </dev/null 2>"$_err" >/dev/null || rc=$?
assert_eq "t⑤ read-fail rc=1" "$rc" "1"

# t⑥ reset ok: mock state 写 recipe + 选 4 + pick 选 1 → 0, recipe 正确
printf '%s: %s\n' "$RECIPE" "$TMP/workspace/sources/$RECIPE" > "$MOCK_DEVTOOL_STATE"; unset MOCK_STATUS_RC
s=""; p=""; r=""; rc=0
dev_intake_tty "$MACHINE" "$BUILD_DIR" s p r <<< $'4\n1\n' 2>"$_err" >/dev/null || rc=$?
assert_eq "t⑥ reset ok rc=0" "$rc" "0"
assert_eq "t⑥ subcmd=reset" "$s" "reset"
assert_eq "t⑥ recipe=phosphor-ipmi-host(经 pick ok)" "$r" "$RECIPE"

# t⑦ reset empty: mock state 空 + 选 4 → 3
: > "$MOCK_DEVTOOL_STATE"; unset MOCK_STATUS_RC
s=""; p=""; r=""; rc=0
dev_intake_tty "$MACHINE" "$BUILD_DIR" s p r <<< $'4\n' 2>"$_err" >/dev/null || rc=$?
assert_eq "t⑦ reset empty rc=3" "$rc" "3"

# t⑧ reset cancel: mock state 写 recipe + 选 4 + pick 选 0 → 2
printf '%s: %s\n' "$RECIPE" "$TMP/workspace/sources/$RECIPE" > "$MOCK_DEVTOOL_STATE"; unset MOCK_STATUS_RC
s=""; p=""; r=""; rc=0
dev_intake_tty "$MACHINE" "$BUILD_DIR" s p r <<< $'4\n0\n' 2>"$_err" >/dev/null || rc=$?
assert_eq "t⑧ reset cancel rc=2" "$rc" "2"

# t⑨ modify 空 recipe: 选 2 + recipe 空行 → 3
s=""; p=""; r=""; rc=0
dev_intake_tty "$MACHINE" "$BUILD_DIR" s p r <<< $'2\n\n' 2>"$_err" >/dev/null || rc=$?
assert_eq "t⑨ modify 空recipe rc=3" "$rc" "3"

assert_summary
