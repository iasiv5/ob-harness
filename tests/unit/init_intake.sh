#!/usr/bin/env bash
# tests/unit/init_intake.sh — init_intake 单测(unit 层)。
# 覆盖 init 机器解析决策树三态(不依赖 PTY): ① empty 列表→3 / ② arg-fastpath(给定合法 machine,不 confirm)→0 /
#   ③ nontty(给定非法/空 machine + 非 TTY)→3。pick+confirm 的 cancel/ok 两态依赖真交互, 留 .exp(manual_matrix.exp)。
# mock 策略: 覆盖 list_available_machines/pick_machine/confirm_action/print_previously_initialized 为可控 stub;
#   nontty 态用 </dev/null(非 TTY) 触发 intake 内 [[ ! -t 0 ]]。
# leaf-pure: 函数 return 0/1/2/3(不 exit); exit_contract Y 静态守卫。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OPENBMC_DIR="$TMP/openbmc"; mkdir -p "$OPENBMC_DIR"; export OPENBMC_DIR
_err="$TMP/err"
rc=0

# mock 依赖(intake 消费的原语): 覆盖 ob_loader source 的同名函数。
# 安全边界: print_previously_initialized 必须 mock 为 no-op——真函数(repo.sh:402)走 nameref 且内部
#   调 machine_state_init_time/format_timestamp/machine_state_initialized_machines 等次级依赖(需真 workspace),
#   不 mock 会触达它们致 unit 失败; 同理 mock pick_machine/confirm_action 隔离交互与全局写入。
list_available_machines()      { printf '%s\n' "${MOCK_MACHINES[@]}"; }
print_previously_initialized() { :; }
pick_machine()                 { MACHINE="${MOCK_PICK_RESULT:-}"; return "${MOCK_PICK_RC:-0}"; }
confirm_action()               { return "${MOCK_CONFIRM_RC:-0}"; }

# ① empty: 列表空 → 3 + stderr 含 "No machines found"
MOCK_MACHINES=(); MACHINE=""; rc=0
init_intake 2>"$_err" || rc=$?
assert_eq "① empty rc=3" "$rc" "3"
assert_contains "① empty remedy" "$(cat "$_err")" "No machines found"

# ② arg-fastpath: 给定合法 machine → 0, 不调 pick/confirm(MOCK_PICK_RC 默认 0 但 fastpath 不应触达)
MOCK_MACHINES=(romulus witherspoon); MACHINE="romulus"; MOCK_PICK_RC=99 MOCK_CONFIRM_RC=99; rc=0
init_intake 2>"$_err" >/dev/null || rc=$?
assert_eq "② fastpath rc=0" "$rc" "0"
assert_eq "② MACHINE 保持 romulus" "$MACHINE" "romulus"

# ③ nontty: 给定非法 machine + 非 TTY(stdin=/dev/null) → 3 + stderr 含 "interactive terminal"
MOCK_MACHINES=(romulus); MACHINE="bogus"; rc=0
init_intake </dev/null 2>"$_err" || rc=$?
assert_eq "③ nontty rc=3" "$rc" "3"
assert_contains "③ nontty remedy" "$(cat "$_err")" "interactive terminal"

assert_summary
