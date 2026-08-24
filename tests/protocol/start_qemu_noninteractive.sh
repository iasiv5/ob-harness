#!/usr/bin/env bash
# tests/protocol/start_qemu_noninteractive.sh — lock cmd_start_qemu's non-TTY
# confirmation-skip branch (bundled with ob test-qemu to make `start-qemu → test-qemu →
# stop-qemu` runnable non-interactively in CI/agent contexts).
#
# Background: cmd_start_qemu wraps its safety confirmation (confirm_action + the
# "Launching QEMU in 3 seconds" escape window) in `if [[ -t 0 ]]`. Non-TTY callers
# (CI, agent, run_all.sh with redirected stdin) skip the confirmation and proceed.
# Before this guard, confirm_action's `read` hit EOF on non-TTY → return 1 →
# cmd_start_qemu exit 1 (blocked). This test locks the non-TTY branch so a revert
# is caught at the fast protocol layer, not only by the slow integration layer
# (integration/test_qemu_baseline_e2e.sh exercises the chain end-to-end).
#
# Two sections:
#   (A) STRUCTURAL — the confirmation block IS gated by `[[ -t 0 ]]`, and a
#       non-TTY else-branch exists. Catches a guard removal textually.
#   (B) RUNTIME   — with stdin NOT a TTY and the launch pipeline stubbed out,
#       cmd_start_qemu proceeds past the confirmation (calls execute_launch,
#       prints the "Non-interactive start" info, prints NO confirmation banner).
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QC="$ROOT/lib/qemu_commands.sh"
test -f "$QC" || { echo "MISSING $QC" >&2; exit 1; }

# === (A) Structural: confirmation gated by [[ -t 0 ]] + non-TTY else exists ===
# Extract cmd_start_qemu body (awk: from definition line to first solo '}').
SQ_BODY="$(awk '/^cmd_start_qemu\(\)/{g=1} g{print; if($0=="}") exit}' "$QC")"
assert_true  "(A) cmd_start_qemu body gates confirmation on [[ -t 0 ]]" \
             grep -q '\[\[ -t 0 \]\]' <<<"$SQ_BODY"
assert_true  "(A) confirm_action is inside the body (the guarded call)" \
             grep -q 'confirm_action "start QEMU for"' <<<"$SQ_BODY"
assert_true  "(A) escape-window banner present in body" \
             grep -q 'Launching QEMU in 3 seconds' <<<"$SQ_BODY"
assert_true  "(A) non-interactive else-branch info present" \
             grep -q 'Non-interactive start' <<<"$SQ_BODY"

# Stronger structural lock: the confirm_action call must appear AFTER (on a later
# line than) the `[[ -t 0 ]]` guard, i.e. it is INSIDE the gated block, not before it.
_guard_ln=$(grep -n '\[\[ -t 0 \]\]' <<<"$SQ_BODY" | head -1 | cut -d: -f1)
_conf_ln=$(grep -n 'confirm_action "start QEMU for"' <<<"$SQ_BODY" | head -1 | cut -d: -f1)
if [[ -n "$_guard_ln" && -n "$_conf_ln" && "$_conf_ln" -gt "$_guard_ln" ]]; then
    _assert_ok "(A) confirm_action (line $_conf_ln) is inside the -t 0 block (guard line $_guard_ln)"
else
    _assert_bad "(A) confirm_action must be inside the [[ -t 0 ]] guard block (guard=$_guard_ln, confirm=$_conf_ln)"
fi

# === (B) Runtime: non-TTY stdin → skip confirmation, proceed to execute_launch ===
# Run cmd_start_qemu in a subshell with stdin from /dev/null (NOT a TTY), with the
# launch pipeline stubbed so no real QEMU is started. Capture stdout+stderr + record
# whether qemu_execute_launch was reached.
RUN_TMP="$(mktemp -d)"
trap 'rm -rf "$RUN_TMP"' EXIT

(
    set +e
    OB_NO_MAIN=1 source "$OB" >/dev/null 2>&1
    # Stub the launch pipeline so cmd_start_qemu reaches the confirmation block and
    # proceeds without starting QEMU or needing a real workspace/image.
    detect_harness_root() { :; }
    WORKSPACE_DIR="$RUN_TMP/workspace"
    machine_state_is_initialized() { return 0; }
    machine_state_deploy_dir() { echo "/tmp/fake-deploy"; }
    machine_state_firmware_image_path() { echo "/tmp/fake/image.mtd"; }
    derive_qemu_paths() {
        QEMU_PIDS_DIR="$RUN_TMP/.pids"; QEMU_PID_FILE="$QEMU_PIDS_DIR/x.pid"
        PIDFILE_PID=""; PIDFILE_BINARY=""; PIDFILE_MACHINE=""
    }
    qemu_instance_load() { return 1; }           # no existing instance → skip conflict block
    qemu_prepare_launch() {
        QEMU_LAUNCH_MACHINE_NAME="fake"; QEMU_LAUNCH_SOC_TYPE="fake-soc"
        QEMU_BIN_FILE="/tmp/fake/qemu"; QEMU_LAUNCH_SERIAL_LOG="/tmp/fake/serial.log"
        QEMU_CMD=(setsid /tmp/fake/qemu)
    }
    # Record that we reached (and would execute) the launch — the proof the
    # confirmation was skipped and cmd_start_qemu proceeded.
    qemu_execute_launch() { echo "EXECUTE_LAUNCH_REACHED"; return 0; }
    MACHINE="fake-machine"; DRY_RUN=0; QEMU_FORCE=0
    parse_args start-qemu "$MACHINE"
    cmd_start_qemu
) </dev/null >"$RUN_TMP/out" 2>&1
rc=$?
OUT="$(cat "$RUN_TMP/out")"

assert_eq    "(B) non-TTY cmd_start_qemu proceeds (rc 0)" "$rc" "0"
assert_true  "(B) non-TTY reached qemu_execute_launch (skipped confirmation)" \
             grep -q 'EXECUTE_LAUNCH_REACHED' <<<"$OUT"
assert_true  "(B) non-TTY prints 'Non-interactive start' info" \
             grep -q 'Non-interactive start' <<<"$OUT"
assert_false "(B) non-TTY prints NO confirm_action banner" \
             grep -q 'Type (Y/y) to confirm' <<<"$OUT"
assert_false "(B) non-TTY prints NO escape-window banner" \
             grep -q 'Launching QEMU in 3 seconds' <<<"$OUT"

assert_summary
