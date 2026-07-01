#!/usr/bin/env bash
# tests/protocol/qemu_launch_profile_remedy.sh — QEMU launch profile exit/remedy 契约。
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

make_env() {
    TMP="$(mktemp -d)"
    DB="$(mktemp -d)"
    mkfake_bin "$DB" bitbake
    OPENBMC_DIR="$TMP/openbmc"
    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
    mkdir -p "$BUILD_DIR" "$OPENBMC_DIR/meta-test/conf/machine/include"
    : > "$OPENBMC_DIR/setup"
}

cleanup_env() {
    rm -rf "${TMP:-}" "${DB:-}"
}

stub_bitbake_vars() {
    local qb_machine="$1"
    local qb_mem="$2"
    local qb_system="$3"

    stub_out "$DB" bitbake "QB_MACHINE=\"$qb_machine\"
QB_MEM=\"$qb_mem\"
QB_SYSTEM_NAME=\"$qb_system\""
}

run_profile_case() {
    local machine="$1"

    with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"; OPENBMC_DIR="$2"; BUILD_DIR="$3"; MACHINE="$4"; resolve_qemu_launch_profile "$4"' _ "$OB" "$OPENBMC_DIR" "$BUILD_DIR" "$machine" 2>&1
}

assert_single_remedy() {
    local label="$1"
    local output="$2"

    local remedy_count=0
    remedy_count=$(grep -Ec "Run 'ob |Define QB_" <<< "$output" || true)
    assert_eq "$label remedy count" "$remedy_count" "1"
}

# --- missing build dir/setup → exit 3 + ob init remedy ---
MACHINE=romulus; make_env; rm -rf "$BUILD_DIR"
stub_bitbake_vars "-machine romulus" "" "qemu-system-arm"
out="$(run_profile_case romulus)"; rc=$?
assert_eq "missing build dir rc" "$rc" "3"
assert_contains "missing build dir diagnosis" "$out" "Build directory not found"
assert_contains "missing build dir remedy" "$out" "Run 'ob init romulus' first."
assert_single_remedy "missing build dir" "$out"
cleanup_env

# --- no SoC evidence → exit 3 + config remedy ---
MACHINE=sample-project; make_env
stub_bitbake_vars "" "" ""
out="$(run_profile_case sample-project)"; rc=$?
assert_eq "no soc evidence rc" "$rc" "3"
assert_contains "no soc evidence diagnosis" "$out" "Cannot determine SoC type"
assert_contains "no soc evidence remedy" "$out" "Define QB_SYSTEM_NAME or include an ast2600/ast2700 machine conf fragment, then retry."
assert_single_remedy "no soc evidence" "$out"
cleanup_env

# --- AST2700 missing bootloader → exit 3 + build remedy ---
MACHINE=ast2700a1-evb; make_env
stub_bitbake_vars "-machine ast2700a1-evb" "" "qemu-system-aarch64"
out="$(run_profile_case ast2700a1-evb)"; rc=$?
assert_eq "missing bootloader rc" "$rc" "3"
assert_contains "missing bootloader diagnosis" "$out" "AST2700 bootloader files are missing"
assert_contains "missing bootloader remedy" "$out" "Run 'ob build ast2700a1-evb' first."
assert_single_remedy "missing bootloader" "$out"
cleanup_env

# --- machine-name fallback failure → exit 3 + QB_MACHINE remedy ---
MACHINE=nodash; make_env
stub_bitbake_vars "" "" "qemu-system-arm"
out="$(run_profile_case nodash)"; rc=$?
assert_eq "machine fallback failure rc" "$rc" "3"
assert_contains "machine fallback failure diagnosis" "$out" "Cannot determine QEMU machine name"
assert_contains "machine fallback failure remedy" "$out" "Define QB_MACHINE in the machine conf, then retry."
assert_single_remedy "machine fallback failure" "$out"
cleanup_env

# --- conflict → exit 1, no ob init/build remedy ---
MACHINE=romulus; make_env
stub_bitbake_vars "-machine romulus" "" "qemu-system-arm"
cat > "$OPENBMC_DIR/meta-test/conf/machine/romulus.conf" <<EOF
require conf/machine/include/ast2700-sdk.inc
EOF
cat > "$OPENBMC_DIR/meta-test/conf/machine/include/ast2700-sdk.inc" <<EOF
SOC_FAMILY = "aspeed-g7"
EOF
out="$(run_profile_case romulus)"; rc=$?
assert_eq "conflict rc" "$rc" "1"
assert_contains "conflict diagnosis" "$out" "SoC type conflict"
assert_false "conflict no init remedy" grep -Fq "Run 'ob init" <<< "$out"
assert_false "conflict no build remedy" grep -Fq "Run 'ob build" <<< "$out"
cleanup_env

assert_summary