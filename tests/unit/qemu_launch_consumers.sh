#!/usr/bin/env bash
# tests/unit/qemu_launch_consumers.sh — QEMU launch profile consumer 单测。
# 覆盖 build_qemu_cmd / ensure_qemu_firmware 只消费 QEMU_LAUNCH_* 决策变量。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
QEMU_BIN_FILE="$TMP/qemu-system-test"
QEMU_BIN_DIR="$TMP/qemu-bin"
QEMU_PCBIOS_DIR="$QEMU_BIN_DIR/pc-bios"
image_file="$TMP/image.static.mtd"
serial_log="$TMP/serial.log"
serial_sock="$TMP/serial.sock"
: > "$QEMU_BIN_FILE"
: > "$image_file"

# --- AST2600: machine + mem, no AST2700 loader ---
QEMU_LAUNCH_SOC_TYPE="ast2600"
QEMU_LAUNCH_MACHINE_NAME="romulus-bmc"
QEMU_LAUNCH_MEM_FLAG="-m 512"
QEMU_LAUNCH_REQUIRES_PCBIOS="no"
mkdir -p "$QEMU_PCBIOS_DIR"
QEMU_CMD=()
build_qemu_cmd "$image_file" 2222 2443 2623 "" "$serial_log" "$serial_sock"
cmd="${QEMU_CMD[*]}"
assert_contains "ast2600 machine" "$cmd" "-machine romulus-bmc"
assert_contains "ast2600 mem" "$cmd" "-m 512"
assert_false "ast2600 no loader" grep -Fq "loader,force-raw" <<< "$cmd"
assert_false "ast2600 no pc-bios search path" grep -Fq -- "-L $QEMU_PCBIOS_DIR" <<< "$cmd"

# --- AST2700: loader args come from QEMU_LAUNCH_BOOTLOADER_* ---
QEMU_LAUNCH_SOC_TYPE="ast2700"
QEMU_LAUNCH_MACHINE_NAME="ast2700a1-evb"
QEMU_LAUNCH_MEM_FLAG=""
QEMU_LAUNCH_REQUIRES_PCBIOS="yes"
QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB="$TMP/u-boot-nodtb.bin"
QEMU_LAUNCH_BOOTLOADER_UBOOT_DTB="$TMP/u-boot.dtb"
QEMU_LAUNCH_BOOTLOADER_BL31="$TMP/bl31.bin"
QEMU_LAUNCH_BOOTLOADER_OPTEE="$TMP/tee-raw.bin"
QEMU_LAUNCH_BOOTLOADER_UBOOT_SIZE="4096"
QEMU_CMD=()
build_qemu_cmd "$image_file" 2222 2443 2623 2080 "$serial_log" "$serial_sock"
cmd="${QEMU_CMD[*]}"
assert_contains "ast2700 machine" "$cmd" "-machine ast2700a1-evb"
assert_contains "ast2700 uboot nodtb" "$cmd" "file=$QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB"
assert_contains "ast2700 uboot dtb offset" "$cmd" "addr=17179873280,file=$QEMU_LAUNCH_BOOTLOADER_UBOOT_DTB"
assert_contains "ast2700 bl31" "$cmd" "file=$QEMU_LAUNCH_BOOTLOADER_BL31"
assert_contains "ast2700 optee" "$cmd" "file=$QEMU_LAUNCH_BOOTLOADER_OPTEE"
assert_contains "ast2700 http fwd" "$cmd" "hostfwd=tcp::2080-:80"
assert_contains "ast2700 pc-bios search path" "$cmd" "-L $QEMU_PCBIOS_DIR"

# --- AST2700 platform machine: bootloader is handled by the machine model ---
QEMU_LAUNCH_SOC_TYPE="ast2700"
QEMU_LAUNCH_MACHINE_NAME="sample-bmc"
QEMU_LAUNCH_MEM_FLAG="-m 1G"
QEMU_LAUNCH_REQUIRES_PCBIOS="yes"
QEMU_CMD=()
build_qemu_cmd "$image_file" 2222 2443 2623 "" "$serial_log" "$serial_sock"
cmd="${QEMU_CMD[*]}"
assert_contains "ast2700 platform machine" "$cmd" "-machine sample-bmc"
assert_contains "ast2700 platform mem" "$cmd" "-m 1G"
assert_false "ast2700 platform no external loader" grep -Fq "loader,force-raw" <<< "$cmd"

# --- QEMU binary-supported platform machine overrides generic qemuboot machine ---
cat > "$QEMU_BIN_FILE" <<'STUB_QEMU'
#!/usr/bin/env bash
if [[ "$*" == "-machine help" ]]; then
	echo "ast2700a1-evb Aspeed AST2700 A1 EVB"
	echo "sample-bmc Example AST2700 platform BMC"
fi
STUB_QEMU
chmod +x "$QEMU_BIN_FILE"
MACHINE="sample-project"
QEMU_LAUNCH_MACHINE_NAME="ast2700a1-evb"
QEMU_LAUNCH_MACHINE_NAME_SOURCE="qemuboot"
qemu_launch_profile_apply_binary_machine_override >/dev/null
assert_eq "binary machine override name" "$QEMU_LAUNCH_MACHINE_NAME" "sample-bmc"
assert_eq "binary machine override source" "$QEMU_LAUNCH_MACHINE_NAME_SOURCE" "qemu-binary"

MACHINE="romulus"
QEMU_LAUNCH_MACHINE_NAME="romulus-bmc"
QEMU_LAUNCH_MACHINE_NAME_SOURCE="qemuboot"
qemu_launch_profile_apply_binary_machine_override >/dev/null
assert_eq "binary machine override keeps no-prefix machine" "$QEMU_LAUNCH_MACHINE_NAME" "romulus-bmc"

# --- ensure_qemu_firmware: no skips pc-bios check ---
QEMU_LAUNCH_REQUIRES_PCBIOS="no"
QEMU_BIN_DIR="$TMP/no-pcbios"
assert_rc 0 "firmware no skips missing pc-bios" ensure_qemu_firmware

# --- ensure_qemu_firmware: yes checks bootrom when pc-bios exists ---
QEMU_LAUNCH_REQUIRES_PCBIOS="yes"
QEMU_BIN_DIR="$TMP/needs-pcbios"
mkdir -p "$QEMU_BIN_DIR/pc-bios"
assert_rc 3 "firmware yes missing bootrom" bash -c 'OB_NO_MAIN=1 source "$1"; QEMU_LAUNCH_REQUIRES_PCBIOS=yes; QEMU_BIN_DIR="$2"; ensure_qemu_firmware' _ "$OB" "$QEMU_BIN_DIR"
: > "$QEMU_BIN_DIR/pc-bios/ast27x0_bootrom.bin"
assert_rc 0 "firmware yes bootrom present" ensure_qemu_firmware

rm -rf "$TMP"
assert_summary