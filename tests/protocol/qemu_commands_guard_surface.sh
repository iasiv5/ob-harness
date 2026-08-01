#!/usr/bin/env bash
# tests/protocol/qemu_commands_guard_surface.sh — cmd_start_qemu 走 guard / cmd_deploy_to_qemu 走 seam 结构回归锁。
# 防回潮: cmd_start_qemu 的 machine-selection 序言经 machine_selection_guard(empty/nontty/ok 三态);
# cmd_deploy_to_qemu 经 resolve_command_machine(ADR-0019, 不再直调 guard); 两段都不再手写 ${#machines[@]} empty 检测。
# cmd_stop_qemu 不在此锁(语义不兼容, D1)。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QCMDS="$ROOT/lib/qemu_commands.sh"
test -f "$QCMDS" || { echo "MISSING $QCMDS" >&2; exit 1; }

# 取函数段(cmd_start_qemu 到 cmd_stop_qemu; cmd_deploy_to_qemu 到文件尾)
start_seg="$(sed -n '/^cmd_start_qemu()/,/^cmd_stop_qemu()/p' "$QCMDS")"
deploy_seg="$(sed -n '/^cmd_deploy_to_qemu()/,$p' "$QCMDS")"

# required: start_qemu 直调 machine_selection_guard; deploy 经 resolve_command_machine(ADR-0019)
assert_true "cmd_start_qemu calls machine_selection_guard"   grep -Fq 'machine_selection_guard' <<< "$start_seg"
assert_true "cmd_deploy_to_qemu calls resolve_command_machine" grep -Fq 'resolve_command_machine' <<< "$deploy_seg"
# forbidden: 两段不再手写 ${#machines[@]} empty 检测(empty 判定已归 guard/seam)
assert_false "cmd_start_qemu drops handwritten empty check"   grep -Fq '${#machines[@]}' <<< "$start_seg"
assert_false "cmd_deploy_to_qemu drops handwritten empty check" grep -Fq '${#machines[@]}' <<< "$deploy_seg"
assert_summary
