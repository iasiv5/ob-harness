#!/usr/bin/env bash
# tests/orchestration/smoke_orchestration.sh — cmd_smoke 编排族(probe)smoke(probe-only, 无 cleanup)。
# 不启真实 QEMU; 用 PATH 注入 stub curl/ipmitool + 本地 python 监听器喂原始信号给 _smoke_probe_*,
# 断言 probe→judge 链(sequencing)。smoke 无 EXIT trap / 无 cleanup —— 本测试不覆盖 cleanup(已退役)。
# 覆盖: (1) _smoke_probe_redfish 解析 curl 输出 → nameref outvars(code/body);
#       (2) _smoke_probe_ipmi 捕 ipmitool rc/out → nameref outvars(rc/out);
#       (3) _smoke_probe_ssh_tcp / _smoke_tcp_probe 对 open/closed 端口的 rc → nameref outvar(rc);
#       (4) probe→judge 链: stubbed pass 信号 → judge return 0 + ✓; fail 信号 → return 1 + ✗。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

# 本地 assert_ne(assert.sh 未提供; 复用其 _assert_ok/_assert_bad)
assert_ne() { local l="$1" a="$2" e="$3"; [[ "$a" != "$e" ]] && _assert_ok "$l" || _assert_bad "$l (got '$a', expected != '$e')"; }

TMP="$(mktemp -d)"; DB="$(mktemp -d)"

# === (1) _smoke_probe_redfish: fake curl 吐 body + __OB_HTTP__200 → nameref outvars ===
# probe 经 nameref 回填(候选 B: 非 _VF_* 全局)。caller 传 outvar 名, callee local -n 写回。
mkfake_bin "$DB" curl
cat > "$DB/.curl.sh" <<'CURL_SH'
# 模拟真 curl 的 -w '%{http_code}': body 后附 __OB_HTTP__<code> 行
printf '%s\n' '{"@Redfish.Copyright":"OpenBMC","Name":"ServiceRoot","Id":"v1"}'
printf '__OB_HTTP__200\n'
CURL_SH
_rcode=""; _rbody=""
PATH="$DB:$PATH" _smoke_probe_redfish 2443 _rcode _rbody
assert_eq "redfish probe nameref code 200" "$_rcode" "200"
assert_contains "redfish probe nameref body has marker" "$_rbody" "@Redfish.Copyright"
# probe→judge 链(pass)
r=0; out=$(smoke_judge_redfish_root "$_rcode" "$_rbody") || r=$?
assert_eq "redfish probe→judge pass returns 0" "$r" "0"
assert_contains "redfish probe→judge prints ✓" "$out" "✓"

# fail 信号: fake curl 吐 500 + 无 marker
cat > "$DB/.curl.sh" <<'CURL_SH'
printf '%s\n' '{"error":"internal"}'
printf '__OB_HTTP__500\n'
CURL_SH
_rcode=""; _rbody=""
PATH="$DB:$PATH" _smoke_probe_redfish 2443 _rcode _rbody
assert_eq "redfish probe nameref code 500" "$_rcode" "500"
r=0; out=$(smoke_judge_redfish_root "$_rcode" "$_rbody") || r=$?
assert_eq "redfish probe→judge fail returns 1" "$r" "1"
assert_contains "redfish probe→judge fail prints ✗" "$out" "✗"

# curl 整体失败(rc!=0, 无输出)→ code 维持 "000"(nameref outvar 初始值)
stub_exit "$DB" curl 7
rm -f "$DB/.curl.out" "$DB/.curl.sh"
_rcode="PRE"; _rbody="PRE"
PATH="$DB:$PATH" _smoke_probe_redfish 2443 _rcode _rbody
assert_eq "redfish probe conn-fail → nameref code 000" "$_rcode" "000"
assert_eq "redfish probe conn-fail → nameref body 空" "$_rbody" ""

# === (1b) _smoke_probe_redfish_managers: fake curl 按 URL 答 Managers body → nameref outvars ===
# 一次 probe 喂 managers + swversion 两个 judge(深一层接口)。fake curl 按 $* 中的 URL 分支答。
rm -f "$DB/.curl.rc"   # 清除上方 conn-fail 段的 exit 7, 让 .curl.sh 重新生效
cat > "$DB/.curl.sh" <<'CURL_SH'
# 按请求 URL 答: Managers/bmc 给 Manager 资源 body(含 FirmwareVersion), 其它给 root body
case "$*" in
  *Managers/bmc*)
    printf '%s\n' '{"@odata.type":"#Manager.v1_5_0.Manager","ManagerType":"BMC","UUID":"abc","FirmwareVersion":"v2.15.0"}'
    printf '__OB_HTTP__200\n' ;;
  *)
    printf '%s\n' '{"@Redfish.Copyright":"x","RedfishVersion":"1.17.0"}'
    printf '__OB_HTTP__200\n' ;;
esac
CURL_SH
_mcode=""; _mbody=""
PATH="$DB:$PATH" _smoke_probe_redfish_managers 2443 _mcode _mbody
assert_eq "managers probe nameref code 200" "$_mcode" "200"
assert_contains "managers probe nameref body has ManagerType" "$_mbody" "ManagerType"
assert_contains "managers probe nameref body has FirmwareVersion" "$_mbody" "FirmwareVersion"
# probe→judge 链(managers pass)
r=0; out=$(smoke_judge_redfish_managers "$_mcode" "$_mbody") || r=$?
assert_eq "managers probe→judge pass returns 0" "$r" "0"
assert_contains "managers probe→judge prints ✓" "$out" "✓"
# probe→judge 链(swversion pass, 复用同一 managers body)
r=0; out=$(smoke_judge_redfish_swversion "$_mbody") || r=$?
assert_eq "swversion probe→judge pass returns 0" "$r" "0"
assert_contains "swversion probe→judge prints ✓" "$out" "✓"
assert_contains "swversion probe→judge prints version" "$out" "v2.15.0"

# fail 信号: fake curl 对 Managers/bmc 答 500 + 无 Manager 标记 → managers ✗; swversion ✗(无版本)
cat > "$DB/.curl.sh" <<'CURL_SH'
case "$*" in
  *Managers/bmc*) printf '%s\n' '{"error":"internal"}'; printf '__OB_HTTP__500\n' ;;
  *)             printf '%s\n' '{"RedfishVersion":"1.17.0"}'; printf '__OB_HTTP__200\n' ;;
esac
CURL_SH
_mcode=""; _mbody=""
PATH="$DB:$PATH" _smoke_probe_redfish_managers 2443 _mcode _mbody
assert_eq "managers probe nameref code 500" "$_mcode" "500"
r=0; out=$(smoke_judge_redfish_managers "$_mcode" "$_mbody") || r=$?
assert_eq "managers probe→judge fail returns 1" "$r" "1"
assert_contains "managers probe→judge fail prints ✗" "$out" "✗"
# swversion 复用 fail body(无 SoftwareVersion/FirmwareVersion) → fail
r=0; out=$(smoke_judge_redfish_swversion "$_mbody") || r=$?
assert_eq "swversion probe→judge fail(missing) returns 1" "$r" "1"
assert_contains "swversion probe→judge fail prints ✗" "$out" "✗"

# === (2) _smoke_probe_ipmi: fake ipmitool rc 0 / rc 1 → nameref outvars ===
rm -f "$DB/.ipmitool.rc"
mkfake_bin "$DB" ipmitool
stub_out "$DB" ipmitool "Device ID                 : 32"
_irc=""; _iout=""
PATH="$DB:$PATH" _smoke_probe_ipmi 2623 _irc _iout
assert_eq "ipmi probe nameref rc 0 on stub success" "$_irc" "0"
assert_contains "ipmi probe nameref out has Device ID" "$_iout" "Device ID"
r=0; out=$(smoke_judge_ipmi_lan "$_irc" "$_iout") || r=$?
assert_eq "ipmi probe→judge pass returns 0" "$r" "0"

stub_exit "$DB" ipmitool 1
stub_out "$DB" ipmitool "Unable to send RAW command"
_irc="PRE"; _iout=""
PATH="$DB:$PATH" _smoke_probe_ipmi 2623 _irc _iout
assert_eq "ipmi probe nameref rc 1 on stub fail" "$_irc" "1"
r=0; out=$(smoke_judge_ipmi_lan "$_irc" "$_iout") || r=$?
assert_eq "ipmi probe→judge fail returns 1" "$r" "1"

# === (3) _smoke_tcp_probe / _smoke_probe_ssh_tcp: open vs closed 端口 → nameref outvar ===
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
    assert_true  "tcp probe open port returns 0"  _smoke_tcp_probe "$OPEN_PORT"
    _src="PRE"
    _smoke_probe_ssh_tcp "$OPEN_PORT" _src
    assert_eq    "ssh probe nameref rc=0 on open" "$_src" "0"
else
    _assert_ok "tcp probe open port (SKIPPED — no listener)"
fi
kill "$LISTENER_PID" 2>/dev/null || true

# closed port(1)→ refused, 即时非0
assert_false "tcp probe closed port(1) returns non-zero" _smoke_tcp_probe 1
_src="PRE"
_smoke_probe_ssh_tcp 1 _src
assert_ne "ssh probe nameref rc!=0 on closed" "$_src" "0"

# smoke 无 cleanup trap: _smoke_cleanup / _verify_cleanup 函数已退役(qemu_commands.sh 不再定义)。
QCMDS="$(cd "$(dirname "$0")/../.." && pwd)/lib/qemu_commands.sh"
assert_false "smoke 退役: 无 _smoke_cleanup 函数" grep -q '^_smoke_cleanup()' "$QCMDS"
assert_false "smoke 退役: 无 _verify_cleanup 函数" grep -q '^_verify_cleanup()' "$QCMDS"
assert_false "smoke 退役: qemu_commands.sh 无 trap" grep -q 'trap ' "$QCMDS"

rm -rf "$TMP" "$DB"
assert_summary
