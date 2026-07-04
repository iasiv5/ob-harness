#!/usr/bin/env bash
# tests/unit/qemu_instance_describe.sh — 实例四行显示 unit。
# 锁住读 PIDFILE_* 全局的统一格式(PID/Started/Ports/Serial),供 start↔stop 复用。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

PIDFILE_PID="12345"
PIDFILE_STARTED_AT="2026-07-04T01:02:03Z"
PIDFILE_SSH_PORT="2222"
PIDFILE_REDFISH_PORT="2443"
PIDFILE_IPMI_PORT="2623"
PIDFILE_SERIAL_LOG="/tmp/serial.log"

out=$(qemu_instance_describe)
assert_contains "has PID line"       "$out" "PID       : 12345"
assert_contains "has Started line"   "$out" "Started   : 2026-07-04T01:02:03Z"
assert_contains "has Ports line"     "$out" "SSH(2222) Redfish(2443) IPMI(2623/UDP)"
assert_contains "has Serial log line" "$out" "Serial log: /tmp/serial.log"
# 四行,无多余
line_count=$(printf '%s\n' "$out" | grep -c '')
assert_eq "exactly 4 lines" "$line_count" "4"

assert_summary
