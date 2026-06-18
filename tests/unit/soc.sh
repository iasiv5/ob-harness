#!/usr/bin/env bash
# tests/unit/soc.sh — SoC/machine 派生类函数单测(unit 层)。
# 覆盖 detect_soc_type(QB_SYSTEM_NAME 推)/ derive_qemu_machine_name / machine_conf_chain_contains。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# --- detect_soc_type:QB_SYSTEM_NAME 直接推(不走 deploy/conf)---
QB_SYSTEM_NAME="qemu-system-arm"; MACHINE="romulus"; BUILD_DIR="/nonexist"; OPENBMC_DIR="/nonexist"
detect_soc_type >/dev/null 2>&1; assert_eq "soc from arm"     "$SOC_TYPE" "ast2600"
QB_SYSTEM_NAME="qemu-system-aarch64"; detect_soc_type >/dev/null 2>&1; assert_eq "soc from aarch64" "$SOC_TYPE" "ast2700"

# --- derive_qemu_machine_name ---
QB_MACHINE_NAME=""; MACHINE="b865g8-bytedance"; derive_qemu_machine_name >/dev/null 2>&1
assert_eq "derive from machine" "$QB_MACHINE_NAME" "b865g8-bmc"
QB_MACHINE_NAME="preset-mach"; MACHINE="x-y"; derive_qemu_machine_name >/dev/null 2>&1
assert_eq "derive preset kept"  "$QB_MACHINE_NAME" "preset-mach"
# 无 '-' 分隔 → exit 3
assert_rc 3 "derive no dash exit 3" bash -c 'OB_NO_MAIN=1 source "$1"; QB_MACHINE_NAME=""; MACHINE="nodash"; derive_qemu_machine_name' _ "$OB"

# --- machine_conf_chain_contains:单文件 grep 命中/不命中 ---
TMP="$(mktemp -d)"
cat > "$TMP/machine.conf" <<EOF
require conf/machine/include/ast2600-default.inc
MACHINE = "x"
EOF
assert_true  "chain contains pattern"   machine_conf_chain_contains "$TMP/machine.conf" 'ast2600-default'
assert_false "chain missing pattern"    machine_conf_chain_contains "$TMP/machine.conf" 'ast2700-sdk'
assert_false "chain missing file"       machine_conf_chain_contains "$TMP/nonexist.conf" 'anything'
rm -rf "$TMP"

assert_summary
