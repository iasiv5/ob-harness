#!/usr/bin/env bash
# tests/orchestration/qemu_launch_profile.sh — QEMU launch profile 编排测试。
# mock: bitbake -e / machine conf / deploy artifacts。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

make_case_root() {
    local tmp="$1"
    local machine="${2:-romulus}"

    OPENBMC_DIR="$tmp/openbmc"
    BUILD_DIR="$OPENBMC_DIR/build/$machine"
    MACHINE="$machine"
    mkdir -p "$BUILD_DIR" "$OPENBMC_DIR/meta-test/conf/machine/include"
    : > "$OPENBMC_DIR/setup"
}

write_bitbake_output() {
    local db="$1"
    local qb_machine="$2"
    local qb_mem="$3"
    local qb_system="$4"

    stub_out "$db" bitbake "QB_MACHINE=\"$qb_machine\"
QB_MEM=\"$qb_mem\"
QB_SYSTEM_NAME=\"$qb_system\""
}

write_bitbake_raw() {
    local db="$1"
    local raw="$2"

    stub_out "$db" bitbake "$raw"
}

write_machine_conf() {
    local machine="$1"
    local include_line="$2"

    cat > "$OPENBMC_DIR/meta-test/conf/machine/$machine.conf" <<EOF
$include_line
EOF
}

write_machine_include() {
    local name="$1"
    local body="$2"

    cat > "$OPENBMC_DIR/meta-test/conf/machine/include/$name" <<EOF
$body
EOF
}

write_qemuboot_conf() {
    local qb_machine="$1"
    local qb_mem="$2"
    local qb_system="$3"
    local deploy_dir
    deploy_dir="$(make_deploy_dir)"

    cat > "$deploy_dir/$MACHINE.qemuboot.conf" <<EOF
[config_bsp]
qb_machine = $qb_machine
qb_mem = $qb_mem
qb_system_name = $qb_system
EOF
}

make_deploy_dir() {
    local deploy_dir="$BUILD_DIR/tmp/deploy/images/$MACHINE"
    mkdir -p "$deploy_dir/optee"
    echo "$deploy_dir"
}

touch_static_mtd() {
    local deploy_dir
    deploy_dir="$(make_deploy_dir)"
    : > "$deploy_dir/$MACHINE.static.mtd"
}

touch_ast2700_bootloaders() {
    local deploy_dir
    deploy_dir="$(make_deploy_dir)"
    : > "$deploy_dir/u-boot-nodtb.bin"
    : > "$deploy_dir/u-boot.dtb"
    : > "$deploy_dir/bl31.bin"
    : > "$deploy_dir/optee/tee-raw.bin"
}

touch_partial_ast2700_bootloader() {
    local deploy_dir
    deploy_dir="$(make_deploy_dir)"
    : > "$deploy_dir/u-boot-nodtb.bin"
}

run_profile_subshell() {
    local tmp="$1"
    local db="$2"
    local machine="$3"

    with_stub "$db" -- bash -c 'OB_NO_MAIN=1 source "$1"
set +e
OPENBMC_DIR="$2"; BUILD_DIR="$3"; MACHINE="$4"
resolve_qemu_launch_profile "$MACHINE"
rc=$?
echo "rc=$rc"
echo "soc=${QEMU_LAUNCH_SOC_TYPE:-}"
echo "source=${QEMU_LAUNCH_SOC_SOURCE:-}"
echo "confidence=${QEMU_LAUNCH_SOC_CONFIDENCE:-}"
echo "system=${QEMU_LAUNCH_SYSTEM_NAME:-}"
echo "machine_name=${QEMU_LAUNCH_MACHINE_NAME:-}"
echo "machine_source=${QEMU_LAUNCH_MACHINE_NAME_SOURCE:-}"
echo "mem=${QEMU_LAUNCH_MEM_FLAG:-}"
echo "pcbios=${QEMU_LAUNCH_REQUIRES_PCBIOS:-}"
echo "uboot=${QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB:-}"
exit "$rc"' _ "$OB" "$OPENBMC_DIR" "$BUILD_DIR" "$machine" 2>&1
}

# --- qemuboot.conf fast path skips BitBake ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" ast2700a1-evb
write_qemuboot_conf "-machine ast2700a1-evb" "-m 1G" "qemu-system-aarch64"
write_machine_include ast2600.inc 'SOC_FAMILY = "aspeed-g6"'
write_machine_conf ast2700a1-evb 'require conf/machine/include/ast2600.inc'
touch_ast2700_bootloaders
out="$(run_profile_subshell "$TMP" "$DB" ast2700a1-evb)"; rc=$?
calls=0; [[ -f "$DB/.bitbake.calls" ]] && calls=$(wc -l < "$DB/.bitbake.calls")
assert_eq "qemuboot fast path rc" "$rc" "0"
assert_eq "qemuboot fast path skips bitbake" "$calls" "0"
assert_contains "qemuboot source" "$out" "source=qemuboot"
assert_contains "qemuboot machine" "$out" "machine_name=ast2700a1-evb"
assert_contains "qemuboot machine source" "$out" "machine_source=qemuboot"
assert_contains "qemuboot mem" "$out" "mem=-m 1G"
assert_contains "qemuboot system" "$out" "system=qemu-system-aarch64"
rm -rf "$TMP" "$DB"

# --- BitBake strong evidence: AST2600 ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
write_bitbake_output "$DB" "-machine romulus" "-m 512" "qemu-system-arm"
out="$(run_profile_subshell "$TMP" "$DB" romulus)"; rc=$?
assert_eq "bitbake arm rc" "$rc" "0"
assert_contains "bitbake arm soc" "$out" "soc=ast2600"
assert_contains "bitbake arm source" "$out" "source=bitbake"
assert_contains "bitbake arm confidence" "$out" "confidence=strong"
assert_contains "bitbake arm system" "$out" "system=qemu-system-arm"
assert_contains "bitbake mem" "$out" "mem=-m 512"
rm -rf "$TMP" "$DB"

# --- BitBake command failure is fatal even when stdout is non-empty ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
write_bitbake_output "$DB" "-machine romulus" "" "qemu-system-arm"
stub_exit "$DB" bitbake 42
out="$(run_profile_subshell "$TMP" "$DB" romulus)"; rc=$?
assert_eq "bitbake nonzero with output rc" "$rc" "1"
assert_contains "bitbake nonzero with output diagnosis" "$out" "Failed to run 'bitbake -e'"
rm -rf "$TMP" "$DB"

# --- BitBake strong evidence: AST2700 with bootloaders ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" ast2700a1-evb
write_bitbake_output "$DB" "-machine ast2700a1-evb" "" "qemu-system-aarch64"
touch_ast2700_bootloaders
out="$(run_profile_subshell "$TMP" "$DB" ast2700a1-evb)"; rc=$?
assert_eq "bitbake aarch64 rc" "$rc" "0"
assert_contains "bitbake aarch64 soc" "$out" "soc=ast2700"
assert_contains "bitbake aarch64 pcbios" "$out" "pcbios=yes"
assert_contains "bitbake aarch64 bootloader" "$out" "uboot=$BUILD_DIR/tmp/deploy/images/ast2700a1-evb/u-boot-nodtb.bin"
rm -rf "$TMP" "$DB"

# --- Strong AST2700 + partial deploy evidence must fail as missing bootloader ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" ast2700a1-evb
write_bitbake_output "$DB" "-machine ast2700a1-evb" "" "qemu-system-aarch64"
touch_partial_ast2700_bootloader
out="$(run_profile_subshell "$TMP" "$DB" ast2700a1-evb)"; rc=$?
assert_eq "ast2700 partial bootloader rc" "$rc" "3"
assert_contains "ast2700 partial bootloader diagnosis" "$out" "AST2700 bootloader files are missing"
assert_contains "ast2700 partial bootloader remedy" "$out" "Run 'ob build ast2700a1-evb' first."
rm -rf "$TMP" "$DB"

# --- machine conf evidence when QB_SYSTEM_NAME is empty ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
write_bitbake_output "$DB" "-machine romulus" "" ""
write_machine_include ast2600.inc 'SOC_FAMILY = "aspeed-g6"'
write_machine_conf romulus 'require conf/machine/include/ast2600.inc'
out="$(run_profile_subshell "$TMP" "$DB" romulus)"; rc=$?
assert_eq "conf ast2600 rc" "$rc" "0"
assert_contains "conf ast2600 soc" "$out" "soc=ast2600"
assert_contains "conf ast2600 source" "$out" "source=machine-conf"
assert_contains "conf ast2600 system inferred" "$out" "system=qemu-system-arm"
rm -rf "$TMP" "$DB"

# --- missing QB_MACHINE/QB_MEM lines tolerate fallback, not pipefail abort ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" sample-project
write_bitbake_raw "$DB" 'QB_SYSTEM_NAME="qemu-system-arm"'
out="$(run_profile_subshell "$TMP" "$DB" sample-project)"; rc=$?
assert_eq "missing machine mem lines rc" "$rc" "0"
assert_contains "missing machine mem lines machine fallback" "$out" "machine_name=sample-bmc"
assert_contains "missing machine mem lines empty mem" "$out" "mem="
assert_contains "missing machine mem lines system" "$out" "system=qemu-system-arm"
rm -rf "$TMP" "$DB"

# --- unknown QB_SYSTEM_NAME does not pollute inferred QEMU binary name ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
write_bitbake_raw "$DB" 'QB_MACHINE="-machine romulus"
QB_SYSTEM_NAME="qemu-system-riscv64"'
write_machine_include ast2600.inc 'SOC_FAMILY = "aspeed-g6"'
write_machine_conf romulus 'require conf/machine/include/ast2600.inc'
out="$(run_profile_subshell "$TMP" "$DB" romulus)"; rc=$?
assert_eq "unknown system fallback rc" "$rc" "0"
assert_contains "unknown system fallback soc" "$out" "soc=ast2600"
assert_contains "unknown system fallback system inferred" "$out" "system=qemu-system-arm"
rm -rf "$TMP" "$DB"

# --- fully missing QB lines still reaches designed SoC remedy ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" sample-project
write_bitbake_raw "$DB" 'SOME_OTHER_VAR="1"'
out="$(run_profile_subshell "$TMP" "$DB" sample-project)"; rc=$?
assert_eq "missing all qb lines rc" "$rc" "3"
assert_contains "missing all qb lines remedy" "$out" "Define QB_SYSTEM_NAME or include an ast2600/ast2700 machine conf fragment, then retry."
rm -rf "$TMP" "$DB"

# --- BitBake/conf conflict ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
write_bitbake_output "$DB" "-machine romulus" "" "qemu-system-arm"
write_machine_include ast2700-sdk.inc 'SOC_FAMILY = "aspeed-g7"'
write_machine_conf romulus 'require conf/machine/include/ast2700-sdk.inc'
out="$(run_profile_subshell "$TMP" "$DB" romulus)"; rc=$?
assert_eq "bitbake conf conflict rc" "$rc" "1"
assert_contains "bitbake conf conflict text" "$out" "SoC type conflict"
rm -rf "$TMP" "$DB"

# --- conf AST2600 + explicit deploy AST2700 conflict ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
write_bitbake_output "$DB" "-machine romulus" "" ""
write_machine_include ast2600.inc 'SOC_FAMILY = "aspeed-g6"'
write_machine_conf romulus 'require conf/machine/include/ast2600.inc'
touch_ast2700_bootloaders
out="$(run_profile_subshell "$TMP" "$DB" romulus)"; rc=$?
assert_eq "conf deploy conflict rc" "$rc" "1"
assert_contains "conf deploy conflict text" "$out" "SoC type conflict"
rm -rf "$TMP" "$DB"

# --- strong AST2600 ignores partial AST2700 deploy evidence ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
write_bitbake_output "$DB" "-machine romulus" "" ""
write_machine_include ast2600.inc 'SOC_FAMILY = "aspeed-g6"'
write_machine_conf romulus 'require conf/machine/include/ast2600.inc'
touch_partial_ast2700_bootloader
out="$(run_profile_subshell "$TMP" "$DB" romulus)"; rc=$?
assert_eq "partial with strong ast2600 rc" "$rc" "0"
assert_contains "partial with strong ast2600 soc" "$out" "soc=ast2600"
rm -rf "$TMP" "$DB"

# --- legacy AST2600 fallback requires static.mtd and no AST2700 evidence ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" sample-project
write_bitbake_output "$DB" "" "" ""
touch_static_mtd
out="$(run_profile_subshell "$TMP" "$DB" sample-project)"; rc=$?
assert_eq "legacy fallback rc" "$rc" "0"
assert_contains "legacy fallback soc" "$out" "soc=ast2600"
assert_contains "legacy fallback confidence" "$out" "confidence=legacy"
assert_contains "legacy fallback warning" "$out" "legacy AST2600"
rm -rf "$TMP" "$DB"

# --- partial AST2700 without strong evidence blocks legacy fallback ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
write_bitbake_output "$DB" "" "" ""
touch_static_mtd
touch_partial_ast2700_bootloader
out="$(run_profile_subshell "$TMP" "$DB" romulus)"; rc=$?
assert_eq "partial without strong rc" "$rc" "3"
assert_contains "partial without strong remedy" "$out" "Define QB_SYSTEM_NAME or include an ast2600/ast2700 machine conf fragment, then retry."
rm -rf "$TMP" "$DB"

# --- no evidence exits 3 ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
write_bitbake_output "$DB" "" "" ""
out="$(run_profile_subshell "$TMP" "$DB" romulus)"; rc=$?
assert_eq "no evidence rc" "$rc" "3"
assert_contains "no evidence remedy" "$out" "Define QB_SYSTEM_NAME or include an ast2600/ast2700 machine conf fragment, then retry."
rm -rf "$TMP" "$DB"

# --- machine name fallback and failure ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" sample-project
write_bitbake_output "$DB" "" "" "qemu-system-arm"
out="$(run_profile_subshell "$TMP" "$DB" sample-project)"; rc=$?
assert_eq "machine name fallback rc" "$rc" "0"
assert_contains "machine name fallback" "$out" "machine_name=sample-bmc"
assert_contains "machine source fallback" "$out" "machine_source=legacy-name"
rm -rf "$TMP" "$DB"

TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" nodash
write_bitbake_output "$DB" "" "" "qemu-system-arm"
out="$(run_profile_subshell "$TMP" "$DB" nodash)"; rc=$?
assert_eq "machine name fallback failure rc" "$rc" "3"
assert_contains "machine name fallback failure remedy" "$out" "Define QB_MACHINE in the machine conf, then retry."
rm -rf "$TMP" "$DB"

# --- entry reset clears AST2700 bootloader state before AST2600 profile ---
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; mkfake_bin "$DB" bitbake
make_case_root "$TMP" romulus
touch_ast2700_bootloaders
write_bitbake_output "$DB" "-machine romulus" "" "qemu-system-aarch64"
rc=0; with_stub "$DB" -- resolve_qemu_launch_profile romulus >/dev/null 2>&1 || rc=$?
assert_eq "reset precondition rc" "$rc" "0"
assert_contains "reset precondition bootloader set" "${QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB:-}" "u-boot-nodtb.bin"
rm -rf "$BUILD_DIR/tmp/deploy/images/$MACHINE"
write_bitbake_output "$DB" "-machine romulus" "" "qemu-system-arm"
rc=0; with_stub "$DB" -- resolve_qemu_launch_profile romulus >/dev/null 2>&1 || rc=$?
assert_eq "reset second rc" "$rc" "0"
assert_eq "reset clears bootloader" "${QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB:-}" ""
assert_eq "reset clears pcbios" "${QEMU_LAUNCH_REQUIRES_PCBIOS:-}" "no"
rm -rf "$TMP" "$DB"

assert_summary