#!/usr/bin/env bash
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

write_pid_file() {
    local pid_file="$1"
    local pid_value="$2"
    cat > "$pid_file" <<EOF
pid=$pid_value
machine=romulus
binary=qemu-system-arm
started_at=2026-06-20T00:00:00Z
ssh_port=2222
EOF
}

run_stop_case() {
    local tmp="$1"
    shift

    local output=""
    local rc=0
    output=$(
        (
            OB_NO_MAIN=1 source "$OB"
            set +e

            detect_harness_root() {
                HARNESS_ROOT="$tmp"
                WORKSPACE_DIR="$HARNESS_ROOT/workspace"
                OPENBMC_DIR="$WORKSPACE_DIR/openbmc"
                BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
                SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"
                CONFIGS_DIR="$WORKSPACE_DIR/configs"
                SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
                QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
                QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
            }

            parse_args "$@"
            detect_harness_root
            cmd_stop_qemu
        ) </dev/null 2>&1
    ) || rc=$?

    STOP_CASE_OUTPUT="$output"
    STOP_CASE_RC="$rc"
}

stale_tmp="$(mktemp -d)"
mkdir -p "$stale_tmp/workspace/qemu-bin/.pids"
write_pid_file "$stale_tmp/workspace/qemu-bin/.pids/romulus.pid" "2147483647"

run_stop_case "$stale_tmp" stop-qemu --all -d
assert_eq "stop-qemu --all -d stale rc" "$STOP_CASE_RC" "0"
assert_true "stale pid file remains during dry-run" test -f "$stale_tmp/workspace/qemu-bin/.pids/romulus.pid"
rm -rf "$stale_tmp"

running_tmp="$(mktemp -d)"
mkdir -p "$running_tmp/workspace/qemu-bin/.pids"
setsid bash -c 'exec -a "qemu-system-arm-romulus" sleep 30' >/dev/null 2>&1 &
running_pid="$!"
write_pid_file "$running_tmp/workspace/qemu-bin/.pids/romulus.pid" "$running_pid"

run_stop_case "$running_tmp" stop-qemu romulus -d
assert_eq "stop-qemu romulus -d running rc" "$STOP_CASE_RC" "0"
assert_true "running process survives dry-run" kill -0 "$running_pid"
assert_true "running pid file remains during dry-run" test -f "$running_tmp/workspace/qemu-bin/.pids/romulus.pid"
kill "$running_pid" >/dev/null 2>&1 || true
wait "$running_pid" 2>/dev/null || true
rm -rf "$running_tmp"

assert_summary