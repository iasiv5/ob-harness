#!/usr/bin/env bash
# Smoke test for ob — non-interactive paths only. Zero dependencies.
# Usage: bash tests/smoke_ob.sh
set -uo pipefail
# NOTE: do NOT set -e here — ob's `set -euo pipefail` would otherwise abort on first non-zero assert.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OB="$SCRIPT_DIR/../ob"
PASS=0; FAIL=0

assert_exit() {
    # assert_exit <expected_rc> <label> <cmd...>
    local exp="$1"; local label="$2"; shift 2
    local rc=0
    ( "$@" ) >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq "$exp" ]]; then PASS=$((PASS+1)); echo "ok   $label (rc=$rc)";
    else FAIL=$((FAIL+1)); echo "FAIL $label (expected rc=$exp got $rc)"; fi
}

# Load ob without triggering main. ob's own `set -euo pipefail` leaks into
# this harness via source; re-disable errexit so a non-zero assert doesn't
# abort the whole run. Keep nounset/pipefail.
OB_NO_MAIN=1 source "$OB" || { echo "source failed"; exit 1; }
set +e
echo "OB_NO_MAIN source OK"

# --- parse_args exit codes (each case runs in its own subshell via assert_exit) ---
assert_exit 0 "parse_args --help"      bash -c 'OB_NO_MAIN=1 source "$0"; parse_args --help' "$OB"
assert_exit 1 "parse_args unknown opt" bash -c 'OB_NO_MAIN=1 source "$0"; parse_args start-qemu --bogus-opt' "$OB"
assert_exit 1 "parse_args missing val" bash -c 'OB_NO_MAIN=1 source "$0"; parse_args start-qemu --ssh-port' "$OB"
# (dispatch / prerequisites tests added in Task 3)

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
