#!/usr/bin/env bash
# tests/unit/smoke_diff.sh — smoke_diff.py 逻辑自测(unit 层)。
# 用 here-doc fixture 钉死回归闸门口径: 仅 ✓→✗ = 回归(exit 1); 其余(版本变更/✗→✓/
#   新出现/消失)不算回归(exit 0)。fixture 镜像真实 `ob smoke` 输出形态
#   (mark + 断言名 + 括号细节; 含 breakdown 段重打 ✗ 的去重场景)。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$DIR/tools/smoke_diff.py"
test -f "$TOOL" || { echo "MISSING $TOOL" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# baseline: 五条全 ✓(Redfish×3 / IPMI / ready)
cat > "$TMP/base.txt" <<'EOF'
Smoke assertions for 'romulus'
  ✓ Redfish root reachable (HTTP 200, Redfish structural marker present)
  ✓ Redfish Managers reachable (HTTP 200, Manager resource present)
  ✓ Redfish SoftwareVersion reported (BMC reports firmware version v2.15.0)
  ✓ IPMI over LAN works (ipmitool mc info exit 0)
  ✓ System ready signal (SSH port TCP-connectable)
EOF

# --- 1. 无退化: 版本号变(v2.15.0→v2.16.0)但同名 ✓ → exit 0 ---
cat > "$TMP/cur_ok.txt" <<'EOF'
  ✓ Redfish root reachable (HTTP 200, Redfish structural marker present)
  ✓ Redfish Managers reachable (HTTP 200, Manager resource present)
  ✓ Redfish SoftwareVersion reported (BMC reports firmware version v2.16.0)
  ✓ IPMI over LAN works (ipmitool mc info exit 0)
  ✓ System ready signal (SSH port TCP-connectable)
EOF
out="$(python3 "$TOOL" "$TMP/base.txt" "$TMP/cur_ok.txt" 2>&1)"; rc=$?
assert_eq "no-regression (version change, same ✓) rc 0" "$rc" "0"
assert_contains "no-regression prints OK 闸门放行" "$out" "闸门放行"
assert_false "no-regression 不含 REGRESSION 字样" grep -q 'REGRESSION' <<<"$out"

# --- 2. 退化: IPMI ✓→✗ → exit 1 + 报退化项 ---
cat > "$TMP/cur_reg.txt" <<'EOF'
  ✓ Redfish root reachable (HTTP 200, Redfish structural marker present)
  ✓ Redfish Managers reachable (HTTP 200, Manager resource present)
  ✓ Redfish SoftwareVersion reported (BMC reports firmware version v2.15.0)
  ✗ IPMI over LAN works (ipmitool exit 1 — Unable to establish RMCP+ session)
  ✓ System ready signal (SSH port TCP-connectable)
EOF
out="$(python3 "$TOOL" "$TMP/base.txt" "$TMP/cur_reg.txt" 2>&1)"; rc=$?
assert_eq "regression (IPMI ✓→✗) rc 1" "$rc" "1"
assert_contains "regression prints REGRESSION"      "$out" "REGRESSION"
assert_contains "regression prints 退化项名"          "$out" "IPMI over LAN works"
assert_contains "regression prints 闸门拦截"          "$out" "闸门拦截"

# --- 3. 改善不算回归: baseline IPMI ✗ → current IPMI ✓ → exit 0 ---
cat > "$TMP/base_onefail.txt" <<'EOF'
  ✓ Redfish root reachable (HTTP 200, ...)
  ✓ Redfish Managers reachable (HTTP 200, ...)
  ✓ Redfish SoftwareVersion reported (BMC reports firmware version v2.15.0)
  ✗ IPMI over LAN works (ipmitool exit 1)
  ✓ System ready signal (SSH port TCP-connectable)
EOF
out="$(python3 "$TOOL" "$TMP/base_onefail.txt" "$TMP/cur_ok.txt" 2>&1)"; rc=$?
assert_eq "improvement (✗→✓) rc 0" "$rc" "0"
assert_contains "improvement prints 改善 info" "$out" "改善"

# --- 4. breakdown 重打去重: current 含 judge 行 + breakdown 段重打 ✗ name(无 detail) → 仍正确判该条 ---
cat > "$TMP/cur_dup.txt" <<'EOF'
Smoke assertions for 'gb200nvl-obmc'
  ✓ Redfish root reachable (HTTP 200, ...)
  ✓ Redfish Managers reachable (HTTP 200, ...)
  ✓ Redfish SoftwareVersion reported (BMC reports firmware version v2.15.0)
  ✗ IPMI over LAN works (ipmitool exit 1 — unable)
  ✓ System ready signal (SSH port TCP-connectable)
Failed assertions (1):
  ✗ IPMI over LAN works
----- RAW response (for localization) -----
EOF
out="$(python3 "$TOOL" "$TMP/base.txt" "$TMP/cur_dup.txt" 2>&1)"; rc=$?
assert_eq "breakdown-dup regression rc 1" "$rc" "1"
assert_contains "breakdown-dup 仍检出 IPMI 退化" "$out" "IPMI over LAN works"
# current 断言计数应 = 5(judge 行去重, breakdown 重打不重复计)
assert_contains "breakdown-dup current 计 5 条(去重)" "$out" "current 断言: 5 条"

# --- 5. 错误路径: 文件不存在 → exit 2 ---
assert_rc 2 "nonexistent file rc 2" python3 "$TOOL" "$TMP/base.txt" "$TMP/nope.txt"

# --- 6. --help → exit 0 + 打印 doc ---
out="$(python3 "$TOOL" --help 2>&1)"; rc=$?
assert_eq "--help rc 0" "$rc" "0"
assert_contains "--help prints 用法" "$out" "smoke baseline-diff"

assert_summary
