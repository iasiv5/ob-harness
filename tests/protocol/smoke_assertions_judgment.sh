#!/usr/bin/env bash
# tests/protocol/smoke_assertions_judgment.sh — leaf-pure 断言判函数族协议测试。
# 喂 STUBBED 原始信号(HTTP code+body / ipmitool rc / tcp rc)给 smoke_judge_*,
# 断言每个判函数的 return 0/1 + ✓/✗ 输出 — 无需真实 QEMU/Redfish/IPMI/SSH。
# 锁定: (1) 三类断言判函数各自 pass/fail 决策边界; (2) ✓/✗ 行打印契约(per-assertion 一行)。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SA="$ROOT/lib/smoke_assertions.sh"
test -f "$SA" || { echo "MISSING $SA" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SA"

# ── 辅助: 跑判函数, 捕 return code + stdout ──
# 用法: run_judge <func> <args...>  → 设 JR (return) / JO (stdout)
run_judge() {
    JO=$("$@" 2>/dev/null); JR=$?
}

# === Redfish root 判函数: pass ⟺ code==200 AND body 含 Redfish 结构标记 ===
run_judge smoke_judge_redfish_root "200" '{"@Redfish.Copyright":"OpenBMC","Name":"Root"}'
assert_eq   "redfish pass(legacy marker) returns 0" "$JR" "0"
assert_contains "redfish pass prints ✓"     "$JO" "✓"
assert_false   "redfish pass not ✗"         grep -q "✗" <<<"$JO"

# 现代 bmcweb 已弃用 @Redfish.Copyright, 改用 RedfishVersion / @odata.type ServiceRoot
run_judge smoke_judge_redfish_root "200" '{"@odata.type":"#ServiceRoot.v1_15_0.ServiceRoot","RedfishVersion":"1.17.0"}'
assert_eq   "redfish pass(modern marker) returns 0" "$JR" "0"
assert_contains "redfish modern-marker prints ✓" "$JO" "✓"

run_judge smoke_judge_redfish_root "200" '{"Name":"Root"}'   # 缺结构标记
assert_eq   "redfish no-marker returns 1"   "$JR" "1"
assert_contains "redfish no-marker prints ✗" "$JO" "✗"
assert_contains "redfish no-marker mentions marker" "$JO" "no Redfish structural marker"

run_judge smoke_judge_redfish_root "404" '{"error":"not found"}'
assert_eq   "redfish 404 returns 1"         "$JR" "1"
assert_contains "redfish 404 prints HTTP code" "$JO" "404"

run_judge smoke_judge_redfish_root "000" ""   # curl 整体失败
assert_eq   "redfish conn-fail(code 000) returns 1" "$JR" "1"
assert_contains "redfish conn-fail prints ✗" "$JO" "✗"

# === IPMI over LAN 判函数: pass ⟺ rc==0 ===
run_judge smoke_judge_ipmi_lan "0"
assert_eq   "ipmi pass returns 0"           "$JR" "0"
assert_contains "ipmi pass prints ✓"        "$JO" "✓"
assert_contains "ipmi pass mentions mc info" "$JO" "mc info"

run_judge smoke_judge_ipmi_lan "1" "Unable to send command"
assert_eq   "ipmi fail returns 1"           "$JR" "1"
assert_contains "ipmi fail prints ✗"        "$JO" "✗"
assert_contains "ipmi fail prints rc"       "$JO" "exit 1"
assert_contains "ipmi fail excerpt present" "$JO" "Unable to send"

# === System ready 判函数: pass ⟺ tcp rc==0 ===
run_judge smoke_judge_system_ready "0"
assert_eq   "ssh-ready pass returns 0"      "$JR" "0"
assert_contains "ssh-ready pass prints ✓"   "$JO" "✓"
assert_contains "ssh-ready mentions TCP"    "$JO" "TCP"

run_judge smoke_judge_system_ready "1"
assert_eq   "ssh-notready returns 1"        "$JR" "1"
assert_contains "ssh-notready prints ✗"     "$JO" "✗"

# === Redfish Managers 判函数: pass ⟺ code==200 AND body 含 Manager 资源结构标记 ===
run_judge smoke_judge_redfish_managers "200" '{"@odata.type":"#Manager.v1_5_0.Manager","ManagerType":"BMC","UUID":"00000000-0000-0000-0000-000000000000"}'
assert_eq   "managers pass(full) returns 0"     "$JR" "0"
assert_contains "managers pass prints ✓"        "$JO" "✓"
assert_contains "managers pass mentions Managers" "$JO" "Managers"
assert_false   "managers pass not ✗"           grep -q "✗" <<<"$JO"

# 单标记也 pass(ManagerType only — bmcweb 必发)
run_judge smoke_judge_redfish_managers "200" '{"ManagerType":"BMC"}'
assert_eq   "managers pass(ManagerType only) returns 0" "$JR" "0"

# 单标记也 pass(UUID only)
run_judge smoke_judge_redfish_managers "200" '{"UUID":"00000000-0000-0000-0000-000000000000"}'
assert_eq   "managers pass(UUID only) returns 0" "$JR" "0"

# 单标记也 pass(@odata.type + Manager)
run_judge smoke_judge_redfish_managers "200" '{"@odata.type":"#Manager.v1_5_0.Manager"}'
assert_eq   "managers pass(@odata.type Manager) returns 0" "$JR" "0"

run_judge smoke_judge_redfish_managers "200" '{"Name":"bmc"}'   # 缺 Manager 结构标记
assert_eq   "managers no-marker returns 1"   "$JR" "1"
assert_contains "managers no-marker prints ✗" "$JO" "✗"
assert_contains "managers no-marker mentions marker" "$JO" "no Manager resource marker"

run_judge smoke_judge_redfish_managers "404" '{"error":"not found"}'
assert_eq   "managers 404 returns 1"         "$JR" "1"
assert_contains "managers 404 prints HTTP code" "$JO" "404"

run_judge smoke_judge_redfish_managers "000" ""   # curl 整体失败
assert_eq   "managers conn-fail(code 000) returns 1" "$JR" "1"
assert_contains "managers conn-fail prints ✗" "$JO" "✗"

# === Redfish SoftwareVersion 判函数: pass ⟺ body 含非空 SoftwareVersion 或 FirmwareVersion ===
run_judge smoke_judge_redfish_swversion '{"FirmwareVersion":"v2.15.0","ManagerType":"BMC"}'
assert_eq   "swversion pass(FirmwareVersion) returns 0" "$JR" "0"
assert_contains "swversion pass prints ✓"               "$JO" "✓"
assert_contains "swversion pass mentions SoftwareVersion" "$JO" "SoftwareVersion"
assert_false   "swversion pass not ✗"                   grep -q "✗" <<<"$JO"

# SoftwareVersion 别名也 pass
run_judge smoke_judge_redfish_swversion '{"SoftwareVersion":"2.16.0-dev"}'
assert_eq   "swversion pass(SoftwareVersion alias) returns 0" "$JR" "0"

# 美化 JSON(冒号后空格, bmcweb 默认吐的形态)也 pass — 真 gb200nvl 实跑抓到的关键边界
run_judge smoke_judge_redfish_swversion '{ "FirmwareVersion": "3.1.0-dev-580", "ManagerType": "BMC" }'
assert_eq   "swversion pass(prettified JSON, space after colon) returns 0" "$JR" "0"
assert_contains "swversion prettified captures version" "$JO" "3.1.0-dev-580"

# 空串 FirmwareVersion 不 pass(防 "":"" 误判)
run_judge smoke_judge_redfish_swversion '{"FirmwareVersion":"","ManagerType":"BMC"}'
assert_eq   "swversion empty-value returns 1"  "$JR" "1"
assert_contains "swversion empty prints ✗"     "$JO" "✗"

# 缺版本属性不 pass
run_judge smoke_judge_redfish_swversion '{"ManagerType":"BMC","UUID":"x"}'
assert_eq   "swversion missing returns 1"      "$JR" "1"

# body 空(curl 整体失败遗留)不 pass
run_judge smoke_judge_redfish_swversion ""
assert_eq   "swversion empty-body returns 1"   "$JR" "1"

# === 各判函数恰好向 stdout 打一行 ✓/✗(无多行噪声) ===
JO=$(smoke_judge_redfish_root "0" "x" 2>/dev/null)
assert_eq "redfish judge prints exactly 1 line" "$(printf '%s\n' "$JO" | wc -l | tr -d ' ')" "1"
JO=$(smoke_judge_ipmi_lan "0" 2>/dev/null)
assert_eq "ipmi judge prints exactly 1 line" "$(printf '%s\n' "$JO" | wc -l | tr -d ' ')" "1"
JO=$(smoke_judge_system_ready "0" 2>/dev/null)
assert_eq "ssh judge prints exactly 1 line" "$(printf '%s\n' "$JO" | wc -l | tr -d ' ')" "1"
JO=$(smoke_judge_redfish_managers "0" "x" 2>/dev/null)
assert_eq "managers judge prints exactly 1 line" "$(printf '%s\n' "$JO" | wc -l | tr -d ' ')" "1"
JO=$(smoke_judge_redfish_swversion "x" 2>/dev/null)
assert_eq "swversion judge prints exactly 1 line" "$(printf '%s\n' "$JO" | wc -l | tr -d ' ')" "1"

assert_summary
