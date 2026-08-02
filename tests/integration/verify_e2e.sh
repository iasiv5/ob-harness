#!/usr/bin/env bash
# tests/integration/verify_e2e.sh — ob verify real integration (opt-in via --integration)。
# 覆盖: ob start-qemu bring-up + 真实 BMC 上的 Redfish/IPMI/ready 三类断言 + 总清。
# gate: 默认不跑(run_all --integration 追加); SKIP 门 exit 77(无 init-ready machine / 缺 curl/ipmitool)。
# 真启 QEMU(~1-2min 到 BMC ready), 仅 CI / 手动 --integration 触发。
# 成功边界 = verify rc=0(三类断言全 ✓); 任一断言 fail = rc=1(打印 raw response)。
set -uo pipefail

root_dir="${OB_INTEGRATION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$root_dir" || exit 1

# 工具前置(curl + ipmitool 是断言依赖; 缺则 SKIP, 不算失败)
command -v curl >/dev/null 2>&1     || { echo "SKIP: curl not installed (verify needs it for Redfish assertion)"; exit 77; }
command -v ipmitool >/dev/null 2>&1 || { echo "SKIP: ipmitool not installed (verify needs it for IPMI assertion)"; exit 77; }

# 探测 init-ready machine(env 覆盖 > 扫 workspace/configs/*.init-done; 照 ob_dev.sh:165-172)
MACHINE="${OB_INTEGRATION_MACHINE:-}"
if [[ -z "$MACHINE" ]]; then
    _marker=""
    for _marker in workspace/configs/*.init-done; do
        [[ -f "$_marker" ]] && MACHINE="$(basename "$_marker" .init-done)" && break
    done
fi
[[ -n "$MACHINE" ]] || { echo "SKIP: no initialized machine for verify integration"; exit 77; }
echo "[integration] verify machine=$MACHINE"

# e2e: ob verify(真启 QEMU + 跑断言 + 总清)
verify_out="$(mktemp "${TMPDIR:-/tmp}/ob-verify-integ-XXXXXX")"
verify_rc=0
./ob verify "$MACHINE" >"$verify_out" 2>&1 || verify_rc=$?
echo "verify rc=$verify_rc"
sed 's/^/  | /' "$verify_out"

if [[ "$verify_rc" -ne 0 ]]; then
    rm -f "$verify_out"
    echo "FAIL: verify rc=$verify_rc"
    exit 1
fi

# 断言: rc=0 时 stdout 含三类 ✓ 行(每类至少一行)
_pass_lines=$(grep -c '✓' "$verify_out" || true)
if [[ "$_pass_lines" -lt 3 ]]; then
    echo "FAIL: expected ≥3 ✓ assertion lines, got $_pass_lines"
    rm -f "$verify_out"
    exit 1
fi
grep -q '✓ Redfish root reachable'    "$verify_out" || { echo "FAIL: missing Redfish ✓ line"; rm -f "$verify_out"; exit 1; }
grep -q '✓ IPMI over LAN works'       "$verify_out" || { echo "FAIL: missing IPMI ✓ line";    rm -f "$verify_out"; exit 1; }
grep -q '✓ System ready signal'       "$verify_out" || { echo "FAIL: missing ready ✓ line";   rm -f "$verify_out"; exit 1; }

# 断言: 总清生效 — 无残留 QEMU .pid for this machine
if [[ -f "workspace/qemu-bin/.pids/$MACHINE.pid" ]]; then
    echo "FAIL: QEMU .pid left for '$MACHINE' (cleanup trap did not fire)"
    rm -f "$verify_out"
    exit 1
fi
rm -f "$verify_out"

echo "[integration] OK (verify: $_pass_lines assertions passed for $MACHINE, QEMU torn down)"
