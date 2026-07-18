#!/usr/bin/env bash
# tests/unit/devtool_reset.sh — devtool_reset leaf-pure helper 单测(unit 层)。
# 覆盖(T1): _devtool_reset_resolve_workspace(workspace 完整默认矩阵 + NUL sentinel + trap 不变)。
# T2/T3 增量扩展 locate_bbappend/classify/devtool_reset_run。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT

# 辅助: 建一个 build_dir(含 conf/)
mk_build() { mkdir -p "$1/conf"; }

# 辅助: 调 _devtool_reset_resolve_workspace, 用生产 receiver _resolved_*, 捕获 rc。
call_resolve() {  # <build_dir>
    _resolved_workspace_raw=""; _resolved_workspace_effective=""; _resolved_phase=""; _rrc=0
    _devtool_reset_resolve_workspace "$1" _resolved_workspace_raw _resolved_workspace_effective _resolved_phase || _rrc=$?
}

# === 默认矩阵(无文件/无[General]/无workspace_path → 默认 build_dir/workspace) ===

# 无 devtool.conf → 默认
b="$TMP/b-nofile"; mk_build "$b"
call_resolve "$b"
assert_eq "无conf: rc=0" "$_rrc" "0"
assert_eq "无conf: phase空" "$_resolved_phase" ""
assert_eq "无conf: raw=default" "$_resolved_workspace_raw" "$b/workspace"
assert_eq "无conf: eff=default" "$_resolved_workspace_effective" "$b/workspace"

# devtool.conf 无 [General] → 默认
b="$TMP/b-nosection"; mk_build "$b"
printf '# comment only\n' > "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "无[General]: rc=0" "$_rrc" "0"
assert_eq "无[General]: phase空" "$_resolved_phase" ""
assert_eq "无[General]: raw=default" "$_resolved_workspace_raw" "$b/workspace"

# [General] 无 workspace_path → 默认
b="$TMP/b-nokey"; mk_build "$b"
printf '[General]\nother = value\n' > "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "无key: rc=0" "$_rrc" "0"
assert_eq "无key: phase空" "$_resolved_phase" ""
assert_eq "无key: raw=default" "$_resolved_workspace_raw" "$b/workspace"

# === 空值/仅空白 → metadata(不静默回退) ===

# workspace_path 空 → metadata
b="$TMP/b-empty"; mk_build "$b"
printf '[General]\nworkspace_path = \n' > "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "空值: phase=metadata" "$_resolved_phase" "metadata"
assert_false "空值: rc非0" test "$_rrc" -eq 0

# workspace_path 仅空白(制表符+空格) → metadata
b="$TMP/b-ws"; mk_build "$b"
printf '[General]\nworkspace_path = \t  \n' > "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "仅空白: phase=metadata" "$_resolved_phase" "metadata"

# === 相对/绝对 workspace_path(raw 未 canonicalize, effective 按 build_dir) ===

# 相对 workspace_path → raw=相对字面, effective=build_dir/相对
b="$TMP/b-rel"; mk_build "$b"
printf '[General]\nworkspace_path = myws\n' > "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "相对: rc=0" "$_rrc" "0"
assert_eq "相对: phase空" "$_resolved_phase" ""
assert_eq "相对: raw未canonicalize(字面myws)" "$_resolved_workspace_raw" "myws"
assert_eq "相对: eff=build_dir/myws" "$_resolved_workspace_effective" "$b/myws"

# 绝对 workspace_path → raw=绝对, effective=绝对(build_dir 不影响绝对路径)
b="$TMP/b-abs"; mk_build "$b"
printf '[General]\nworkspace_path = /abs/work\n' > "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "绝对: rc=0" "$_rrc" "0"
assert_eq "绝对: phase空" "$_resolved_phase" ""
assert_eq "绝对: raw=/abs/work" "$_resolved_workspace_raw" "/abs/work"
assert_eq "绝对: eff=/abs/work" "$_resolved_workspace_effective" "/abs/work"

# === 不可读/损坏 → metadata ===

# 不可读配置(devtool.conf 是目录, 不依赖 chmod) → metadata
b="$TMP/b-dir"; mk_build "$b"
mkdir "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "目录: phase=metadata" "$_resolved_phase" "metadata"
assert_false "目录: rc非0" test "$_rrc" -eq 0

# 语法损坏(无 section header) → metadata
b="$TMP/b-bad"; mk_build "$b"
printf 'no section header here\nworkspace_path = x\n' > "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "语法损坏: phase=metadata" "$_resolved_phase" "metadata"

# === NUL 传输不截断(workspace_path 含空格) ===
b="$TMP/b-space"; mk_build "$b"
printf '[General]\nworkspace_path = /path with space\n' > "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "含空格: rc=0" "$_rrc" "0"
assert_eq "含空格: phase空" "$_resolved_phase" ""
assert_eq "含空格: raw完整(含空格)" "$_resolved_workspace_raw" "/path with space"
assert_eq "含空格: eff完整(含空格)" "$_resolved_workspace_effective" "/path with space"

# workspace_path 含 % 插值(镜像 devtool 默认 ConfigParser: %% → %; 单 % 非法→metadata)
b="$TMP/b-pct"; mk_build "$b"
printf '[General]\nworkspace_path = ws%%%%name\n' > "$b/conf/devtool.conf"
call_resolve "$b"
assert_eq "含%%插值: rc=0" "$_rrc" "0"
assert_eq "含%%插值: raw=ws%name(镜像 devtool 默认插值)" "$_resolved_workspace_raw" "ws%name"
b="$TMP/b-pctbad"; mk_build "$b"
cat > "$b/conf/devtool.conf" <<EOF
[General]
workspace_path = ws%name
EOF
call_resolve "$b"
assert_eq "含单%非法插值: phase=metadata" "$_resolved_phase" "metadata"

# === trap 不变(helper 不安装 EXIT/RETURN trap) ===
trap 'echo TEST_TRAP' EXIT
b="$TMP/b-trap"; mk_build "$b"
call_resolve "$b"
_trap_state="$(trap -p EXIT)"
assert_contains "trap不变(仍TEST_TRAP)" "$_trap_state" "TEST_TRAP"
trap - EXIT

# === NUL protocol corruption → helper fail closed(phase=metadata; bare_mirror 先例) ===
# fake python3 注入坏 NUL(字段截断/额外/缺 sentinel) → resolve bash 字段数/sentinel 校验失败 → metadata
REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON
_BP="$(mktemp -d)"; mkfake_bin "$_BP" python3
stub_script "$_BP" python3 'case "${PLAN_MODE:-}" in
  trunc) printf "only_two\0fields\0"; exit 0 ;;
  extra) printf "a\0b\0c\0d\0e\0__OB_NUL_END__\0"; exit 0 ;;
  nosentinel) printf "a\0b\0\0__WRONG_END__\0"; exit 0 ;;
  *) exec "$REAL_PYTHON" "$@" ;;
esac'
for _mode in trunc extra nosentinel; do
    b="$(mktemp -d)"; mkdir -p "$b/conf"
    printf '[General]\nworkspace_path = ws\n' > "$b/conf/devtool.conf"
    _nc_raw=""; _nc_eff=""; _nc_phase=""
    PLAN_MODE="$_mode" with_stub "$_BP" -- _devtool_reset_resolve_workspace "$b" _nc_raw _nc_eff _nc_phase || true
    assert_eq "NUL corruption $_mode: phase=metadata(fail closed)" "$_nc_phase" "metadata"
    rm -rf "$b"
done
rm -rf "$_BP"

# ============================================================================
# T2: _devtool_reset_locate_bbappend + _devtool_reset_classify
# ============================================================================

# --- _devtool_reset_locate_bbappend <workspace> <recipe> <status_srctree> <srctreebase_raw_out> <bbappend_out> <phase_out> ---
call_locate() {  # <workspace> <recipe> <status_srctree>
    _located_srctreebase_raw=""; _located_bbappend=""; _located_phase=""; _lrc=0
    _devtool_reset_locate_bbappend "$1" "$2" "$3" _located_srctreebase_raw _located_bbappend _located_phase || _lrc=$?
}

# 普通 bbappend 命中(无 srctreebase 注释 → srctreebase_raw=status_srctree)
ws="$TMP/loc1"; mkdir -p "$ws/appends"
printf 'EXTERNALSRC:pn-myrecipe = "%s/myrecipe-src"\n' "$TMP" > "$ws/appends/myrecipe_1.0.bbappend"
call_locate "$ws" "myrecipe" "$TMP/myrecipe-src"
assert_eq "locate普通: rc=0" "$_lrc" "0"
assert_eq "locate普通: phase空" "$_located_phase" ""
assert_eq "locate普通: srctreebase_raw=status_srctree(无注释)" "$_located_srctreebase_raw" "$TMP/myrecipe-src"
assert_eq "locate普通: bbappend=命中文件路径" "$_located_bbappend" "$ws/appends/myrecipe_1.0.bbappend"

# 有 # srctreebase: 注释 → srctreebase_raw=注释值
ws="$TMP/loc2"; mkdir -p "$ws/appends"
printf '# srctreebase: %s/sb-base\nEXTERNALSRC:pn-myrecipe = "%s/myrecipe-src"\n' "$TMP" "$TMP" > "$ws/appends/myrecipe_1.0.bbappend"
call_locate "$ws" "myrecipe" "$TMP/myrecipe-src"
assert_eq "locate注释: rc=0" "$_lrc" "0"
assert_eq "locate注释: srctreebase_raw=注释值" "$_located_srctreebase_raw" "$TMP/sb-base"
assert_eq "locate注释: bbappend=命中文件路径" "$_located_bbappend" "$ws/appends/myrecipe_1.0.bbappend"

# # srctreebase 注释后置于 EXTERNALSRC(顺序无关: 先完整解析单文件再关联)
ws="$TMP/loc-after"; mkdir -p "$ws/appends"
printf 'EXTERNALSRC:pn-myrecipe = "%s/myrecipe-src"\n# srctreebase: %s/sb-after\n' "$TMP" "$TMP" > "$ws/appends/myrecipe_1.0.bbappend"
call_locate "$ws" "myrecipe" "$TMP/myrecipe-src"
assert_eq "locate注释后置: srctreebase_raw=注释值(顺序无关)" "$_located_srctreebase_raw" "$TMP/sb-after"
assert_eq "locate注释后置: bbappend=命中文件路径" "$_located_bbappend" "$ws/appends/myrecipe_1.0.bbappend"

# gstreamer1.0 PN 含 . 字面匹配(不正则误匹配)
ws="$TMP/loc3"; mkdir -p "$ws/appends"
printf 'EXTERNALSRC:pn-gstreamer1.0 = "%s/gst-src"\n' "$TMP" > "$ws/appends/gstreamer1.0_1.0.bbappend"
call_locate "$ws" "gstreamer1.0" "$TMP/gst-src"
assert_eq "locate gstreamer1.0: rc=0" "$_lrc" "0"
assert_eq "locate gstreamer1.0: srctreebase_raw" "$_located_srctreebase_raw" "$TMP/gst-src"
assert_eq "locate gstreamer1.0: bbappend=命中文件路径" "$_located_bbappend" "$ws/appends/gstreamer1.0_1.0.bbappend"

# PN 前缀相近(foobar 不匹配 foo) → 零匹配 metadata
ws="$TMP/loc4"; mkdir -p "$ws/appends"
printf 'EXTERNALSRC:pn-foobar = "%s/x"\n' "$TMP" > "$ws/appends/foobar_1.0.bbappend"
call_locate "$ws" "foo" "$TMP/x"
assert_eq "locate前缀相近: phase=metadata" "$_located_phase" "metadata"
assert_eq "locate前缀相近: bbappend空(metadata)" "$_located_bbappend" ""

# 注释伪 EXTERNALSRC(# 开头) → 不命中 → metadata
ws="$TMP/loc5"; mkdir -p "$ws/appends"
printf '# EXTERNALSRC:pn-myrecipe = "%s/x"\n' "$TMP" > "$ws/appends/myrecipe_1.0.bbappend"
call_locate "$ws" "myrecipe" "$TMP/x"
assert_eq "locate注释伪: phase=metadata" "$_located_phase" "metadata"
assert_eq "locate注释伪: bbappend空(metadata)" "$_located_bbappend" ""

# 多冲突行(同 bbappend 两行匹配) → metadata
ws="$TMP/loc6"; mkdir -p "$ws/appends"
printf 'EXTERNALSRC:pn-myrecipe = "%s/a"\nEXTERNALSRC:pn-myrecipe = "%s/b"\n' "$TMP" "$TMP" > "$ws/appends/myrecipe_1.0.bbappend"
call_locate "$ws" "myrecipe" "$TMP/a"
assert_eq "locate多冲突行: phase=metadata" "$_located_phase" "metadata"
assert_eq "locate多冲突行: bbappend空(metadata)" "$_located_bbappend" ""

# 零匹配(无 bbappend) → metadata
ws="$TMP/loc7"; mkdir -p "$ws/appends"
call_locate "$ws" "myrecipe" "$TMP/x"
assert_eq "locate零匹配: phase=metadata" "$_located_phase" "metadata"
assert_eq "locate零匹配: bbappend空(metadata)" "$_located_bbappend" ""

# appends 目录不存在 → metadata
ws="$TMP/loc8"; mkdir -p "$ws"
call_locate "$ws" "myrecipe" "$TMP/x"
assert_eq "locate无appends目录: phase=metadata" "$_located_phase" "metadata"
assert_eq "locate无appends目录: bbappend空(metadata)" "$_located_bbappend" ""

# 多 bbappend 匹配同一 recipe → metadata
ws="$TMP/loc9"; mkdir -p "$ws/appends"
printf 'EXTERNALSRC:pn-myrecipe = "%s/x"\n' "$TMP" > "$ws/appends/myrecipe_1.0.bbappend"
printf 'EXTERNALSRC:pn-myrecipe = "%s/x"\n' "$TMP" > "$ws/appends/myrecipe_1.2.bbappend"
call_locate "$ws" "myrecipe" "$TMP/x"
assert_eq "locate多bbappend: phase=metadata" "$_located_phase" "metadata"
assert_eq "locate多bbappend: bbappend空(metadata)" "$_located_bbappend" ""

# EXTERNALSRC != status_srctree → metadata
ws="$TMP/loc10"; mkdir -p "$ws/appends"
printf 'EXTERNALSRC:pn-myrecipe = "%s/a"\n' "$TMP" > "$ws/appends/myrecipe_1.0.bbappend"
call_locate "$ws" "myrecipe" "$TMP/different"
assert_eq "locate EXTERNALSRC!=status: phase=metadata" "$_located_phase" "metadata"
assert_eq "locate EXTERNALSRC!=status: bbappend空(metadata)" "$_located_bbappend" ""

# --- _devtool_reset_classify <build_dir> <ws_raw> <ws_eff> <srctreebase_raw> <expected_out> <phase_out> ---
call_classify() {  # <build_dir> <ws_raw> <ws_eff> <srctreebase_raw>
    _classified_expected=""; _classified_phase=""; _crc=0
    _devtool_reset_classify "$1" "$2" "$3" "$4" _classified_expected _classified_phase || _crc=$?
}

# 普通 managed(P=true,O=true,nonempty) → moved
ws="$TMP/cls1"; mkdir -p "$ws/sources/myrecipe"; echo content > "$ws/sources/myrecipe/file"
call_classify "$TMP" "$ws" "$ws" "$ws/sources/myrecipe"
assert_eq "classify moved: rc=0" "$_crc" "0"
assert_eq "classify moved: phase空" "$_classified_phase" ""
assert_eq "classify moved: expected=moved" "$_classified_expected" "moved"

# 普通外部(P=false,O=false,nonempty) → retained
ext="$TMP/ext-ret"; mkdir -p "$ext"; echo c > "$ext/f"
ws="$TMP/cls2"; mkdir -p "$ws/sources"
call_classify "$TMP" "$ws" "$ws" "$ext"
assert_eq "classify retained: expected=retained" "$_classified_expected" "retained"

# sources-backup/<recipe>(P=true,O=false) → metadata
ws="$TMP/cls3"; mkdir -p "$ws/sources-backup/myrecipe"; echo c > "$ws/sources-backup/myrecipe/f"
call_classify "$TMP" "$ws" "$ws" "$ws/sources-backup/myrecipe"
assert_eq "classify sources-backup: phase=metadata" "$_classified_phase" "metadata"

# alias../sources/<recipe>(P=false,O=true) → metadata
ws="$TMP/cls4"; mkdir -p "$ws/sources/myrecipe"; echo c > "$ws/sources/myrecipe/f"
call_classify "$TMP" "$ws" "$ws" "$ws/alias/../sources/myrecipe"
assert_eq "classify alias../sources: phase=metadata" "$_classified_phase" "metadata"

# symlink 出(sources 内 symlink 指外)(P=true,O=false) → metadata
ws="$TMP/cls5"; mkdir -p "$ws/sources"; ext2="$TMP/ext-symout"; mkdir -p "$ext2"; echo c > "$ext2/f"
ln -s "$ext2" "$ws/sources/myrecipe"
call_classify "$TMP" "$ws" "$ws" "$ws/sources/myrecipe"
assert_eq "classify symlink出: phase=metadata" "$_classified_phase" "metadata"

# symlink 入(外部 symlink 指入 sources)(P=false,O=true) → metadata
ws="$TMP/cls6"; mkdir -p "$ws/sources/myrecipe"; echo c > "$ws/sources/myrecipe/f"
extlink="$TMP/ext-symin"; ln -s "$ws/sources/myrecipe" "$extlink"
call_classify "$TMP" "$ws" "$ws" "$extlink"
assert_eq "classify symlink入: phase=metadata" "$_classified_phase" "metadata"

# 相对 workspace_path + 相对 srctreebase → moved(P 用 raw 与 Poky 一致)
bd="$TMP/cls-bd"; mkdir -p "$bd/ws/sources/myrecipe"; echo c > "$bd/ws/sources/myrecipe/f"
call_classify "$bd" "ws" "ws" "ws/sources/myrecipe"
assert_eq "classify相对: expected=moved" "$_classified_expected" "moved"

# pre_state empty_dir → removed
ws="$TMP/cls7"; mkdir -p "$ws/sources/myrecipe"   # 空目录
call_classify "$TMP" "$ws" "$ws" "$ws/sources/myrecipe"
assert_eq "classify empty_dir: expected=removed" "$_classified_expected" "removed"

# pre_state missing → absent
ws="$TMP/cls8"; mkdir -p "$ws/sources"
call_classify "$TMP" "$ws" "$ws" "$ws/sources/nope"
assert_eq "classify missing: expected=absent" "$_classified_expected" "absent"

# 非目录(普通文件) → metadata
ws="$TMP/cls9"; mkdir -p "$ws/sources"; printf 'x' > "$ws/sources/afile"
call_classify "$TMP" "$ws" "$ws" "$ws/sources/afile"
assert_eq "classify非目录: phase=metadata" "$_classified_phase" "metadata"

# dangling symlink(lexical 存在但目标不存在 → 无法 stat → metadata, 不折叠为 absent)
ws="$TMP/cls-dang"; mkdir -p "$ws/sources"
ln -s /nonexistent-target-cls "$ws/sources/dangling"
call_classify "$TMP" "$ws" "$ws" "$ws/sources/dangling"
assert_eq "classify dangling symlink: phase=metadata(非折叠 absent)" "$_classified_phase" "metadata"

# 重叠 appends → metadata
ws="$TMP/cls10"; mkdir -p "$ws/appends/myrecipe"; echo c > "$ws/appends/myrecipe/f"
call_classify "$TMP" "$ws" "$ws" "$ws/appends/myrecipe"
assert_eq "classify重叠appends: phase=metadata" "$_classified_phase" "metadata"

# 重叠 recipes → metadata
ws="$TMP/cls11"; mkdir -p "$ws/recipes/myrecipe"; echo c > "$ws/recipes/myrecipe/f"
call_classify "$TMP" "$ws" "$ws" "$ws/recipes/myrecipe"
assert_eq "classify重叠recipes: phase=metadata" "$_classified_phase" "metadata"

# trap 不变
trap 'echo TEST_TRAP' EXIT
ws="$TMP/cls-trap"; mkdir -p "$ws/sources/myrecipe"; echo c > "$ws/sources/myrecipe/f"
call_classify "$TMP" "$ws" "$ws" "$ws/sources/myrecipe"
_trap_state="$(trap -p EXIT)"
assert_contains "classify trap不变" "$_trap_state" "TEST_TRAP"
trap - EXIT

# ============================================================================
# T3: devtool_reset_run(组装 + 默认 reset + postcondition; 普通路径 + 空格)
# ============================================================================

# mock build env(参照 devtool_modify unit): setup/devtool/bitbake-layers + local.conf
T3TMP="$(mktemp -d)"
export T3TMP
OPENBMC_DIR="$T3TMP/openbmc"; BUILD_DIR="$T3TMP/build"
export OPENBMC_DIR BUILD_DIR
mkdir -p "$OPENBMC_DIR" "$BUILD_DIR/conf" "$T3TMP/bin"

cat > "$OPENBMC_DIR/setup" <<'EOF'
#!/usr/bin/env bash
export SETUP_DONE=1
EOF
chmod +x "$OPENBMC_DIR/setup"

# mock devtool: status 输出 recipe 行; reset 模拟 devtool 处置(moved 移 attic / retained 不动 / removed rmdir / absent 不动)
cat > "$T3TMP/bin/devtool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status)
    # reset 完成后 recipe 退出 workspace → status 不再输出 recipe 行(模拟 devtool 真实语义)
    # MOCK_POST_STATUS_RC 注入二次 status 失败(默认 0); moved-noflag 不设 flag → recipe 仍在 workspace
    if [[ -f "${MOCK_RESET_FLAG:-/nonexistent}" ]]; then exit "${MOCK_POST_STATUS_RC:-0}"; fi
    [[ -n "$MOCK_SRCTREE" ]] && printf '%s: %s\n' "$MOCK_RECIPE" "$MOCK_SRCTREE"
    exit "${MOCK_STATUS_RC:-0}"
    ;;
  reset)
    case "${MOCK_RESET_ACTION:-moved}" in
      moved)
        if [[ -n "$MOCK_SRCTREEBASE" && -d "$MOCK_SRCTREEBASE" ]]; then
          _attic="$(dirname "$(dirname "$MOCK_SRCTREEBASE")")/attic/sources"
          mkdir -p "$_attic"
          mv "$MOCK_SRCTREEBASE" "$_attic/$(basename "$MOCK_SRCTREEBASE").ts" 2>/dev/null
        fi
        : > "${MOCK_RESET_FLAG:-/dev/null}"
        exit 0 ;;
      moved-noflag)
        # moved 移 srctreebase 但不设 flag → 二次 status 仍输出 recipe(recipe 未退出 workspace)
        if [[ -n "$MOCK_SRCTREEBASE" && -d "$MOCK_SRCTREEBASE" ]]; then
          _attic="$(dirname "$(dirname "$MOCK_SRCTREEBASE")")/attic/sources"
          mkdir -p "$_attic"
          mv "$MOCK_SRCTREEBASE" "$_attic/$(basename "$MOCK_SRCTREEBASE").ts" 2>/dev/null
        fi
        exit 0 ;;
      retained) : > "${MOCK_RESET_FLAG:-/dev/null}"; exit 0 ;;
      removed)
        [[ -n "$MOCK_SRCTREEBASE" && -d "$MOCK_SRCTREEBASE" ]] && rmdir "$MOCK_SRCTREEBASE" 2>/dev/null
        : > "${MOCK_RESET_FLAG:-/dev/null}"
        exit 0 ;;
      absent) : > "${MOCK_RESET_FLAG:-/dev/null}"; exit 0 ;;
      fail-reset) exit 1 ;;
      post-fail) : > "${MOCK_RESET_FLAG:-/dev/null}"; exit 0 ;;
    esac
    exit 0 ;;
esac
EOF
chmod +x "$T3TMP/bin/devtool"

printf '#!/usr/bin/env bash\nexit 0\n' > "$T3TMP/bin/bitbake-layers"
chmod +x "$T3TMP/bin/bitbake-layers"
export PATH="$T3TMP/bin:$PATH"

MOCK_RESET_FLAG="$T3TMP/.reset_done"
export MOCK_RESET_FLAG

MACHINE="testm"
touch "$BUILD_DIR/conf/local.conf" "$BUILD_DIR/conf/bblayers.conf"

# call_run <recipe>: 调 devtool_reset_run(生产 receiver _reset_*), 捕获 rc, 清 stderr_file
call_run() {
    _reset_srctree=""; _reset_srctreebase=""; _reset_disposition=""
    _reset_destination_parent=""; _reset_cleaned_bbappend=""; _reset_phase=""; _reset_stage=""; _reset_stderr_file=""; _runrc=0
    devtool_reset_run "$MACHINE" "$BUILD_DIR" "$1" \
        _reset_srctree _reset_srctreebase _reset_disposition _reset_destination_parent \
        _reset_cleaned_bbappend _reset_phase _reset_stage _reset_stderr_file || _runrc=$?
    rm -f "$_reset_stderr_file" 2>/dev/null
}

# setup_modified <recipe> <srctree> <ws> <sb_state: nonempty|empty|missing>
# 建 devtool.conf(workspace_path=ws) + appends/<recipe>.bbappend(EXTERNALSRC=srctree) + srctree 目录
setup_modified() {
    local recipe="$1" srctree="$2" ws="$3" sb_state="$4"
    mkdir -p "$ws/appends"
    printf 'EXTERNALSRC:pn-%s = "%s"\n' "$recipe" "$srctree" > "$ws/appends/${recipe}_1.0.bbappend"
    printf '[General]\nworkspace_path = %s\n' "$ws" > "$BUILD_DIR/conf/devtool.conf"
    case "$sb_state" in
        nonempty) mkdir -p "$srctree"; echo c > "$srctree/f" ;;
        empty) mkdir -p "$srctree" ;;
        missing) ;;
    esac
    export MOCK_RECIPE="$recipe" MOCK_SRCTREE="$srctree" MOCK_SRCTREEBASE="$srctree"
    rm -f "$MOCK_RESET_FLAG"   # 每个用例重置(reset 完成标志)
}

# --- moved(普通 managed, P=true/O=true, reset 移 attic) ---
ws="$T3TMP/ws-moved"; setup_modified "recipe1" "$ws/sources/recipe1" "$ws" nonempty
MOCK_RESET_ACTION=moved call_run "recipe1"
assert_eq "moved: rc=0" "$_runrc" "0"
assert_eq "moved: phase空" "$_reset_phase" ""
assert_eq "moved: disposition=moved" "$_reset_disposition" "moved"
assert_eq "moved: srctree" "$_reset_srctree" "$ws/sources/recipe1"
assert_eq "moved: srctreebase" "$_reset_srctreebase" "$ws/sources/recipe1"
assert_eq "moved: destination_parent=ws/attic/sources" "$_reset_destination_parent" "$ws/attic/sources"
assert_eq "moved: cleaned_bbappend=命中bbappend" "$_reset_cleaned_bbappend" "$ws/appends/recipe1_1.0.bbappend"

# --- retained(外部 srctree, P=false/O=false) ---
ext="$T3TMP/external-r2"; ws="$T3TMP/ws-ret"
setup_modified "recipe2" "$ext" "$ws" nonempty
MOCK_RESET_ACTION=retained call_run "recipe2"
assert_eq "retained: rc=0" "$_runrc" "0"
assert_eq "retained: disposition=retained" "$_reset_disposition" "retained"
assert_eq "retained: destination_parent空" "$_reset_destination_parent" ""
assert_eq "retained: cleaned_bbappend=命中bbappend" "$_reset_cleaned_bbappend" "$ws/appends/recipe2_1.0.bbappend"

# --- removed(empty_dir, Poky rmdir) ---
ws="$T3TMP/ws-rem"; setup_modified "recipe3" "$ws/sources/recipe3" "$ws" empty
MOCK_RESET_ACTION=removed call_run "recipe3"
assert_eq "removed: rc=0" "$_runrc" "0"
assert_eq "removed: disposition=removed" "$_reset_disposition" "removed"
assert_eq "removed: destination_parent空" "$_reset_destination_parent" ""
assert_eq "removed: cleaned_bbappend=命中bbappend" "$_reset_cleaned_bbappend" "$ws/appends/recipe3_1.0.bbappend"

# --- absent(pre missing) ---
ws="$T3TMP/ws-abs"; setup_modified "recipe4" "$ws/sources/recipe4" "$ws" missing
MOCK_RESET_ACTION=absent call_run "recipe4"
assert_eq "absent: rc=0" "$_runrc" "0"
assert_eq "absent: disposition=absent" "$_reset_disposition" "absent"
assert_eq "absent: cleaned_bbappend=命中bbappend" "$_reset_cleaned_bbappend" "$ws/appends/recipe4_1.0.bbappend"

# --- noop(status 无 recipe 行) ---
ws="$T3TMP/ws-noop"; mkdir -p "$ws/appends"
printf '[General]\nworkspace_path = %s\n' "$ws" > "$BUILD_DIR/conf/devtool.conf"
MOCK_SRCTREE="" MOCK_RESET_ACTION=moved call_run "recipe5"
assert_eq "noop: rc=0" "$_runrc" "0"
assert_eq "noop: disposition=noop" "$_reset_disposition" "noop"
assert_eq "noop: srctree空" "$_reset_srctree" ""
assert_eq "noop: srctreebase空" "$_reset_srctreebase" ""
assert_eq "noop: destination_parent空" "$_reset_destination_parent" ""
assert_eq "noop: cleaned_bbappend空(未locate)" "$_reset_cleaned_bbappend" ""

# --- postcondition 失败(moved 预期但 reset 未移 → srctreebase 仍存在) ---
ws="$T3TMP/ws-pf"; setup_modified "recipe6" "$ws/sources/recipe6" "$ws" nonempty
MOCK_RESET_ACTION=post-fail call_run "recipe6"
assert_false "post-fail: rc非0" test "$_runrc" -eq 0
assert_eq "post-fail: phase=postcondition" "$_reset_phase" "postcondition"

# --- postcondition: recipe 仍在 workspace(moved-noflag 移 srctreebase 但 recipe 未退出) → phase=postcondition ---
ws="$T3TMP/ws-pin"; setup_modified "recipePIN" "$ws/sources/recipePIN" "$ws" nonempty
MOCK_RESET_ACTION=moved-noflag call_run "recipePIN"
assert_false "postcondition recipe仍在: rc非0" test "$_runrc" -eq 0
assert_eq "postcondition recipe仍在: phase=postcondition" "$_reset_phase" "postcondition"

# --- postcondition: 二次 status 失败(MOCK_POST_STATUS_RC 注入) → phase=postcondition ---
ws="$T3TMP/ws-psf"; setup_modified "recipePSF" "$ws/sources/recipePSF" "$ws" nonempty
MOCK_RESET_ACTION=moved MOCK_POST_STATUS_RC=1 call_run "recipePSF"
assert_false "postcondition status失败: rc非0" test "$_runrc" -eq 0
assert_eq "postcondition status失败: phase=postcondition" "$_reset_phase" "postcondition"

# --- reset 失败(phase=reset) ---
ws="$T3TMP/ws-rf"; setup_modified "recipe7" "$ws/sources/recipe7" "$ws" nonempty
MOCK_RESET_ACTION=fail-reset call_run "recipe7"
assert_false "reset-fail: rc非0" test "$_runrc" -eq 0
assert_eq "reset-fail: phase=reset" "$_reset_phase" "reset"

# --- status 失败(phase=status) ---
ws="$T3TMP/ws-sf"; mkdir -p "$ws/appends"
printf '[General]\nworkspace_path = %s\n' "$ws" > "$BUILD_DIR/conf/devtool.conf"
MOCK_STATUS_RC=1 MOCK_SRCTREE="x" MOCK_RESET_ACTION=moved call_run "recipe8"
assert_false "status-fail: rc非0" test "$_runrc" -eq 0
assert_eq "status-fail: phase=status" "$_reset_phase" "status"

# --- _devtool_env_exec postcondition 检查失败(local.conf 缺) → status 失败 + stage=postcondition ---
# 证明 cmd_dev stage case 的 postcondition 分支非死代码: _devtool_env_exec 在 local.conf/devtool/bitbake-layers
# 可用性检查失败时写 stage_file=postcondition, devtool_reset_run 第一次 status 读到它并回传。
ws="$T3TMP/ws-pc"; setup_modified "recipePC" "$ws/sources/recipePC" "$ws" nonempty
rm -f "$BUILD_DIR/conf/local.conf"
MOCK_RESET_ACTION=moved call_run "recipePC"
assert_false "postcondition-fail: rc非0" test "$_runrc" -eq 0
assert_eq "postcondition-fail: stage=postcondition" "$_reset_stage" "postcondition"
assert_eq "postcondition-fail: phase=status" "$_reset_phase" "status"
touch "$BUILD_DIR/conf/local.conf"

# --- srctree/srctreebase 含空格 → 7 outvar 原样 ---
ws="$T3TMP/ws-sp"; sp_path="$ws/sources/recipe with space"
setup_modified "recipe9" "$sp_path" "$ws" nonempty
MOCK_RESET_ACTION=moved call_run "recipe9"
assert_eq "空格: disposition=moved" "$_reset_disposition" "moved"
assert_eq "空格: srctree含空格原样" "$_reset_srctree" "$sp_path"
assert_eq "空格: srctreebase含空格原样" "$_reset_srctreebase" "$sp_path"
assert_eq "空格: destination_parent含空格" "$_reset_destination_parent" "$ws/attic/sources"

# --- devtool.conf 解析失败(metadata) ---
ws="$T3TMP/ws-md"; setup_modified "recipe10" "$ws/sources/recipe10" "$ws" nonempty
printf '[General]\nworkspace_path = \n' > "$BUILD_DIR/conf/devtool.conf"   # 空值 → metadata
MOCK_RESET_ACTION=moved call_run "recipe10"
assert_false "metadata: rc非0" test "$_runrc" -eq 0
assert_eq "metadata: phase=metadata" "$_reset_phase" "metadata"

# --- trap 不变 ---
trap 'echo TEST_TRAP' EXIT
ws="$T3TMP/ws-trap"; setup_modified "recipe11" "$ws/sources/recipe11" "$ws" nonempty
MOCK_RESET_ACTION=moved call_run "recipe11"
_trap_state="$(trap -p EXIT)"
assert_contains "run trap不变" "$_trap_state" "TEST_TRAP"
trap - EXIT

rm -rf "$T3TMP"

assert_summary
