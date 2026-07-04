#!/usr/bin/env bash
# tests/unit/pick_machine.sh — pick_machine 契约单测(unit 层,here-string 喂 stdin)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

__pick_test_list() { printf '%s\n' romulus witherspoon; }

# 数字选择
MACHINE=""; pick_machine __pick_test_list Build <<< $'1\n' >/dev/null 2>&1; assert_eq "number 1 rc" "$?" 0
assert_eq "number 1 MACHINE" "$MACHINE" "romulus"
MACHINE=""; pick_machine __pick_test_list Build <<< $'2\n' >/dev/null 2>&1; assert_eq "number 2 rc" "$?" 0
assert_eq "number 2 MACHINE" "$MACHINE" "witherspoon"
# 名字选择(exact match)
MACHINE=""; pick_machine __pick_test_list Build <<< $'witherspoon\n' >/dev/null 2>&1; assert_eq "name rc" "$?" 0
assert_eq "name MACHINE" "$MACHINE" "witherspoon"
# cancel(0)
MACHINE=""; pick_machine __pick_test_list Build <<< $'0\n' >/dev/null 2>&1; assert_eq "cancel rc" "$?" 2
# read 失败(EOF/非TTY) → 打印 error + return 1（遵 select_from_list 旧约定：L3 helper 自打 read-fail error，exit_on_user_cancel 只 exit）
MACHINE=""; pick_machine __pick_test_list Build </dev/null >/dev/null 2>&1; assert_eq "eof read-fail rc" "$?" 1
# 越界/非法 → 重试后有效
MACHINE=""; pick_machine __pick_test_list Build <<< $'9\nfoo\nromulus\n' >/dev/null 2>&1; assert_eq "invalid then valid rc" "$?" 0
assert_eq "invalid then valid MACHINE" "$MACHINE" "romulus"

assert_summary
