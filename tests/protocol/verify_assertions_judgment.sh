#!/usr/bin/env bash
# tests/protocol/verify_assertions_judgment.sh — leaf-pure 断言判函数族协议测试。
# 喂 STUBBED 原始信号(HTTP code+body / ipmitool rc / tcp rc)给 verify_judge_*,
# 断言每个判函数的 return 0/1 + ✓/✗ 输出 — 无需真实 QEMU/Redfish/IPMI/SSH。
# 锁定: (1) 三类断言判函数各自 pass/fail 决策边界; (2) ✓/✗ 行打印契约(per-assertion 一行)。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VA="$ROOT/lib/verify_assertions.sh"
test -f "$VA" || { echo "MISSING $VA" >&2; exit 1; }
# shellcheck disable=SC1090
source "$VA"

# ── 辅助: 跑判函数, 捕 return code + stdout ──
# 用法: run_judge <func> <args...>  → 设 JR (return) / JO (stdout)
run_judge() {
    JO=$("$@" 2>/dev/null); JR=$?
}

# === Redfish root 判函数: pass ⟺ code==200 AND body 含 @Redfish.Copyright ===
run_judge verify_judge_redfish_root "200" '{"@Redfish.Copyright":"OpenBMC","Name":"Root"}'
assert_eq   "redfish pass(legacy marker) returns 0" "$JR" "0"
assert_contains "redfish pass prints ✓"     "$JO" "✓"
assert_false   "redfish pass not ✗"         grep -q "✗" <<<"$JO"

# 现代 bmcweb 已弃用 @Redfish.Copyright, 改用 RedfishVersion / @odata.type ServiceRoot
run_judge verify_judge_redfish_root "200" '{"@odata.type":"#ServiceRoot.v1_15_0.ServiceRoot","RedfishVersion":"1.17.0"}'
assert_eq   "redfish pass(modern marker) returns 0" "$JR" "0"
assert_contains "redfish modern-marker prints ✓" "$JO" "✓"

run_judge verify_judge_redfish_root "200" '{"Name":"Root"}'   # 缺结构标记
assert_eq   "redfish no-marker returns 1"   "$JR" "1"
assert_contains "redfish no-marker prints ✗" "$JO" "✗"
assert_contains "redfish no-marker mentions marker" "$JO" "no Redfish structural marker"

run_judge verify_judge_redfish_root "404" '{"error":"not found"}'
assert_eq   "redfish 404 returns 1"         "$JR" "1"
assert_contains "redfish 404 prints HTTP code" "$JO" "404"

run_judge verify_judge_redfish_root "000" ""   # curl 整体失败
assert_eq   "redfish conn-fail(code 000) returns 1" "$JR" "1"
assert_contains "redfish conn-fail prints ✗" "$JO" "✗"

# === IPMI over LAN 判函数: pass ⟺ rc==0 ===
run_judge verify_judge_ipmi_lan "0"
assert_eq   "ipmi pass returns 0"           "$JR" "0"
assert_contains "ipmi pass prints ✓"        "$JO" "✓"
assert_contains "ipmi pass mentions mc info" "$JO" "mc info"

run_judge verify_judge_ipmi_lan "1" "Unable to send command"
assert_eq   "ipmi fail returns 1"           "$JR" "1"
assert_contains "ipmi fail prints ✗"        "$JO" "✗"
assert_contains "ipmi fail prints rc"       "$JO" "exit 1"
assert_contains "ipmi fail excerpt present" "$JO" "Unable to send"

# === System ready 判函数: pass ⟺ tcp rc==0 ===
run_judge verify_judge_system_ready "0"
assert_eq   "ssh-ready pass returns 0"      "$JR" "0"
assert_contains "ssh-ready pass prints ✓"   "$JO" "✓"
assert_contains "ssh-ready mentions TCP"    "$JO" "TCP"

run_judge verify_judge_system_ready "1"
assert_eq   "ssh-notready returns 1"        "$JR" "1"
assert_contains "ssh-notready prints ✗"     "$JO" "✗"

# === 三类各一行 ✓/✗ 的契约: 每个判函数恰好向 stdout 打一行(无多行噪声) ===
JO=$(verify_judge_redfish_root "0" "x" 2>/dev/null)
assert_eq "redfish judge prints exactly 1 line" "$(printf '%s\n' "$JO" | wc -l | tr -d ' ')" "1"
JO=$(verify_judge_ipmi_lan "0" 2>/dev/null)
assert_eq "ipmi judge prints exactly 1 line" "$(printf '%s\n' "$JO" | wc -l | tr -d ' ')" "1"
JO=$(verify_judge_system_ready "0" 2>/dev/null)
assert_eq "ssh judge prints exactly 1 line" "$(printf '%s\n' "$JO" | wc -l | tr -d ' ')" "1"

assert_summary
