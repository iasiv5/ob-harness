#!/usr/bin/env bash
# tests/unit/smoke_diff_contract.sh — ob smoke 输出格式 ↔ smoke_diff.py 解析器 契约测试。
# 锁住「judge 实际 stdout 行 → smoke_diff.py 解析」的耦合: source lib/smoke_assertions.sh,
# 用代表性 pass/fail 信号调每个 judge, 捕获 judge 实际 stdout 行, 拼成 smoke 输出, 喂给
# smoke_diff.py, 断言全部 N 条 ✓/✗ 断言行被解析、未解析行数 = 0。
# 防有人改了 judge 的 echo 格式(前导空格/✓ 字符/断言名)而 diff 静默假通过(parser 漏解析 →
#   闸门看似放行实则漏判)。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SA="$ROOT/lib/smoke_assertions.sh"
TOOL="$ROOT/tools/smoke_diff.py"
test -f "$SA"   || { echo "MISSING $SA"   >&2; exit 1; }
test -f "$TOOL" || { echo "MISSING $TOOL" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SA"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# judge 数量(改 judge 族时同步): redfish_root / redfish_managers / redfish_swversion / ipmi_lan / system_ready
readonly N_JUDGES=5

# ── 辅助: 跑一个 judge 捕其 stdout 一行(无多行噪声) ──
jout() { local o; o=$("$@" 2>/dev/null); printf '%s\n' "$o"; }

# ── 构造 pass 形态 smoke 输出(5 条 ✓): 每条来自对应 judge 的真实 stdout ──
{
    echo "Smoke assertions for 'contract-fixture'"
    jout smoke_judge_redfish_root     "200" '{"@odata.type":"#ServiceRoot.v1_15_0.ServiceRoot","RedfishVersion":"1.17.0"}'
    jout smoke_judge_redfish_managers "200" '{"@odata.type":"#Manager.v1_5_0.Manager","ManagerType":"BMC","UUID":"abc"}'
    jout smoke_judge_redfish_swversion         '{"FirmwareVersion":"v2.15.0","ManagerType":"BMC"}'
    jout smoke_judge_ipmi_lan          "0"
    jout smoke_judge_system_ready      "0"
} > "$TMP/pass.txt"

# ── 构造 fail 形态 smoke 输出(5 条 ✗): 同样来自 judge 真实 stdout ──
{
    echo "Smoke assertions for 'contract-fixture'"
    jout smoke_judge_redfish_root     "500" '{"error":"internal"}'
    jout smoke_judge_redfish_managers "404" '{"error":"not found"}'
    jout smoke_judge_redfish_swversion         '{"ManagerType":"BMC"}'
    jout smoke_judge_ipmi_lan          "1" "Unable to send command"
    jout smoke_judge_system_ready      "1"
} > "$TMP/fail.txt"

# ── 统计: 输入里"看起来像断言行"的行数(^\s*[✓✗]) ──
count_assert_lines() { grep -cE '^[[:space:]]*[✓✗]' "$1"; }

# ── 从 smoke_diff 输出抽 baseline 断言解析数("baseline 断言: N 条") ──
parsed_count() {
    grep -oE 'baseline 断言: [0-9]+ 条' | grep -oE '[0-9]+' | head -1
}

# === pass 形态: 5 条 ✓ 全解析, 0 未解析 ===
pass_looking=$(count_assert_lines "$TMP/pass.txt")
assert_eq "pass fixture 含 $N_JUDGES 条 ✓ 断言行(judge 真实产出)" "$pass_looking" "$N_JUDGES"
out="$(python3 "$TOOL" "$TMP/pass.txt" "$TMP/pass.txt" 2>&1)"; rc=$?
assert_eq "pass self-diff exit 0" "$rc" "0"
pass_parsed=$(printf '%s' "$out" | parsed_count)
assert_eq "pass fixture 全 $N_JUDGES 条被 parser 解析" "$pass_parsed" "$N_JUDGES"
assert_eq "pass fixture 0 未解析(looking == parsed)" "$pass_parsed" "$pass_looking"

# === fail 形态: 5 条 ✗ 全解析, 0 未解析 ===
fail_looking=$(count_assert_lines "$TMP/fail.txt")
assert_eq "fail fixture 含 $N_JUDGES 条 ✗ 断言行(judge 真实产出)" "$fail_looking" "$N_JUDGES"
out="$(python3 "$TOOL" "$TMP/fail.txt" "$TMP/fail.txt" 2>&1)"; rc=$?
# fail self-diff(两边同 5 ✗)→ 无退化 → exit 0(✗→✗ 不变不算回归)
assert_eq "fail self-diff exit 0(✗→✗ 不变不算回归)" "$rc" "0"
fail_parsed=$(printf '%s' "$out" | parsed_count)
assert_eq "fail fixture 全 $N_JUDGES 条被 parser 解析" "$fail_parsed" "$N_JUDGES"
assert_eq "fail fixture 0 未解析(looking == parsed)" "$fail_parsed" "$fail_looking"

# === 混合契约: pass→fail 应触发 ✓→✗ 回归(证明 ✓ 与 ✗ 两种 mark 都正确解析并配对) ===
out="$(python3 "$TOOL" "$TMP/pass.txt" "$TMP/fail.txt" 2>&1)"; rc=$?
assert_eq "pass→fail mix 触发回归 exit 1" "$rc" "1"
assert_contains "mix 报 REGRESSION" "$out" "REGRESSION"
# 5 条同名 ✓→✗ 全数退化(parser 正确配对, 非漏解析)
mix_reg=$(printf '%s' "$out" | grep -oE '检出 [0-9]+ 条退化' | grep -oE '[0-9]+' | head -1)
assert_eq "mix 全 $N_JUDGES 条 ✓→✗ 退化被检出" "$mix_reg" "$N_JUDGES"

assert_summary
