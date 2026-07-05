#!/usr/bin/env bash
# tests/unit/ports.sh — 端口/PID 检查单测(unit 层)。
# 覆盖 get_port_occupants / check_ports_available(exit 3)/ qemu_instance_is_alive。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

# --- get_port_occupants: mock ss ---
DB="$(mktemp -d)"; mkfake_bin "$DB" ss
stub_out "$DB" ss ""
out="$(with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"; get_port_occupants tcp 2222' _ "$OB")"
assert_eq "get_port_occupants empty" "$out" ""
stub_out "$DB" ss "LISTEN 0 128 0.0.0.0:2222 users:((\"sshd\",pid=1234,fd=3))"
out="$(with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"; get_port_occupants tcp 2222' _ "$OB")"
assert_contains "get_port_occupants occupied" "$out" "pid=1234"
rm -rf "$DB"

# --- check_ports_available: exit 函数,子进程捕获 ---
DB="$(mktemp -d)"; mkfake_bin "$DB" ss; stub_out "$DB" ss ""
# 无占用 → return 0(不 exit)
assert_rc 0 "ports all free" with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"; MACHINE=m; check_ports_available tcp 2222 tcp 2443' _ "$OB"
# 有占用 → exit 3
stub_out "$DB" ss "LISTEN users:((\"x\",pid=5,fd=3))"
assert_rc 3 "ports conflict exit 3" with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"; MACHINE=m; check_ports_available tcp 2222' _ "$OB"
rm -rf "$DB"

# --- qemu_instance_is_alive: /proc 真实进程 ---
qemu_instance_is_alive 99999999 qemu-system-arm romulus >/dev/null 2>&1; assert_eq "qemu_instance_is_alive exited rc" "$?" 1
qemu_instance_is_alive "$$" qemu-system-arm romulus >/dev/null 2>&1;       assert_eq "qemu_instance_is_alive recycled rc" "$?" 2

assert_summary
