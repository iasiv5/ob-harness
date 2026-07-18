#!/usr/bin/env bash
# tests/unit/devtool_modify.sh — devtool_modify_run 单测(unit 层)。
# 覆盖: 三段(初始未 modify → modify → 再次 status) / 已 modify 不重复 / status 失败不 modify /
#       recipe 含 . 字面匹配(非正则) / recipefile 后缀剥离 / srctree 非绝对路径校验失败。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP   # mock devtool 子进程需读到(建 srctree 目录)
trap 'rm -rf "$TMP"' EXIT

# === mock build env ===
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$TMP/build"
export OPENBMC_DIR BUILD_DIR
MOCK_DEVTOOL_STATE="$TMP/devtool_state"
export MOCK_DEVTOOL_STATE
mkdir -p "$OPENBMC_DIR" "$BUILD_DIR/conf" "$TMP/bin" "$TMP/workspace/sources"
: > "$MOCK_DEVTOOL_STATE"

# mock setup 脚本(source 时 export SETUP_DONE + 向 stdout 打噪声,测输出隔离)
cat > "$OPENBMC_DIR/setup" <<'EOF'
#!/usr/bin/env bash
export SETUP_DONE=1
echo "MOCK_SETUP_NOISE_TO_STDOUT"
EOF
chmod +x "$OPENBMC_DIR/setup"

# mock devtool: status 输出 state; modify 追加 state + 建源码目录
cat > "$TMP/bin/devtool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status)
    [[ -f "$MOCK_DEVTOOL_STATE" ]] && cat "$MOCK_DEVTOOL_STATE"
    exit "${MOCK_STATUS_RC:-0}"
    ;;
  modify)
    recipe="$2"
    srctree="$TMP/workspace/sources/$recipe"
    printf '%s: %s\n' "$recipe" "$srctree" >> "$MOCK_DEVTOOL_STATE"
    mkdir -p "$srctree"
    exit "${MOCK_MODIFY_RC:-0}"
    ;;
esac
EOF
chmod +x "$TMP/bin/devtool"

# mock bitbake-layers(postcondition 校验可执行性)
printf '#!/usr/bin/env bash\necho mock-bitbake-layers\n' > "$TMP/bin/bitbake-layers"
chmod +x "$TMP/bin/bitbake-layers"
export PATH="$TMP/bin:$PATH"

MACHINE="testm"
touch "$BUILD_DIR/conf/local.conf" "$BUILD_DIR/conf/bblayers.conf"

# === devtool_modify_run: 三段(初始未 modify → modify → 再次 status 解析 srctree) ===
: > "$MOCK_DEVTOOL_STATE"   # target 未 modify
RECIPE="phosphor-ipmi-host"
srctree_var=""; stage_var=""; stderr_var=""
devtool_modify_run "$MACHINE" "$BUILD_DIR" "$RECIPE" srctree_var stage_var stderr_var || true
assert_contains "devtool_modify_run srctree 非空(含 recipe)" "$srctree_var" "$RECIPE"
assert_eq       "devtool_modify_run stage=command"        "$stage_var" "command"
assert_true     "devtool_modify_run stderr_file 存在"      test -f "$stderr_var"
assert_contains "devtool_modify_run modify 被调(state 含 target)" "$(cat "$MOCK_DEVTOOL_STATE")" "$RECIPE"

# === devtool_modify_run: 已 modify 不重复 modify ===
lines_before=$(wc -l < "$MOCK_DEVTOOL_STATE")
devtool_modify_run "$MACHINE" "$BUILD_DIR" "$RECIPE" srctree_var stage_var stderr_var || true
lines_after=$(wc -l < "$MOCK_DEVTOOL_STATE")
assert_eq "devtool_modify_run 已 modify 不重复 modify(行数不变)" "$lines_after" "$lines_before"

# === status 失败则不 modify(不进 modify 分支) ===
: > "$MOCK_DEVTOOL_STATE"
export MOCK_STATUS_RC=1
sv=""; st=""; se=""
devtool_modify_run "$MACHINE" "$BUILD_DIR" "$RECIPE" sv st se 2>/dev/null || true
unset MOCK_STATUS_RC
assert_eq "status 失败不 modify(state 空)" "$(wc -l < "$MOCK_DEVTOOL_STATE")" "0"

# === recipe 含 . 字面匹配(不正则误匹配) ===
: > "$MOCK_DEVTOOL_STATE"
mkdir -p "$TMP/workspace/sources/gstreamer1.0"
printf 'gstreamer1.0: %s/gstreamer1.0\n' "$TMP/workspace/sources" >> "$MOCK_DEVTOOL_STATE"
sv=""; st=""; se=""
devtool_modify_run "$MACHINE" "$BUILD_DIR" "gstreamer1.0" sv st se || true
assert_contains "recipe 含 . 字面匹配(srctree)" "$sv" "gstreamer1.0"

# === recipefile 后缀剥离(不把 (recipefile) 当路径) ===
: > "$MOCK_DEVTOOL_STATE"
mkdir -p "$TMP/workspace/sources/foorecipe"
printf 'foorecipe: %s/foorecipe (recipes-foo/foorecipe.bb)\n' "$TMP/workspace/sources" >> "$MOCK_DEVTOOL_STATE"
sv=""; st=""; se=""
devtool_modify_run "$MACHINE" "$BUILD_DIR" "foorecipe" sv st se || true
assert_contains "recipefile 后缀剥离(srctree)" "$sv" "foorecipe"
assert_false "srctree 不含 recipefile 括号" grep -q "foorecipe.bb" <<<"$sv"

# === srctree 非绝对路径 → 校验失败(rc!=0) ===
: > "$MOCK_DEVTOOL_STATE"
printf 'badrecipe: relative/path\n' >> "$MOCK_DEVTOOL_STATE"
sv=""; st=""; se=""; mrc=0
devtool_modify_run "$MACHINE" "$BUILD_DIR" "badrecipe" sv st se 2>/dev/null || mrc=$?
assert_false "srctree 非绝对 → rc!=0" test "$mrc" -eq 0

assert_summary
