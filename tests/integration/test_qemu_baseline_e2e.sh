#!/usr/bin/env bash
# tests/integration/test_qemu_baseline_e2e.sh — ob test-qemu real integration (opt-in via --integration)。
# 在真实 romulus QEMU 实例上跑 5 条 baseline AR, 断言五态 verdict + exit 契约成立。
#
# 生命周期(评审五轮 🟡1, 对照 smoke_e2e.sh start→probe→stop): 测试自管 QEMU 生命周期 ——
#   无 firmware image → exit 77 SKIP; 有 image 但无 running 实例 → ob start-qemu(started_by_test=1);
#   已有 running → 复用(started_by_test=0); 收尾只 stop 自己启动的, 不动复用的既有实例。
# Redfish readiness gate(评审六轮 🟡1, 对齐 smoke_e2e.sh Step 1b): ob start-qemu 的 BMC-ready 只等
#   SSH 不等 Redfish, bmcweb boot 窗口会 flap 200↔500, 5 条 Redfish probe 必踩 race —— 故测试层
#   轮询 Redfish root 连续 N 次 200 才放行 test-qemu。
# 断言: ob test-qemu rc ∈ {0,1}(α truth: 0 全 applicable pass / 1 有 fail = BMC 不满足 baseline);
#   report JSON: skip>=1(BMC-7-7-1)、xfail+xpass>=1(BMC-XF-1, 不强求 xfail>=1 否则 xpass 改善信号误判)。
set -uo pipefail

root_dir="${OB_INTEGRATION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$root_dir" || exit 1

# 工具前置: python3 + PyYAML(run.sh/report.py/probe_redfish.py) + curl(Redfish gate)
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 77; }
python3 -c "import yaml" 2>/dev/null        || { echo "SKIP: PyYAML not installed (run.sh/report.py need it)"; exit 77; }
command -v curl    >/dev/null 2>&1          || { echo "SKIP: curl not installed (Redfish readiness gate)"; exit 77; }

# firmware image 门: 用 ob 权威检测(machine_state_firmware_image_path, cmd_start_qemu 同款);
# 无 image → exit 77 SKIP(不阻断 run_all)。
# 注意: source ob_loader 会触发 ob 顶部全局 MACHINE="" 声明, 故 MACHINE 赋值须在 source 之后。
source tests/lib/ob_loader.sh
detect_harness_root
MACHINE="${OB_INTEGRATION_MACHINE:-romulus}"
img="$(machine_state_firmware_image_path "$MACHINE" 2>/dev/null || true)"
if [[ -z "$img" ]]; then
    echo "SKIP: no firmware image for '$MACHINE' (build it first: ob build $MACHINE)"
    exit 77
fi
echo "[integration] test-qemu machine=$MACHINE image=$img"

# 实例生命周期: 复用 running / 否则自起(started_by_test 标记收尾只清自己的)。
derive_qemu_paths
_liv=""
qemu_instance_liveness "$MACHINE" _liv
started_by_test=0
if [[ "$_liv" != "running" ]]; then
    echo "[integration] starting QEMU for '$MACHINE' (start-qemu --force)..."
    start_out="$(mktemp "${TMPDIR:-/tmp}/ob-tq-integ-start-XXXXXX")"
    start_rc=0
    ./ob start-qemu "$MACHINE" --force >"$start_out" 2>&1 || start_rc=$?
    if [[ "$start_rc" -ne 0 ]]; then
        echo "FAIL: ob start-qemu rc=$start_rc (test-qemu needs a running instance)"
        sed 's/^/  | /' "$start_out"; rm -f "$start_out"; exit 1
    fi
    rm -f "$start_out"
    started_by_test=1
else
    echo "[integration] reusing running instance for '$MACHINE'"
fi

# 收尾 helper: 只 stop 测试自起的实例(started_by_test==1), best-effort; 不动复用的既有实例。
_stop_if_started() {
    [[ "$started_by_test" == "1" ]] || return 0
    ./ob stop-qemu "$MACHINE" --force >/dev/null 2>&1 || true
}

# Redfish readiness gate(连续 N 次 200, 对齐 smoke_e2e.sh Step 1b): 闭合 bmcweb boot flap race。
REDFISH_PORT="$(grep '^redfish_port=' "workspace/qemu-bin/.pids/${MACHINE}.pid" 2>/dev/null | cut -d= -f2)"
REDFISH_PORT="${REDFISH_PORT:-2443}"
_rb_attempts=0; _rb_max="${OB_INTEG_REDFISH_ATTEMPTS:-30}"; _rb_needed="${OB_INTEG_REDFISH_DEBOUNCE:-2}"
_rb_consec=0; _rb_ready=0; _rb_code="000"
echo "[integration] waiting for Redfish root HTTP 200 ×${_rb_needed} consecutive (port ${REDFISH_PORT}, up to $((_rb_max*5))s)..."
while [[ $_rb_attempts -lt $_rb_max ]]; do
    _rb_attempts=$((_rb_attempts + 1))
    _rb_code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "https://localhost:${REDFISH_PORT}/redfish/v1" 2>/dev/null || echo 000)"
    if [[ "$_rb_code" == "200" ]]; then
        _rb_consec=$((_rb_consec + 1))
        [[ $_rb_consec -ge $_rb_needed ]] && { _rb_ready=1; break; }
        printf "\r  Redfish 200... confirming %d/%d (attempt %d)   " "$_rb_consec" "$_rb_needed" "$_rb_attempts"
    else
        _rb_consec=0
        printf "\r  Redfish not ready... attempt %d/%d (HTTP %s)   " "$_rb_attempts" "$_rb_max" "$_rb_code"
    fi
    sleep 5
done
echo ""
if [[ "$_rb_ready" -ne 1 ]]; then
    echo "FAIL: Redfish root never stable 200 within $((_rb_max*5))s (last code=$_rb_code) — real Redfish outage"
    _stop_if_started
    exit 1
fi

# ob test-qemu + JSON report
report_json="$(mktemp "${TMPDIR:-/tmp}/ob-tq-integ-report-XXXXXX.json")"
tq_out="$(mktemp "${TMPDIR:-/tmp}/ob-tq-integ-out-XXXXXX")"
tq_rc=0
./ob test-qemu "$MACHINE" --report "$report_json" >"$tq_out" 2>&1 || tq_rc=$?
echo "test-qemu rc=$tq_rc"
sed 's/^/  | /' "$tq_out"

# 断言 1: exit ∈ {0,1}(0 全 applicable pass / 1 α truth = BMC 不满足 baseline; 非 0/1 = test-qemu 异常)
if [[ "$tq_rc" != "0" && "$tq_rc" != "1" ]]; then
    echo "FAIL: test-qemu rc=$tq_rc (expected 0 or 1; 3=precondition lost after readiness gate — unexpected)"
    rm -f "$report_json" "$tq_out"
    _stop_if_started
    exit 1
fi

# 断言 2: report JSON 五态计数(skip>=1, xfail+xpass>=1)
_skip=$(python3 -c "import json; print(json.load(open('$report_json'))['counts'].get('skip',0))" 2>/dev/null || echo "?")
_xfp=$(python3 -c "import json; c=json.load(open('$report_json'))['counts']; print(c.get('xfail',0)+c.get('xpass',0))" 2>/dev/null || echo "?")
echo "report counts: skip=$_skip xfail+xpass=$_xfp"
rm -f "$tq_out"
if [[ "$_skip" == "?" || "$_skip" -lt 1 ]]; then
    echo "FAIL: expected skip>=1 (BMC-7-7-1 applicability), got skip=$_skip"
    rm -f "$report_json"
    _stop_if_started
    exit 1
fi
if [[ "$_xfp" == "?" || "$_xfp" -lt 1 ]]; then
    echo "FAIL: expected xfail+xpass>=1 (BMC-XF-1 verdict ∈ {xfail,xpass}), got xfail+xpass=$_xfp"
    rm -f "$report_json"
    _stop_if_started
    exit 1
fi

# 断言 3 (评审 🟡3): records AR 集合精确 == 5 ID + 各状态约束。
# 锁"确实跑了 5 条 AR"(非只聚合计数, 防漏集/空集 PASS); BMC-3-1-2 锁"实际执行 pass|fail",
# 不锁具体 α 结果(它依赖 romulus 真实行为)。
if ! python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
recs = {r['ar']: r['status'] for r in d['records']}
expected = {'BMC-2-2-1', 'BMC-3-15-1', 'BMC-3-1-2', 'BMC-7-7-1', 'BMC-XF-1'}
assert set(recs) == expected, 'AR set mismatch: got %s want %s' % (sorted(recs), sorted(expected))
assert recs['BMC-7-7-1'] == 'skip', 'BMC-7-7-1 not skip: %s' % recs['BMC-7-7-1']
assert recs['BMC-XF-1'] in ('xfail', 'xpass'), 'BMC-XF-1 not xfail/xpass: %s' % recs['BMC-XF-1']
for ar in ('BMC-2-2-1', 'BMC-3-15-1', 'BMC-3-1-2'):
    assert recs[ar] in ('pass', 'fail'), '%s not pass/fail (must actually execute): %s' % (ar, recs[ar])
print('AR set + per-status ok')
" "$report_json" 2>&1; then
    rm -f "$report_json"
    _stop_if_started
    exit 1
fi

rm -f "$report_json"
# 收尾: 只 stop 测试自起的实例, 不动复用的既有实例(评审 🟡7: 不误伤环境里其他 running instance)
_stop_if_started
echo "[integration] OK (test-qemu: $MACHINE rc=$tq_rc, skip=$_skip xfail+xpass=$_xfp)"
exit 0
