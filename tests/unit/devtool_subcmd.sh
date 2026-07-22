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
devtool_search_refresh() {
    # $1=machine $2=build_dir $3=stage_outvar $4=stderr_outvar
    printf -v "$3" '%s' "${MOCK_R_STAGE:-tinfoil}"
    printf -v "$4" '%s' "${MOCK_R_STDERR:-}"
    return "${MOCK_REFRESH_RC:-0}"
}
devtool_modify_run() {
    # $1=machine $2=build_dir $3=recipe $4=srctree_outvar $5=stage_outvar $6=stderr_outvar
    printf -v "$4" '%s' "${MOCK_SRCTREE:-/src/x}"
    printf -v "$5" '%s' "${MOCK_M_STAGE:-command}"
    printf -v "$6" '%s' "${MOCK_M_STDERR:-}"
    return "${MOCK_MODIFY_RC:-0}"
}
devtool_build_run() {
    # $1=machine $2=build_dir $3=recipe $4=stage_outvar $5=stderr_outvar $6=notmod_outvar
    printf -v "$4" '%s' "${MOCK_B_STAGE:-command}"
    printf -v "$5" '%s' "${MOCK_B_STDERR:-}"
    printf -v "$6" '%s' "${MOCK_B_NOTMOD:-0}"
    return "${MOCK_BUILD_RC:-0}"
}
devtool_reset_run() {
    # $1=machine $2=build_dir $3=recipe $4=srctree $5=srctreebase $6=disposition
    # $7=dest_parent $8=cleaned_bbappend $9=phase $10=stage $11=stderr
    printf -v "$4"  '%s' "${MOCK_RS_SRCTREE:-/src}"
    printf -v "$5"  '%s' "${MOCK_RS_SRCTREEBASE:-/srcbase}"
    printf -v "$6"  '%s' "${MOCK_RS_DISP:-moved}"
    printf -v "$7"  '%s' "${MOCK_RS_DEST_PARENT:-/attic}"
    printf -v "$8"  '%s' "${MOCK_RS_CLEANED:-}"
    printf -v "$9"  '%s' "${MOCK_RS_PHASE:-}"
    printf -v "${10}" '%s' "${MOCK_RS_STAGE:-command}"
    printf -v "${11}" '%s' "${MOCK_RS_STDERR:-}"
    return "${MOCK_RESET_RC:-0}"
}
dev_emit_reset_json() {
    local _d='{"recipe":"x"}'
    printf '%s\n' "${MOCK_EMIT_RESET_OUT:-$_d}"
    return "${MOCK_EMIT_RESET_RC:-0}"
}
devtool_finish_run() {
    # $1=machine $2=build_dir $3=recipe $4=srctree $5=srctreebase $6=disposition
    # $7=dest_parent $8=cleaned_bbappend $9=landing_mode $10=landing_layer $11=patches
    # $12=recipe_files $13=srcrev $14=phase $15=stage $16=stderr
    printf -v "$4"  '%s' "${MOCK_F_SRCTREE:-/src}"
    printf -v "$5"  '%s' "${MOCK_F_SRCTREEBASE:-/srcbase}"
    printf -v "$6"  '%s' "${MOCK_F_DISP:-moved}"
    printf -v "$7"  '%s' "${MOCK_F_DEST_PARENT:-/attic}"
    printf -v "$8"  '%s' "${MOCK_F_CLEANED:-}"
    printf -v "$9"  '%s' "${MOCK_F_LMODE:-patch}"
    printf -v "${10}" '%s' "${MOCK_F_LLAYER:-/layer}"
    printf -v "${11}" '%s' "${MOCK_F_PATCHES:-[]}"
    printf -v "${12}" '%s' "${MOCK_F_RFILES:-[]}"
    printf -v "${13}" '%s' "${MOCK_F_SREV:-abc}"
    printf -v "${14}" '%s' "${MOCK_F_PHASE:-}"
    printf -v "${15}" '%s' "${MOCK_F_STAGE:-command}"
    printf -v "${16}" '%s' "${MOCK_F_STDERR:-}"
    return "${MOCK_FINISH_RC:-0}"
}
dev_emit_finish_json() {
    local _d='{"recipe":"x","landing_mode":"patch"}'
    printf '%s\n' "${MOCK_EMIT_FINISH_OUT:-$_d}"
    return "${MOCK_EMIT_FINISH_RC:-0}"
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

# ========== refresh handler ==========
# === ⑥ refresh dry_run → return 0 + stderr 含 [DRY-RUN]，refresh 未被调 ===
MOCK_REFRESH_RC=0; _err="$(mktemp)"
dev_subcmd_refresh "$MACHINE" "$TMP/build" "" "" 1 2>"$_err" >/dev/null
rc=$?
assert_eq "⑥ refresh dry_run: return 0" "$rc" "0"
assert_contains "⑥ refresh dry_run: stderr 含 [DRY-RUN]" "$(cat "$_err")" "[DRY-RUN] ob dev refresh"
rm -f "$_err"

# === ⑦ refresh rc≠0 → return 1 + stderr 含 "failed (stage=...)" ===
MOCK_REFRESH_RC=1; MOCK_R_STAGE="tinfoil"; _err="$(mktemp)"
dev_subcmd_refresh "$MACHINE" "$TMP/build" "" "" 0 2>"$_err" >/dev/null
rc=$?
assert_eq "⑦ refresh rc=1: return 1" "$rc" "1"
assert_contains "⑦ refresh rc=1: stderr 含 failed" "$(cat "$_err")" "failed (stage=tinfoil)"
rm -f "$_err"

# === ⑧ refresh 正常 → return 0 + stdout 空 ===
MOCK_REFRESH_RC=0; _out="$(mktemp)"; _err="$(mktemp)"
dev_subcmd_refresh "$MACHINE" "$TMP/build" "" "" 0 >"$_out" 2>"$_err"
rc=$?
assert_eq "⑧ refresh 正常: return 0" "$rc" "0"
assert_eq "⑧ refresh 正常: stdout 空" "$(cat "$_out")" ""
rm -f "$_out" "$_err"

# ========== modify handler ==========
# === ⑨ modify recipe 空 → return 3 + stderr remedy "list [pattern]" ===
_err="$(mktemp)"
dev_subcmd_modify "$MACHINE" "$TMP/build" "" "" 0 2>"$_err" >/dev/null
rc=$?
assert_eq "⑨ modify recipe 空: return 3" "$rc" "3"
assert_contains "⑨ modify recipe 空: remedy list [pattern]" "$(cat "$_err")" "list [pattern]"
rm -f "$_err"

# === ⑩ modify dry_run（recipe 非空）→ return 0 + stderr [DRY-RUN] ===
_err="$(mktemp)"
dev_subcmd_modify "$MACHINE" "$TMP/build" "x" "" 1 2>"$_err" >/dev/null
rc=$?
assert_eq "⑩ modify dry_run: return 0" "$rc" "0"
assert_contains "⑩ modify dry_run: stderr [DRY-RUN]" "$(cat "$_err")" "[DRY-RUN] ob dev modify"
rm -f "$_err"

# === ⑪ modify relay rc=1 → return 1 ===
MOCK_MODIFY_RC=0; MOCK_RELAY_RC=1; RELAY_CALLED=0
dev_subcmd_modify "$MACHINE" "$TMP/build" "x" "" 0 >/dev/null 2>&1
rc=$?
assert_eq "⑪ modify relay rc=1: return 1" "$rc" "1"

# === ⑫ modify 正常 → return 0 + stdout = srctree ===
MOCK_MODIFY_RC=0; MOCK_RELAY_RC=0; MOCK_SRCTREE="/src/phosphor"; RELAY_CALLED=0
_out="$(mktemp)"; _err="$(mktemp)"
dev_subcmd_modify "$MACHINE" "$TMP/build" "x" "" 0 >"$_out" 2>"$_err"
rc=$?
assert_eq "⑫ modify 正常: return 0" "$rc" "0"
assert_eq "⑫ modify 正常: stdout = srctree" "$(cat "$_out")" "/src/phosphor"
rm -f "$_out" "$_err"

# ========== build handler（D5 not_mod 冻结） ==========
# === ⑬ build recipe 空 → return 3 + remedy "status"（list modified recipes）===
_err="$(mktemp)"
dev_subcmd_build "$MACHINE" "$TMP/build" "" "" 0 2>"$_err" >/dev/null
rc=$?
assert_eq "⑬ build recipe 空: return 3" "$rc" "3"
assert_contains "⑬ build recipe 空: remedy status" "$(cat "$_err")" "list modified recipes"
rm -f "$_err"

# === ⑭ build dry_run → return 0 + stderr [DRY-RUN] ===
_err="$(mktemp)"
dev_subcmd_build "$MACHINE" "$TMP/build" "x" "" 1 2>"$_err" >/dev/null
rc=$?
assert_eq "⑭ build dry_run: return 0" "$rc" "0"
assert_contains "⑭ build dry_run: stderr [DRY-RUN]" "$(cat "$_err")" "[DRY-RUN] ob dev build"
rm -f "$_err"

# === ⑮ build not_mod（stub notmod=1 + run rc=0）→ return 3 + relay 未被调（D5 核心锁）===
MOCK_BUILD_RC=0; MOCK_B_NOTMOD=1; MOCK_B_STDERR="some build stderr"; RELAY_CALLED=0; _err="$(mktemp)"
dev_subcmd_build "$MACHINE" "$TMP/build" "x" "" 0 2>"$_err" >/dev/null
rc=$?
assert_eq "⑮ build not_mod: return 3" "$rc" "3"
assert_eq "⑮ build not_mod: relay 未被调(D5 锁)" "$RELAY_CALLED" "0"
assert_contains "⑮ build not_mod: stderr not modified" "$(cat "$_err")" "not modified"
rm -f "$_err"

# === ⑯ build relay rc=1 → return 1 ===
MOCK_BUILD_RC=0; MOCK_B_NOTMOD=0; MOCK_RELAY_RC=1; RELAY_CALLED=0
dev_subcmd_build "$MACHINE" "$TMP/build" "x" "" 0 >/dev/null 2>&1
rc=$?
assert_eq "⑯ build relay rc=1: return 1" "$rc" "1"

# === ⑰ build 正常 → return 0 + stdout 空 ===
MOCK_BUILD_RC=0; MOCK_B_NOTMOD=0; MOCK_RELAY_RC=0; RELAY_CALLED=0
_out="$(mktemp)"; _err="$(mktemp)"
dev_subcmd_build "$MACHINE" "$TMP/build" "x" "" 0 >"$_out" 2>"$_err"
rc=$?
assert_eq "⑰ build 正常: return 0" "$rc" "0"
assert_eq "⑰ build 正常: stdout 空" "$(cat "$_out")" ""
rm -f "$_out" "$_err"

# ========== reset handler ==========
# === ⑱ reset recipe 空 → return 3 + remedy "list [pattern]" ===
_err="$(mktemp)"
dev_subcmd_reset "$MACHINE" "$TMP/build" "" "" 0 2>"$_err" >/dev/null
rc=$?
assert_eq "⑱ reset recipe 空: return 3" "$rc" "3"
assert_contains "⑱ reset recipe 空: remedy list" "$(cat "$_err")" "list [pattern]"
rm -f "$_err"

# === ⑲ reset dry_run → return 0 + stderr [DRY-RUN] ===
_err="$(mktemp)"
dev_subcmd_reset "$MACHINE" "$TMP/build" "x" "" 1 2>"$_err" >/dev/null
rc=$?
assert_eq "⑲ reset dry_run: return 0" "$rc" "0"
assert_contains "⑲ reset dry_run: stderr [DRY-RUN]" "$(cat "$_err")" "[DRY-RUN] ob dev reset"
rm -f "$_err"

# === ⑳ reset relay rc=1 → return 1 ===
MOCK_RESET_RC=0; MOCK_RELAY_RC=1; RELAY_CALLED=0
dev_subcmd_reset "$MACHINE" "$TMP/build" "x" "" 0 >/dev/null 2>&1
rc=$?
assert_eq "⑳ reset relay rc=1: return 1" "$rc" "1"

# === ㉑ reset emit rc=1 → return 1 ===
MOCK_RESET_RC=0; MOCK_RELAY_RC=0; MOCK_EMIT_RESET_RC=1; RELAY_CALLED=0
dev_subcmd_reset "$MACHINE" "$TMP/build" "x" "" 0 >/dev/null 2>&1
rc=$?
assert_eq "㉑ reset emit rc=1: return 1" "$rc" "1"

# === ㉒ reset 正常 → return 0 + stdout = emit 输出 ===
MOCK_RESET_RC=0; MOCK_RELAY_RC=0; MOCK_EMIT_RESET_RC=0; MOCK_EMIT_RESET_OUT='{"recipe":"x","disposition":"moved"}'; RELAY_CALLED=0
_out="$(mktemp)"; _err="$(mktemp)"
dev_subcmd_reset "$MACHINE" "$TMP/build" "x" "" 0 >"$_out" 2>"$_err"
rc=$?
assert_eq "㉒ reset 正常: return 0" "$rc" "0"
assert_eq "㉒ reset 正常: stdout = emit 输出" "$(cat "$_out")" '{"recipe":"x","disposition":"moved"}'
rm -f "$_out" "$_err"

# ========== finish handler ==========
# === ㉓ finish recipe 空 → return 3 + remedy "status"（list modified recipes）===
_err="$(mktemp)"
dev_subcmd_finish "$MACHINE" "$TMP/build" "" "" 0 2>"$_err" >/dev/null
rc=$?
assert_eq "㉓ finish recipe 空: return 3" "$rc" "3"
assert_contains "㉓ finish recipe 空: remedy status" "$(cat "$_err")" "list modified recipes"
rm -f "$_err"

# === ㉔ finish dry_run → return 0 + stderr [DRY-RUN] ===
_err="$(mktemp)"
dev_subcmd_finish "$MACHINE" "$TMP/build" "x" "" 1 2>"$_err" >/dev/null
rc=$?
assert_eq "㉔ finish dry_run: return 0" "$rc" "0"
assert_contains "㉔ finish dry_run: stderr [DRY-RUN]" "$(cat "$_err")" "[DRY-RUN] ob dev finish"
rm -f "$_err"

# === ㉕ finish relay rc=1 → return 1 ===
MOCK_FINISH_RC=0; MOCK_RELAY_RC=1; RELAY_CALLED=0
dev_subcmd_finish "$MACHINE" "$TMP/build" "x" "" 0 >/dev/null 2>&1
rc=$?
assert_eq "㉕ finish relay rc=1: return 1" "$rc" "1"

# === ㉖ finish emit rc=1 → return 1 ===
MOCK_FINISH_RC=0; MOCK_RELAY_RC=0; MOCK_EMIT_FINISH_RC=1; RELAY_CALLED=0
dev_subcmd_finish "$MACHINE" "$TMP/build" "x" "" 0 >/dev/null 2>&1
rc=$?
assert_eq "㉖ finish emit rc=1: return 1" "$rc" "1"

# === ㉗ finish 正常 → return 0 + stdout = emit 输出 ===
MOCK_FINISH_RC=0; MOCK_RELAY_RC=0; MOCK_EMIT_FINISH_RC=0; MOCK_EMIT_FINISH_OUT='{"recipe":"x","landing_mode":"patch"}'; RELAY_CALLED=0
_out="$(mktemp)"; _err="$(mktemp)"
dev_subcmd_finish "$MACHINE" "$TMP/build" "x" "" 0 >"$_out" 2>"$_err"
rc=$?
assert_eq "㉗ finish 正常: return 0" "$rc" "0"
assert_eq "㉗ finish 正常: stdout = emit 输出" "$(cat "$_out")" '{"recipe":"x","landing_mode":"patch"}'
rm -f "$_out" "$_err"

assert_summary
