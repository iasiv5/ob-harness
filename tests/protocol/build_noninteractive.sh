#!/usr/bin/env bash
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

FIXTURES_DIR="$(cd "$(dirname "$0")/../fixtures" && pwd)"

setup_no_marker() {
    :
}

setup_marker() {
    local tmp_root="$1"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$tmp_root/workspace/configs/romulus.init-done"
}

run_build_case() {
    local setup_fn="$1"
    shift

    local tmp
    tmp="$(mktemp -d)"

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
                SOURCE_LOCK_FILE="$CONFIGS_DIR/openbmc-source.lock"
                QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
                QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
            }

            mkdir -p "$tmp/workspace/openbmc/.git" "$tmp/workspace/configs"
            cp "$FIXTURES_DIR/source_lock.sample" "$tmp/workspace/configs/openbmc-source.lock"
            "$setup_fn" "$tmp"

            parse_args "$@"
            detect_harness_root
            cmd_build
        ) </dev/null 2>&1
    ) || rc=$?

    BUILD_CASE_OUTPUT="$output"
    BUILD_CASE_RC="$rc"
    rm -rf "$tmp"
}

run_build_case setup_no_marker build romulus
assert_eq "build <machine> without init-done rc" "$BUILD_CASE_RC" "3"
assert_contains "build <machine> without init-done remedy" "$BUILD_CASE_OUTPUT" "Run 'ob init romulus' first."
assert_false "build <machine> remedy is single-command" grep -Fq ", then:" <<< "$BUILD_CASE_OUTPUT"

run_build_case setup_marker build romulus -d
assert_eq "build <machine> dry-run rc" "$BUILD_CASE_RC" "0"

run_build_case setup_marker build
assert_eq "build without machine non-TTY rc" "$BUILD_CASE_RC" "3"
assert_contains "build without machine non-TTY remedy" "$BUILD_CASE_OUTPUT" "Specify a machine: ob build <machine>"

assert_summary