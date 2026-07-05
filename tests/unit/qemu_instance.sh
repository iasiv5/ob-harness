#!/usr/bin/env bash
# tests/unit/qemu_instance.sh — QEMU instance module 单测（hermetic）。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WORKSPACE_DIR="$TMP/workspace"
PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
mkdir -p "$PIDS_DIR"
# 造两个实例 PID 文件
printf 'pid=111\nbinary=qemu-system-arm\nmachine=romulus\nssh_port=2222\nredfish_port=2443\nipmi_port=2623\n' > "$PIDS_DIR/romulus.pid"
printf 'pid=222\nmachine=witherspoon\n' > "$PIDS_DIR/witherspoon.pid"

# --- qemu_instance_list ---
out="$(qemu_instance_list | sort)"
assert_eq "list returns all machines" "$out" "romulus
witherspoon"

# --- qemu_instance_load（Task 7 关键接口：接 machine 设路径 + 读字段；无参兼容 caller 的 QEMU_PID_FILE）---
qemu_instance_load romulus
assert_eq "load sets pid" "$PIDFILE_PID" "111"
assert_eq "load sets machine" "$PIDFILE_MACHINE" "romulus"
assert_eq "load sets pid file path" "$QEMU_PID_FILE" "$PIDS_DIR/romulus.pid"
QEMU_PID_FILE="$PIDS_DIR/witherspoon.pid"
qemu_instance_load
assert_eq "load no-arg keeps compatibility" "$PIDFILE_MACHINE" "witherspoon"

# 空目录
rm -f "$PIDS_DIR"/*.pid
out="$(qemu_instance_list)"
assert_eq "list empty when no pids" "$out" ""

# --- qemu_instance_summarize_full（合并自 qemu_instance_describe.sh）---
PIDFILE_PID="12345"; PIDFILE_STARTED_AT="2026-07-04T01:02:03Z"
PIDFILE_SSH_PORT="2222"; PIDFILE_REDFISH_PORT="2443"; PIDFILE_IPMI_PORT="2623"
PIDFILE_SERIAL_LOG="/tmp/serial.log"
out="$(qemu_instance_summarize_full)"
assert_contains "full has PID line"     "$out" "PID       : 12345"
assert_contains "full has Ports line"   "$out" "SSH(2222) Redfish(2443) IPMI(2623/UDP)"
assert_contains "full has Serial line"  "$out" "Serial log: /tmp/serial.log"

assert_summary
