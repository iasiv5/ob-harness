#!/usr/bin/env bash
# tests/protocol/smoke_exit_contract.sh — criterion-1: lock the ob smoke exit-code contract.
# Verbatim contract (must match the smoke Options section of `ob --help`):
#   no machine arg                            → exit 3
#   machine given but no running instance     → exit 3
#   running instance + all 5 assertions pass  → exit 0
#   running instance + some assertion fails   → exit 1
# Pure stub-based: NO real QEMU, NO network, fast (runs in default run_all .sh suite).
#
# How a "running instance" is faked (so qemu_instance_liveness returns "running" without QEMU):
#   - a long-lived process whose /proc/<pid>/cmdline contains BOTH the binary path and
#     the machine name (via `exec -a "<binary> <machine>" sleep N`);
#   - a local python TCP listener on the SSH port (so the system-ready probe connects);
#   - PATH-injected stub curl (HTTP 200 + Redfish markers) and stub ipmitool
#     (rc 0 = all-pass / rc 1 = IPMI ✗).
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

TMP="$(mktemp -d)"; DB="$(mktemp -d)"
FAKE_PID=""; LISTENER_PID=""
cleanup() {
    [[ -n "$FAKE_PID"    ]] && kill "$FAKE_PID"    2>/dev/null || true
    [[ -n "$LISTENER_PID" ]] && kill "$LISTENER_PID" 2>/dev/null || true
    rm -rf "$TMP" "$DB"
}
trap cleanup EXIT

# _run_smoke <machine> <pid_content_or_empty> <stubdir_or_empty>
# Runs cmd_smoke in an isolated subshell with a stub workspace; echoes nothing,
# exit code = cmd_smoke's exit. Combines stdout+stderr on the captured fd.
_run_smoke() {
    local machine="${1:-}" pid_content="${2:-}" stubdir="${3:-}"
    (
        OB_NO_MAIN=1 source "$OB"; set +e
        detect_harness_root() {
            HARNESS_ROOT="$TMP"; WORKSPACE_DIR="$HARNESS_ROOT/workspace"
            OPENBMC_DIR="$WORKSPACE_DIR/openbmc"; BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
            SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"; CONFIGS_DIR="$WORKSPACE_DIR/configs"
            SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
            QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
            QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
        }
        mkdir -p "$TMP/workspace/qemu-bin/.pids"
        [[ -n "$pid_content" ]] && printf '%s' "$pid_content" > "$TMP/workspace/qemu-bin/.pids/${machine}.pid"
        MACHINE="$machine"
        detect_harness_root
        [[ -n "$stubdir" ]] && PATH="$stubdir:$PATH"
        OB_SMOKE_READY_ATTEMPTS=2 cmd_smoke
    )
}

# _setup_alive_instance <machine> <ipmi_rc>
# Side effects: starts a TCP listener (LISTENER_PID, free port → SSH_PORT) and a fake
# alive "qemu" process (FAKE_PID); writes stub curl (Redfish 200, URL-branching) and
# stub ipmitool (exit <ipmi_rc>) into $DB; assembles PID_CONTENT for the PID file.
_setup_alive_instance() {
    local machine="$1" ipmi_rc="$2"
    local port_file="$TMP/ssh_port"
    rm -f "$port_file"
    python3 - "$port_file" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(5)
with open(sys.argv[1], "w") as f: f.write(str(s.getsockname()[1]))
time.sleep(120)
PY
    LISTENER_PID=$!
    local i
    for i in $(seq 1 30); do [[ -s "$port_file" ]] && break; sleep 0.2; done
    SSH_PORT="$(cat "$port_file" 2>/dev/null || true)"
    [[ -n "$SSH_PORT" ]] || { echo "SETUP-FAIL: no listener port" >&2; return 1; }

    # fake alive qemu: /proc/$FAKE_PID/cmdline = "<binary> <machine>\0120\0"
    bash -c 'exec -a "/fake/qemu-system-arm '"$machine"'" sleep 120' &
    FAKE_PID=$!
    for i in $(seq 1 20); do [[ -d "/proc/$FAKE_PID" ]] && break; sleep 0.1; done

    # stub curl: root body has Redfish marker; Managers body has FirmwareVersion.
    mkfake_bin "$DB" curl
    cat > "$DB/.curl.sh" <<'CURL_SH'
case "$*" in
  *Managers/bmc*)
    printf '%s\n' '{"@odata.type":"#Manager.v1_5_0.Manager","ManagerType":"BMC","UUID":"abc","FirmwareVersion":"v2.15.0"}'
    printf '__OB_HTTP__200\n' ;;
  *)
    printf '%s\n' '{"@Redfish.Copyright":"OpenBMC","RedfishVersion":"1.17.0"}'
    printf '__OB_HTTP__200\n' ;;
esac
CURL_SH

    # stub ipmitool: rc 0 (all-pass) or rc 1 (IPMI ✗, mirrors image lacking RMCP+).
    mkfake_bin "$DB" ipmitool
    if [[ "$ipmi_rc" == "0" ]]; then
        stub_out "$DB" ipmitool "Device ID                 : 32"
    else
        stub_out  "$DB" ipmitool "Unable to establish IPMI v2 / RMCP+ session"
        stub_exit "$DB" ipmitool "$ipmi_rc"
    fi

    PID_CONTENT="pid=$FAKE_PID
user=${USER:-test}
machine=$machine
binary=/fake/qemu-system-arm
started_at=now
ssh_port=$SSH_PORT
redfish_port=2443
ipmi_port=2623
http_port=none
"
}

# === (1) no machine arg, no running instance → exit 3 + start-qemu nudge ===
rc=0; out="$(_run_smoke "" "" "" 2>&1)" || rc=$?
assert_eq "(1) no machine arg → exit 3" "$rc" "3"
assert_contains "(1) no-instance path nudges to ob start-qemu" "$out" "start-qemu"

# === (2) machine given, no PID file → exit 3 ===
rc=0; out="$(_run_smoke "romulus" "" "" 2>&1)" || rc=$?
assert_eq "(2) machine + no PID file → exit 3" "$rc" "3"

# === (1b) no machine arg BUT a running instance exists → exit 3 AND smoke lists it ===
# _run_smoke ties the .pid filename to its machine arg; for the empty-MACHINE case we
# seed the stub workspace with the alive instance's PID file by hand, then run MACHINE="".
_setup_alive_instance "romulus" 0
printf '%s' "$PID_CONTENT" > "$TMP/workspace/qemu-bin/.pids/romulus.pid"
rc=0; out="$(_run_smoke "" "" "$DB" 2>&1)" || rc=$?
assert_eq "(1b) no machine arg + running instance → exit 3" "$rc" "3"
assert_contains "(1b) smoke lists the running instance as a smokable target" "$out" "romulus"
kill "$FAKE_PID" 2>/dev/null || true
kill "$LISTENER_PID" 2>/dev/null || true
rm -f "$TMP/workspace/qemu-bin/.pids/romulus.pid"
FAKE_PID=""; LISTENER_PID=""

# === (3) running instance + all 5 pass → exit 0 ===
_setup_alive_instance "romulus" 0
rc=0; out="$(_run_smoke "romulus" "$PID_CONTENT" "$DB" 2>&1)" || rc=$?
assert_eq "(3) running + all 5 pass → exit 0" "$rc" "0"
_check_5=$(printf '%s' "$out" | grep -cE '^[[:space:]]*✓ ' || true)
assert_eq "(3) prints exactly 5 ✓ assertion lines" "$_check_5" "5"
assert_false "(3) all-pass path emits NO α truth-reporter line" grep -q "truth-reporter" <<<"$out"
assert_contains "(3) prints Smoke summary 5/5" "$out" "Smoke summary: 5/5 assertions passed"
assert_contains "(3) all-pass machine passthrough" "$out" "all smoke assertions passed for 'romulus'"
# tear down (3)'s instance before building (4)'s (clean port/PID space)
kill "$FAKE_PID" 2>/dev/null || true
kill "$LISTENER_PID" 2>/dev/null || true
FAKE_PID=""; LISTENER_PID=""

# === (4) running instance + some assertion fails (IPMI rc 1) → exit 1 ===
_setup_alive_instance "romulus" 1
rc=0; out="$(_run_smoke "romulus" "$PID_CONTENT" "$DB" 2>&1)" || rc=$?
assert_eq "(4) running + IPMI fail → exit 1" "$rc" "1"
assert_contains "(4) prints ✗ IPMI row" "$out" "✗ IPMI over LAN works"
assert_true  "(4) emits α truth-reporter clarification" grep -q "truth-reporter" <<<"$out"
assert_true  "(4) IPMI RAW shows generic RMCP+/LAN possible-cause hint" \
             grep -qi "RMCP+/LAN responder" <<<"$out"
assert_contains "(4) prints Smoke summary 4/5" "$out" "Smoke summary: 4/5 assertions passed"
assert_contains "(4) prints Failed assertions (1)" "$out" "Failed assertions (1)"
assert_contains "(4) fail machine passthrough" "$out" "smoke assertions failed for 'romulus'"
# RAW 块计数须锁 header 专属串 "RAW response (for localization)": 本用例 2>&1 合并捕获,
# error 收尾行 "...see ✗ rows + RAW responses above)." 含 "RAW response" 子串, 裸 grep 会
# 多算 1(2 而非 1)。勿简化回 grep -c "RAW response"。
_raw4=$(grep -c "RAW response (for localization)" <<<"$out" || true); assert_eq "(4) exactly 1 RAW block" "$_raw4" 1

assert_summary
