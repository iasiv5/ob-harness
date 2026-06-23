#!/usr/bin/env bash
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

setup_cmd_init_env() {
    MACHINE="romulus"
    SKIP_DEPS=0
    DRY_RUN=0

    WORKSPACE_DIR="$TMP/workspace"
    CONFIGS_DIR="$WORKSPACE_DIR/configs"
    OPENBMC_DIR="$WORKSPACE_DIR/openbmc"
    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
    SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"
    SOURCE_LOCK_FILE="$CONFIGS_DIR/openbmc-source.lock"
    QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
    QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"

    mkdir -p "$CONFIGS_DIR" "$OPENBMC_DIR/.git" "$QEMU_PIDS_DIR"
    cat > "$SOURCE_LOCK_FILE" <<'EOF'
normalized_source=github.com/openbmc/openbmc
origin_url=https://github.com/openbmc/openbmc.git
source_label=community
machine_first_init=
created_at=2026-06-23T00:00:00Z
EOF
}

stub_cmd_init_dependencies() {
    prerequisites_check() { :; }
    require_openbmc_repo() { return 0; }
    clone_openbmc() { :; }
    run_repo_init_script() { :; }
    resolve_machine() { MACHINE="romulus"; }
    init_bitbake_env() { :; }
    generate_dep_graph() { :; }
    clone_sub_repos() { :; }
    generate_machine_snapshot() { :; }
    generate_build_config() { :; }
    print_report() { echo "PRINT_REPORT"; }
}

run_cmd_init_case() {
    local fail_stage="$1"

    (
        setup_cmd_init_env
        stub_cmd_init_dependencies

        case "$fail_stage" in
            clear)
                machine_state_clear_init_progress() { return 1; }
                machine_state_mark_init_done() { return 0; }
                ;;
            mark)
                machine_state_clear_init_progress() { return 0; }
                machine_state_mark_init_done() { return 1; }
                ;;
        esac

        cmd_init
    ) 2>&1
}

output="$(run_cmd_init_case clear)"; rc=$?
assert_eq "init clear failure rc" "$rc" 1
assert_contains "init clear failure message" "$output" "Failed to clear machine state for 'romulus'."

output="$(run_cmd_init_case mark)"; rc=$?
assert_eq "init mark failure rc" "$rc" 1
assert_contains "init mark failure message" "$output" "Failed to write init-done marker: $TMP/workspace/configs/romulus.init-done"

assert_summary