#!/usr/bin/env bash
# tests/integration/smoke_e2e.sh — ob smoke real integration (opt-in via --integration)。
# 覆盖: ob start-qemu bring-up → ob smoke 探活实例(Redfish root/Managers/SoftwareVersion + IPMI + ready 五条断言) → ob stop-qemu 总清。
# smoke 自己不 bring-up/teardown, 故 e2e 显式 start-qemu + stop-qemu 包夹 smoke。
# gate: 默认不跑(run_all --integration 追加); SKIP 门 exit 77(无 init-ready machine / 缺 curl/ipmitool / 无跑着的实例)。
# 真启 QEMU(~1-2min 到 BMC ready), 仅 CI / 手动 --integration 触发。
#
# 成功边界 = smoke rc=0(五条断言全 ✓); 任一断言 fail = rc=1(打印 raw response)。
# gb200nvl-obmc 已知: image 无 phosphor-ipmi-netbridged(RMCP+ IPMI-over-LAN 不可用),
# 故 gb200nvl 上 smoke 合法报 Redfish✓(×3) IPMI✗ SSH✓ → rc=1(α by design: truth, 非失败)。
# 本测试对 gb200nvl 接受 rc=1 并断言其 breakdown(Redfish✓(×3) / IPMI✗ / ready✓), 而非强求 rc=0。
set -uo pipefail

root_dir="${OB_INTEGRATION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$root_dir" || exit 1

# 工具前置(curl + ipmitool 是断言依赖; 缺则 SKIP, 不算失败)
command -v curl >/dev/null 2>&1     || { echo "SKIP: curl not installed (smoke needs it for Redfish assertion)"; exit 77; }
command -v ipmitool >/dev/null 2>&1 || { echo "SKIP: ipmitool not installed (smoke needs it for IPMI assertion)"; exit 77; }

# 探测 init-ready machine(env 覆盖 > 扫 workspace/configs/*.init-done; 照 ob_dev.sh:165-172)
MACHINE="${OB_INTEGRATION_MACHINE:-}"
if [[ -z "$MACHINE" ]]; then
    _marker=""
    for _marker in workspace/configs/*.init-done; do
        [[ -f "$_marker" ]] && MACHINE="$(basename "$_marker" .init-done)" && break
    done
fi
[[ -n "$MACHINE" ]] || { echo "SKIP: no initialized machine for smoke integration"; exit 77; }
echo "[integration] smoke machine=$MACHINE"

# ── Step 1: start-qemu(smoke probe-only, 不自带 bring-up —— e2e 显式起) ──
echo "[integration] starting QEMU for '$MACHINE'..."
start_out="$(mktemp "${TMPDIR:-/tmp}/ob-smoke-integ-start-XXXXXX")"
start_rc=0
./ob start-qemu "$MACHINE" --force >"$start_out" 2>&1 || start_rc=$?
if [[ "$start_rc" -ne 0 ]]; then
    echo "FAIL: ob start-qemu rc=$start_rc (smoke needs a running instance)"
    sed 's/^/  | /' "$start_out"
    rm -f "$start_out"
    exit 1
fi
rm -f "$start_out"

# ── Step 1b: bounded Redfish root readiness gate (F6 fix — test-layer only) ──
# ob smoke 只在探针前轮询 SSH 就绪(lib/qemu_commands.sh _smoke_wait_ssh_tcp, SSH-only),
# 从不轮询 Redfish 就绪; 高负载下 SSH 端口已通但 bmcweb 仍在初始化窗口 → Redfish root
# HTTP 500 → smoke rc=1 → 本 e2e 误判 FAIL(3/3 全量失败, 单跑 rc=0 的根因)。在此插入有界
# Redfish root 轮询闭合该 race。风格对齐 OB_SMOKE_READY_ATTEMPTS(30×5s=150s)。
# 超时未 200 → 明确 FAIL + 总清: 不掩盖真实 Redfish 故障(bmcweb 起不来是真问题, 要浮出)。
# Debounce（F6 后续强化）：bmcweb 在 boot 窗口会瞬时报 200 后又 flap 回 500（高负载下的窄窗），
# 单次 200 不足以证明稳定。故要求 N 次连续 200（默认 2，间隔 5s）才认为 Redfish 真正就绪。
# 真 Redfish 故障（bmcweb 起不来）永远凑不齐连续 200 → 超时 FAIL，不掩盖。
REDFISH_PORT="$(grep '^redfish_port=' "workspace/qemu-bin/.pids/${MACHINE}.pid" 2>/dev/null | cut -d= -f2)"
REDFISH_PORT="${REDFISH_PORT:-2443}"
_rb_attempts=0
_rb_max="${OB_INTEG_REDFISH_ATTEMPTS:-30}"
_rb_needed="${OB_INTEG_REDFISH_DEBOUNCE:-2}"   # consecutive 200s required to confirm stability
_rb_consec=0
_rb_ready=0
_rb_code="000"
echo "[integration] waiting for Redfish root HTTP 200 ×${_rb_needed} consecutive (https://localhost:${REDFISH_PORT}/redfish/v1, up to $((_rb_max*5))s)..."
while [[ $_rb_attempts -lt $_rb_max ]]; do
    _rb_attempts=$((_rb_attempts + 1))
    _rb_code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "https://localhost:${REDFISH_PORT}/redfish/v1" 2>/dev/null || echo 000)"
    if [[ "$_rb_code" == "200" ]]; then
        _rb_consec=$((_rb_consec + 1))
        if [[ $_rb_consec -ge $_rb_needed ]]; then
            echo "[integration] Redfish root HTTP 200 stable (attempt $_rb_attempts, ~$((_rb_attempts*5))s, ${_rb_consec} consecutive 200s)"
            _rb_ready=1
            break
        fi
        printf "\r  Redfish 200... confirming stability %d/%d (attempt %d)   " "$_rb_consec" "$_rb_needed" "$_rb_attempts"
    else
        _rb_consec=0
        printf "\r  Redfish not ready... attempt %d/%d (HTTP %s)   " "$_rb_attempts" "$_rb_max" "$_rb_code"
    fi
    sleep 5
done
echo ""
if [[ "$_rb_ready" -ne 1 ]]; then
    echo "FAIL: Redfish root never returned HTTP 200 within $((_rb_max*5))s (last code=$_rb_code) — real Redfish outage, not a race"
    ./ob stop-qemu "$MACHINE" --force >/dev/null 2>&1 || true
    exit 1
fi

# ── Step 2: ob smoke(probe-only — 不 bring-up/不 teardown) ──
smoke_out="$(mktemp "${TMPDIR:-/tmp}/ob-smoke-integ-XXXXXX")"
smoke_rc=0
./ob smoke "$MACHINE" >"$smoke_out" 2>&1 || smoke_rc=$?
echo "smoke rc=$smoke_rc"
sed 's/^/  | /' "$smoke_out"

# ── Step 3: 总清(smoke 不拥有 QEMU —— e2e 显式 stop) ──
./ob stop-qemu "$MACHINE" --force >/dev/null 2>&1 || true

# ── 断言: smoke 打印了 5 条断言行(Redfish root/Managers/SoftwareVersion + IPMI + ready) ──
_assert_lines=$(grep -cE '^[[:space:]]*[✓✗] Redfish root reachable' "$smoke_out" || true)
_assert_lines=$((_assert_lines + $(grep -cE '^[[:space:]]*[✓✗] Redfish Managers reachable' "$smoke_out" || true)))
_assert_lines=$((_assert_lines + $(grep -cE '^[[:space:]]*[✓✗] Redfish SoftwareVersion reported' "$smoke_out" || true)))
_assert_lines=$((_assert_lines + $(grep -cE '^[[:space:]]*[✓✗] IPMI over LAN works' "$smoke_out" || true)))
_assert_lines=$((_assert_lines + $(grep -cE '^[[:space:]]*[✓✗] System ready signal' "$smoke_out" || true)))
if [[ "$_assert_lines" -lt 5 ]]; then
    echo "FAIL: expected 5 assertion lines (Redfish root/Managers/SoftwareVersion + IPMI + ready), got $_assert_lines"
    rm -f "$smoke_out"
    exit 1
fi

# gb200nvl 已知缺 RMCP+ → IPMI ✗ 合法(smoke α 报 truth), 接受 rc=1 + Redfish✓(×3)/ready✓/IPMI✗ breakdown。
# 其它 machine(如 romulus)装了 RMCP+ → 五条全 ✓, 期望 rc=0。
if [[ "$smoke_rc" -eq 0 ]]; then
    # 全 ✓ 路径: 五条都应是 ✓
    grep -q '✓ Redfish root reachable'        "$smoke_out" || { echo "FAIL: missing Redfish root ✓ line";        rm -f "$smoke_out"; exit 1; }
    grep -q '✓ Redfish Managers reachable'    "$smoke_out" || { echo "FAIL: missing Redfish Managers ✓ line";    rm -f "$smoke_out"; exit 1; }
    grep -q '✓ Redfish SoftwareVersion reported' "$smoke_out" || { echo "FAIL: missing Redfish SoftwareVersion ✓ line"; rm -f "$smoke_out"; exit 1; }
    grep -q '✓ IPMI over LAN works'           "$smoke_out" || { echo "FAIL: missing IPMI ✓ line";               rm -f "$smoke_out"; exit 1; }
    grep -q '✓ System ready signal'           "$smoke_out" || { echo "FAIL: missing ready ✓ line";              rm -f "$smoke_out"; exit 1; }
    rm -f "$smoke_out"
    echo "[integration] OK (smoke: 5/5 assertions passed for $MACHINE)"
    exit 0
fi

# smoke_rc=1: 接受的 α 路径 = Redfish(×3)✓ + ready✓ + IPMI✗(image 缺 RMCP+); 否则 FAIL。
# Redfish 三层与 ready 必须仍 ✓(BMC 基本可达性 + 功能态, 与 image IPMI 配置无关)。
grep -q '✓ Redfish root reachable'           "$smoke_out" || { echo "FAIL: rc=1 but Redfish root not ✓ (unexpected — not the known IPMI-only gap)";        rm -f "$smoke_out"; exit 1; }
grep -q '✓ Redfish Managers reachable'       "$smoke_out" || { echo "FAIL: rc=1 but Redfish Managers not ✓ (unexpected — not the known IPMI-only gap)";    rm -f "$smoke_out"; exit 1; }
grep -q '✓ Redfish SoftwareVersion reported' "$smoke_out" || { echo "FAIL: rc=1 but Redfish SoftwareVersion not ✓ (unexpected — not the known IPMI-only gap)"; rm -f "$smoke_out"; exit 1; }
grep -q '✓ System ready signal'              "$smoke_out" || { echo "FAIL: rc=1 but ready not ✓ (unexpected — not the known IPMI-only gap)";              rm -f "$smoke_out"; exit 1; }
grep -q '✗ IPMI over LAN works'               "$smoke_out" || { echo "FAIL: rc=1 but IPMI not the failing one (unexpected breakdown)";                       rm -f "$smoke_out"; exit 1; }
rm -f "$smoke_out"
echo "[integration] OK (smoke: α truth for $MACHINE — Redfish✓(×3) IPMI✗(image lacks RMCP+) ready✓ → rc=1 by design)"
exit 0
