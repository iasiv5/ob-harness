#!/usr/bin/env bash
# tests/protocol/bitbake_env_entry_contract.sh — Characterize BitBake setup entry contracts.
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

TMP_DIRS=()

make_tmp() {
    local tmp
    tmp="$(mktemp -d)"
    TMP_DIRS+=("$tmp")
    echo "$tmp"
}

cleanup() {
    local tmp
    for tmp in "${TMP_DIRS[@]:-}"; do
        rm -rf "$tmp"
    done
}
trap cleanup EXIT

write_setup_marker() {
    local openbmc_dir="$1"
    local marker="$2"

    cat > "$openbmc_dir/setup" <<EOF
: > "$marker"
EOF
}

case_init_dry_run_skips_setup() {
    local tmp openbmc_dir marker rc
    tmp="$(make_tmp)"
    openbmc_dir="$tmp/openbmc"
    marker="$tmp/setup-called"
    mkdir -p "$openbmc_dir"
    write_setup_marker "$openbmc_dir" "$marker"

    OPENBMC_DIR="$openbmc_dir"
    BUILD_DIR="$openbmc_dir/build/romulus"
    MACHINE="romulus"
    DRY_RUN=1

    rc=0
    init_bitbake_env >/dev/null 2>&1 || rc=$?
    assert_eq "init dry-run rc" "$rc" "0"
    assert_false "init dry-run does not source setup" test -f "$marker"
}

case_generate_dep_graph_dry_run_skips_setup_and_bitbake() {
    local tmp openbmc_dir marker db rc
    tmp="$(make_tmp)"
    openbmc_dir="$tmp/openbmc"
    marker="$tmp/setup-called"
    db="$(make_tmp)"
    mkdir -p "$openbmc_dir"
    write_setup_marker "$openbmc_dir" "$marker"
    mkfake_bin "$db" bitbake

    OPENBMC_DIR="$openbmc_dir"
    BUILD_DIR="$openbmc_dir/build/romulus"
    MACHINE="romulus"
    DRY_RUN=1

    rc=0
    with_stub "$db" -- generate_dep_graph >/dev/null 2>&1 || rc=$?
    assert_eq "dep graph dry-run rc" "$rc" "0"
    assert_false "dep graph dry-run does not source setup" test -f "$marker"
    assert_false "dep graph dry-run does not call bitbake" test -f "$db/.bitbake.calls"
}

case_cmd_build_dry_run_skips_setup_and_bitbake() {
    local tmp workspace_dir openbmc_dir configs_dir marker db rc
    tmp="$(make_tmp)"
    workspace_dir="$tmp/workspace"
    openbmc_dir="$workspace_dir/openbmc"
    configs_dir="$workspace_dir/configs"
    marker="$tmp/setup-called"
    db="$(make_tmp)"
    mkdir -p "$openbmc_dir/.git" "$configs_dir"
    write_setup_marker "$openbmc_dir" "$marker"
    : > "$configs_dir/openbmc-source.manifest"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$configs_dir/romulus.init-done"
    mkfake_bin "$db" bitbake

    (
        PATH="$db:$PATH"
        WORKSPACE_DIR="$workspace_dir"
        OPENBMC_DIR="$openbmc_dir"
        CONFIGS_DIR="$configs_dir"
        SOURCE_MANIFEST_FILE="$configs_dir/openbmc-source.manifest"
        MACHINE="romulus"
        BUILD_DIR="$openbmc_dir/build/romulus"
        DRY_RUN=1
        cmd_build >/dev/null 2>&1
    )
    rc=$?

    assert_eq "build dry-run rc" "$rc" "0"
    assert_false "build dry-run does not source setup" test -f "$marker"
    assert_false "build dry-run does not call bitbake" test -f "$db/.bitbake.calls"
}

case_init_bitbake_env_handles_nounset_and_restores() {
    local tmp openbmc_dir build_dir configs_dir rc
    tmp="$(make_tmp)"
    openbmc_dir="$tmp/openbmc"
    build_dir="$openbmc_dir/build/romulus"
    configs_dir="$tmp/configs"
    mkdir -p "$openbmc_dir" "$configs_dir" "$tmp/home"
    cat > "$openbmc_dir/setup" <<'SETUP'
: "${OB_TEST_UNSET_FROM_SETUP}"
build_dir="$2"
mkdir -p "$build_dir/conf"
: > "$build_dir/conf/local.conf"
SETUP

    (
        set -u
        HOME="$tmp/home"
        OPENBMC_DIR="$openbmc_dir"
        BUILD_DIR="$build_dir"
        WORKSPACE_DIR="$tmp/workspace"
        CONFIGS_DIR="$configs_dir"
        MACHINE="romulus"
        DRY_RUN=0
        ensure_bootstrap_local_conf() { :; }
        init_bitbake_env >/dev/null 2>&1 || exit $?
        [[ "$(set -o | awk '$1 == "nounset" { print $2 }')" == "on" ]]
    )
    rc=$?

    assert_eq "init setup tolerates unset vars and restores nounset" "$rc" "0"
}

case_init_bitbake_env_missing_local_conf_exits_one() {
    local tmp openbmc_dir build_dir configs_dir
    tmp="$(make_tmp)"
    openbmc_dir="$tmp/openbmc"
    build_dir="$openbmc_dir/build/romulus"
    configs_dir="$tmp/configs"
    mkdir -p "$openbmc_dir" "$configs_dir"
    cat > "$openbmc_dir/setup" <<'SETUP'
: "${OB_TEST_UNSET_FROM_SETUP}"
mkdir -p "$2/conf"
SETUP

    assert_rc 1 "init missing local.conf exits 1" bash -c 'OB_NO_MAIN=1 source "$1"
set -u
OPENBMC_DIR="$2"
BUILD_DIR="$3"
WORKSPACE_DIR="$4"
CONFIGS_DIR="$5"
MACHINE="romulus"
DRY_RUN=0
init_bitbake_env' _ "$OB" "$openbmc_dir" "$build_dir" "$tmp/workspace" "$configs_dir"
}

case_qemu_bitbake_fallback_contract() {
    local tmp openbmc_dir build_dir db stdout stderr rc calls
    tmp="$(make_tmp)"
    openbmc_dir="$tmp/openbmc"
    build_dir="$openbmc_dir/build/romulus"
    db="$(make_tmp)"
    stdout="$tmp/stdout"
    stderr="$tmp/stderr"
    mkdir -p "$build_dir"
    cat > "$openbmc_dir/setup" <<'SETUP'
: "${OB_TEST_UNSET_FROM_SETUP}"
echo SETUP_STDERR_MARKER >&2
SETUP
    mkfake_bin "$db" bitbake
    stub_script "$db" bitbake 'echo BITBAKE_STDERR_MARKER >&2
cat <<EOF
QB_MACHINE="-machine romulus"
QB_MEM="-m 512"
QB_SYSTEM_NAME="qemu-system-arm"
EOF'

    rc=0
    with_stub "$db" -- bash -c 'OB_NO_MAIN=1 source "$1"
set -u
OPENBMC_DIR="$2"
BUILD_DIR="$3"
MACHINE="romulus"
resolve_qemu_launch_profile romulus' _ "$OB" "$openbmc_dir" "$build_dir" >"$stdout" 2>"$stderr" || rc=$?
    calls=0
    [[ -f "$db/.bitbake.calls" ]] && calls="$(wc -l < "$db/.bitbake.calls")"

    assert_eq "qemu fallback rc" "$rc" "0"
    assert_eq "qemu fallback calls bitbake once" "$calls" "1"
    assert_false "qemu fallback suppresses setup stderr" grep -Fq "SETUP_STDERR_MARKER" "$stderr"
    assert_false "qemu fallback suppresses bitbake stderr" grep -Fq "BITBAKE_STDERR_MARKER" "$stderr"
}

case_qemu_empty_bitbake_output_exits_one() {
    local tmp openbmc_dir build_dir db rc
    tmp="$(make_tmp)"
    openbmc_dir="$tmp/openbmc"
    build_dir="$openbmc_dir/build/romulus"
    db="$(make_tmp)"
    mkdir -p "$build_dir"
    cat > "$openbmc_dir/setup" <<'SETUP'
: "${OB_TEST_UNSET_FROM_SETUP}"
SETUP
    mkfake_bin "$db" bitbake
    stub_out "$db" bitbake ""

    rc=0
    with_stub "$db" -- bash -c 'OB_NO_MAIN=1 source "$1"
set -u
OPENBMC_DIR="$2"
BUILD_DIR="$3"
MACHINE="romulus"
resolve_qemu_launch_profile romulus' _ "$OB" "$openbmc_dir" "$build_dir" >/dev/null 2>&1 || rc=$?
    assert_eq "qemu empty bitbake output exits 1" "$rc" "1"
}

case_list_available_machines_captures_setup_stderr() {
    local tmp openbmc_dir output rc
    tmp="$(make_tmp)"
    openbmc_dir="$tmp/openbmc"
    mkdir -p "$openbmc_dir/.git"
    cat > "$openbmc_dir/setup" <<'SETUP'
: "${OB_TEST_UNSET_FROM_SETUP}"
echo "Use one of:" >&2
echo "  romulus   ast2600-evb" >&2
return 7
SETUP

    OPENBMC_DIR="$openbmc_dir"
    rc=0
    output=$(set -u; list_available_machines) || rc=$?
    assert_eq "list machines rc" "$rc" "0"
    assert_contains "list machines parses stderr romulus" "$output" "romulus"
    assert_contains "list machines parses stderr ast2600" "$output" "ast2600-evb"
}

case_init_dry_run_skips_setup
case_generate_dep_graph_dry_run_skips_setup_and_bitbake
case_cmd_build_dry_run_skips_setup_and_bitbake
case_init_bitbake_env_handles_nounset_and_restores
case_init_bitbake_env_missing_local_conf_exits_one
case_qemu_bitbake_fallback_contract
case_qemu_empty_bitbake_output_exits_one
case_list_available_machines_captures_setup_stderr

assert_summary