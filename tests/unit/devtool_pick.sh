#!/usr/bin/env bash
# tests/unit/devtool_pick.sh — devtool_pick_modified_recipe 单测(unit 层, 全 5 态)。
# 覆盖 status_outvar 5 态: status-failed(stage/rc) / empty / ok:<recipe> / cancel / read-fail。
# 镜像 devtool_build.sh 的 mock devtool 二进制 + interact.sh 的 here-string/</dev/null 喂 stdin。
# 🔴 格式契约: MOCK_DEVTOOL_STATE 必须冒号空格 + 绝对 srctree(经 _devtool_parse_status_all 解析为 entries);
#              写 <TAB> 格式会让 ok/cancel/read-fail 三 case 解析为空而必挂、status-failed 两 case 假绿。
# 🔴2 回归锁: status 失败必须 status-failed(非 empty——误报让 cmd_dev exit 3 而非 1)。
# outvar 回传: helper 经 printf -v "$status_outvar" 写 caller 作用域, 必须当前 shell 跑;
#              ①② 用文件捕获 stderr(2>"$_err") 而非 $() 子 shell(否则 _pick_st 不回传)。
# leaf-pure: 失败态(①②) helper 恒返回 0(|| rc=$? 捕获, 能跑到 assert 即证明 return 非 exit); exit_contract Y 静态守卫。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT

# === mock build env ===
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$TMP/build"
export OPENBMC_DIR BUILD_DIR
MOCK_DEVTOOL_STATE="$TMP/devtool_state"
export MOCK_DEVTOOL_STATE
mkdir -p "$OPENBMC_DIR" "$BUILD_DIR/conf" "$TMP/bin" "$TMP/workspace/sources"
: > "$MOCK_DEVTOOL_STATE"

# setup swap(① 要 setup 失败; ②-⑥ 恢复成功)。默认成功。
write_ok_setup()   { printf '#!/usr/bin/env bash\nexport SETUP_DONE=1\n' > "$OPENBMC_DIR/setup"; chmod +x "$OPENBMC_DIR/setup"; }
write_fail_setup() { printf '#!/usr/bin/env bash\nexit 1\n'             > "$OPENBMC_DIR/setup"; chmod +x "$OPENBMC_DIR/setup"; }
write_ok_setup

# mock devtool: status 输出 MOCK_DEVTOOL_STATE 原始 stdout(冒号格式) + exit MOCK_STATUS_RC
cat > "$TMP/bin/devtool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status)
    [[ -f "$MOCK_DEVTOOL_STATE" ]] && cat "$MOCK_DEVTOOL_STATE"
    exit "${MOCK_STATUS_RC:-0}"
    ;;
esac
EOF
chmod +x "$TMP/bin/devtool"

printf '#!/usr/bin/env bash\necho mock-bitbake-layers\n' > "$TMP/bin/bitbake-layers"
chmod +x "$TMP/bin/bitbake-layers"
export PATH="$TMP/bin:$PATH"

MACHINE="testm"
touch "$BUILD_DIR/conf/local.conf" "$BUILD_DIR/conf/bblayers.conf"
RECIPE="phosphor-ipmi-host"

_pick_st=""

# === 🔴 格式契约自检(④前): MOCK_DEVTOOL_STATE 冒号格式经 _devtool_parse_status_all 解析非空 ===
printf '%s: %s\n' "$RECIPE" "$TMP/workspace/sources/$RECIPE" > "$MOCK_DEVTOOL_STATE"
unset MOCK_STATUS_RC
_e=""; _s=""; _se=""
devtool_status_run "$MACHINE" "$BUILD_DIR" _e _s _se
assert_true "🔴 格式契约: 冒号格式解析非空(非 <TAB>)" test -n "$_e"
rm -f "$_se"

# === ① status-failed(stage): swap setup 失败 → stage=setup, rc≠0 → dev_relay_result "build env not ready" + return 1 → status-failed ===
write_fail_setup
: > "$MOCK_DEVTOOL_STATE"; unset MOCK_STATUS_RC
_pick_st="MUST_STAY_DEFAULT"; rc=0; _err="$(mktemp)"
devtool_pick_modified_recipe "$MACHINE" "$BUILD_DIR" reset _pick_st 2>"$_err" >/dev/null || rc=$?
out="$(cat "$_err")"; rm -f "$_err"
assert_eq "① stage: helper 恒返回 0(leaf-pure)" "$rc" "0"
assert_eq "① stage: _pick_st=status-failed(🔴2 非 empty)" "$_pick_st" "status-failed"
assert_contains "① stage: stderr 文案(build env not ready)" "$out" "build env not ready"

# === ② status-failed(rc): 恢复 ok setup + MOCK_STATUS_RC=1 + 空 state → stage=command, rc=1 → "devtool failed (rc,stage)" → status-failed ===
write_ok_setup
: > "$MOCK_DEVTOOL_STATE"; export MOCK_STATUS_RC=1
_pick_st="MUST_STAY_DEFAULT"; rc=0; _err="$(mktemp)"
devtool_pick_modified_recipe "$MACHINE" "$BUILD_DIR" reset _pick_st 2>"$_err" >/dev/null || rc=$?
out="$(cat "$_err")"; rm -f "$_err"
unset MOCK_STATUS_RC
assert_eq "② rc: helper 恒返回 0(leaf-pure)" "$rc" "0"
assert_eq "② rc: _pick_st=status-failed(🔴2 非 empty)" "$_pick_st" "status-failed"
assert_contains "② rc: stderr 文案(devtool failed rc,stage)" "$out" "devtool failed (rc=1, stage=command)"

# === ③ empty: MOCK_STATUS_RC=0 + 空 state → entries 空 → _recipes=() → empty ===
write_ok_setup
: > "$MOCK_DEVTOOL_STATE"; unset MOCK_STATUS_RC
_pick_st=""; rc=0
devtool_pick_modified_recipe "$MACHINE" "$BUILD_DIR" reset _pick_st >/dev/null 2>&1 || rc=$?
assert_eq "③ empty: helper 恒返回 0" "$rc" "0"
assert_eq "③ empty: _pick_st=empty" "$_pick_st" "empty"

# === ④ ok:<recipe>: state 写冒号格式 + stdin 选 1 → ok:<recipe> ===
printf '%s: %s\n' "$RECIPE" "$TMP/workspace/sources/$RECIPE" > "$MOCK_DEVTOOL_STATE"; unset MOCK_STATUS_RC
_pick_st=""
devtool_pick_modified_recipe "$MACHINE" "$BUILD_DIR" reset _pick_st <<< $'1\n' >/dev/null 2>&1
assert_eq "④ ok: _pick_st=ok:<recipe>" "$_pick_st" "ok:$RECIPE"

# === ⑤ cancel: state 同 ④ + stdin 选 0 → cancel ===
_pick_st=""
devtool_pick_modified_recipe "$MACHINE" "$BUILD_DIR" reset _pick_st <<< $'0\n' >/dev/null 2>&1
assert_eq "⑤ cancel: _pick_st=cancel" "$_pick_st" "cancel"

# === ⑥ read-fail: state 同 ④ + stdin EOF → read_list_choice read 失败 → read-fail ===
_pick_st=""
devtool_pick_modified_recipe "$MACHINE" "$BUILD_DIR" reset _pick_st </dev/null >/dev/null 2>&1
assert_eq "⑥ read-fail: _pick_st=read-fail" "$_pick_st" "read-fail"

assert_summary
