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
            SOURCE_LOCK_FILE="$CONFIGS_DIR/openbmc-source.lock"
            QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
            QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
        }

        mkdir -p "$tmp/workspace/configs" "$tmp/workspace/qemu-bin/.pids"
        parse_args "$@"
        detect_harness_root

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

# Empty isolated workspace protocol:
#   status and stop-qemu are informational when nothing exists, so they return 0.
#   init/build/start-qemu report missing prerequisites as 3.
assert_ob_rc 3 "init dry-run non-TTY without repo" init romulus -d --url https://github.com/openbmc/openbmc.git
assert_ob_rc 3 "build empty workspace" build
assert_ob_rc 0 "status empty workspace" status
assert_ob_rc 3 "start-qemu missing init-done" start-qemu romulus
assert_ob_rc 0 "stop-qemu no instances" stop-qemu

assert_summary