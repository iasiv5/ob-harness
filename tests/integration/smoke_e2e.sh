#!/usr/bin/env bash
# tests/integration/smoke_e2e.sh — ob smoke real integration (opt-in via --integration)。
# 覆盖: ob start-qemu bring-up → ob smoke 探活实例(Redfish/IPMI/ready 三类断言) → ob stop-qemu 总清。
# smoke 自己不 bring-up/teardown, 故 e2e 显式 start-qemu + stop-qemu 包夹 smoke。
# gate: 默认不跑(run_all --integration 追加); SKIP 门 exit 77(无 init-ready machine / 缺 curl/ipmitool / 无跑着的实例)。
# 真启 QEMU(~1-2min 到 BMC ready), 仅 CI / 手动 --integration 触发。
#
# 成功边界 = smoke rc=0(三类断言全 ✓); 任一断言 fail = rc=1(打印 raw response)。
# gb200nvl-obmc 已知: image 无 phosphor-ipmi-netbridged(RMCP+ IPMI-over-LAN 不可用),
# 故 gb200nvl 上 smoke 合法报 Redfish✓ IPMI✗ SSH✓ → rc=1(α by design: truth, 非失败)。
# 本测试对 gb200nvl 接受 rc=1 并断言其 breakdown(Redfish✓ / IPMI✗ / ready✓), 而非强求 rc=0。
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

# ── Step 2: ob smoke(probe-only — 不 bring-up/不 teardown) ──
smoke_out="$(mktemp "${TMPDIR:-/tmp}/ob-smoke-integ-XXXXXX")"
smoke_rc=0
./ob smoke "$MACHINE" >"$smoke_out" 2>&1 || smoke_rc=$?
echo "smoke rc=$smoke_rc"
sed 's/^/  | /' "$smoke_out"

# ── Step 3: 总清(smoke 不拥有 QEMU —— e2e 显式 stop) ──
./ob stop-qemu "$MACHINE" --force >/dev/null 2>&1 || true

# ── 断言: smoke 打印了 3 条断言行(每类至少一行 ✓/✗) ──
_assert_lines=$(grep -cE '^[[:space:]]*[✓✗] Redfish root reachable' "$smoke_out" || true)
_assert_lines=$((_assert_lines + $(grep -cE '^[[:space:]]*[✓✗] IPMI over LAN works' "$smoke_out" || true)))
_assert_lines=$((_assert_lines + $(grep -cE '^[[:space:]]*[✓✗] System ready signal' "$smoke_out" || true)))
if [[ "$_assert_lines" -lt 3 ]]; then
    echo "FAIL: expected 3 assertion lines (Redfish/IPMI/ready), got $_assert_lines"
    rm -f "$smoke_out"
    exit 1
fi

# gb200nvl 已知缺 RMCP+ → IPMI ✗ 合法(smoke α 报 truth), 接受 rc=1 + Redfish✓/ready✓/IPMI✗ breakdown。
# 其它 machine(如 romulus)装了 RMCP+ → 三类全 ✓, 期望 rc=0。
if [[ "$smoke_rc" -eq 0 ]]; then
    # 全 ✓ 路径: 三类都应是 ✓
    grep -q '✓ Redfish root reachable' "$smoke_out" || { echo "FAIL: missing Redfish ✓ line"; rm -f "$smoke_out"; exit 1; }
    grep -q '✓ IPMI over LAN works'    "$smoke_out" || { echo "FAIL: missing IPMI ✓ line";    rm -f "$smoke_out"; exit 1; }
    grep -q '✓ System ready signal'    "$smoke_out" || { echo "FAIL: missing ready ✓ line";   rm -f "$smoke_out"; exit 1; }
    rm -f "$smoke_out"
    echo "[integration] OK (smoke: 3/3 assertions passed for $MACHINE)"
    exit 0
fi

# smoke_rc=1: 接受的 α 路径 = Redfish✓ + ready✓ + IPMI✗(image 缺 RMCP+); 否则 FAIL。
# Redfish 与 ready 必须仍 ✓(这两个是 BMC 基本可达性, 与 image IPMI 配置无关)。
grep -q '✓ Redfish root reachable' "$smoke_out" || { echo "FAIL: rc=1 but Redfish not ✓ (unexpected — not the known IPMI-only gap)"; rm -f "$smoke_out"; exit 1; }
grep -q '✓ System ready signal'    "$smoke_out" || { echo "FAIL: rc=1 but ready not ✓ (unexpected — not the known IPMI-only gap)";   rm -f "$smoke_out"; exit 1; }
grep -q '✗ IPMI over LAN works'     "$smoke_out" || { echo "FAIL: rc=1 but IPMI not the failing one (unexpected breakdown)";         rm -f "$smoke_out"; exit 1; }
rm -f "$smoke_out"
echo "[integration] OK (smoke: α truth for $MACHINE — Redfish✓ IPMI✗(image lacks RMCP+) ready✓ → rc=1 by design)"
exit 0
