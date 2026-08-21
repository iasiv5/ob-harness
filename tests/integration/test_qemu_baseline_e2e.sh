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

# baseline 目录门(与 cmd_test_qemu 同判定: 谱系路由 community→tests/, custom→contexts/;
# MISSING → SKIP 77)。谱系单维度(source label, ADR-0026; strict 读取 — manifest 缺失/
# 字段空判 unknown 不 fallback, 2026-08-18 修订), 不依赖 liveness 的 PID 文件,
# 预检即完整判定(非宽预检)。
_lineage_pre=""
test_qemu_resolve_lineage _lineage_pre
_baseline_dir=""
test_qemu_resolve_baseline_dir "$_lineage_pre" "$MACHINE" _baseline_dir
if [[ "$_baseline_dir" == "MISSING" ]]; then
    echo "SKIP: no baseline dir for '$MACHINE' (lineage: $_lineage_pre; expected $([ "$_lineage_pre" == custom ] && echo contexts/baseline/$MACHINE/ || echo tests/baseline/$MACHINE/), ADR-0026)"
    exit 77
fi

# 实例生命周期: 复用 running / 否则自起(started_by_test 标记收尾只清自己的)。
derive_qemu_paths
_lifecycle_lock_fd=""; _lifecycle_lock_status=""
qemu_instance_lifecycle_lock_acquire "$MACHINE" _lifecycle_lock_fd _lifecycle_lock_status
case "$_lifecycle_lock_status" in
    ok)
        export OB_QEMU_LIFECYCLE_LOCK_FD="$_lifecycle_lock_fd"
        export OB_QEMU_LIFECYCLE_LOCK_MACHINE="$MACHINE"
        ;;
    busy)
        echo "SKIP: another QEMU lifecycle operation is active for '$MACHINE'"
        exit 77
        ;;
    *)
        echo "FAIL: cannot acquire QEMU lifecycle lock for '$MACHINE'"
        exit 1
        ;;
esac
_liv=""
qemu_instance_liveness "$MACHINE" _liv
started_by_test=0
_started_pid=""
_integ_serial_log="${OB_INTEG_SERIAL_LOG:-${TMPDIR:-/tmp}/ob-tq-${MACHINE}-$$.serial.log}"
_integ_serial_sock="${_integ_serial_log%.log}.sock"
start_out=""; report_json=""; tq_out=""
_stop_if_started() {
    [[ "$started_by_test" == "1" ]] || return 0
    local _cur=""
    qemu_instance_liveness "$MACHINE" _cur
    case "$_cur" in
        running)
            # The parent holds the machine lifecycle lock. Before PID capture,
            # any running instance created after the initial nopid check is ours.
            if [[ -z "$_started_pid" || "$PIDFILE_PID" == "$_started_pid" ]]; then
                qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
            fi
            ;;
        exited|recycled)
            if [[ -z "$_started_pid" || "$PIDFILE_PID" == "$_started_pid" ]]; then
                qemu_instance_clean_stale "$MACHINE"
            fi
            ;;
        nopid)
            # Covers SIGTERM after QEMU daemonized but before manifest publish.
            local pending_pid=""
            pending_pid=$(pgrep -u "$(whoami)" -f "$_integ_serial_sock" 2>/dev/null | head -1 || true)
            if [[ "$pending_pid" =~ ^[0-9]+$ ]]; then
                qemu_instance_stop "$pending_pid" "$QEMU_PID_FILE"
            fi
            ;;
    esac
}
_cleanup_integration() {
    _stop_if_started
    [[ -n "$start_out" ]] && rm -f "$start_out"
    [[ -n "$report_json" ]] && rm -f "$report_json"
    [[ -n "$tq_out" ]] && rm -f "$tq_out"
    qemu_instance_lifecycle_lock_release "$_lifecycle_lock_fd"
    unset OB_QEMU_LIFECYCLE_LOCK_FD OB_QEMU_LIFECYCLE_LOCK_MACHINE
}
trap '_cleanup_integration' EXIT
trap 'exit 130' INT TERM HUP
if [[ "$_liv" != "running" ]]; then
    # ownership 前置(评审 🟡3): start-qemu 写 PID 后、等 SSH 期间收到信号也能清(started_by_test 已 1)
    started_by_test=1
    echo "[integration] starting QEMU for '$MACHINE' (start-qemu, 不 --force 避误杀竞态实例, 评审 🔴2)..."
    start_out="$(mktemp "${TMPDIR:-/tmp}/ob-tq-integ-start-XXXXXX")"
    start_rc=0
    # </dev/null 关 stdin; 不 --force(遇冲突 exit 不杀对方, 评审 🔴2); --no-wait(E2E 自己 readiness gate, 评审 🟡3);
    # OB_INTEG_*_PORT 注入空闲端口(多用户避默认冲突)。
    _start_args=(start-qemu "$MACHINE")
    [[ -n "${OB_INTEG_SSH_PORT:-}" ]] && _start_args+=(--ssh-port "$OB_INTEG_SSH_PORT")
    [[ -n "${OB_INTEG_REDFISH_PORT:-}" ]] && _start_args+=(--redfish-port "$OB_INTEG_REDFISH_PORT")
    [[ -n "${OB_INTEG_IPMI_PORT:-}" ]] && _start_args+=(--ipmi-port "$OB_INTEG_IPMI_PORT")
    _start_args+=(--serial-log "$_integ_serial_log")
    _start_args+=(--no-wait)
    ./ob "${_start_args[@]}" </dev/null >"$start_out" 2>&1 || start_rc=$?
    if [[ "$start_rc" -ne 0 ]]; then
        echo "FAIL: ob start-qemu rc=$start_rc (test-qemu needs a running instance)"
        sed 's/^/  | /' "$start_out"; rm -f "$start_out"; exit 1
    fi
    rm -f "$start_out"
else
    echo "[integration] reusing running instance for '$MACHINE'"
fi

# start/reuse 后重新 liveness 拿当前端口 + 确认 running(评审 🟡2: start 子进程不更新父 PIDFILE_*)
_liv_post=""
qemu_instance_liveness "$MACHINE" _liv_post
if [[ "$_liv_post" != "running" || -z "$PIDFILE_REDFISH_PORT" ]]; then
    echo "FAIL: '$MACHINE' not running or no Redfish port after start/reuse"
    _stop_if_started
    exit 1
fi
[[ "$started_by_test" == "1" ]] && _started_pid="$PIDFILE_PID"   # 记录自起 PID(cleanup 身份校验, 评审 🔴2)

# Redfish readiness gate(连续 N 次 200, 对齐 smoke_e2e.sh Step 1b): 闭合 bmcweb boot flap race。
# 端口事实源 = qemu_instance_liveness 填的 PIDFILE_REDFISH_PORT(评审 🟡4: 不 grep PID file);
# 绝对 deadline(评审 🟡4: 不 attempts×(curl+sleep) 双倍预算)。
REDFISH_PORT="$PIDFILE_REDFISH_PORT"
_rb_budget="${OB_INTEG_REDFISH_BUDGET:-450}"
_rb_needed="${OB_INTEG_REDFISH_DEBOUNCE:-2}"
_rb_start=$(date +%s)
_rb_consec=0; _rb_ready=0; _rb_code="000"
echo "[integration] waiting for Redfish root HTTP 200 ×${_rb_needed} consecutive (port ${REDFISH_PORT}, budget ${_rb_budget}s)..."
while [[ $(( $(date +%s) - _rb_start )) -lt $_rb_budget ]]; do
    _remain=$(( _rb_budget - $(date +%s) + _rb_start ))
    (( _remain > 0 )) || break
    _ct=5; (( _remain < _ct )) && _ct=$_remain   # curl 按剩余截断(评审 🟡3: 配置 2s 不实际跑 5s)
    _rb_code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time "$_ct" "https://localhost:${REDFISH_PORT}/redfish/v1" 2>/dev/null) || _rb_code="${_rb_code:-000}"
    if [[ "$_rb_code" == "200" ]]; then
        _rb_consec=$((_rb_consec + 1))
        [[ $_rb_consec -ge $_rb_needed ]] && { _rb_ready=1; break; }
        printf "\r  Redfish 200... confirming %d/%d (%ss elapsed)   " "$_rb_consec" "$_rb_needed" "$(( $(date +%s) - _rb_start ))"
    else
        _rb_consec=0
        printf "\r  Redfish not ready... %ss elapsed (HTTP %s)   " "$(( $(date +%s) - _rb_start ))" "$_rb_code"
    fi
    _remain=$(( _rb_budget - $(date +%s) + _rb_start ))
    _st=5; (( _remain < _st )) && _st=$_remain; (( _st > 0 )) && sleep "$_st"
done
echo ""
if [[ "$_rb_ready" -ne 1 ]]; then
    echo "FAIL: '$MACHINE' Redfish not stable-200 within ${_rb_budget}s budget (last code=$_rb_code; may still be booting — raise OB_INTEG_REDFISH_BUDGET to extend, not necessarily a real outage)"
    _stop_if_started
    exit 1
fi

# ob test-qemu + JSON report. Retry only infra rc3: rc0/1 are deterministic
# baseline truth and must never be retried into a different verdict.
report_json="$(mktemp "${TMPDIR:-/tmp}/ob-tq-integ-report-XXXXXX.json")"
tq_out="$(mktemp "${TMPDIR:-/tmp}/ob-tq-integ-out-XXXXXX")"
tq_rc=3
_tq_attempt=0; _tq_max="${OB_INTEG_TEST_QEMU_ATTEMPTS:-3}"
while [[ "$_tq_attempt" -lt "$_tq_max" ]]; do
    _tq_attempt=$((_tq_attempt + 1))
    : > "$tq_out"
    tq_rc=0
    ./ob test-qemu "$MACHINE" --report "$report_json" >"$tq_out" 2>&1 || tq_rc=$?
    [[ "$tq_rc" != "3" ]] && break
    echo "[integration] test-qemu infra rc=3 (attempt $_tq_attempt/$_tq_max); retrying after 5s..."
    [[ "$_tq_attempt" -lt "$_tq_max" ]] && sleep 5
done
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
import json, os, sys
report = json.load(open(sys.argv[1]))
recs_list = report['records']
recs = {r['ar']: r['status'] for r in recs_list}
# records 唯一(评审 🟡1: 重复 AR 折叠丢, 防漏集/假绿)
assert len(recs_list) == len(recs), 'duplicate AR in records: %d records vs %d unique' % (len(recs_list), len(recs))
# 布局 v2: ar_probes 是薄顶层+分片, 直读 d['ars'] 拿不到 AR — 复用 runner loader
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'baseline', 'runner'))
import plan  # noqa: E402
d, appl = plan.load_inputs(sys.argv[2], sys.argv[3])
tq_rc = int(sys.argv[4])
default = appl.get('default', 'applicable')
overrides = appl.get('overrides', {})
# AR 集合 == baseline 全集(锁跑全, 防漏集)
expected_ars = {a['ar'] for a in d['ars']}
assert set(recs) == expected_ars, 'AR set mismatch: got %s want %s' % (sorted(recs), sorted(expected_ars))
# per-AR 状态匹配 applicability + core-suite applicable 必须 pass(评审 🔴2: core fail 不该绿)
ar_suite = {a['ar']: a.get('suite', '') for a in d['ars']}
for ar, status in recs.items():
    appl_st = overrides.get(ar, {}).get('status', default)
    if appl_st == 'skip':
        assert status == 'skip', '%s applicability=skip but got %s' % (ar, status)
    elif appl_st == 'xfail':
        assert status in ('xfail', 'xpass'), '%s applicability=xfail but got %s' % (ar, status)
    else:
        if ar_suite.get(ar) == 'core':
            assert status == 'pass', '%s core+applicable must pass, got %s' % (ar, status)
        else:
            assert status in ('pass', 'fail'), '%s applicable but got %s (must actually execute)' % (ar, status)
# 独立重算 verdict/counts(评审 🔴2/🟡1: 不同源 report, 防报告 bug + counts 精确比 report)
_STATUSES = ('pass', 'fail', 'skip', 'xfail', 'xpass', 'error')
recounts = {s: 0 for s in _STATUSES}
for r in recs_list:
    st = r.get('status') if isinstance(r, dict) else None
    if st in _STATUSES:
        recounts[st] += 1
    else:
        recounts['error'] += 1
assert report['counts'] == recounts, 'counts mismatch: report %s != recomputed %s' % (report['counts'], recounts)
if recounts.get('error', 0) > 0:
    re_verdict, exp_rc = 'ERROR', 3
elif recounts.get('fail', 0) > 0:
    re_verdict, exp_rc = 'FAIL', 1
else:
    re_verdict, exp_rc = 'PASS', 0
assert report['verdict'] == re_verdict, 'report verdict %s != recomputed %s' % (report['verdict'], re_verdict)
assert tq_rc == exp_rc, 'tq_rc %s != expected %s (verdict %s)' % (tq_rc, exp_rc, re_verdict)
print('AR set + per-status + verdict recompute + tq_rc consistency ok')
" "$report_json" "$_baseline_dir/ar_probes.yaml" "$_baseline_dir/applicability.yaml" "$tq_rc" 2>&1; then
    rm -f "$report_json"
    _stop_if_started
    exit 1
fi

rm -f "$report_json"
# 收尾: 只 stop 测试自起的实例, 不动复用的既有实例(评审 🟡7: 不误伤环境里其他 running instance)
_stop_if_started
echo "[integration] OK (test-qemu: $MACHINE rc=$tq_rc, AR set + per-status matched baseline)"
exit 0
