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
# 渲染序号+名字表（read -p 的 prompt 非 tty 不输出，prompt 文案契约改由 ob_check lint 静态守）
_pmt_out=$(pick_machine __pick_test_list "Build" <<< $'0\n' 2>&1)
assert_contains "渲染序号+名字表" "$_pmt_out" "1) romulus"
# post-list-msg（可选第三参数）：列表后、提示词前打印 caller 上下文
_plm_out=$(pick_machine __pick_test_list "init" "PREV_MARKER" <<< $'0\n' 2>&1)
assert_contains "post-list-msg 打印" "$_plm_out" "PREV_MARKER"
# 不传第三参数时正常工作（向后兼容）
MACHINE=""; pick_machine __pick_test_list Build <<< $'1\n' >/dev/null 2>&1; assert_eq "无 post-list-msg 兼容" "$?" 0

# read_machine_choice（caller 自渲染列表时复用 read 循环；cmd_stop_qemu 用）
__rmc_test=(romulus witherspoon)
MACHINE=""; read_machine_choice 2 "Stop QEMU" __rmc_test <<< $'1\n' >/dev/null 2>&1; assert_eq "read_choice number rc" "$?" 0
assert_eq "read_choice number MACHINE" "$MACHINE" "romulus"
MACHINE=""; read_machine_choice 2 "Stop QEMU" __rmc_test <<< $'witherspoon\n' >/dev/null 2>&1; assert_eq "read_choice name rc" "$?" 0
assert_eq "read_choice name MACHINE" "$MACHINE" "witherspoon"
MACHINE=""; read_machine_choice 2 "Stop QEMU" __rmc_test <<< $'0\n' >/dev/null 2>&1; assert_eq "read_choice cancel rc" "$?" 2
# read 失败(EOF/非TTY) → 打印 error + return 1（遵 select_from_list 旧约定：L3 helper 自打 read-fail error，exit_on_user_cancel 只 exit）
MACHINE=""; pick_machine __pick_test_list Build </dev/null >/dev/null 2>&1; assert_eq "eof read-fail rc" "$?" 1
# 越界/非法 → 重试后有效
MACHINE=""; pick_machine __pick_test_list Build <<< $'9\nfoo\nromulus\n' >/dev/null 2>&1; assert_eq "invalid then valid rc" "$?" 0
assert_eq "invalid then valid MACHINE" "$MACHINE" "romulus"

# === read_list_choice: 参数化 noun/verb 的索引选择 ===
# caller 数组名用 _rlc_data(避开 helper 内部 nameref _rlc_items/_rlc_sel, 防 nameref 同名遮蔽 circular)
RLC_SEL=""
_rlc_data=("ipmi-host" "bmcweb")
read_list_choice 2 "recipe" "reset" _rlc_data RLC_SEL <<< $'1\n' >/dev/null 2>&1
assert_eq "read_list_choice 数字选中 rc" "$?" "0"
assert_eq "read_list_choice 数字选中值" "$RLC_SEL" "ipmi-host"
RLC_SEL=""; read_list_choice 2 "recipe" "reset" _rlc_data RLC_SEL <<< $'bmcweb\n' >/dev/null 2>&1
assert_eq "read_list_choice 名字选中 rc" "$?" "0"
assert_eq "read_list_choice 名字选中值" "$RLC_SEL" "bmcweb"
RLC_SEL=""; read_list_choice 2 "recipe" "reset" _rlc_data RLC_SEL <<< $'0\n' >/dev/null 2>&1
assert_eq "read_list_choice cancel rc" "$?" "2"
# 非法输入(越界数字 + 不存在名字)后重试, 最终合法选中
RLC_SEL=""; read_list_choice 2 "recipe" "reset" _rlc_data RLC_SEL <<< $'9\nbadname\n1\n' >/dev/null 2>&1
assert_eq "read_list_choice 非法重试后选中 rc" "$?" "0"
assert_eq "read_list_choice 非法重试后选中值" "$RLC_SEL" "ipmi-host"

assert_summary
