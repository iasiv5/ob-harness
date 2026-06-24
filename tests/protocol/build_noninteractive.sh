#!/usr/bin/env bash
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

FIXTURES_DIR="$(cd "$(dirname "$0")/../fixtures" && pwd)"

setup_no_marker() {
    :
}

setup_snapshot_only() {
    local tmp_root="$1"
    cat > "$tmp_root/workspace/configs/romulus.snapshot" <<'EOF'
{
  "machine": "romulus",
  "generated_at": "2026-06-23T00:00:00+00:00",
  "openbmc_commit": "deadbeef1234",
  "target_image": "obmc-phosphor-image",
  "sub_repos": []
}
EOF
}

setup_legacy_lock_only() {
    local tmp_root="$1"
    printf '{"sub_repos": []}\n' > "$tmp_root/workspace/configs/romulus.lock"
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
                SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
                QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
                QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
            }

            mkdir -p "$tmp/workspace/openbmc/.git" "$tmp/workspace/configs"
            cp "$FIXTURES_DIR/source_manifest.sample" "$tmp/workspace/configs/openbmc-source.manifest"
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

run_build_case setup_snapshot_only build romulus
assert_eq "build <machine> snapshot-only rc" "$BUILD_CASE_RC" "3"
assert_contains "build <machine> snapshot-only remedy" "$BUILD_CASE_OUTPUT" "Run 'ob init romulus' first."

run_build_case setup_legacy_lock_only build romulus
assert_eq "build <machine> legacy lock only rc" "$BUILD_CASE_RC" "3"
assert_contains "build <machine> legacy lock only remedy" "$BUILD_CASE_OUTPUT" "Run 'ob init romulus' first."

run_build_case setup_marker build romulus -d
assert_eq "build <machine> dry-run rc" "$BUILD_CASE_RC" "0"

run_build_case setup_marker build
assert_eq "build without machine non-TTY rc" "$BUILD_CASE_RC" "3"
assert_contains "build without machine non-TTY remedy" "$BUILD_CASE_OUTPUT" "Specify a machine: ob build <machine>"

assert_summary