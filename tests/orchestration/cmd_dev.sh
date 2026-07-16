#!/usr/bin/env bash
# tests/orchestration/cmd_dev.sh — cmd_dev 编排单测(mock devtool_search/devtool_modify_run/machine_state)。
# 覆盖: machine 前置(非TTY/无候选)、list 三态(missing 懒生成/stale/fresh)、modify(无recipe/已modify/setup失败/command失败)、
#       refresh、无子命令、porcelain(stdout 纯)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OPENBMC_DIR="$TMP/openbmc"; BUILD_DIR="$TMP/build"; CONFIGS_DIR="$TMP/configs"
export OPENBMC_DIR BUILD_DIR CONFIGS_DIR
mkdir -p "$OPENBMC_DIR/build/testm" "$CONFIGS_DIR"

# === mock 控制 + mock 函数 ===
MOCK_STATE="fresh"; MOCK_SRCTREE=""; MOCK_STAGE="command"; MOCK_MODRC=0; MOCK_REFRC=0; MOCK_READ_RC=0
MOCK_INIT_MACHINES="testm"

machine_state_initialized_machines() { printf '%s\n' "$MOCK_INIT_MACHINES"; }
machine_state_is_initialized() { [[ "$1" == "testm" ]]; }
devtool_search_read() {
    local so="$4"
    printf -v "$so" '%s' "$MOCK_STATE"
    [[ "$MOCK_READ_RC" -eq 0 && "$MOCK_STATE" == "fresh" ]] &&
        printf '{"recipe":"phosphor-ipmi-host","layer":"meta-phosphor","summary":"IPMI host"}\n'
    return "$MOCK_READ_RC"
}
devtool_search_refresh() {
    local so="$3" se="$4"
    touch "$TMP/refresh_called" 2>/dev/null || true   # 文件标记(跨子 shell 可见,变量不回传)
    printf -v "$so" '%s' "command"
    printf -v "$se" '%s' "/dev/null"
    MOCK_STATE="fresh"   # 🔴1: refresh 成功后 cache fresh(cmd_dev list missing 重检 cache_state 要 fresh)
    return "$MOCK_REFRC"
}
devtool_modify_run() {
    local s="$4" st="$5" se="$6"
    touch "$TMP/modify_called" 2>/dev/null || true
    printf -v "$s" '%s' "$MOCK_SRCTREE"
    printf -v "$st" '%s' "$MOCK_STAGE"
    printf -v "$se" '%s' "/dev/null"
    return "$MOCK_MODRC"
}

# reset mock: 10 参数(machine/build_dir/recipe + 7 outvar); 用 MOCK_RST_* 回传, 真实 _reset_*
MOCK_RST_SRCTREE=""; MOCK_RST_SRCTREEBASE=""; MOCK_RST_DISPOSITION="moved"
MOCK_RST_DEST_PARENT=""; MOCK_RST_PHASE=""; MOCK_RST_STAGE=""; MOCK_RST_RC=0
devtool_reset_run() {
    local _o_srctree="$4" _o_srctreebase="$5" _o_disposition="$6" _o_dest="$7" _o_phase="$8" _o_stage="$9" _o_stderr="${10}"
    touch "$TMP/reset_called" 2>/dev/null || true
    printf -v "$_o_srctree" '%s' "$MOCK_RST_SRCTREE"
    printf -v "$_o_srctreebase" '%s' "$MOCK_RST_SRCTREEBASE"
    printf -v "$_o_disposition" '%s' "$MOCK_RST_DISPOSITION"
    printf -v "$_o_dest" '%s' "$MOCK_RST_DEST_PARENT"
    printf -v "$_o_phase" '%s' "$MOCK_RST_PHASE"
    printf -v "$_o_stage" '%s' "$MOCK_RST_STAGE"
    printf -v "$_o_stderr" '%s' "/dev/null"
    return "$MOCK_RST_RC"
}

# run_dev <args...>: 跑 cmd_dev(子 shell 捕获 exit), 设 RUN_RC/RUN_OUT/RUN_ERR
run_dev() {
    local err
    err="$(mktemp)"
    local rc=0
    RUN_OUT="$( { cmd_dev "$@"; } 2>"$err" </dev/null )" && rc=0 || rc=$?   # </dev/null 强制非 TTY(评审 🟡6,避免 TTY 跑卡 pick_machine)
    RUN_RC=$rc; RUN_ERR="$(cat "$err")"; rm -f "$err"
}

# === list fresh ===
MOCK_STATE="fresh"; run_dev --machine testm list
assert_eq "list fresh exit 0" "$RUN_RC" 0
assert_contains "list fresh stdout JSONL(含 recipe)" "$RUN_OUT" "phosphor-ipmi-host"
assert_false "list fresh stdout 纯(无 [ERROR])" grep -q "\[ERROR\]" <<<"$RUN_OUT"

# === shared-lock read failure → exit 1，不输出 cache ===
MOCK_STATE="fresh"; MOCK_READ_RC=1; run_dev --machine testm list
assert_eq "list shared-lock read failure exit 1" "$RUN_RC" 1
assert_contains "list shared-lock read failure diagnostic" "$RUN_ERR" "failed to read recipe cache safely"
MOCK_READ_RC=0

# === list stale → exit 3 + refresh remedy ===
MOCK_STATE="stale"; run_dev --machine testm list
assert_eq "list stale exit 3" "$RUN_RC" 3
assert_contains "list stale remedy(refresh)" "$RUN_ERR" "ob dev --machine testm refresh"

# === list missing → 懒生成(调 refresh) + list ===
MOCK_STATE="missing"; MOCK_REFRC=0; rm -f "$TMP/refresh_called"; run_dev --machine testm list
assert_eq "list missing exit 0(懒生成)" "$RUN_RC" 0
assert_true "list missing 调了 refresh" test -f "$TMP/refresh_called"
assert_contains "list missing stdout JSONL" "$RUN_OUT" "phosphor-ipmi-host"

# === list missing + refresh 失败 → exit 1 ===
MOCK_STATE="missing"; MOCK_REFRC=1; run_dev --machine testm list
assert_false "list missing refresh 失败 exit 1" test "$RUN_RC" -eq 0

# === modify 无 recipe → exit 3 + list remedy ===
run_dev --machine testm modify
assert_eq "modify 无 recipe exit 3" "$RUN_RC" 3
assert_contains "modify 无 recipe remedy(list)" "$RUN_ERR" "ob dev --machine testm list"

# === modify 已 modify(stage=command, rc=0) → stdout srctree ===
MOCK_SRCTREE="$TMP/sources/phosphor-ipmi-host"; MOCK_STAGE="command"; MOCK_MODRC=0
run_dev --machine testm modify phosphor-ipmi-host
assert_eq "modify 已 modify exit 0" "$RUN_RC" 0
assert_contains "modify stdout srctree(恰好一行)" "$RUN_OUT" "phosphor-ipmi-host"
assert_eq "modify stdout 恰好一行" "$(grep -c . <<<"$RUN_OUT")" "1"

# === modify setup 失败(stage=postcondition) → exit 1 ===
MOCK_STAGE="postcondition"; MOCK_MODRC=1
run_dev --machine testm modify phosphor-ipmi-host
assert_eq "modify setup 失败 exit 1" "$RUN_RC" 1
assert_contains "modify setup 失败诊断(build env)" "$RUN_ERR" "build env"

# === modify command 失败(stage=command, rc!=0) → exit 1 ===
MOCK_STAGE="command"; MOCK_MODRC=1
run_dev --machine testm modify phosphor-ipmi-host
assert_eq "modify command 失败 exit 1" "$RUN_RC" 1
assert_contains "modify command 失败诊断(devtool)" "$RUN_ERR" "devtool"

# === refresh 成功 → exit 0 ===
MOCK_REFRC=0; run_dev --machine testm refresh
assert_eq "refresh exit 0" "$RUN_RC" 0

# === 无子命令 → exit 3 + list remedy ===
run_dev --machine testm
assert_eq "无子命令 exit 3" "$RUN_RC" 3
assert_contains "无子命令 remedy(list)" "$RUN_ERR" "ob dev --machine testm list"

# === 无 --machine + 非 TTY(test 环境)→ exit 3 Specify machine ===
MOCK_INIT_MACHINES="testm"; run_dev list
assert_eq "无 --machine 非 TTY exit 3" "$RUN_RC" 3
assert_contains "无 --machine remedy(Specify machine)" "$RUN_ERR" "Specify a machine"

# === 无 --machine + 无候选 → exit 3 ob init remedy ===
MOCK_INIT_MACHINES=""; run_dev list
assert_eq "无候选 exit 3" "$RUN_RC" 3
assert_contains "无候选 remedy(ob init)" "$RUN_ERR" "ob init"

# === dry-run: 不调 devtool/_devtool_env_exec, exit 0(评审 🔴3) ===
rm -f "$TMP/modify_called" "$TMP/refresh_called"
DRY_RUN=1 run_dev --machine testm modify somerecipe
assert_eq "dry-run modify exit 0" "$RUN_RC" 0
assert_false "dry-run modify 不调 devtool_modify_run" test -f "$TMP/modify_called"
assert_contains "dry-run modify 预览(srctree preview)" "$RUN_ERR" "DRY-RUN"
DRY_RUN=1 run_dev --machine testm refresh
assert_eq "dry-run refresh exit 0" "$RUN_RC" 0
assert_false "dry-run refresh 不调 devtool_search_refresh" test -f "$TMP/refresh_called"
DRY_RUN=1 run_dev --machine testm list
assert_eq "dry-run list exit 0" "$RUN_RC" 0
unset DRY_RUN

# === invalid recipe → modify 失败 → exit 1(评审 🟡6) ===
MOCK_STAGE="command"; MOCK_MODRC=1
run_dev --machine testm modify nonexistent-recipe
assert_eq "invalid recipe(modify 失败) exit 1" "$RUN_RC" 1

# === 🔴1 完整 argv parser: 尾随/recipe后 -d + 多余 positional 拒绝 ===
MOCK_STAGE="command"; MOCK_MODRC=0
rm -f "$TMP/modify_called"
run_dev --machine testm modify somerecipe --dry-run
assert_eq "尾随 -d modify exit 0(dry-run)" "$RUN_RC" 0
assert_false "尾随 -d 不调 devtool_modify_run" test -f "$TMP/modify_called"
run_dev --machine testm modify somerecipe -d
assert_false "recipe 后 -d 不调 devtool_modify_run" test -f "$TMP/modify_called"
run_dev --machine testm refresh --dry-run
assert_eq "refresh 后 -d exit 0(dry-run)" "$RUN_RC" 0
run_dev --machine testm modify recipe1 recipe2
assert_false "多余 positional(modify 2 recipe) 拒绝" test "$RUN_RC" -eq 0
run_dev --machine=-d list
assert_eq "--machine=-d 拒绝" "$RUN_RC" 1
assert_contains "--machine=-d 诊断" "$RUN_ERR" "invalid --machine value"

# ============================================================================
# reset: JSON 六字段精确契约 + 原子发布 + phase 映射 + parser + porcelain
# ============================================================================

# assert_reset_json <label> <stdout> <recipe> <srctree> <srctreebase> <disposition> <dest_parent(空=None)>
# 校验: 恰好一物理行 + 尾换行 + json.loads + 精确六字段 key 集合 + 类型/值
assert_reset_json() {
    local label="$1" out="$2" recipe="$3" srctree="$4" srctreebase="$5" disposition="$6" dest_parent="$7"
    local jrc=0
    EXP_RECIPE="$recipe" EXP_ST="$srctree" EXP_SB="$srctreebase" EXP_DISP="$disposition" EXP_DP="$dest_parent" \
    python3 -c '
import json, os, sys
data = sys.stdin.read()
lines = data.splitlines()
assert len(lines) == 1, "物理行数=%d (want 1): %r" % (len(lines), data)
assert data.endswith("\n"), "缺尾换行: %r" % data
d = json.loads(data)
keys = sorted(d.keys())
assert keys == ["destination", "destination_parent", "disposition", "recipe", "srctree", "srctreebase"], "keys=%r" % keys
assert d["recipe"] == os.environ["EXP_RECIPE"], ("recipe", d["recipe"])
assert d["srctree"] == os.environ["EXP_ST"], ("srctree", d["srctree"])
assert d["srctreebase"] == os.environ["EXP_SB"], ("srctreebase", d["srctreebase"])
assert d["disposition"] == os.environ["EXP_DISP"], ("disposition", d["disposition"])
exp_dp = None if os.environ["EXP_DP"] == "" else os.environ["EXP_DP"]
assert d["destination_parent"] == exp_dp, ("destination_parent", d["destination_parent"], exp_dp)
assert d["destination"] is None, ("destination", d["destination"])
' <<< "$out" || jrc=$?
    assert_eq "$label (JSON 六字段精确)" "$jrc" "0"
}

# --- moved → destination_parent=<ws>/attic/sources, destination=null ---
MOCK_RST_SRCTREE="/ws/sources/r1"; MOCK_RST_SRCTREEBASE="/ws/sources/r1"
MOCK_RST_DISPOSITION="moved"; MOCK_RST_DEST_PARENT="/ws/attic/sources"; MOCK_RST_PHASE=""; MOCK_RST_RC=0
run_dev --machine testm reset r1
assert_eq "reset moved: exit 0" "$RUN_RC" "0"
assert_reset_json "reset moved" "$RUN_OUT" "r1" "/ws/sources/r1" "/ws/sources/r1" "moved" "/ws/attic/sources"

# --- retained/removed/absent → destination_parent=null, destination=null ---
MOCK_RST_DISPOSITION="retained"; MOCK_RST_DEST_PARENT=""
run_dev --machine testm reset r2
assert_reset_json "reset retained" "$RUN_OUT" "r2" "/ws/sources/r1" "/ws/sources/r1" "retained" ""
MOCK_RST_DISPOSITION="removed"; run_dev --machine testm reset r3
assert_reset_json "reset removed" "$RUN_OUT" "r3" "/ws/sources/r1" "/ws/sources/r1" "removed" ""
MOCK_RST_DISPOSITION="absent"; run_dev --machine testm reset r4
assert_reset_json "reset absent" "$RUN_OUT" "r4" "/ws/sources/r1" "/ws/sources/r1" "absent" ""

# --- noop → srctree="", srctreebase="" ---
MOCK_RST_SRCTREE=""; MOCK_RST_SRCTREEBASE=""; MOCK_RST_DISPOSITION="noop"; MOCK_RST_DEST_PARENT=""
run_dev --machine testm reset r5
assert_eq "reset noop: exit 0" "$RUN_RC" "0"
assert_reset_json "reset noop" "$RUN_OUT" "r5" "" "" "noop" ""

# --- JSON 全链路 round-trip 含特殊字符(引号/反斜杠/真换行) ---
_weird_st=$'/ws/strange "quote\nline'
MOCK_RST_SRCTREE="$_weird_st"; MOCK_RST_SRCTREEBASE='/ws/back\slash'
MOCK_RST_DISPOSITION="retained"; MOCK_RST_DEST_PARENT=""
run_dev --machine testm reset r6
assert_reset_json "reset 特殊字符 round-trip" "$RUN_OUT" "r6" "$_weird_st" '/ws/back\slash' "retained" ""

# --- JSON 编码失败(REAL_PYTHON fake python 只让 -c 失败) → exit 1 + stdout 空(约束 ④) ---
REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON
_PYDB="$(mktemp -d)"; mkfake_bin "$_PYDB" python3
stub_script "$_PYDB" python3 'if [[ "$1" == "-c" ]]; then exit 1; fi
exec "$REAL_PYTHON" "$@"'
MOCK_RST_DISPOSITION="moved"; MOCK_RST_DEST_PARENT="/ws/attic/sources"; MOCK_RST_PHASE=""; MOCK_RST_RC=0
_jerr="$(mktemp)"; _jrc=0
RUN_OUT="$(with_stub "$_PYDB" -- cmd_dev --machine testm reset rfail 2>"$_jerr" </dev/null)" && _jrc=0 || _jrc=$?
RUN_RC=$_jrc; RUN_ERR="$(cat "$_jerr")"; rm -f "$_jerr"
assert_false "JSON 编码失败: exit 1" test "$RUN_RC" -eq 0
assert_eq "JSON 编码失败: stdout 空" "$RUN_OUT" ""
rm -rf "$_PYDB"

# --- stage=postcondition(_devtool_env_exec postcondition 检查失败) → build env not ready ---
# 证明 cmd_dev stage case 的 postcondition 分支非死代码(对应 _devtool_env_exec postcondition 检查失败,
# devtool_modify 同模式; 报告 🟢1 误判它为死代码——实际 _devtool_env_exec 在 local.conf/devtool/bitbake-layers
# 可用性检查失败时写 stage_file=postcondition, 经 devtool_reset_run 第一次 status 回传)。
MOCK_RST_SRCTREE="/ws/s"; MOCK_RST_DISPOSITION="moved"; MOCK_RST_DEST_PARENT=""; MOCK_RST_RC=1
MOCK_RST_STAGE="postcondition"; MOCK_RST_PHASE="status"
run_dev --machine testm reset rstage
assert_eq "stage=postcondition: exit 1" "$RUN_RC" "1"
assert_contains "stage=postcondition: build env 诊断" "$RUN_ERR" "build env"

# --- phase 映射(status/metadata/reset/postcondition → exit 1, 诊断含 phase 词) ---
MOCK_RST_STAGE=""; MOCK_RST_SRCTREE="/ws/s"; MOCK_RST_DISPOSITION="moved"; MOCK_RST_DEST_PARENT=""; MOCK_RST_RC=1
MOCK_RST_PHASE="metadata"; run_dev --machine testm reset rmeta
assert_eq "reset phase=metadata: exit 1" "$RUN_RC" "1"
assert_contains "reset phase=metadata 诊断" "$RUN_ERR" "metadata"
MOCK_RST_PHASE="status"; run_dev --machine testm reset rstat
assert_false "reset phase=status: exit 1" test "$RUN_RC" -eq 0
assert_contains "reset phase=status 诊断" "$RUN_ERR" "status"
MOCK_RST_PHASE="reset"; run_dev --machine testm reset rreset
assert_contains "reset phase=reset 诊断" "$RUN_ERR" "reset"
MOCK_RST_PHASE="postcondition"; run_dev --machine testm reset rpost
assert_contains "reset phase=postcondition 诊断" "$RUN_ERR" "postcondition"

# --- parser + 前置 ---
MOCK_RST_PHASE=""; MOCK_RST_RC=0; MOCK_RST_DISPOSITION="noop"; MOCK_RST_SRCTREE=""
run_dev --machine testm reset
assert_eq "reset 无recipe: exit 3" "$RUN_RC" "3"
assert_contains "reset 无recipe remedy(list)" "$RUN_ERR" "ob dev --machine testm list"
rm -f "$TMP/reset_called"
run_dev --machine testm reset rr --dry-run
assert_eq "reset 尾随dry-run: exit 0" "$RUN_RC" "0"
assert_false "reset dry-run 不调 devtool_reset_run" test -f "$TMP/reset_called"
run_dev --machine testm reset r1 r2
assert_false "reset 双recipe 拒绝" test "$RUN_RC" -eq 0
run_dev --machine testm --remove-work reset r1
assert_false "--remove-work(子命令前): exit 1" test "$RUN_RC" -eq 0
assert_contains "--remove-work 诊断(unknown option)" "$RUN_ERR" "unknown option"
run_dev --machine testm reset r1 --remove-work
assert_false "--remove-work(recipe 后): exit 1" test "$RUN_RC" -eq 0

# --- porcelain: stdout 只 JSON, 无 [ERROR]/logo ---
MOCK_RST_DISPOSITION="moved"; MOCK_RST_DEST_PARENT="/ws/attic/sources"; MOCK_RST_PHASE=""; MOCK_RST_RC=0
MOCK_RST_SRCTREE="/ws/sources/rp"; MOCK_RST_SRCTREEBASE="/ws/sources/rp"
run_dev --machine testm reset rporc
assert_eq "reset porcelain: exit 0" "$RUN_RC" "0"
assert_false "reset stdout 纯(无 [ERROR])" grep -q "\[ERROR\]" <<<"$RUN_OUT"
assert_eq "reset stdout 恰好一行 JSON" "$(grep -c . <<<"$RUN_OUT")" "1"

# JSON 字节检查: cmd_dev stdout 直接写 tempfile(不经命令替换删尾换行), 按字节验证生产 stdout 自带恰好一个尾换行
_jbf="$(mktemp)"; _jbrc=0
MOCK_RST_DISPOSITION="moved"; MOCK_RST_DEST_PARENT="/ws/attic/sources"; MOCK_RST_PHASE=""; MOCK_RST_RC=0
MOCK_RST_SRCTREE="/ws/s"; MOCK_RST_SRCTREEBASE="/ws/s"
( cmd_dev --machine testm reset rbyte ) > "$_jbf" 2>/dev/null || _jbrc=$?
if [[ "$_jbrc" -eq 0 ]]; then
    python3 -c '
import json, sys
data = open(sys.argv[1], "rb").read()
assert data.endswith(b"\n") and data.count(b"\n") == 1, "trailing newline wrong: %r" % data
json.loads(data)
' "$_jbf" || _jbrc=1
fi
rm -f "$_jbf"
assert_eq "JSON 字节: 生产 stdout 恰好一个尾换行" "$_jbrc" "0"

assert_summary
