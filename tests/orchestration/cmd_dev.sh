#!/usr/bin/env bash
# tests/orchestration/cmd_dev.sh — cmd_dev 编排单测(mock devtool_search/devtool_modify_run/machine_state)。
# 覆盖: machine 前置(非TTY/无候选)、list 三态(missing 懒生成/stale/fresh)、modify(无recipe/已modify/setup失败/command失败)、
#       refresh、无子命令、porcelain(stdout 纯)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
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

assert_summary
