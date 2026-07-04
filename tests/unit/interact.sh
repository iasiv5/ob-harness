#!/usr/bin/env bash
# tests/unit/interact.sh — 交互叶子函数单测(unit 层,stdin 喂入)。
# 覆盖 confirm_action / exit_on_user_cancel / prompt_for_absolute_path / prompt_for_available_port。
# 依据:这些函数只 read stdin、不自检 TTY(TTY gate 在调用方 cmd_* 的 [[ -t 0 ]]),
#       故 here-string 喂入即可驱动分支逻辑(在当前 shell,全局可见)。
# caution: here-string 喂足输入行;无效分支会 loop 重读,须喂够行数。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

# --- confirm_action ---
confirm_action init m <<< $'y\n' >/dev/null 2>&1;     assert_eq "confirm y rc" "$?" 0
confirm_action init m <<< $'n\n' >/dev/null 2>&1;     assert_eq "confirm n rc" "$?" 2
confirm_action init m <<< $'x\ny\n' >/dev/null 2>&1;  assert_eq "confirm invalid then y rc" "$?" 0

# --- exit_on_user_cancel: 消费 pick_machine/confirm_action 的 rc ---
# 会 exit,用 $(...) 子 shell 跑,父 shell 捕 $?;函数已由 ob_loader source 进当前 shell。
out=$( exit_on_user_cancel 0 "Build" ); assert_eq "exit rc0 returns 0" "$?" 0
out=$( exit_on_user_cancel 2 "Build" ); assert_eq "exit rc2 exits 2" "$?" 2
assert_contains "exit rc2 cancel msg" "$out" "Build cancelled by user."
out=$( exit_on_user_cancel 1 "Build" ); assert_eq "exit rc1 exits 1" "$?" 1

# --- prompt_for_absolute_path ---
PROMPT_PATH_RESULT=""
prompt_for_absolute_path "p" <<< $'/foo\n' >/dev/null 2>&1; assert_eq "prompt abs rc" "$?" 0
assert_eq "prompt abs result" "$PROMPT_PATH_RESULT" "/foo"
# 非绝对路径 → 重试,再喂有效值
PROMPT_PATH_RESULT=""
prompt_for_absolute_path "p" <<< $'relpath\n/bar\n' >/dev/null 2>&1; assert_eq "prompt non-abs retry rc" "$?" 0
assert_eq "prompt non-abs result" "$PROMPT_PATH_RESULT" "/bar"

# --- prompt_for_available_port: stub ss 空占用 → 端口空闲 return 0 ---
DB="$(mktemp -d)"; mkfake_bin "$DB" ss; stub_out "$DB" ss ""
assert_rc 0 "port free returns 0" with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"; MYPORT=2222; prompt_for_available_port MYPORT svc tcp </dev/null' _ "$OB"
rm -rf "$DB"

assert_summary
