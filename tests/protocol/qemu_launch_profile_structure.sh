#!/usr/bin/env bash
# tests/protocol/qemu_launch_profile_structure.sh — QEMU launch profile 结构回归锁。
set -uo pipefail

source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OB="$ROOT/ob"
QEMU_SH="$ROOT/lib/qemu.sh"
COMMANDS_SH="$ROOT/lib/commands.sh"

extract_shell_function() {
    local file="$1"
    local function_name="$2"

    awk -v fn="$function_name" '
        BEGIN { in_fn = 0; found = 0 }
        $0 ~ "^" fn "[(][)] [{$]" || $0 ~ "^" fn "[(][)]$" {
            in_fn = 1
            found = 1
            print
            next
        }
        in_fn && $0 ~ "^[A-Za-z_][A-Za-z0-9_]*[(][)] [{$]" {
            in_fn = 0
            exit
        }
        in_fn { print }
        END { if (!found) exit 42 }
    ' "$file"
}

assert_function_contains() {
    local label="$1"
    local file="$2"
    local function_name="$3"
    local needle="$4"
    local body

    body=$(extract_shell_function "$file" "$function_name") || {
        _assert_bad "$label (function '$function_name' not found)"
        return
    }
    assert_contains "$label" "$body" "$needle"
}

assert_function_not_match() {
    local label="$1"
    local file="$2"
    local function_name="$3"
    local pattern="$4"
    local body

    body=$(extract_shell_function "$file" "$function_name") || {
        _assert_bad "$label (function '$function_name' not found)"
        return
    }
    if rg -q "$pattern" <<< "$body"; then
        _assert_bad "$label (matched /$pattern/)"
    else
        _assert_ok "$label"
    fi
}

assert_function_contains "cmd_start_qemu uses profile" "$COMMANDS_SH" cmd_start_qemu "resolve_qemu_launch_profile"
assert_function_not_match "cmd_start_qemu no old launch calls" "$COMMANDS_SH" cmd_start_qemu '^[[:space:]]*(resolve_qb_vars|detect_soc_type|derive_qemu_machine_name|find_ast2700_bootloaders)([[:space:]]|$)'

assert_function_not_match "build_qemu_cmd no discovery/old vars" "$QEMU_SH" build_qemu_cmd 'find_ast2700_bootloaders|machine_conf_chain_contains|detect_soc_type|\bQB_MEM_SIZE_FLAG\b|\bSOC_TYPE\b'
assert_function_not_match "derive_qemu_paths no old arch vars" "$QEMU_SH" derive_qemu_paths 'QB_SYSTEM_NAME|\bSOC_TYPE\b'
assert_function_not_match "check_jenkins_update no old arch vars" "$QEMU_SH" check_jenkins_update 'QB_SYSTEM_NAME|\bSOC_TYPE\b'
assert_function_not_match "ensure_qemu_binary_community no old arch vars" "$QEMU_SH" ensure_qemu_binary_community 'QB_SYSTEM_NAME|\bSOC_TYPE\b'
assert_function_not_match "ensure_qemu_binary_custom no old arch vars" "$QEMU_SH" ensure_qemu_binary_custom 'QB_SYSTEM_NAME|\bSOC_TYPE\b'
assert_function_not_match "ensure_qemu_firmware no soc-derived gating" "$QEMU_SH" ensure_qemu_firmware 'QB_SYSTEM_NAME|QEMU_LAUNCH_SOC_TYPE|\bSOC_TYPE\b'
assert_function_contains "ensure_qemu_firmware uses pcbios flag" "$QEMU_SH" ensure_qemu_firmware "QEMU_LAUNCH_REQUIRES_PCBIOS"
assert_function_contains "machine conf lookup stops after first hit" "$QEMU_SH" qemu_launch_profile_find_machine_conf "-print -quit"
assert_function_contains "include lookup stops after first hit" "$QEMU_SH" resolve_machine_conf_include "-print -quit"

# Missing target function must fail, not return an empty body that can pass scans.
if extract_shell_function "$QEMU_SH" __missing_qemu_launch_profile_function >/dev/null 2>&1; then
    _assert_bad "extract_shell_function missing target fails"
else
    _assert_ok "extract_shell_function missing target fails"
fi

# qemuboot.conf fast path: profile resolution should not call fake bitbake.
TMP="$(mktemp -d)"
DB="$(mktemp -d)"
mkfake_bin "$DB" bitbake
stub_out "$DB" bitbake 'QB_MACHINE="-machine romulus"
QB_MEM="-m 512"
QB_SYSTEM_NAME="qemu-system-arm"'
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$OPENBMC_DIR/build/romulus"
MACHINE="romulus"
mkdir -p "$BUILD_DIR"
: > "$OPENBMC_DIR/setup"
deploy_dir="$BUILD_DIR/tmp/deploy/images/romulus"
mkdir -p "$deploy_dir"
cat > "$deploy_dir/romulus.qemuboot.conf" <<EOF
[config_bsp]
qb_machine = -machine romulus
qb_mem = -m 512
qb_system_name = qemu-system-arm
EOF
with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"; OPENBMC_DIR="$2"; BUILD_DIR="$3"; MACHINE=romulus; resolve_qemu_launch_profile romulus' _ "$OB" "$OPENBMC_DIR" "$BUILD_DIR" >/dev/null 2>&1
calls=0
if [[ -f "$DB/.bitbake.calls" ]]; then
    calls=$(wc -l < "$DB/.bitbake.calls")
fi
assert_eq "profile qemuboot fast path skips bitbake" "$calls" "0"
rm -rf "$TMP" "$DB"

# bitbake fallback: without qemuboot.conf, one profile resolution should call fake bitbake exactly once.
TMP="$(mktemp -d)"
DB="$(mktemp -d)"
mkfake_bin "$DB" bitbake
stub_out "$DB" bitbake 'QB_MACHINE="-machine romulus"
QB_MEM="-m 512"
QB_SYSTEM_NAME="qemu-system-arm"'
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$OPENBMC_DIR/build/romulus"
MACHINE="romulus"
mkdir -p "$BUILD_DIR"
: > "$OPENBMC_DIR/setup"
with_stub "$DB" -- bash -c 'OB_NO_MAIN=1 source "$1"; OPENBMC_DIR="$2"; BUILD_DIR="$3"; MACHINE=romulus; resolve_qemu_launch_profile romulus' _ "$OB" "$OPENBMC_DIR" "$BUILD_DIR" >/dev/null 2>&1
calls=0
if [[ -f "$DB/.bitbake.calls" ]]; then
    calls=$(wc -l < "$DB/.bitbake.calls")
fi
assert_eq "profile fallback calls bitbake once" "$calls" "1"
rm -rf "$TMP" "$DB"

assert_summary