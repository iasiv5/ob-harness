#!/usr/bin/env bash
# tests/unit/qemu_manifest.sh — QEMU 配置/manifest 读写单测(unit 层,文件 IO)。
# 覆盖 derive_qemu_paths / derive_qemu_url_config_path /
#       read_qemu_url_config / write_qemu_url_config(upsert)/
#       write_qemu_binary_manifest / write_qemu_pcbios_manifest。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"; WORKSPACE_DIR="$TMP"
MACHINE='romulus'; QB_SYSTEM_NAME='qemu-system-arm'
SOURCE_LOCK_FILE="$TMP/no-lock"   # read_source_label 无文件 → 默认 community

# --- derive_qemu_paths: 设 QEMU_BIN_DIR/FILE/PIDS_DIR/PID_FILE ---
derive_qemu_paths
assert_eq "qemu bin dir"  "$QEMU_BIN_DIR"  "$TMP/qemu-bin/community"
assert_eq "qemu bin file" "$QEMU_BIN_FILE" "$TMP/qemu-bin/community/qemu-system-arm"
assert_eq "qemu pids dir" "$QEMU_PIDS_DIR" "$TMP/qemu-bin/.pids"
assert_eq "qemu pid file" "$QEMU_PID_FILE" "$TMP/qemu-bin/.pids/romulus.pid"

# --- write_qemu_url_config + read_qemu_url_config 往返 ---
write_qemu_url_config community qemu-system-arm 'https://example.com/qemu-arm'
assert_eq "read url config" "$(read_qemu_url_config community qemu-system-arm)" 'https://example.com/qemu-arm'
# 同 key 覆盖(upsert)
write_qemu_url_config community qemu-system-arm 'https://example.com/qemu-arm-v2'
assert_eq "read url config after upsert" "$(read_qemu_url_config community qemu-system-arm)" 'https://example.com/qemu-arm-v2'
# 不同 key 共存
write_qemu_url_config custom qemu-system-arm 'https://custom/qemu'
assert_eq "read custom url config" "$(read_qemu_url_config custom qemu-system-arm)" 'https://custom/qemu'

# --- write_qemu_binary_manifest: 字段 ---
QEMU_BIN_FILE="$TMP/qemu-bin/community/qemu-system-arm"; mkdir -p "$(dirname "$QEMU_BIN_FILE")"
write_qemu_binary_manifest download qemu-system-arm jenkins_build 12345 abc123 678
mf="$QEMU_BIN_FILE.manifest"
assert_true "manifest created" test -f "$mf"
mc="$(cat "$mf")"
assert_contains "manifest asset"     "$mc" 'asset=binary'
assert_contains "manifest source"    "$mc" 'source=download'
assert_contains "manifest arch"      "$mc" 'arch=qemu-system-arm'
assert_contains "manifest sha256"    "$mc" 'sha256=abc123'
assert_contains "manifest src_key"   "$mc" 'jenkins_build=12345'
assert_contains "manifest build_no"  "$mc" 'build_number=678'

# --- write_qemu_pcbios_manifest ---
QEMU_BIN_DIR="$TMP/qemu-bin/community"; mkdir -p "$QEMU_BIN_DIR"
write_qemu_pcbios_manifest copy /path/to/pc-bios.tar
pmf="$QEMU_BIN_DIR/pc-bios.manifest"
assert_true "pcbios manifest created" test -f "$pmf"
pc="$(cat "$pmf")"
assert_contains "pcbios asset"  "$pc" 'asset=pc-bios'
assert_contains "pcbios source" "$pc" 'source=copy'
assert_contains "pcbios src"    "$pc" 'pcbios_source=/path/to/pc-bios.tar'

rm -rf "$TMP"
assert_summary
