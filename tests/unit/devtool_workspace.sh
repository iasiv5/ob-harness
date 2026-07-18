#!/usr/bin/env bash
# tests/unit/devtool_workspace.sh — _devtool_env_exec + _devtool_parse_srctree + _devtool_parse_status_all 单测。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT

# === mock build env(镜像 tests/unit/devtool_modify.sh 的 setup) ===
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$TMP/build"
export OPENBMC_DIR BUILD_DIR
mkdir -p "$OPENBMC_DIR" "$BUILD_DIR/conf" "$TMP/bin" "$TMP/workspace/sources"
cat > "$OPENBMC_DIR/setup" <<'EOF'
#!/usr/bin/env bash
export SETUP_DONE=1
echo "MOCK_SETUP_NOISE_TO_STDOUT"
EOF
chmod +x "$OPENBMC_DIR/setup"
cat > "$TMP/bin/devtool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status) exit "${MOCK_STATUS_RC:-0}" ;;
esac
EOF
chmod +x "$TMP/bin/devtool"
printf '#!/usr/bin/env bash\necho mock-bitbake-layers\n' > "$TMP/bin/bitbake-layers"
chmod +x "$TMP/bin/bitbake-layers"
export PATH="$TMP/bin:$PATH"
MACHINE="testm"
touch "$BUILD_DIR/conf/local.conf" "$BUILD_DIR/conf/bblayers.conf"

# === _devtool_env_exec: tempfile 协议 + 输出隔离(从 modify 测试搬入) ===
s="$TMP/s1"; o="$TMP/o1"; e="$TMP/e1"; : >"$s"; : >"$o"; : >"$e"
rc=0
_devtool_env_exec "$MACHINE" "$BUILD_DIR" "$s" "$o" "$e" -- echo HELLO || rc=$?
assert_eq     "_devtool_env_exec echo rc=0"        "$rc" 0
assert_contains "_devtool_env_exec stdout 含 HELLO"   "$(cat "$o")" "HELLO"
assert_false  "_devtool_env_exec stdout 不含 setup 噪声" grep -q "MOCK_SETUP_NOISE" "$o"
assert_contains "_devtool_env_exec stage=command"     "$(cat "$s")" "command"

# === _devtool_env_exec: 同一 subshell(setup 注入的 SETUP_DONE 在 cmd 可见) ===
s="$TMP/s2"; o="$TMP/o2"; e="$TMP/e2"; : >"$s"; : >"$o"; : >"$e"
_devtool_env_exec "$MACHINE" "$BUILD_DIR" "$s" "$o" "$e" -- sh -c 'echo "SETUP=$SETUP_DONE"' || true
assert_contains "_devtool_env_exec 同一 subshell(SETUP 可见)" "$(cat "$o")" "SETUP=1"

# === _devtool_env_exec: postcondition 失败(删 local.conf) ===
rm -f "$BUILD_DIR/conf/local.conf"
s="$TMP/s3"; o="$TMP/o3"; e="$TMP/e3"; : >"$s"; : >"$o"; : >"$e"; rc=0
_devtool_env_exec "$MACHINE" "$BUILD_DIR" "$s" "$o" "$e" -- echo HELLO || rc=$?
assert_false  "_devtool_env_exec postcondition 失败 rc!=0" test "$rc" -eq 0
assert_contains "_devtool_env_exec stage=postcondition" "$(cat "$s")" "postcondition"
touch "$BUILD_DIR/conf/local.conf"

# === _devtool_parse_srctree: 独立断言(现状仅 modify_run 间接覆盖,补 test surface;只锁输出不锁 rc) ===
_pst_tmp="$(mktemp)"
printf 'foorecipe: /ws/foorecipe (recipes-foo/foorecipe.bb)\n' > "$_pst_tmp"
printf 'other: /ws/other\n' >> "$_pst_tmp"
printf 'gstreamer1.0: /ws/gstreamer1.0\n' >> "$_pst_tmp"
assert_eq "parse_srctree 字面匹配+剥 recipefile" "$(_devtool_parse_srctree "foorecipe" "$_pst_tmp")" "/ws/foorecipe"
assert_eq "parse_srctree 精确匹配 other" "$(_devtool_parse_srctree "other" "$_pst_tmp")" "/ws/other"
assert_eq "parse_srctree 含 . 字面匹配(非正则)" "$(_devtool_parse_srctree "gstreamer1.0" "$_pst_tmp")" "/ws/gstreamer1.0"
assert_eq "parse_srctree 无匹配输出空" "$(_devtool_parse_srctree "nonexist" "$_pst_tmp")" ""
rm -f "$_pst_tmp"

# === _devtool_parse_status_all: 全量解析(从 modify 测试搬入) ===
_psa_tmp="$(mktemp)"
printf 'foorecipe: %s/workspace/sources/foorecipe (recipes-foo/foorecipe.bb)\n' "$TMP" > "$_psa_tmp"
printf 'barrecipe: %s/workspace/sources/barrecipe\n' "$TMP" >> "$_psa_tmp"
printf 'Currently working recipes:\n' >> "$_psa_tmp"
_psa_out="$(_devtool_parse_status_all "$_psa_tmp")"
assert_eq "parse_status_all 行数(2 recipe,header 跳过)" "$(printf '%s\n' "$_psa_out" | grep -c .)" "2"
assert_contains "parse_status_all foorecipe+srctree" "$_psa_out" $'foorecipe\t'"$TMP/workspace/sources/foorecipe"
assert_false "parse_status_all 剥掉 recipefile 后缀" grep -q 'recipes-foo/foorecipe.bb' <<<"$_psa_out"
assert_false "parse_status_all 跳过 header" grep -q 'Currently working recipes' <<<"$_psa_out"
rm -f "$_psa_tmp"
_psa_empty="$(mktemp)"; assert_eq "parse_status_all 空文件无输出" "$(_devtool_parse_status_all "$_psa_empty" | grep -c .)" "0"; rm -f "$_psa_empty"
_psa_neg="$(mktemp)"
printf 'NOTE: some bitbake noise\n' > "$_psa_neg"
printf 'WARNING: /abs/path\n' >> "$_psa_neg"
printf 'foo bar: /tmp/x\n' >> "$_psa_neg"
printf 'good: relative/path\n' >> "$_psa_neg"
assert_eq "parse_status_all 负例全跳过(0 行)" "$(_devtool_parse_status_all "$_psa_neg" | grep -c .)" "0"
rm -f "$_psa_neg"

assert_summary
