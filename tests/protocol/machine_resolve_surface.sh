#!/usr/bin/env bash
# tests/protocol/machine_resolve_surface.sh — command machine resolution interface-shrink 回归锁。
# 防回潮(ADR-0019): cmd_build/cmd_dev/cmd_deploy_to_qemu 的 machine 解析必须经 resolve_command_machine,
# 不再内联 machine_selection_guard + pick_machine + machine_state_is_initialized 组合 ritual(bestpractice_10 形态 A)。
# cmd_start_qemu 不在此锁(image-ready 协议维持 inline, ADR-0019 scope); cmd_stop_qemu 选 running instance、不经 guard。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_SH="$ROOT/lib/commands.sh"
QEMU_COMMANDS_SH="$ROOT/lib/qemu_commands.sh"
test -f "$COMMANDS_SH"      || { echo "MISSING $COMMANDS_SH" >&2; exit 1; }
test -f "$QEMU_COMMANDS_SH" || { echo "MISSING $QEMU_COMMANDS_SH" >&2; exit 1; }

# 提取单个函数体(从 ^name() 到下一个 ^func() 定义), 对照 qemu_launch_profile_structure.sh。
extract_fn() {
    local file="$1" fn="$2"
    awk -v fn="$fn" '
        BEGIN { in_fn = 0 }
        $0 ~ "^" fn "[(][)] [{$]" || $0 ~ "^" fn "[(][)]$" { in_fn = 1; print; next }
        in_fn && $0 ~ "^[A-Za-z_][A-Za-z0-9_]*[(][)] [{$]" { in_fn = 0; exit }
        in_fn { print }
    ' "$file"
}

build_seg="$(extract_fn  "$COMMANDS_SH"      cmd_build)"
dev_seg="$(extract_fn    "$COMMANDS_SH"      cmd_dev)"
deploy_seg="$(extract_fn "$QEMU_COMMANDS_SH" cmd_deploy_to_qemu)"

# 提取非空守卫(防函数名漂移致静默空通过 → forbidden 假绿)
assert_true "extracted cmd_build body"        test -n "$build_seg"
assert_true "extracted cmd_dev body"          test -n "$dev_seg"
assert_true "extracted cmd_deploy_to_qemu body" test -n "$deploy_seg"

# required: 三段都经 resolve_command_machine(锁实际调用次数=1, 用调用形 'resolve_command_machine machine_state_initialized_machines' 避注释干扰)
assert_eq "cmd_build resolve_command_machine calls"        "$(grep -Fc 'resolve_command_machine machine_state_initialized_machines' <<< "$build_seg")" 1
assert_eq "cmd_dev resolve_command_machine calls"          "$(grep -Fc 'resolve_command_machine machine_state_initialized_machines' <<< "$dev_seg")" 1
assert_eq "cmd_deploy_to_qemu resolve_command_machine calls" "$(grep -Fc 'resolve_command_machine machine_state_initialized_machines' <<< "$deploy_seg")" 1

# forbidden: 三段不再内联 machine-selection ritual(guard + pick + is_initialized), interface-shrink
for sym in machine_selection_guard pick_machine machine_state_is_initialized; do
    assert_false "cmd_build drops inline $sym"           grep -Fq "$sym" <<< "$build_seg"
    assert_false "cmd_dev drops inline $sym"             grep -Fq "$sym" <<< "$dev_seg"
    assert_false "cmd_deploy_to_qemu drops inline $sym"  grep -Fq "$sym" <<< "$deploy_seg"
done

assert_summary
