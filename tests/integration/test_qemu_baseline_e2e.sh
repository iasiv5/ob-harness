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
#   report JSON: records AR 集合 == 该 machine baseline 全集(锁跑全, 防漏集) + per-AR 状态
#   匹配 applicability 期望(动态读 baseline, 不硬编码 AR ID → 对任何 machine 通用)。
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

# baseline 目录门(与 cmd_test_qemu 同序: custom 优先 > community; MISSING → SKIP 77)
_baseline_dir=""
test_qemu_resolve_baseline_dir "$MACHINE" _baseline_dir
if [[ "$_baseline_dir" == "MISSING" ]]; then
    echo "SKIP: no baseline dir for '$MACHINE' (expected tests/baseline/$MACHINE/ or contexts/baseline/$MACHINE/)"
    exit 77
fi

# 实例生命周期: 复用 running / 否则自起(started_by_test 标记收尾只清自己的)。
derive_qemu_paths
_liv=""
qemu_instance_liveness "$MACHINE" _liv
started_by_test=0
# 收尾 helper + trap(评审 🟡4: 中断/退出时清自起实例, 不遗留) — 注册在 start-qemu 前, 覆盖自起后任何 exit。
_stop_if_started() {
    [[ "$started_by_test" == "1" ]] || return 0
    ./ob stop-qemu "$MACHINE" --force >/dev/null 2>&1 || true
}
trap '_stop_if_started' EXIT INT TERM HUP
if [[ "$_liv" != "running" ]]; then
    echo "[integration] starting QEMU for '$MACHINE' (start-qemu --force)..."
    start_out="$(mktemp "${TMPDIR:-/tmp}/ob-tq-integ-start-XXXXXX")"
    start_rc=0
    # </dev/null 关 stdin(评审 🟡4: 避免端口冲突/首启 prompt 在继承 TTY 时交互挂起);
    # OB_INTEG_*_PORT 注入空闲端口(多用户环境避默认端口冲突; CI 单用户可不设)。
    _start_args=(start-qemu "$MACHINE" --force)
    [[ -n "${OB_INTEG_SSH_PORT:-}" ]] && _start_args+=(--ssh-port "$OB_INTEG_SSH_PORT")
    [[ -n "${OB_INTEG_REDFISH_PORT:-}" ]] && _start_args+=(--redfish-port "$OB_INTEG_REDFISH_PORT")
    [[ -n "${OB_INTEG_IPMI_PORT:-}" ]] && _start_args+=(--ipmi-port "$OB_INTEG_IPMI_PORT")
    ./ob "${_start_args[@]}" </dev/null >"$start_out" 2>&1 || start_rc=$?
    if [[ "$start_rc" -ne 0 ]]; then
        echo "FAIL: ob start-qemu rc=$start_rc (test-qemu needs a running instance)"
        sed 's/^/  | /' "$start_out"; rm -f "$start_out"; exit 1
    fi
    rm -f "$start_out"
    started_by_test=1
else
    echo "[integration] reusing running instance for '$MACHINE'"
fi

# Redfish readiness gate(连续 N 次 200, 对齐 smoke_e2e.sh Step 1b): 闭合 bmcweb boot flap race。
REDFISH_PORT="$(grep '^redfish_port=' "workspace/qemu-bin/.pids/${MACHINE}.pid" 2>/dev/null | cut -d= -f2)"
REDFISH_PORT="${REDFISH_PORT:-2443}"
_rb_attempts=0; _rb_max="${OB_INTEG_REDFISH_ATTEMPTS:-90}"; _rb_needed="${OB_INTEG_REDFISH_DEBOUNCE:-2}"
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
    echo "FAIL: '$MACHINE' Redfish not stable-200 within $((_rb_max*5))s budget (last code=$_rb_code; may still be booting — raise OB_INTEG_REDFISH_ATTEMPTS to extend, not necessarily a real outage)"
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

# 断言 2 (通用化, 评审 🟡3 + 用户问题3): records AR 集合 == 该 machine baseline 全集
# (锁跑全, 防漏集/空集 PASS) + per-AR 状态匹配 applicability 期望。动态读 $_baseline_dir,
# 不硬编码 AR ID → 对任何 machine 通用(romulus / custom 机都行)。
rm -f "$tq_out"
if ! python3 -c "
import json, yaml, sys
recs = {r['ar']: r['status'] for r in json.load(open(sys.argv[1]))['records']}
d = yaml.safe_load(open(sys.argv[2]))
appl = yaml.safe_load(open(sys.argv[3]))
default = appl.get('default', 'applicable')
overrides = appl.get('overrides', {})
expected_ars = {a['ar'] for a in d['ars']}
assert set(recs) == expected_ars, 'AR set mismatch: got %s want %s' % (sorted(recs), sorted(expected_ars))
for ar, status in recs.items():
    appl_st = overrides.get(ar, {}).get('status', default)
    if appl_st == 'skip':
        assert status == 'skip', '%s applicability=skip but got %s' % (ar, status)
    elif appl_st == 'xfail':
        assert status in ('xfail', 'xpass'), '%s applicability=xfail but got %s' % (ar, status)
    else:
        assert status in ('pass', 'fail'), '%s applicability=applicable but got %s (must actually execute)' % (ar, status)
print('AR set + per-status (from baseline) ok')
" "$report_json" "$_baseline_dir/ar_probes.yaml" "$_baseline_dir/applicability.yaml" 2>&1; then
    rm -f "$report_json"
    _stop_if_started
    exit 1
fi

rm -f "$report_json"
# 收尾: 只 stop 测试自起的实例, 不动复用的既有实例(评审 🟡7: 不误伤环境里其他 running instance)
_stop_if_started
echo "[integration] OK (test-qemu: $MACHINE rc=$tq_rc, AR set + per-status matched baseline)"
exit 0
