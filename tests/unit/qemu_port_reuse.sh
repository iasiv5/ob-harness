#!/usr/bin/env bash
# tests/unit/qemu_port_reuse.sh — resolve_qemu_port_reuse leaf-pure 单测(unit 层)。
# 纯函数(4 argv → set QEMU_*_PORT)，无 stub。锁 cli_first(ADR-0022) + HTTP none sentinel + 恒 return 0 契约。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

reset_ports(){ QEMU_SSH_PORT=""; QEMU_REDFISH_PORT=""; QEMU_IPMI_PORT=""; QEMU_HTTP_PORT=""; }

# --- cli_first: CLI flag 压旧实例端口 ---
reset_ports; QEMU_SSH_PORT=9999
resolve_qemu_port_reuse 2222 2443 2623 none; rc=$?
assert_eq "恒 return 0 (CLI set 路径)" "$rc" 0
assert_eq "CLI wins over old (SSH)" "$QEMU_SSH_PORT" 9999

# --- 旧实例填空 CLI（restart 复用主路径）---
reset_ports
resolve_qemu_port_reuse 2222 2443 2623 none; rc=$?
assert_eq "恒 return 0 (旧实例填空路径)" "$rc" 0
assert_eq "old fills empty CLI (SSH)"    "$QEMU_SSH_PORT" 2222
assert_eq "old fills empty CLI (Redfish)" "$QEMU_REDFISH_PORT" 2443
assert_eq "old fills empty CLI (IPMI)"   "$QEMU_IPMI_PORT" 2623

# --- 两皆空 → 保持空 + rc=0（三条 numeric guard 亦全 false）---
reset_ports
resolve_qemu_port_reuse "" "" "" ""; rc=$?
assert_eq "恒 return 0 (全空路径)" "$rc" 0
assert_eq "both empty stays empty (SSH)" "$QEMU_SSH_PORT" ""

# --- HTTP none sentinel: rc=0 + HTTP 不注入（🔴1 主路径; set -e 裸调中止的回归点）---
reset_ports
resolve_qemu_port_reuse 2222 2443 2623 none; rc=$?
assert_eq "恒 return 0 (HTTP none sentinel 主路径)" "$rc" 0
assert_eq "HTTP none sentinel skipped" "$QEMU_HTTP_PORT" ""

# --- HTTP 旧值有效 + CLI 空 → 注入 ---
reset_ports
resolve_qemu_port_reuse 2222 2443 2623 8080; rc=$?
assert_eq "恒 return 0 (HTTP 注入路径)" "$rc" 0
assert_eq "HTTP old set, CLI empty → set" "$QEMU_HTTP_PORT" 8080

# --- HTTP cli_first: CLI 压旧值 ---
reset_ports; QEMU_HTTP_PORT=9000
resolve_qemu_port_reuse 2222 2443 2623 8080; rc=$?
assert_eq "恒 return 0 (HTTP CLI wins 路径)" "$rc" 0
assert_eq "HTTP CLI wins over old" "$QEMU_HTTP_PORT" 9000

assert_summary
