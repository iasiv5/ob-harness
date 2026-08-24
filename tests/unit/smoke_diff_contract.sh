#!/usr/bin/env bash
# tests/unit/smoke_diff_contract.sh — test-qemu report JSON ↔ smoke_diff.py 解析器 契约测试。
# 锁住「report.py 实际产出 schema → smoke_diff.py 消费」的耦合: fixture 生成走真实
# runner 链(assemble.record → report JSON), 字段名(ar/status)是配对与判定的唯一契约。
# 防有人改了 report 的字段名(如 status → verdict)而 diff 静默假通过(parser 漏解析 →
#   闸门看似放行实则漏判)。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER_DIR="$ROOT/tests/baseline/runner"
TOOL="$ROOT/tools/smoke_diff.py"
test -d "$RUNNER_DIR" || { echo "MISSING $RUNNER_DIR" >&2; exit 1; }
test -f "$TOOL"       || { echo "MISSING $TOOL" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# smoke suite AR 数(两 machine 一致, ADR-0028)
readonly N_ARS=5

# ── 用真实 assemble/report 链生成 report JSON(pass/fail 两份) ──
# 直接调 report_mod.run_report: records 用 assemble.assemble_record 构造,
# 与 runner 主循环同源 — 字段名契约由真实代码钉死, 不手写 JSON。
gen_report() {  # $1=outfile $2=rc_for_smoke04(0=pass,1=fail)
    OB_TQ_GEN_OUT="$1" OB_TQ_GEN_RC="$2" python3 - "$RUNNER_DIR" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import assemble, report

rc = int(os.environ["OB_TQ_GEN_RC"])
records = [assemble.assemble_record("SMOKE-%02d" % i, "applicable", "", "",
                                    0 if i != 4 else rc,
                                    json.dumps({"pass": (i != 4 or rc == 0),
                                                "code": 200, "body": "",
                                                "actual": None, "reason": "fixture"}))
           for i in range(1, 6)]
report.run_report(records, os.environ["OB_TQ_GEN_OUT"], True)
PY
}

gen_report "$TMP/pass.json" 0 || { echo "gen pass.json failed" >&2; exit 1; }
gen_report "$TMP/fail.json" 1 || { echo "gen fail.json failed" >&2; exit 1; }

# ── 契约: report JSON 顶层结构与字段名 ──
shape=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert sorted(d) == ["counts", "records", "verdict"], d.keys()
assert all("ar" in r and "status" in r for r in d["records"])
print("shape-ok")' "$TMP/pass.json")
assert_eq "report 顶层 {verdict,counts,records} + record.ar/.status 契约" "$shape" "shape-ok"

# ── 从 smoke_diff 输出抽 baseline AR 解析数 ──
parsed_count() { grep -oE 'baseline AR: [0-9]+ 条' | grep -oE '[0-9]+' | head -1; }

# === pass 形态: 5 条全被 parser 消费 ===
out="$(python3 "$TOOL" "$TMP/pass.json" "$TMP/pass.json" 2>&1)"; rc=$?
assert_eq "pass self-diff exit 0" "$rc" "0"
pass_parsed=$(printf '%s' "$out" | parsed_count)
assert_eq "pass report 全 $N_ARS 条被 parser 消费" "$pass_parsed" "$N_ARS"

# === fail 形态: 5 条(fail 记录含在内)全被消费 ===
out="$(python3 "$TOOL" "$TMP/fail.json" "$TMP/fail.json" 2>&1)"; rc=$?
# fail self-diff(两边同 1 fail)→ 无退化 → exit 0(fail→fail 不变不算回归)
assert_eq "fail self-diff exit 0(fail→fail 不变不算回归)" "$rc" "0"
fail_parsed=$(printf '%s' "$out" | parsed_count)
assert_eq "fail report 全 $N_ARS 条被 parser 消费" "$fail_parsed" "$N_ARS"

# === 混合契约: pass→fail 应触发 pass→fail 回归(证明配对键 ar 与判定字段 status 都正确解析) ===
out="$(python3 "$TOOL" "$TMP/pass.json" "$TMP/fail.json" 2>&1)"; rc=$?
assert_eq "pass→fail mix 触发回归 exit 1" "$rc" "1"
assert_contains "mix 报 REGRESSION" "$out" "REGRESSION"
assert_contains "mix 报 SMOKE-04 退化" "$out" "SMOKE-04"

assert_summary
