#!/usr/bin/env bash
# tests/protocol/deploy_to_qemu_machine_selection.sh — cmd_deploy_to_qemu machine-selection 序言行为 pin。
# 锁 deploy 的 empty 路径(无 MACHINE + 无 initialized machine → exit 3 + remedy), 改造走 guard 前后同态。
# 仿 start_qemu_remedy.sh 的 detect_harness_root mock + setup_fn + subshell 范式;
#   parse_args 在 `source "$OB"` 后可见、对无 machine 子命令设 MACHINE 空——由 start_qemu_remedy.sh:88-99
#   同模式已验证(同构先例), 非假设。empty 路径在 guard 第一关(initialized 集合空)就 exit 3, 不到
#   image-ready 判定, 故 mock 不含 image 路径。
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

run_deploy_case() {
    local setup_fn="$1"; shift
    local tmp output="" rc=0
    tmp="$(mktemp -d)"
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
            cmd_deploy_to_qemu
        ) </dev/null 2>&1
    ) || rc=$?
    DEPLOY_CASE_OUTPUT="$output"; DEPLOY_CASE_RC="$rc"
    rm -rf "$tmp"
}

setup_no_initialized() { :; }   # 空 configs(无 init-done) → machine_state_initialized_machines 空
setup_has_initialized() {       # 有 initialized(init-done) + 无 MACHINE + 非 TTY → 命中 nontty(N1)
    local tmp_root="$1"
    : > "$tmp_root/workspace/configs/romulus.init-done"
}

# empty: 无 MACHINE + 无 initialized → exit 3 + remedy
run_deploy_case setup_no_initialized deploy-to-qemu
assert_eq "deploy empty rc=3" "$DEPLOY_CASE_RC" "3"
assert_contains "deploy empty diagnosis" "$DEPLOY_CASE_OUTPUT" "No initialized machines found."
assert_contains "deploy empty remedy" "$DEPLOY_CASE_OUTPUT" "Run 'ob init <machine>' first."

# nontty: 有 initialized + 无 MACHINE + 非 TTY(run_deploy_case 内 </dev/null) → exit 3 + terminal remedy
run_deploy_case setup_has_initialized deploy-to-qemu
assert_eq "deploy nontty rc=3" "$DEPLOY_CASE_RC" "3"
assert_contains "deploy nontty diagnosis" "$DEPLOY_CASE_OUTPUT" "No interactive terminal"
assert_contains "deploy nontty remedy" "$DEPLOY_CASE_OUTPUT" "ob deploy-to-qemu <machine>"

assert_summary
