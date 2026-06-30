#!/usr/bin/env bash
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

setup_no_marker() {
    :
}

setup_legacy_lock_only() {
    local tmp_root="$1"
    printf '{"sub_repos": []}\n' > "$tmp_root/workspace/configs/romulus.lock"
}

setup_init_done_only() {
    local tmp_root="$1"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$tmp_root/workspace/configs/romulus.init-done"
}

setup_init_done_build_dir_no_image() {
    local tmp_root="$1"
    setup_init_done_only "$tmp_root"
    mkdir -p "$tmp_root/workspace/openbmc/build/romulus"
}

setup_orphan_artifact() {
    local tmp_root="$1"
    local deploy_dir="$tmp_root/workspace/openbmc/build/romulus/tmp/deploy/images/romulus"
    mkdir -p "$deploy_dir"
    touch "$deploy_dir/romulus.static.mtd"
}

run_start_qemu_case() {
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
                SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
                QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
                QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
            }

            mkdir -p "$tmp/workspace/configs"
            "$setup_fn" "$tmp"

            parse_args "$@"
            detect_harness_root
            cmd_start_qemu
        ) </dev/null 2>&1
    ) || rc=$?

    START_QEMU_CASE_OUTPUT="$output"
    START_QEMU_CASE_RC="$rc"
    rm -rf "$tmp"
}

run_start_qemu_case setup_no_marker start-qemu
assert_eq "start-qemu without init-done rc" "$START_QEMU_CASE_RC" "3"
assert_contains "start-qemu without init-done remedy" "$START_QEMU_CASE_OUTPUT" "Run 'ob init <machine>' first."
assert_false "start-qemu without init-done remedy is single-command" grep -Fq "then 'ob build'" <<< "$START_QEMU_CASE_OUTPUT"

run_start_qemu_case setup_legacy_lock_only start-qemu romulus
assert_eq "start-qemu legacy lock only rc" "$START_QEMU_CASE_RC" "3"
assert_contains "start-qemu legacy lock only remedy" "$START_QEMU_CASE_OUTPUT" "Run 'ob init romulus' first."

run_start_qemu_case setup_orphan_artifact start-qemu romulus
assert_eq "start-qemu orphan artifact explicit rc" "$START_QEMU_CASE_RC" "3"
assert_contains "start-qemu orphan artifact explicit remedy" "$START_QEMU_CASE_OUTPUT" "Run 'ob init romulus' first."

run_start_qemu_case setup_init_done_only start-qemu
assert_eq "start-qemu init-done without build rc" "$START_QEMU_CASE_RC" "3"
assert_contains "start-qemu init-done without build diagnosis" "$START_QEMU_CASE_OUTPUT" "No firmware-image-ready machines found."
assert_contains "start-qemu init-done without build remedy" "$START_QEMU_CASE_OUTPUT" "Run 'ob build <machine>' first."
stale_built_prefix="No built"
stale_built_suffix=" machines"
assert_false "start-qemu init-done without build avoids built wording" grep -Fq "${stale_built_prefix}${stale_built_suffix}" <<< "$START_QEMU_CASE_OUTPUT"

run_start_qemu_case setup_init_done_build_dir_no_image start-qemu
assert_eq "start-qemu build dir without image rc" "$START_QEMU_CASE_RC" "3"
assert_contains "start-qemu build dir without image diagnosis" "$START_QEMU_CASE_OUTPUT" "No firmware-image-ready machines found."
assert_contains "start-qemu build dir without image remedy" "$START_QEMU_CASE_OUTPUT" "Run 'ob build <machine>' first."

assert_summary