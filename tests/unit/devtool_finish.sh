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

# ============================================================================
# T4: _devtool_finish_capture_landing_snapshot (JSON) + _devtool_finish_detect_landing (status+digest)
# ============================================================================

PREJ="$TMP/det_pre.json"; POSTJ="$TMP/det_post.json"; SNAP="$TMP/cap.snap"

# --- _devtool_finish_capture_landing_snapshot <openbmc_dir> <snapshot_outfile> <phase_out> ---
call_capture() {  # <openbmc_dir>
    _cap_phase=""; _caprc=0
    _devtool_finish_capture_landing_snapshot "$1" "$SNAP" _cap_phase || _caprc=$?
}

# git 仓库: dirty foo.bb(M) + 新增 patch(??) + build/workspace/attic(过滤)
CAP="$TMP/cap-git"; mkdir -p "$CAP/meta-x/conf" "$CAP/meta-x/recipes/foo" "$CAP/build/m/workspace/attic" "$CAP/workspace/w"
git -C "$CAP" init -q
: > "$CAP/meta-x/conf/layer.conf"
printf 'SRCREV = "old"\nSRC_URI = "file://x.patch "\n' > "$CAP/meta-x/recipes/foo/foo.bb"
git -C "$CAP" add -A && git -C "$CAP" -c user.email=t@t -c user.name=t commit -q -m init
echo "changed" >> "$CAP/meta-x/recipes/foo/foo.bb"   # M
: > "$CAP/meta-x/recipes/foo/0001-new.patch"          # ?? 新增
: > "$CAP/build/m/workspace/attic/x"                  # 过滤
: > "$CAP/workspace/w/y"                              # 过滤
call_capture "$CAP"
assert_eq "capture git: phase空" "$_cap_phase" ""
_cvrc=0
python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
paths = d["paths"]
assert "meta-x/recipes/foo/foo.bb" in paths, ("foo.bb missing", list(paths))
assert "meta-x/recipes/foo/0001-new.patch" in paths, ("patch missing", list(paths))
for p in paths:
    assert not (p.startswith("build/") or p.startswith("workspace/") or p.startswith("attic/")), ("未过滤", p)
for p in ("meta-x/recipes/foo/foo.bb", "meta-x/recipes/foo/0001-new.patch"):
    sha = paths[p]["sha256"]
    assert re.match(r"^[0-9a-f]{64}$", sha), ("sha非64hex", p, sha)
assert "M" in paths["meta-x/recipes/foo/foo.bb"]["status"], paths["meta-x/recipes/foo/foo.bb"]
assert "?" in paths["meta-x/recipes/foo/0001-new.patch"]["status"], paths["meta-x/recipes/foo/0001-new.patch"]
' "$SNAP" || _cvrc=$?
assert_eq "capture git: JSON校验(过滤build/workspace/attic + sha64hex + status)" "$_cvrc" "0"

# capture 复用(T8 要求): 同一 helper 跑两次(pre/post)格式一致
call_capture "$CAP"
assert_eq "capture 复用: 二次仍phase空" "$_cap_phase" ""

# 非 git 仓库 → phase(fail closed)
NOGIT="$TMP/cap-nogit"; mkdir -p "$NOGIT/sub"; : > "$NOGIT/sub/f.bb"
call_capture "$NOGIT"
assert_false "capture非git: phase非空(fail closed)" test -z "$_cap_phase"

# --- _devtool_finish_detect_landing <openbmc_dir> <pre_json> <post_json> <mode><patches><recipe_files><srcrev><landing_layer><phase> ---
call_detect() {  # <openbmc_dir> <pre_json_str> <post_json_str>
    printf '%s' "$2" > "$PREJ"
    printf '%s' "$3" > "$POSTJ"
    _det_mode=""; _det_patches=""; _det_recipe_files=""; _det_srcrev=""; _det_landing_layer=""; _det_phase=""; _detrc=0
    _devtool_finish_detect_landing "$1" "$PREJ" "$POSTJ" \
        _det_mode _det_patches _det_recipe_files _det_srcrev _det_landing_layer _det_phase || _detrc=$?
}

# detect fixture: openbmc_dir + meta-x/conf/layer.conf + post recipe(.bb, 可选 SRCREV)
mk_det() {  # <root> <srcrev_or_empty>
    mkdir -p "$1/meta-x/conf" "$1/meta-x/recipes/foo"
    : > "$1/meta-x/conf/layer.conf"
    if [[ -n "$2" ]]; then printf 'SRCREV = "%s"\n' "$2" > "$1/meta-x/recipes/foo/foo.bb"
    else printf 'SUMMARY = "foo"\n' > "$1/meta-x/recipes/foo/foo.bb"; fi
}
# 校验 JSON array outvar: <label> <actual_json_array_str> <expected_list_python>
ja_eq() {  # <label> <actual> <expected_py_literal>
    _jarc=0
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])==json.loads(sys.argv[2])' "$2" "$3" || _jarc=$?
    assert_eq "$1" "$_jarc" "0"
}

# patch mode: post 新增 patch(pre 无) + foo.bb M(digest 变), 同 layer → patch
DET="$TMP/det-patch"; mk_det "$DET" ""
call_detect "$DET" \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"aaa"}}}' \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"bbb"},"meta-x/recipes/foo/0001-new.patch":{"status":"??","sha256":"ccc"}}}'
assert_eq "detect patch: mode" "$_det_mode" "patch"
assert_eq "detect patch: phase空" "$_det_phase" ""
ja_eq "detect patch: patches" "$_det_patches" '["meta-x/recipes/foo/0001-new.patch"]'
ja_eq "detect patch: recipe_files" "$_det_recipe_files" '["meta-x/recipes/foo/foo.bb"]'
assert_eq "detect patch: srcrev空" "$_det_srcrev" ""
assert_eq "detect patch: landing_layer=meta-x(相对openbmc)" "$_det_landing_layer" "meta-x"

# dirty-to-dirty(🔴 round-3): pre/post 都 M foo.bb, sha 变 → recipe_files 含 foo.bb(不漏报)
DET="$TMP/det-dirty"; mk_det "$DET" "newrev"
call_detect "$DET" \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"aaa"}}}' \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"bbb"}}}'
assert_eq "detect dirty-to-dirty: mode=srcrev" "$_det_mode" "srcrev"
assert_eq "detect dirty-to-dirty: phase空" "$_det_phase" ""
ja_eq "detect dirty-to-dirty: recipe_files含foo.bb(digest变)" "$_det_recipe_files" '["meta-x/recipes/foo/foo.bb"]'
assert_eq "detect dirty-to-dirty: srcrev=post值" "$_det_srcrev" "newrev"

# patch-only refresh(🟡 round-3): post M existing.patch(sha 变, recipe 不变) → patch, recipe_files=[]
DET="$TMP/det-patchonly"; mk_det "$DET" ""
call_detect "$DET" \
    '{"paths":{"meta-x/recipes/foo/existing.patch":{"status":" M","sha256":"aaa"}}}' \
    '{"paths":{"meta-x/recipes/foo/existing.patch":{"status":" M","sha256":"bbb"}}}'
assert_eq "detect patch-only: mode=patch" "$_det_mode" "patch"
assert_eq "detect patch-only: phase空(不因recipe_files空fail)" "$_det_phase" ""
ja_eq "detect patch-only: patches" "$_det_patches" '["meta-x/recipes/foo/existing.patch"]'
ja_eq "detect patch-only: recipe_files空" "$_det_recipe_files" '[]'

# srcrev mode: 无 patch + foo.bb M + post SRCREV → srcrev
DET="$TMP/det-srcrev"; mk_det "$DET" "deadbeef"
call_detect "$DET" \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"aaa"}}}' \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"bbb"}}}'
assert_eq "detect srcrev: mode=srcrev" "$_det_mode" "srcrev"
assert_eq "detect srcrev: srcrev值" "$_det_srcrev" "deadbeef"
ja_eq "detect srcrev: patches空" "$_det_patches" '[]'

# srcrev 边界(🟢5 评审): recipe_files 有 .bb 但无 ^SRCREV=" → mode 仍 srcrev(按落点判) + srcrev 空(正则未匹配)
DET="$TMP/det-srcrev-norev"; mk_det "$DET" ""   # recipe 无 SRCREV(只 SUMMARY)
call_detect "$DET" \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"aaa"}}}' \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"bbb"}}}'
assert_eq "detect srcrev无SRCREV: mode=srcrev(按落点判, 不因缺 SRCREV 降级)" "$_det_mode" "srcrev"
assert_eq "detect srcrev无SRCREV: srcrev空(正则未匹配, 下游 null)" "$_det_srcrev" ""

# deleted patch(pre 有 post 无) → phase=landing(fail closed, 不塞进 patches)
DET="$TMP/det-deleted"; mk_det "$DET" ""
call_detect "$DET" \
    '{"paths":{"meta-x/recipes/foo/old.patch":{"status":" M","sha256":"aaa"}}}' \
    '{"paths":{}}'
assert_eq "detect deleted patch: phase=landing(fail closed)" "$_det_phase" "landing"

# 多 layer root(增量跨 meta-x/meta-y) → phase=landing
DET="$TMP/det-multi"; mkdir -p "$DET/meta-x/conf" "$DET/meta-x/recipes/a" "$DET/meta-y/conf" "$DET/meta-y/recipes/b"
: > "$DET/meta-x/conf/layer.conf"; : > "$DET/meta-y/conf/layer.conf"
call_detect "$DET" \
    '{"paths":{}}' \
    '{"paths":{"meta-x/recipes/a/a.bb":{"status":"??","sha256":"x"},"meta-y/recipes/b/b.bb":{"status":"??","sha256":"y"}}}'
assert_eq "detect 多layer: phase=landing" "$_det_phase" "landing"

# noop(status 同 + digest 同) → phase=landing(无变化)
DET="$TMP/det-noop"; mk_det "$DET" ""
call_detect "$DET" \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"aaa"}}}' \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"aaa"}}}'
assert_eq "detect noop: phase=landing(无变化)" "$_det_phase" "landing"

# JSON 解析失败(post 非法) → phase=landing
DET="$TMP/det-badjson"; mk_det "$DET" ""
call_detect "$DET" '{"paths":{}}' 'not json'
assert_eq "detect JSON失败: phase=landing" "$_det_phase" "landing"

# trap 不变(capture + detect 都不安装 trap)
trap 'echo TEST_TRAP' EXIT
call_capture "$CAP" >/dev/null 2>&1 || true
_trap_state="$(trap -p EXIT)"; assert_contains "capture trap不变" "$_trap_state" "TEST_TRAP"
DET="$TMP/det-trap"; mk_det "$DET" ""
call_detect "$DET" \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"aaa"}}}' \
    '{"paths":{"meta-x/recipes/foo/foo.bb":{"status":" M","sha256":"bbb"},"meta-x/recipes/foo/p.patch":{"status":"??","sha256":"c"}}}' >/dev/null 2>&1 || true
_trap_state="$(trap -p EXIT)"; assert_contains "detect trap不变" "$_trap_state" "TEST_TRAP"
trap - EXIT

# ============================================================================
# T5: devtool_finish_run(组装: resolver + reset 链 + capture/detect; 无 safety copy)
# ============================================================================
T5TMP="$(mktemp -d)"; export T5TMP
OPENBMC_DIR="$T5TMP/openbmc"; BUILD_DIR="$T5TMP/build"
export OPENBMC_DIR BUILD_DIR
mkdir -p "$OPENBMC_DIR" "$BUILD_DIR/conf" "$T5TMP/bin"

cat > "$OPENBMC_DIR/setup" <<'EOF'
#!/usr/bin/env bash
export SETUP_DONE=1
EOF
chmod +x "$OPENBMC_DIR/setup"

# OPENBMC_DIR 是 git 仓库(capture 需要) + meta-x layer + recipe(committed 干净 → capture pre 空)
git -C "$OPENBMC_DIR" init -q
mkdir -p "$OPENBMC_DIR/meta-x/conf" "$OPENBMC_DIR/meta-x/recipes/foo"
: > "$OPENBMC_DIR/meta-x/conf/layer.conf"
printf 'SUMMARY = "foo"\nSRCREV = "oldrev"\n' > "$OPENBMC_DIR/meta-x/recipes/foo/foo.bb"
git -C "$OPENBMC_DIR" add -A && git -C "$OPENBMC_DIR" -c user.email=t@t -c user.name=t commit -q -m init

# mock devtool: status(输出 recipe+recipefile, 二次无); finish(归档 srctreebase + 删 bbappend + 落回 patch + 退出)
cat > "$T5TMP/bin/devtool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status)
    if [[ -f "${MOCK_FINISH_FLAG:-/nonexistent}" ]]; then exit "${MOCK_POST_STATUS_RC:-0}"; fi
    if [[ -n "$MOCK_SRCTREE" ]]; then
        if [[ -n "${MOCK_RECIPEFILE:-}" ]]; then printf '%s: %s (%s)\n' "$MOCK_RECIPE" "$MOCK_SRCTREE" "$MOCK_RECIPEFILE"
        else printf '%s: %s\n' "$MOCK_RECIPE" "$MOCK_SRCTREE"; fi
    fi
    exit "${MOCK_STATUS_RC:-0}" ;;
  finish)
    case "${MOCK_FINISH_ACTION:-patch}" in
      patch)
        if [[ -n "$MOCK_SRCTREEBASE" && -d "$MOCK_SRCTREEBASE" ]]; then
            _attic="$(dirname "$(dirname "$MOCK_SRCTREEBASE")")/attic/sources"
            mkdir -p "$_attic"; mv "$MOCK_SRCTREEBASE" "$_attic/$(basename "$MOCK_SRCTREEBASE").ts" 2>/dev/null
        fi
        [[ -n "$MOCK_CLEANED_BBAPPEND" ]] && rm -f "$MOCK_CLEANED_BBAPPEND" 2>/dev/null
        _rf="${MOCK_RECIPEFILE:-${MOCK_BITBAKE_FILE:-}}"
        _ld="$(dirname "$_rf")"
        : > "$_ld/0001-new.patch"
        echo 'SRC_URI += "file://0001-new.patch"' >> "$_rf"
        : > "${MOCK_FINISH_FLAG:-/dev/null}"; exit 0 ;;
      fail) exit 1 ;;
    esac ;;
esac
EOF
chmod +x "$T5TMP/bin/devtool"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T5TMP/bin/bitbake-layers"; chmod +x "$T5TMP/bin/bitbake-layers"
cat > "$T5TMP/bin/bitbake" <<'EOF'
#!/usr/bin/env bash
# bitbake -e <recipe>: 输出 MOCK_BITBAKE_FILE 作 FILE(模拟 recipe FILE 解析, fallback 路径)
if [[ "${1:-}" == "-e" && -n "${MOCK_BITBAKE_FILE:-}" ]]; then
    printf 'FILE="%s"\n' "$MOCK_BITBAKE_FILE"
    exit 0
fi
exit 1
EOF
chmod +x "$T5TMP/bin/bitbake"
export PATH="$T5TMP/bin:$PATH"

MACHINE="testm"
touch "$BUILD_DIR/conf/local.conf" "$BUILD_DIR/conf/bblayers.conf"
MOCK_FINISH_FLAG="$T5TMP/.finish_done"; export MOCK_FINISH_FLAG

# setup_modified <recipe> <srctree> <ws>: devtool.conf + appends bbappend + srctreebase(nonempty)
setup_modified() {
    local recipe="$1" srctree="$2" ws="$3"
    mkdir -p "$ws/appends" "$srctree"
    printf 'EXTERNALSRC:pn-%s = "%s"\n' "$recipe" "$srctree" > "$ws/appends/${recipe}_1.0.bbappend"
    printf '[General]\nworkspace_path = %s\n' "$ws" > "$BUILD_DIR/conf/devtool.conf"
    echo c > "$srctree/f"
    export MOCK_RECIPE="$recipe" MOCK_SRCTREE="$srctree" MOCK_SRCTREEBASE="$srctree"
    export MOCK_RECIPEFILE="$OPENBMC_DIR/meta-x/recipes/foo/foo.bb"
    export MOCK_CLEANED_BBAPPEND="$ws/appends/${recipe}_1.0.bbappend"
    rm -f "$MOCK_FINISH_FLAG"
}

call_run() {  # <recipe>
    _fin_srctree=""; _fin_srctreebase=""; _fin_disposition=""; _fin_dest_parent=""; _fin_cleaned_bbappend=""
    _fin_landing_mode=""; _fin_landing_layer=""; _fin_patches=""; _fin_recipe_files=""; _fin_srcrev=""
    _fin_phase=""; _fin_stage=""; _fin_stderr_file=""; _finrc=0
    devtool_finish_run "$MACHINE" "$BUILD_DIR" "$1" \
        _fin_srctree _fin_srctreebase _fin_disposition _fin_dest_parent _fin_cleaned_bbappend \
        _fin_landing_mode _fin_landing_layer _fin_patches _fin_recipe_files _fin_srcrev \
        _fin_phase _fin_stage _fin_stderr_file || _finrc=$?
    rm -f "$_fin_stderr_file" 2>/dev/null
}

# --- patch mode(mock finish 落回 patch + moved 归档) ---
ws="$T5TMP/ws-patch"; setup_modified "foo" "$ws/sources/foo" "$ws"
MOCK_FINISH_ACTION=patch call_run "foo"
assert_eq "patch: rc=0" "$_finrc" "0"
assert_eq "patch: phase空" "$_fin_phase" ""
assert_eq "patch: disposition=moved" "$_fin_disposition" "moved"
assert_eq "patch: srctreebase" "$_fin_srctreebase" "$ws/sources/foo"
assert_eq "patch: destination_parent=ws/attic/sources" "$_fin_dest_parent" "$ws/attic/sources"
assert_eq "patch: cleaned_bbappend" "$_fin_cleaned_bbappend" "$ws/appends/foo_1.0.bbappend"
assert_eq "patch: landing_mode=patch" "$_fin_landing_mode" "patch"
assert_eq "patch: landing_layer=meta-x" "$_fin_landing_layer" "meta-x"
python3 -c 'import json,sys; assert json.loads(sys.argv[1])==["meta-x/recipes/foo/0001-new.patch"]' "$_fin_patches" || _fv=$?
assert_eq "patch: patches(JSON array, 相对OPENBMC_DIR)" "${_fv:-0}" "0"; _fv=0
python3 -c 'import json,sys; assert json.loads(sys.argv[1])==["meta-x/recipes/foo/foo.bb"]' "$_fin_recipe_files" || _fv=$?
assert_eq "patch: recipe_files(JSON array)" "${_fv:-0}" "0"; _fv=0

# --- recipefile 空(devtool status 不给, 如真实 a2jmidid) → bitbake -e FILE fallback → resolve_layer_root ---
mkdir -p "$OPENBMC_DIR/meta-x/recipes/fbrec"; : > "$OPENBMC_DIR/meta-x/recipes/fbrec/fbrec.bb"
ws="$T5TMP/ws-fb"; setup_modified "fbrec" "$ws/sources/fbrec" "$ws"
MOCK_RECIPEFILE=""; export MOCK_RECIPEFILE
MOCK_BITBAKE_FILE="$OPENBMC_DIR/meta-x/recipes/fbrec/fbrec.bb"; export MOCK_BITBAKE_FILE
MOCK_FINISH_ACTION=patch call_run "fbrec"
assert_eq "fallback: rc=0" "$_finrc" "0"
assert_eq "fallback: phase空(bitbake -e FILE → resolve, 不 metadata)" "$_fin_phase" ""
assert_eq "fallback: disposition=moved(非 noop, fallback 成功落回)" "$_fin_disposition" "moved"
unset MOCK_BITBAKE_FILE

# --- noop(status 无 recipe 行 → disposition=noop, landing 全空) ---
setup_modified "bar" "$T5TMP/ws-noop/sources/bar" "$T5TMP/ws-noop"
MOCK_SRCTREE="" MOCK_FINISH_ACTION=patch call_run "bar"
assert_eq "noop: rc=0" "$_finrc" "0"
assert_eq "noop: disposition=noop" "$_fin_disposition" "noop"
assert_eq "noop: landing_mode空" "$_fin_landing_mode" ""
assert_eq "noop: patches空" "$_fin_patches" ""
assert_eq "noop: srctree空" "$_fin_srctree" ""

# --- finish 失败(mock finish fail) → phase=finish ---
setup_modified "failr" "$T5TMP/ws-fail/sources/failr" "$T5TMP/ws-fail"
MOCK_FINISH_ACTION=fail call_run "failr"
assert_false "finish-fail: rc非0" test "$_finrc" -eq 0
assert_eq "finish-fail: phase=finish" "$_fin_phase" "finish"

# --- capture pre 失败(OPENBMC_DIR 非 git) → phase=landing(short-circuit, 不 finish) ---
NOGIT="$T5TMP/nogit-ob"; mkdir -p "$NOGIT/meta-x/conf" "$NOGIT/meta-x/recipes/foo"
: > "$NOGIT/meta-x/conf/layer.conf"
printf 'SUMMARY = "x"\n' > "$NOGIT/meta-x/recipes/foo/foo.bb"
cat > "$NOGIT/setup" <<'EOF'
#!/usr/bin/env bash
export SETUP_DONE=1
EOF
chmod +x "$NOGIT/setup"
_OPENBMC_SAVE="$OPENBMC_DIR"; OPENBMC_DIR="$NOGIT"; export OPENBMC_DIR
ws="$T5TMP/ws-nogit"; setup_modified "nogr" "$ws/sources/nogr" "$ws"
MOCK_FINISH_ACTION=patch call_run "nogr"
assert_eq "capture非git: phase=landing(fail closed, 不 finish)" "$_fin_phase" "landing"
assert_false "capture非git: rc非0" test "$_finrc" -eq 0
OPENBMC_DIR="$_OPENBMC_SAVE"; export OPENBMC_DIR

# --- srctreebase/srctree 含空格 → 13 outvar 原样 ---
ws="$T5TMP/ws-sp"; sp_path="$ws/sources/recipe with space"
setup_modified "foosp" "$sp_path" "$ws"
MOCK_FINISH_ACTION=patch call_run "foosp"
assert_eq "空格: disposition=moved" "$_fin_disposition" "moved"
assert_eq "空格: srctree含空格原样" "$_fin_srctree" "$sp_path"
assert_eq "空格: srctreebase含空格原样" "$_fin_srctreebase" "$sp_path"

# --- trap 不变 ---
trap 'echo TEST_TRAP' EXIT
ws="$T5TMP/ws-trap"; setup_modified "trapr" "$ws/sources/trapr" "$ws"
MOCK_FINISH_ACTION=patch call_run "trapr"
_trap_state="$(trap -p EXIT)"
assert_contains "run trap不变" "$_trap_state" "TEST_TRAP"
trap - EXIT

rm -rf "$T5TMP"

assert_summary
