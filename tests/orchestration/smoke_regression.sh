#!/usr/bin/env bash
# tests/orchestration/smoke_regression.sh — tools/smoke_regression.sh 编排族测试。
# 用 PATH 注入 stub `ob`(按调用计数轮放 baseline/current fixture), 无需真实 QEMU,
# 断言 gate 的 baseline→change→current→diff→exit 链路(exit 透传语义)。
# 覆盖: (a) 两份相同输出 → exit 0; (b) ✓→✗ 退化对 → exit 1; (c) ob smoke exit 3(前置缺失) → 透传 exit 3。
# 范式对照 tests/orchestration/smoke_orchestration.sh 的 PATH/stub 注入。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO/tools/smoke_regression.sh"
DIFF="$REPO/tools/smoke_diff.py"
test -f "$GATE" || { echo "MISSING $GATE" >&2; exit 1; }
test -f "$DIFF" || { echo "MISSING $DIFF" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 固定 fixture(镜像真实 ob smoke 的 judge 行形态: 2 空格 + mark + 空格 + 断言名 + 括号细节)
cat > "$TMP/base_ok.txt" <<'EOF'
Smoke assertions for 'romulus'
  ✓ Redfish root reachable (HTTP 200, Redfish structural marker present)
  ✓ Redfish Managers reachable (HTTP 200, Manager resource present)
  ✓ Redfish SoftwareVersion reported (BMC reports firmware version v2.15.0)
  ✓ IPMI over LAN works (ipmitool mc info exit 0)
  ✓ System ready signal (SSH port TCP-connectable)
EOF

# current 退化对(IPMI ✓→✗)
cat > "$TMP/cur_regression.txt" <<'EOF'
Smoke assertions for 'romulus'
  ✓ Redfish root reachable (HTTP 200, Redfish structural marker present)
  ✓ Redfish Managers reachable (HTTP 200, Manager resource present)
  ✓ Redfish SoftwareVersion reported (BMC reports firmware version v2.15.0)
  ✗ IPMI over LAN works (ipmitool exit 1 — Unable to establish RMCP+ session)
  ✓ System ready signal (SSH port TCP-connectable)
EOF

# ── stub ob 生成器: 按调用计数轮放 fixture ──
# stub 第一次调用(=baseline) cat $BASE_FIX exit $BASE_RC;
# 第二次调用(=current) cat $CUR_FIX exit $CUR_RC。
# env: STUB_STATE(counter file) / BASE_FIX / CUR_FIX / BASE_RC / CUR_RC
make_stub_ob() {
    local bindir="$1"
    cat > "$bindir/ob" <<'OB_SH'
#!/usr/bin/env bash
# stub ob: 把 `ob smoke <m>` 路由到 fixture, 按调用计数轮放 baseline/current。
CNT="$(cat "$STUB_STATE" 2>/dev/null || echo 0)"; CNT=$((CNT+1)); echo "$CNT" > "$STUB_STATE"
case "$*" in
    *smoke*)
        if [[ "$CNT" -eq 1 ]]; then cat "$BASE_FIX"; exit "${BASE_RC:-0}"; fi
        cat "${CUR_FIX:-$BASE_FIX}"; exit "${CUR_RC:-0}"
        ;;
esac
exit 0
OB_SH
    chmod +x "$bindir/ob"
}

# ── 跑 gate 并捕 exit(经 PATH-stub, 改变命令固定 true) ──
# 用法: run_gate <base_fix> <base_rc> <cur_fix> <cur_rc> → 设 GR (gate exit)
run_gate() {
    local bindir="$TMP/bin"
    rm -rf "$bindir"; mkdir -p "$bindir"
    make_stub_ob "$bindir"
    echo 0 > "$TMP/.cnt"   # 重置计数器: 每次跑 gate 都从 baseline(第1次调用)开始
    local rc=0
    PATH="$bindir:$PATH" \
        STUB_STATE="$TMP/.cnt" BASE_FIX="$1" BASE_RC="$2" CUR_FIX="$3" CUR_RC="$4" \
        bash "$GATE" romulus -- true >/dev/null 2>&1 || rc=$?
    GR="$rc"
}

# === (a) 两份相同输出 → gate exit 0(无退化) ===
GR=255; run_gate "$TMP/base_ok.txt" 0 "$TMP/base_ok.txt" 0
assert_eq "(a) identical baseline/current → gate exit 0" "$GR" "0"

# === (b) ✓→✗ 退化对 → gate exit 1(diff 拦截) ===
GR=255; run_gate "$TMP/base_ok.txt" 0 "$TMP/cur_regression.txt" 1
assert_eq "(b) ✓→✗ regression → gate exit 1" "$GR" "1"

# === (b-explicit) 真跑 gate 取 stdout, 验 diff 报告透传 ===
rm -rf "$TMP/bin"; mkdir -p "$TMP/bin"; make_stub_ob "$TMP/bin"
echo 0 > "$TMP/.cnt"
out=$(PATH="$TMP/bin:$PATH" STUB_STATE="$TMP/.cnt" \
      BASE_FIX="$TMP/base_ok.txt" BASE_RC=0 \
      CUR_FIX="$TMP/cur_regression.txt" CUR_RC=1 \
      bash "$GATE" romulus -- true 2>/dev/null) || true
assert_contains "(b) gate stdout 含 diff REGRESSION 报告" "$out" "REGRESSION"
assert_contains "(b) gate stdout 含 IPMI 退化项" "$out" "IPMI over LAN works"
assert_contains "(b) gate stdout 含 闸门拦截" "$out" "闸门拦截"

# === (c) ob smoke exit 3(前置缺失 = 无在跑实例) → 透传 exit 3(非 gate 失败) ===
GR=255; run_gate "$TMP/base_ok.txt" 3 "$TMP/cur_regression.txt" 0
assert_eq "(c) ob smoke exit 3 → gate 透传 exit 3" "$GR" "3"

# === (d) baseline exit 0 / current exit 3(改后实例挂了) → 透传 exit 3 ===
GR=255; run_gate "$TMP/base_ok.txt" 0 "$TMP/cur_regression.txt" 3
assert_eq "(d) current capture exit 3 → gate 透传 exit 3" "$GR" "3"

# === (e) gate exit 1 的真因是 diff, 非 ob smoke exit 1: gb200nvl 形态(baseline=current=4✓1✗) → exit 0 ===
# 验证"ob smoke exit 1(合法真相)不算 gate 失败": 两边同形态(IPMI ✗ 两边一致) → 无退化 → exit 0
cat > "$TMP/gb200_base.txt" <<'EOF'
Smoke assertions for 'gb200nvl-obmc'
  ✓ Redfish root reachable (HTTP 200, Redfish structural marker present)
  ✓ Redfish Managers reachable (HTTP 200, Manager resource present)
  ✓ Redfish SoftwareVersion reported (BMC reports firmware version v2.15.0)
  ✗ IPMI over LAN works (ipmitool exit 1 — Unable to establish RMCP+ session)
  ✓ System ready signal (SSH port TCP-connectable)
EOF
GR=255; run_gate "$TMP/gb200_base.txt" 1 "$TMP/gb200_base.txt" 1
assert_eq "(e) ob smoke exit 1 两边一致 → gate exit 0(真相非失败)" "$GR" "0"

assert_summary
