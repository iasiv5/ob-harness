#!/usr/bin/env bash
# tests/unit/soc.sh — QEMU launch profile 纯规则单测(unit 层)。
# 覆盖:QB_SYSTEM_NAME→SoC / machine conf include chain / QEMU machine name fallback。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# --- QEMU system name → SoC strong evidence ---
reset_qemu_launch_profile >/dev/null 2>&1
qemu_launch_profile_apply_system_name "qemu-system-arm" >/dev/null 2>&1
assert_eq "soc from arm" "${QEMU_LAUNCH_SOC_TYPE:-}" "ast2600"
assert_eq "soc source from arm" "${QEMU_LAUNCH_SOC_SOURCE:-}" "bitbake"
assert_eq "soc confidence from arm" "${QEMU_LAUNCH_SOC_CONFIDENCE:-}" "strong"

reset_qemu_launch_profile >/dev/null 2>&1
qemu_launch_profile_apply_system_name "qemu-system-aarch64" >/dev/null 2>&1
assert_eq "soc from aarch64" "${QEMU_LAUNCH_SOC_TYPE:-}" "ast2700"
assert_eq "system name kept" "${QEMU_LAUNCH_SYSTEM_NAME:-}" "qemu-system-aarch64"

reset_qemu_launch_profile >/dev/null 2>&1
qemu_launch_profile_apply_system_name "qemu-system-riscv64" >/dev/null 2>&1
assert_eq "unknown system no soc" "${QEMU_LAUNCH_SOC_TYPE:-}" ""
assert_eq "unknown system no binary name" "${QEMU_LAUNCH_SYSTEM_NAME:-}" ""

# --- QEMU machine name derivation ---
reset_qemu_launch_profile >/dev/null 2>&1
qemu_launch_profile_apply_machine_name "preset-mach" "x-y" >/dev/null 2>&1
assert_eq "machine from bitbake" "${QEMU_LAUNCH_MACHINE_NAME:-}" "preset-mach"
assert_eq "machine source bitbake" "${QEMU_LAUNCH_MACHINE_NAME_SOURCE:-}" "bitbake"

reset_qemu_launch_profile >/dev/null 2>&1
qemu_launch_profile_apply_machine_name "" "sample-project" >/dev/null 2>&1
assert_eq "derive from machine" "${QEMU_LAUNCH_MACHINE_NAME:-}" "sample-bmc"
assert_eq "machine source legacy" "${QEMU_LAUNCH_MACHINE_NAME_SOURCE:-}" "legacy-name"

assert_rc 3 "derive no dash exit 3" bash -c 'OB_NO_MAIN=1 source "$1"; reset_qemu_launch_profile; qemu_launch_profile_apply_machine_name "" "nodash"' _ "$OB"

# --- machine_conf_chain_contains:multi-file include / loop / missing ---
TMP="$(mktemp -d)"
OPENBMC_DIR="$TMP/openbmc"
mkdir -p "$OPENBMC_DIR/meta-a/conf/machine/include" "$OPENBMC_DIR/meta-a/conf/machine" "$OPENBMC_DIR/meta-b/conf/machine/include"
cat > "$OPENBMC_DIR/meta-a/conf/machine/ast2600.conf" <<EOF
require conf/machine/include/ast2600-default.inc
MACHINE = "x"
EOF
cat > "$OPENBMC_DIR/meta-a/conf/machine/include/ast2600-default.inc" <<EOF
SOC_FAMILY = "aspeed-g6"
EOF
cat > "$OPENBMC_DIR/meta-a/conf/machine/ast2700.conf" <<EOF
require conf/machine/include/board.inc
EOF
cat > "$OPENBMC_DIR/meta-a/conf/machine/include/board.inc" <<EOF
include conf/machine/include/ast2700-sdk.inc
EOF
cat > "$OPENBMC_DIR/meta-a/conf/machine/include/ast2700-sdk.inc" <<EOF
SOC_FAMILY = "aspeed-g7"
EOF
cat > "$OPENBMC_DIR/meta-b/conf/machine/loop-a.conf" <<EOF
require conf/machine/include/loop-b.inc
EOF
cat > "$OPENBMC_DIR/meta-b/conf/machine/include/loop-b.inc" <<EOF
require conf/machine/loop-a.conf
EOF

assert_true  "chain contains ast2600"   machine_conf_chain_contains "$OPENBMC_DIR/meta-a/conf/machine/ast2600.conf" 'ast2600-default'
assert_true  "chain contains ast2700"   machine_conf_chain_contains "$OPENBMC_DIR/meta-a/conf/machine/ast2700.conf" 'ast2700-sdk\.inc|aspeed-g7'
assert_false "chain loop terminates"    machine_conf_chain_contains "$OPENBMC_DIR/meta-b/conf/machine/loop-a.conf" 'ast2700-sdk'
assert_false "chain missing file"       machine_conf_chain_contains "$TMP/nonexist.conf" 'anything'

# --- system_name_for_soc / extract_qemuboot_var(F5 真漏候选补测,降 coverage N5) ---
assert_eq "soc ast2600 → arm"     "$(qemu_launch_profile_system_name_for_soc ast2600)" "qemu-system-arm"
assert_eq "soc ast2700 → aarch64" "$(qemu_launch_profile_system_name_for_soc ast2700)" "qemu-system-aarch64"
assert_eq "soc unknown → empty"   "$(qemu_launch_profile_system_name_for_soc unknownsoc)" ""

QB_CONF="$TMP/qemuboot.conf"
printf 'QB_MEM = "512"\n# comment\nQB_SYSTEM_NAME = "qemu-system-arm"\n' > "$QB_CONF"
assert_eq "extract QB_MEM"         "$(qemu_launch_profile_extract_qemuboot_var "$QB_CONF" QB_MEM)" '"512"'
assert_eq "extract QB_SYSTEM_NAME" "$(qemu_launch_profile_extract_qemuboot_var "$QB_CONF" QB_SYSTEM_NAME)" '"qemu-system-arm"'
assert_eq "extract missing var"    "$(qemu_launch_profile_extract_qemuboot_var "$QB_CONF" QB_NOMATCH)" ""

rm -rf "$TMP"

assert_summary
