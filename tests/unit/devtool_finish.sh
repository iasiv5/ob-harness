#!/usr/bin/env bash
# tests/unit/devtool_finish.sh — devtool_finish leaf-pure helper 单测(unit 层)。
# 覆盖(T3): _devtool_parse_status_entry(workspace.sh 新增) + _devtool_resolve_layer_root(finish.sh, 绝对 layer root)。
# T4/T5 增量扩展 capture_landing_snapshot/detect_landing/devtool_finish_run。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT

# ============================================================================
# _devtool_parse_status_entry <recipe> <status_file> <srctree_out> <recipefile_out>
#   解析 "recipe: srctree (recipefile)" → srctree + recipefile(剥括号);
#   无 (recipefile) → recipefile 空, srctree 仍出; 无匹配 → 两者空。绝不 exit。
# ============================================================================

PSE_FILE="$TMP/pse.status"
call_parse() {  # <recipe>
    _pse_srctree=""; _pse_recipefile=""; _pserc=0
    _devtool_parse_status_entry "$1" "$PSE_FILE" _pse_srctree _pse_recipefile || _pserc=$?
}

# recipe: srctree (recipefile) → srctree + recipefile
printf 'myrecipe: /src/mine (/rf/mine.bb)\n' > "$PSE_FILE"
call_parse "myrecipe"
assert_eq "parse普通: srctree" "$_pse_srctree" "/src/mine"
assert_eq "parse普通: recipefile(剥括号)" "$_pse_recipefile" "/rf/mine.bb"

# 无 (recipefile) → recipefile 空, srctree 仍出
printf 'myrecipe: /src/mine\n' > "$PSE_FILE"
call_parse "myrecipe"
assert_eq "parse无recipefile: srctree" "$_pse_srctree" "/src/mine"
assert_eq "parse无recipefile: recipefile空" "$_pse_recipefile" ""

# srctree 含空格 → 完整保留
printf 'myrecipe: /path with space/src (/rf/mine.bb)\n' > "$PSE_FILE"
call_parse "myrecipe"
assert_eq "parse srctree含空格: srctree完整" "$_pse_srctree" "/path with space/src"
assert_eq "parse srctree含空格: recipefile" "$_pse_recipefile" "/rf/mine.bb"

# recipefile 含空格 → 完整保留
printf 'myrecipe: /src/mine (/path with space/rf.bb)\n' > "$PSE_FILE"
call_parse "myrecipe"
assert_eq "parse recipefile含空格: recipefile完整" "$_pse_recipefile" "/path with space/rf.bb"

# 无匹配(其它 recipe) → 两者空
printf 'other: /src/other (/rf/other.bb)\n' > "$PSE_FILE"
call_parse "myrecipe"
assert_eq "parse无匹配: srctree空" "$_pse_srctree" ""
assert_eq "parse无匹配: recipefile空" "$_pse_recipefile" ""

# recipe 前缀相近(foobar 不匹配 foo) → 无匹配
printf 'foobar: /src/fb (/rf/fb.bb)\n' > "$PSE_FILE"
call_parse "foo"
assert_eq "parse前缀相近: srctree空" "$_pse_srctree" ""

# 多行 status(含 NOTE 噪声 + 其它 recipe) → 精确匹配目标 recipe
printf 'NOTE: Starting bitbake server...\nfoo: /src/foo (/rf/foo.bb)\nmyrecipe: /src/mine (/rf/mine.bb)\nbar: /src/bar (/rf/bar.bb)\n' > "$PSE_FILE"
call_parse "myrecipe"
assert_eq "parse多行: srctree(精确匹配目标)" "$_pse_srctree" "/src/mine"
assert_eq "parse多行: recipefile(精确匹配目标)" "$_pse_recipefile" "/rf/mine.bb"

# 空文件 → 两者空
: > "$PSE_FILE"
call_parse "myrecipe"
assert_eq "parse空文件: srctree空" "$_pse_srctree" ""
assert_eq "parse空文件: recipefile空" "$_pse_recipefile" ""

# ============================================================================
# _devtool_resolve_layer_root <base_dir> <file> <layer_root_out> <phase_out>
#   file 相对 → join base_dir; 从 file 目录向上找最近 conf/layer.conf → layer root 绝对;
#   无 conf/layer.conf → phase=metadata。NUL 3 字段 + epilogue rm, 不 trap。绝不 exit。
# ============================================================================

call_resolve() {  # <base_dir> <file>
    _rlr_layer_root=""; _rlr_phase=""; _rlrrc=0
    _devtool_resolve_layer_root "$1" "$2" _rlr_layer_root _rlr_phase || _rlrrc=$?
}

# 绝对 file → 找到 meta-x/conf/layer.conf
ROOT="$TMP/root1"; mkdir -p "$ROOT/meta-x/recipes-phosphor/foo" "$ROOT/meta-x/conf"
: > "$ROOT/meta-x/conf/layer.conf"
: > "$ROOT/meta-x/recipes-phosphor/foo/foo.bb"
call_resolve "$ROOT" "$ROOT/meta-x/recipes-phosphor/foo/foo.bb"
assert_eq "resolve绝对: phase空" "$_rlr_phase" ""
assert_eq "resolve绝对: layer_root=meta-x" "$_rlr_layer_root" "$ROOT/meta-x"
assert_match "resolve绝对: layer_root是绝对路径" "$_rlr_layer_root" '^/'
assert_false "resolve绝对: rc=0" test "$_rlrrc" -ne 0

# 相对 file → join base_dir 再向上找
ROOT="$TMP/root2"; mkdir -p "$ROOT/meta-y/recipes/foo" "$ROOT/meta-y/conf"
: > "$ROOT/meta-y/conf/layer.conf"
: > "$ROOT/meta-y/recipes/foo/bar.bb"
call_resolve "$ROOT/meta-y" "recipes/foo/bar.bb"
assert_eq "resolve相对: phase空" "$_rlr_phase" ""
assert_eq "resolve相对: layer_root(按base_dir解析)" "$_rlr_layer_root" "$ROOT/meta-y"

# 无 conf/layer.conf(向上到根无) → phase=metadata
ROOT="$TMP/root3"; mkdir -p "$ROOT/no-layer/sub"
: > "$ROOT/no-layer/sub/x.bb"
call_resolve "$ROOT" "$ROOT/no-layer/sub/x.bb"
assert_eq "resolve无layer.conf: phase=metadata" "$_rlr_phase" "metadata"
assert_eq "resolve无layer.conf: layer_root空" "$_rlr_layer_root" ""

# 嵌套: file 在深层, conf/layer.conf 在最近的祖先 meta-x(非 root)
ROOT="$TMP/root4"; mkdir -p "$ROOT/meta-x/conf" "$ROOT/meta-x/recipes/a/b/c"
: > "$ROOT/meta-x/conf/layer.conf"
: > "$ROOT/meta-x/recipes/a/b/c/deep.bb"
call_resolve "$ROOT" "$ROOT/meta-x/recipes/a/b/c/deep.bb"
assert_eq "resolve嵌套: layer_root=最近meta-x" "$_rlr_layer_root" "$ROOT/meta-x"

# recipefile 含空格(file 路径含空格) → 解析正常
ROOT="$TMP/root5"; mkdir -p "$ROOT/meta-x/conf" "$ROOT/meta-x/recipes/a b"
: > "$ROOT/meta-x/conf/layer.conf"
: > "$ROOT/meta-x/recipes/a b/c.bb"
call_resolve "$ROOT" "$ROOT/meta-x/recipes/a b/c.bb"
assert_eq "resolve file含空格: layer_root" "$_rlr_layer_root" "$ROOT/meta-x"

# 相对 file 但 base_dir 不含该 layer(conf/layer.conf 在 base_dir 之外祖先) → 仍能向上找到
# (真实场景: recipefile 绝对路径, base_dir=OPENBMC_DIR; 此处测相对 file 跨 base_dir 边界)
ROOT="$TMP/root6"; mkdir -p "$ROOT/openbmc/meta-z/conf" "$ROOT/openbmc/meta-z/recipes/f"
: > "$ROOT/openbmc/meta-z/conf/layer.conf"
: > "$ROOT/openbmc/meta-z/recipes/f/f.bb"
call_resolve "$ROOT/openbmc" "meta-z/recipes/f/f.bb"
assert_eq "resolve跨base_dir: layer_root" "$_rlr_layer_root" "$ROOT/openbmc/meta-z"

# trap 不变(两个 helper 都不安装 EXIT trap)
trap 'echo TEST_TRAP' EXIT
printf 'myrecipe: /src/mine (/rf/mine.bb)\n' > "$PSE_FILE"
_devtool_parse_status_entry "myrecipe" "$PSE_FILE" _pse_srctree _pse_recipefile
_trap_state="$(trap -p EXIT)"
assert_contains "parse trap不变" "$_trap_state" "TEST_TRAP"

call_resolve "$TMP/root1" "$TMP/root1/meta-x/recipes-phosphor/foo/foo.bb"
_trap_state="$(trap -p EXIT)"
assert_contains "resolve trap不变" "$_trap_state" "TEST_TRAP"
trap - EXIT

# resolve NUL protocol corruption(fake python3 注入坏 NUL) → phase=metadata(fail closed)
REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON
_BP="$(mktemp -d)"; mkfake_bin "$_BP" python3
stub_script "$_BP" python3 'case "${PLAN_MODE:-}" in
  trunc) printf "only_one\0"; exit 0 ;;
  nosentinel) printf "a\0b\0__WRONG_END__\0"; exit 0 ;;
  *) exec "$REAL_PYTHON" "$@" ;;
esac'
for _mode in trunc nosentinel; do
    _nc_root=""; _nc_phase=""
    PLAN_MODE="$_mode" with_stub "$_BP" -- _devtool_resolve_layer_root "$TMP/root1" "$TMP/root1/meta-x/recipes-phosphor/foo/foo.bb" _nc_root _nc_phase || true
    assert_eq "resolve NUL corruption $_mode: phase=metadata(fail closed)" "$_nc_phase" "metadata"
done
rm -rf "$_BP"

assert_summary
