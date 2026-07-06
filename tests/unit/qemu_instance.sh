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

# load 无参且未设 QEMU_PID_FILE → 防御性 return 1（不靠 set -u 中止）
unset QEMU_PID_FILE
qemu_instance_load
assert_eq "load no-arg without QEMU_PID_FILE returns 1" "$?" "1"

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

# --- qemu_instance_summarize_brief ---
# 路径 A: stale（pid 不在 /proc）
printf 'pid=99999999\nbinary=qemu-system-arm\nmachine=romulus\nssh_port=2222\nredfish_port=2443\nipmi_port=2623\n' > "$PIDS_DIR/romulus.pid"
out="$(qemu_instance_summarize_brief romulus)"
assert_contains "brief stale marks stale" "$out" "⚠️ stale"
assert_contains "brief stale has ports"   "$out" "SSH(2222) Redfish(2443) IPMI(2623/UDP)"
assert_false "brief excludes machine name (caller lays out)" grep -q "romulus" <<< "$out"

# 路径 B: running（stub 放子 shell,不污染父 shell 的真实 is_alive——unset -f 是删除不是恢复,
# 父 shell 若被污染会让路径 C 的 recycled 判断假绿）
out="$(qemu_instance_is_alive() { return 0; }; qemu_instance_summarize_brief romulus)"
assert_contains "brief running marks running" "$out" "✅ running"

# 路径 C: recycled（pid=$$ 测试进程存在,但 cmdline 不匹配 qemu binary/machine → is_alive 返 2 → stale）
printf 'pid=%s\nbinary=qemu-system-arm\nmachine=recyc\nssh_port=2222\nredfish_port=2443\nipmi_port=2623\n' "$$" > "$PIDS_DIR/recyc.pid"
out="$(qemu_instance_summarize_brief recyc)"
assert_contains "brief recycled marks stale" "$out" "⚠️ stale"

# 路径 D: load 失败（PID 文件不存在/race）→ 视作 stale（不显示空行）
rm -f "$PIDS_DIR/nonexist.pid"
out="$(qemu_instance_summarize_brief nonexist)"
assert_contains "brief load-fail marks stale" "$out" "⚠️ stale"

# --- qemu_instance_clean_stale ---
printf 'pid=99999999\nmachine=romulus\n' > "$PIDS_DIR/romulus.pid"
[[ -f "$PIDS_DIR/romulus.pid" ]] || { echo "fixture missing"; exit 1; }
qemu_instance_clean_stale romulus
assert_false "clean_stale removes pid file" test -f "$PIDS_DIR/romulus.pid"
# 不存在时也恒返回 0（best-effort；不能用 cmd && assert，set +e 下 cmd 失败不记 failure）
qemu_instance_clean_stale nonexistent
assert_eq "clean_stale idempotent rc" "$?" "0"

assert_summary
