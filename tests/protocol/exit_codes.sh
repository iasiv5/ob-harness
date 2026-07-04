#!/usr/bin/env bash
# ob protocol 层退出码补全 —— 用临时 workspace 隔离真实仓库状态。
#
# 直接执行 ./ob 会把 WORKSPACE_DIR 固定到当前 harness 的 workspace/。
# 本脚本在子进程 source ob 后 override detect_harness_root，让 status/stop-qemu
# 等 case 只看到空的临时 workspace，避免受真实 QEMU PID 或 init-done 影响。
# shellcheck disable=SC1090,SC2034
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

assert_ob_rc() {
    local expected="$1" label="$2"
    shift 2

    local tmp
    tmp="$(mktemp -d)"

    local rc=0
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

        mkdir -p "$tmp/workspace/configs" "$tmp/workspace/qemu-bin/.pids"
        parse_args "$@"
        detect_harness_root

        # per-case setup hook（造候选/前置文件 + 可 override 函数）
        if [[ -n "${OB_RC_SETUP:-}" ]] && declare -F "$OB_RC_SETUP" >/dev/null; then
            "$OB_RC_SETUP" "$tmp"
        fi

        case "$COMMAND" in
            init)       cmd_init ;;
            build)      cmd_build ;;
            status)     cmd_status ;;
            start-qemu) cmd_start_qemu ;;
            stop-qemu)  cmd_stop_qemu ;;
            *)          exit 1 ;;
        esac
    ) </dev/null >/dev/null 2>&1 || rc=$?

    rm -rf "$tmp"
    if [[ "$rc" -eq "$expected" ]]; then
        _assert_ok "$label (rc=$rc)"
    else
        _assert_bad "$label (rc=$rc want $expected)"
    fi
}

assert_build_machine_parse() {
    local expected_machine="$1" label="$2"

    local actual_machine=""
    actual_machine=$( (
        OB_NO_MAIN=1 source "$OB"
        set +e
        parse_args build "$expected_machine"
        printf '%s' "$MACHINE"
    ) )

    assert_eq "$label" "$actual_machine" "$expected_machine"
}

# Empty isolated workspace protocol:
#   status and stop-qemu are informational when nothing exists, so they return 0.
#   init/build/start-qemu report missing prerequisites as 3.
assert_ob_rc 3 "init dry-run non-TTY without repo" init romulus -d --url https://github.com/openbmc/openbmc.git
assert_ob_rc 3 "build empty workspace" build
assert_ob_rc 3 "build <machine> positional accepted (empty ws)" build romulus
assert_build_machine_parse "romulus" "parse_args assigns MACHINE for build <machine>"
assert_ob_rc 0 "status empty workspace" status
assert_ob_rc 3 "start-qemu missing init-done" start-qemu romulus
assert_ob_rc 0 "stop-qemu no instances" stop-qemu

# ── per-case setup helpers（造候选 + 前置文件，让"有候选+非TTY"能真走到 guard）──
_setup_build_candidates() {
    local tmp="$1"
    mkdir -p "$tmp/workspace/openbmc/.git"
    printf 'origin_url=https://github.com/openbmc/openbmc.git\nsource_label=community\n' \
        > "$tmp/workspace/configs/openbmc-source.manifest"
    : > "$tmp/workspace/configs/romulus.init-done"
    : > "$tmp/workspace/configs/romulus.snapshot"
}
_setup_start_qemu_candidates() {
    local tmp="$1"
    local deploy="$tmp/workspace/openbmc/build/romulus/tmp/deploy/images/romulus"
    mkdir -p "$deploy"
    : > "$tmp/workspace/configs/romulus.init-done"
    : > "$tmp/workspace/configs/romulus.snapshot"
    : > "$deploy/romulus.static.mtd"
}
_setup_stop_qemu_candidates() {
    local tmp="$1"
    mkdir -p "$tmp/workspace/qemu-bin/.pids"
    : > "$tmp/workspace/qemu-bin/.pids/romulus.pid"
}
_setup_init_candidates() {
    local tmp="$1"
    mkdir -p "$tmp/workspace/openbmc/.git"
    printf 'origin_url=https://github.com/openbmc/openbmc.git\nsource_label=community\n' \
        > "$tmp/workspace/configs/openbmc-source.manifest"
    list_available_machines() { printf 'romulus\n'; }   # override（子 shell 内生效）
}

# 空 workspace 基线（锁现状）
assert_ob_rc 3 "start-qemu empty workspace" start-qemu

# 有候选 + 非 TTY = exit 3（关键回归门：防 caller 漏 [[ -t 0 ]] guard；
# 迁移时若某 caller 漏 guard → pick_machine 非 TTY read fail → exit_on_user_cancel exit 1，基线变红）
OB_RC_SETUP=_setup_build_candidates assert_ob_rc 3 "build candidates but non-TTY" build
OB_RC_SETUP=_setup_start_qemu_candidates assert_ob_rc 3 "start-qemu candidates but non-TTY" start-qemu
OB_RC_SETUP=_setup_stop_qemu_candidates assert_ob_rc 3 "stop-qemu candidates but non-TTY" stop-qemu
OB_RC_SETUP=_setup_init_candidates assert_ob_rc 3 "init candidates but non-TTY" init

assert_summary