#!/usr/bin/env bash
# tests/protocol/verify_surface.sh — ob verify 表面/契约协议测试。
# 锁定: (1) verify 在 usage Commands 段登记 + verify Options 段 + 示例;
#       (2) parse_args verify <machine> 设 COMMAND/MACHINE; --ssh/redfish/ipmi-port 设对应全局;
#       (3) main verify 真调 cmd_verify(MACHINE 透传);
#       (4) cmd_verify 函数登记在 lib/qemu_commands.sh;
#       (5) 空 workspace / candidates-but-non-TTY → exit 3(前置缺失, 非失败);
#       (6) 顶层 dispatch(usage_dispatch_sync 顶部 awk 自动断言 commands 集合 == dispatch case 集合,
#           verify 已加进二者, 此处补 main→cmd 通路锁)。
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# === (1) usage 登记 verify ===
_usage_out="$(usage 2>/dev/null)"
assert_contains "usage Commands 含 verify"          "$_usage_out" "verify"
assert_contains "usage verify 行说明 smoke"          "$_usage_out" "smoke"
assert_contains "usage 含 verify Options 段"         "$_usage_out" "verify Options:"
assert_contains "usage verify 含 --redfish-port"     "$_usage_out" "--redfish-port"
assert_contains "usage verify 含 closed-port fail 提示" "$_usage_out" "CLOSED port"
assert_contains "usage 含 ob verify 示例"            "$_usage_out" "ob verify romulus"

# === (2) parse_args: verify <machine> 设 COMMAND/MACHINE; 端口 override 设全局 ===
DEV_ARGS=(); QEMU_SSH_PORT=""; QEMU_REDFISH_PORT=""; QEMU_IPMI_PORT=""
_pm="$(parse_args verify romulus 2>/dev/null; printf '|CMD:%s|M:%s' "$COMMAND" "$MACHINE")"
assert_contains "parse_args verify 设 COMMAND" "$_pm" "|CMD:verify"
assert_contains "parse_args verify 设 MACHINE" "$_pm" "|M:romulus"

DEV_ARGS=(); QEMU_SSH_PORT=""; QEMU_REDFISH_PORT=""; QEMU_IPMI_PORT=""
parse_args verify romulus --redfish-port 24430 --ssh-port 22220 --ipmi-port 26230
assert_eq "verify --redfish-port 设 QEMU_REDFISH_PORT" "$QEMU_REDFISH_PORT" "24430"
assert_eq "verify --ssh-port 设 QEMU_SSH_PORT"         "$QEMU_SSH_PORT"     "22220"
assert_eq "verify --ipmi-port 设 QEMU_IPMI_PORT"       "$QEMU_IPMI_PORT"    "26230"

# verify 位置参数不吞 flag(--redfish-port 不被当 machine)
DEV_ARGS=(); MACHINE=""
parse_args verify --redfish-port 9999
assert_eq "verify 不带 machine → MACHINE 空" "$MACHINE" ""
assert_eq "verify --redfish-port 9999 仍解析" "$QEMU_REDFISH_PORT" "9999"

# === (3) main verify → cmd_verify(MACHINE 透传) ===
cmd_verify() { printf 'VERIFY_CALLED machine=%s\n' "$MACHINE"; return 0; }
_disp="$(main verify romulus 2>/dev/null)" || true
assert_contains "main verify 调 cmd_verify" "$_disp" "VERIFY_CALLED machine=romulus"

# === (4) cmd_verify 登记在 lib/qemu_commands.sh ===
QCMDS="$(cd "$(dirname "$0")/../.." && pwd)/lib/qemu_commands.sh"
assert_true "cmd_verify defined in qemu_commands.sh" grep -q '^cmd_verify()' "$QCMDS"
assert_true "cmd_verify reuses qemu_prepare_launch(既有 bring-up)" grep -q 'qemu_prepare_launch "$MACHINE" "$image_file"' "$QCMDS"
assert_true "cmd_verify reuses qemu_execute_launch(既有 bring-up)" grep -q 'qemu_execute_launch' "$QCMDS"
assert_true "cmd_verify installs EXIT cleanup trap" grep -q "trap '_verify_cleanup" "$QCMDS"

# === (5) 空 workspace → exit 3(前置缺失) ===
assert_ob_rc() {
    local expected="$1" label="$2"; shift 2
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        OB_NO_MAIN=1 source "$OB"; set +e
        detect_harness_root() {
            HARNESS_ROOT="$tmp"; WORKSPACE_DIR="$HARNESS_ROOT/workspace"
            OPENBMC_DIR="$WORKSPACE_DIR/openbmc"; BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
            SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"; CONFIGS_DIR="$WORKSPACE_DIR/configs"
            SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
            QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
            QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
        }
        mkdir -p "$tmp/workspace/configs" "$tmp/workspace/qemu-bin/.pids"
        parse_args "$@"; detect_harness_root
        case "$COMMAND" in verify) cmd_verify ;; *) exit 99 ;; esac
    ) </dev/null >/dev/null 2>&1 || rc=$?
    rm -rf "$tmp"
    [[ "$rc" -eq "$expected" ]] && _assert_ok "$label (rc=$rc)" || _assert_bad "$label (rc=$rc want $expected)"
}
assert_ob_rc 3 "verify empty workspace → exit 3(无 init machine)" verify

# candidates-but-non-TTY(image-ready 候选存在但非交互)→ exit 3
_setup_verify_candidates() { :; }   # placeholder(本测试用直接 mkdir)
_rc3_tmp_helper() {
    local tmp="$1"
    local deploy="$tmp/workspace/openbmc/build/romulus/tmp/deploy/images/romulus"
    mkdir -p "$deploy" "$tmp/workspace/configs"
    : > "$tmp/workspace/configs/romulus.init-done"
    : > "$tmp/workspace/configs/romulus.snapshot"
    : > "$deploy/romulus.static.mtd"
}
# 直接造候选 + 跑(同 exit_codes.sh _setup_start_qemu_candidates 形态)
_tmp="$(mktemp -d)"; _rc3_tmp_helper "$_tmp"; _rc=0
(
    OB_NO_MAIN=1 source "$OB"; set +e
    detect_harness_root() {
        HARNESS_ROOT="$_tmp"; WORKSPACE_DIR="$HARNESS_ROOT/workspace"
        OPENBMC_DIR="$WORKSPACE_DIR/openbmc"; BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
        SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"; CONFIGS_DIR="$WORKSPACE_DIR/configs"
        SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
        QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"; QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
    }
    parse_args verify; detect_harness_root; cmd_verify
) </dev/null >/dev/null 2>&1 || _rc=$?
rm -rf "$_tmp"
[[ "$_rc" -eq 3 ]] && _assert_ok "verify candidates non-TTY → exit 3 (rc=$_rc)" || _assert_bad "verify candidates non-TTY (rc=$_rc want 3)"

assert_summary
