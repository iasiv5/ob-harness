#!/usr/bin/env bash
# tests/unit/devtool_modify.sh — _devtool_env_exec + devtool_modify_run 单测(unit 层)。
# 覆盖: tempfile 协议(stage/stdout/stderr) / 输出隔离 / 同一 subshell / postcondition / devtool_modify_run 三段。
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

# === _devtool_env_exec: tempfile 协议 + 输出隔离 ===
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
touch "$BUILD_DIR/conf/local.conf"   # 恢复

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

# === _devtool_parse_status_all: 全量解析 status 行 ===
_psa_tmp="$(mktemp)"
printf 'foorecipe: %s/workspace/sources/foorecipe (recipes-foo/foorecipe.bb)\n' "$TMP" > "$_psa_tmp"
printf 'barrecipe: %s/workspace/sources/barrecipe\n' "$TMP" >> "$_psa_tmp"
printf 'Currently working recipes:\n' >> "$_psa_tmp"   # header 行(应跳过)
_psa_out="$(_devtool_parse_status_all "$_psa_tmp")"
assert_eq "parse_status_all 行数(2 recipe,header 跳过)" "$(printf '%s\n' "$_psa_out" | grep -c .)" "2"
assert_contains "parse_status_all foorecipe+srctree" "$_psa_out" $'foorecipe\t'"$TMP/workspace/sources/foorecipe"
assert_false "parse_status_all 剥掉 recipefile 后缀" grep -q 'recipes-foo/foorecipe.bb' <<<"$_psa_out"
assert_false "parse_status_all 跳过 header" grep -q 'Currently working recipes' <<<"$_psa_out"
rm -f "$_psa_tmp"
# 空文件 → 空输出
_psa_empty="$(mktemp)"; assert_eq "parse_status_all 空文件无输出" "$(_devtool_parse_status_all "$_psa_empty" | grep -c .)" "0"; rm -f "$_psa_empty"
# 负例: NOTE 噪声 / WARNING+绝对路径(诊断 token) / recipe 含空白 / srctree 相对路径 → 全跳过
_psa_neg="$(mktemp)"
printf 'NOTE: some bitbake noise\n' > "$_psa_neg"
printf 'WARNING: /abs/path\n' >> "$_psa_neg"         # 诊断 token + 绝对路径 → 仍跳过(靠 token 排除)
printf 'foo bar: /tmp/x\n' >> "$_psa_neg"           # recipe 含空白 → 跳过
printf 'good: relative/path\n' >> "$_psa_neg"        # srctree 非绝对 → 跳过
assert_eq "parse_status_all 负例全跳过(0 行)" "$(_devtool_parse_status_all "$_psa_neg" | grep -c .)" "0"
rm -f "$_psa_neg"

# === devtool_status_run: env_exec → 全量解析 → outvar ===
_dsr_machine="testm" _dsr_build="$TMP/build"
# mock _devtool_env_exec: 把 status 内容写进 stdout_file($4)
_devtool_env_exec() {
    local m="$1" b="$2" sf="$3" of="$4" erf="$5"; shift 5; [[ "$1" == "--" ]] && shift
    echo command > "$sf"
    printf 'ipmi-host: %s/workspace/sources/ipmi-host (recipes-core/ipmi-host.bb)\n' "$_dsr_build" > "$of"
    printf 'web: %s/workspace/sources/web\n' "$_dsr_build" >> "$of"
    return 0
}
_status_entries="" _status_stage="" _status_stderr=""
devtool_status_run "$_dsr_machine" "$_dsr_build" _status_entries _status_stage _status_stderr
assert_eq "status_run rc 0" "$?" "0"
assert_eq "status_run stage=command" "$_status_stage" "command"
assert_eq "status_run entries 行数" "$(printf '%s\n' "$_status_entries" | grep -c .)" "2"
assert_contains "status_run entries ipmi-host" "$_status_entries" $'ipmi-host\t'"$_dsr_build/workspace/sources/ipmi-host"
rm -f "$_status_stderr"
# rc 失败(command 阶段) → entries 空 + rc 非零 + stage 传播
_devtool_env_exec() { local sf="$3" of="$4"; echo command > "$sf"; : > "$of"; return 1; }
devtool_status_run "$_dsr_machine" "$_dsr_build" _status_entries _status_stage _status_stderr
assert_false "status_run rc 失败返回非零" test $? -eq 0
assert_eq "status_run 失败时 entries 空" "$_status_entries" ""
assert_eq "status_run 失败 stage=command" "$_status_stage" "command"
rm -f "$_status_stderr"
# stage 失败(postcondition, build env 未 ready) → stage 传播 + entries 空 + rc 非零
_devtool_env_exec() { local sf="$3" of="$4"; echo postcondition > "$sf"; : > "$of"; return 1; }
devtool_status_run "$_dsr_machine" "$_dsr_build" _status_entries _status_stage _status_stderr
assert_false "status_run postcondition 失败返回非零" test $? -eq 0
assert_eq "status_run postcondition stage 传播" "$_status_stage" "postcondition"
assert_eq "status_run postcondition entries 空" "$_status_entries" ""
rm -f "$_status_stderr"

assert_summary
