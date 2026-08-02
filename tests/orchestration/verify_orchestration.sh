#!/usr/bin/env bash
# tests/orchestration/verify_orchestration.sh — cmd_verify 编排族(probe/cleanup)smoke。
# 不启真实 QEMU; 用 PATH 注入 stub curl/ipmitool + 本地 python 监听器喂原始信号给 _verify_probe_*,
# 断言 probe→judge 链(sequencing)+ _verify_cleanup trap 回调(stub ob 记录调用)。
# 覆盖: (1) _verify_probe_redfish 解析 curl 输出 → _VF_REDFISH_CODE/BODY;
#       (2) _verify_probe_ipmi 捕 ipmitool rc/out;
#       (3) _verify_probe_ssh_tcp / _verify_tcp_probe 对 open/closed 端口的 rc;
#       (4) probe→judge 链: stubbed pass 信号 → judge return 0 + ✓; fail 信号 → return 1 + ✗;
#       (5) _verify_cleanup 调 'ob stop-qemu <machine> --force'(经 stub ob 记录)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

# 本地 assert_ne(assert.sh 未提供; 复用其 _assert_ok/_assert_bad)
assert_ne() { local l="$1" a="$2" e="$3"; [[ "$a" != "$e" ]] && _assert_ok "$l" || _assert_bad "$l (got '$a', expected != '$e')"; }

TMP="$(mktemp -d)"; DB="$(mktemp -d)"

# === (1) _verify_probe_redfish: fake curl 吐 body + __OB_HTTP__200 ===
mkfake_bin "$DB" curl
cat > "$DB/.curl.sh" <<'CURL_SH'
# 模拟真 curl 的 -w '%{http_code}': body 后附 __OB_HTTP__<code> 行
printf '%s\n' '{"@Redfish.Copyright":"OpenBMC","Name":"ServiceRoot","Id":"v1"}'
printf '__OB_HTTP__200\n'
CURL_SH
PATH="$DB:$PATH" _verify_probe_redfish 2443
assert_eq "redfish probe parses code 200" "$_VF_REDFISH_CODE" "200"
assert_contains "redfish probe body has marker" "$_VF_REDFISH_BODY" "@Redfish.Copyright"
# probe→judge 链(pass)
r=0; out=$(verify_judge_redfish_root "$_VF_REDFISH_CODE" "$_VF_REDFISH_BODY") || r=$?
assert_eq "redfish probe→judge pass returns 0" "$r" "0"
assert_contains "redfish probe→judge prints ✓" "$out" "✓"

# fail 信号: fake curl 吐 500 + 无 marker
cat > "$DB/.curl.sh" <<'CURL_SH'
printf '%s\n' '{"error":"internal"}'
printf '__OB_HTTP__500\n'
CURL_SH
PATH="$DB:$PATH" _verify_probe_redfish 2443
assert_eq "redfish probe parses code 500" "$_VF_REDFISH_CODE" "500"
r=0; out=$(verify_judge_redfish_root "$_VF_REDFISH_CODE" "$_VF_REDFISH_BODY") || r=$?
assert_eq "redfish probe→judge fail returns 1" "$r" "1"
assert_contains "redfish probe→judge fail prints ✗" "$out" "✗"

# curl 整体失败(rc!=0, 无输出)→ code 维持 "000"
stub_exit "$DB" curl 7
rm -f "$DB/.curl.out" "$DB/.curl.sh"
PATH="$DB:$PATH" _verify_probe_redfish 2443
assert_eq "redfish probe conn-fail → code 000" "$_VF_REDFISH_CODE" "000"

# === (2) _verify_probe_ipmi: fake ipmitool rc 0 / rc 1 ===
rm -f "$DB/.ipmitool.rc"
mkfake_bin "$DB" ipmitool
stub_out "$DB" ipmitool "Device ID                 : 32"
PATH="$DB:$PATH" _verify_probe_ipmi 2623
assert_eq "ipmi probe rc 0 on stub success" "$_VF_IPMI_RC" "0"
assert_contains "ipmi probe out has Device ID" "$_VF_IPMI_OUT" "Device ID"
r=0; out=$(verify_judge_ipmi_lan "$_VF_IPMI_RC" "$_VF_IPMI_OUT") || r=$?
assert_eq "ipmi probe→judge pass returns 0" "$r" "0"

stub_exit "$DB" ipmitool 1
stub_out "$DB" ipmitool "Unable to send RAW command"
PATH="$DB:$PATH" _verify_probe_ipmi 2623
assert_eq "ipmi probe rc 1 on stub fail" "$_VF_IPMI_RC" "1"
r=0; out=$(verify_judge_ipmi_lan "$_VF_IPMI_RC" "$_VF_IPMI_OUT") || r=$?
assert_eq "ipmi probe→judge fail returns 1" "$r" "1"

# === (3) _verify_tcp_probe / _verify_probe_ssh_tcp: open vs closed 端口 ===
# race-free open 端口: python 绑 0 → 把真实端口写文件 → 保持 listen
PORT_FILE="$TMP/port"
python3 - "$PORT_FILE" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(1)
with open(sys.argv[1], "w") as f:
    f.write(str(s.getsockname()[1]))
time.sleep(60)
PY
LISTENER_PID=$!
for _ in $(seq 1 20); do [[ -s "$PORT_FILE" ]] && break; sleep 0.2; done
OPEN_PORT="$(cat "$PORT_FILE" 2>/dev/null || true)"
if [[ -n "$OPEN_PORT" ]]; then
    assert_true  "tcp probe open port returns 0"  _verify_tcp_probe "$OPEN_PORT"
    _verify_probe_ssh_tcp "$OPEN_PORT"
    assert_eq    "ssh probe sets _VF_SSH_RC=0 on open" "$_VF_SSH_RC" "0"
else
    _assert_ok "tcp probe open port (SKIPPED — no listener)"
fi
kill "$LISTENER_PID" 2>/dev/null || true

# closed port(1)→ refused, 即时非0
assert_false "tcp probe closed port(1) returns non-zero" _verify_tcp_probe 1
_verify_probe_ssh_tcp 1
assert_ne "ssh probe sets _VF_SSH_RC!=0 on closed" "$_VF_SSH_RC" "0"

# === (4) _verify_cleanup: stub ob 记录 stop-qemu 调用 ===
_FAKEOB="$TMP/fakeobdir"; mkdir -p "$_FAKEOB"
_VERIFY_CLEANUP_CALLS="$TMP/cleanup.calls"
: > "$_VERIFY_CLEANUP_CALLS"
# unquoted heredoc: $CALLS_FILE 在写脚本时展开成字面路径; \$* 留到 fake ob 运行时展开。
CALLS_FILE="$_VERIFY_CLEANUP_CALLS"
cat > "$_FAKEOB/ob" <<OBSH
#!/usr/bin/env bash
echo "ob \$*" >> "$CALLS_FILE"
exit 0
OBSH
chmod +x "$_FAKEOB/ob"
SAVED_OB_ENTRY_DIR="$OB_ENTRY_DIR"
OB_ENTRY_DIR="$_FAKEOB"
_verify_cleanup "romulus"
OB_ENTRY_DIR="$SAVED_OB_ENTRY_DIR"
assert_true "cleanup called stop-qemu"   grep -q 'stop-qemu' "$_VERIFY_CLEANUP_CALLS"
assert_true "cleanup passed machine romulus" grep -q 'romulus' "$_VERIFY_CLEANUP_CALLS"
assert_true "cleanup used --force"       grep -q -- '--force' "$_VERIFY_CLEANUP_CALLS"

# cleanup 对空 machine 早退(不调 ob)
: > "$_VERIFY_CLEANUP_CALLS"
OB_ENTRY_DIR="$_FAKEOB"
_verify_cleanup ""
OB_ENTRY_DIR="$SAVED_OB_ENTRY_DIR"
assert_eq "cleanup empty machine → no ob call" "$(wc -l < "$_VERIFY_CLEANUP_CALLS" | tr -d ' ')" "0"

rm -rf "$TMP" "$DB"
assert_summary
