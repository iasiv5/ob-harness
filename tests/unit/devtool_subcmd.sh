#!/usr/bin/env bash
# tests/unit/devtool_subcmd.sh — dev_subcmd_* handler 单测（unit 层）。
# 用 stub 下游（devtool_status_run / dev_relay_result / dev_emit_status_jsonl）聚焦 handler 编排。
# outvar 形参名（_st_entries 等）是 handler 内 local，经 printf -v 写 caller（handler）作用域；
# stub 收到的 $N 是名字字符串，printf -v "$N" 动态作用域写 handler 的 local——outvar 名不与
# stub 内 local 同名即可（nameref 同名负向 case 不测，语义模糊，参考 devtool_pick.sh unit 免责）。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT

MACHINE="testm"
RELAY_CALLED=0

# stub 下游（重定义覆盖 lib 原函数）
devtool_status_run() {
    # $1=machine $2=build_dir $3=entries_outvar $4=stage_outvar $5=stderr_outvar
    printf -v "$3" '%s' "${MOCK_ENTRIES:-}"
    printf -v "$4" '%s' "${MOCK_STAGE:-command}"
    printf -v "$5" '%s' "${MOCK_STDERR:-}"
    return "${MOCK_RUN_RC:-0}"
}
dev_relay_result() {
    RELAY_CALLED=1
    return "${MOCK_RELAY_RC:-0}"
}
dev_emit_status_jsonl() {
    printf '%s\n' "${MOCK_EMIT_OUT:-[]}"
    return "${MOCK_EMIT_RC:-0}"
}

# === ① dry_run=1 → return 0 + stderr 含 [DRY-RUN] notice，relay 未被调 ===
RELAY_CALLED=0; _err="$(mktemp)"
dev_subcmd_status "$MACHINE" "$TMP/build" "" "" 1 2>"$_err" >/dev/null
rc=$?
assert_eq "① dry_run: return 0" "$rc" "0"
assert_contains "① dry_run: stderr 含 [DRY-RUN] notice" "$(cat "$_err")" "[DRY-RUN] ob dev status"
assert_eq "① dry_run: relay 未被调" "$RELAY_CALLED" "0"
rm -f "$_err"

# === ② entries 空（status 成功 + 无 modified）→ return 0 + relay 被调 + warn "No modified recipes" ===
MOCK_ENTRIES=""; MOCK_RUN_RC=0; MOCK_RELAY_RC=0; RELAY_CALLED=0; _err="$(mktemp)"
dev_subcmd_status "$MACHINE" "$TMP/build" "" "" 0 2>"$_err" >/dev/null
rc=$?
assert_eq "② empty entries: return 0（良性，非失败）" "$rc" "0"
assert_eq "② empty entries: relay 被调" "$RELAY_CALLED" "1"
assert_contains "② empty entries: warn No modified recipes" "$(cat "$_err")" "No modified recipes"
rm -f "$_err"

# === ③ relay 返回 1 → handler return 1 ===
MOCK_ENTRIES="nonempty"; MOCK_RUN_RC=0; MOCK_RELAY_RC=1; RELAY_CALLED=0
dev_subcmd_status "$MACHINE" "$TMP/build" "" "" 0 >/dev/null 2>&1
rc=$?
assert_eq "③ relay rc=1: handler return 1" "$rc" "1"
assert_eq "③ relay rc=1: relay 被调" "$RELAY_CALLED" "1"

# === ④ emit 返回 1 → handler return 1（relay 已过，emit 失败） ===
MOCK_ENTRIES="nonempty"; MOCK_RUN_RC=0; MOCK_RELAY_RC=0; MOCK_EMIT_RC=1; RELAY_CALLED=0
dev_subcmd_status "$MACHINE" "$TMP/build" "" "" 0 >/dev/null 2>&1
rc=$?
assert_eq "④ emit rc=1: handler return 1" "$rc" "1"

# === ⑤ 正常 → return 0 + stdout = emit 输出（emit JSONL 透传） ===
MOCK_ENTRIES="nonempty"; MOCK_RUN_RC=0; MOCK_RELAY_RC=0; MOCK_EMIT_RC=0
MOCK_EMIT_OUT='{"recipe":"x","srctree":"/p"}'; RELAY_CALLED=0
_out="$(mktemp)"; _err="$(mktemp)"
dev_subcmd_status "$MACHINE" "$TMP/build" "" "" 0 >"$_out" 2>"$_err"
rc=$?
out="$(cat "$_out")"
assert_eq "⑤ 正常: return 0" "$rc" "0"
assert_eq "⑤ 正常: relay 被调" "$RELAY_CALLED" "1"
assert_eq "⑤ 正常: stdout = emit 输出" "$out" '{"recipe":"x","srctree":"/p"}'
rm -f "$_out" "$_err"

assert_summary
