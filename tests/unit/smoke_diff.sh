#!/usr/bin/env bash
# tests/unit/smoke_diff.sh — smoke_diff.py 逻辑自测(unit 层, ADR-0028 JSON report 形态)。
# fixture = 从真实 `ob test-qemu --suite smoke --report` 裁剪的 JSON(顶层 {verdict,
#   counts, records}, 配对键 records[].ar, 判定字段 records[].status)。
# 钉死回归闸门口径: pass→fail(同名退化) 与 baseline 无此 AR + current fail(新出现的
#   失败) = 回归(exit 1); 其余(fail→pass 改善/新出现的非 fail/消失/skip·error 不参与)不算回归。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$DIR/tools/smoke_diff.py"
test -f "$TOOL" || { echo "MISSING $TOOL" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# rec <ar> <status> — 生成一条最小合法 record(字段名对齐 report.py 实测契约)
rec() { printf '{"ar": "%s", "status": "%s", "pass": %s, "reason": "fixture", "code": 200, "body": "", "actual": null, "source": "", "probe_reason": "ok"}' "$1" "$2" "$([[ "$2" == pass ]] && echo true || echo false)"; }
wrap() { printf '{"verdict": "PASS", "counts": {"pass": 0, "fail": 0, "skip": 0, "xfail": 0, "xpass": 0, "error": 0}, "records": [%s]}' "$1"; }

# baseline: 五条全 pass(真实 smoke suite 的 SMOKE-01..05)
BASE_ROWS="$(rec SMOKE-01 pass), $(rec SMOKE-02 pass), $(rec SMOKE-03 pass), $(rec SMOKE-04 pass), $(rec SMOKE-05 pass)"
wrap "$BASE_ROWS" > "$TMP/base.json"

# --- 1. 无退化: 同名全 pass(细节 reason 变化不影响) → exit 0 ---
wrap "$BASE_ROWS" > "$TMP/cur_ok.json"
out="$(python3 "$TOOL" "$TMP/base.json" "$TMP/cur_ok.json" 2>&1)"; rc=$?
assert_eq "no-regression (same pass) rc 0" "$rc" "0"
assert_contains "no-regression prints OK 闸门放行" "$out" "闸门放行"
assert_false "no-regression 不含 REGRESSION 字样" grep -q 'REGRESSION' <<<"$out"

# --- 2. 退化: SMOKE-04 pass→fail → exit 1 + 报退化项 ---
wrap "$(rec SMOKE-01 pass), $(rec SMOKE-02 pass), $(rec SMOKE-03 pass), $(rec SMOKE-04 fail), $(rec SMOKE-05 pass)" > "$TMP/cur_reg.json"
out="$(python3 "$TOOL" "$TMP/base.json" "$TMP/cur_reg.json" 2>&1)"; rc=$?
assert_eq "regression (SMOKE-04 pass→fail) rc 1" "$rc" "1"
assert_contains "regression prints REGRESSION" "$out" "REGRESSION"
assert_contains "regression prints 退化项 AR" "$out" "SMOKE-04"
assert_contains "regression prints 闸门拦截" "$out" "闸门拦截"

# --- 3. 改善不算回归: baseline SMOKE-04 fail → current pass → exit 0 ---
wrap "$(rec SMOKE-01 pass), $(rec SMOKE-02 pass), $(rec SMOKE-03 pass), $(rec SMOKE-04 fail), $(rec SMOKE-05 pass)" > "$TMP/base_onefail.json"
out="$(python3 "$TOOL" "$TMP/base_onefail.json" "$TMP/cur_ok.json" 2>&1)"; rc=$?
assert_eq "improvement (fail→pass) rc 0" "$rc" "0"
assert_contains "improvement prints 改善 info" "$out" "改善"

# --- 4. skip/error 行不参与退化判定: baseline SMOKE-04 error(被丢弃)→ current fail
#     按"baseline 无此 AR + current fail = 新增失败"拦截 → exit 1(闸门 fail-closed) ---
wrap "$(rec SMOKE-01 pass), $(rec SMOKE-02 pass), $(rec SMOKE-03 pass), $(rec SMOKE-04 error), $(rec SMOKE-05 pass)" > "$TMP/base_err.json"
out="$(python3 "$TOOL" "$TMP/base_err.json" "$TMP/cur_reg.json" 2>&1)"; rc=$?
assert_eq "error→fail 按新增 fail 拦截(error 非 α 真相, fail-closed) rc 1" "$rc" "1"

# baseline 子集(无 SMOKE-04)— 用于 5/6 测试 "新出现 AR" 语义
wrap "$(rec SMOKE-01 pass), $(rec SMOKE-02 pass), $(rec SMOKE-03 pass), $(rec SMOKE-05 pass)" > "$TMP/base_no04.json"

# --- 5. 语义严格化: baseline 无此 AR + current fail(新出现的失败 AR) → exit 1 ---
out="$(python3 "$TOOL" "$TMP/base_no04.json" "$TMP/cur_reg.json" 2>&1)"; rc=$?
assert_eq "new-fail regression rc 1" "$rc" "1"
assert_contains "new-fail prints REGRESSION" "$out" "REGRESSION"
assert_contains "new-fail mentions SMOKE-04" "$out" "SMOKE-04"
assert_contains "new-fail prints absent baseline 标注" "$out" "absent — new AR"
assert_contains "new-fail prints 闸门拦截" "$out" "闸门拦截"

# --- 6. 新出现的非 fail AR 不算回归: baseline 无 SMOKE-04 + current pass → exit 0 ---
out="$(python3 "$TOOL" "$TMP/base_no04.json" "$TMP/cur_ok.json" 2>&1)"; rc=$?
assert_eq "new-pass no-regression rc 0" "$rc" "0"
assert_contains "new-pass prints 新出现的非 fail info" "$out" "新出现的非 fail"
assert_false "new-pass 不含 REGRESSION" grep -q 'REGRESSION' <<<"$out"

# --- 6b. schema 漂移 fail-closed(评审 🔴): record 字段名错(status→verdict)/
#     非 dict / 重复 AR → exit 2, 不静默丢弃折叠成假放行 ---
cat > "$TMP/cur_drift.json" <<'JSON'
{"verdict": "FAIL", "counts": {"pass": 4, "fail": 1, "skip": 0, "xfail": 0, "xpass": 0, "error": 0}, "records": [{"ar": "SMOKE-04", "verdict": "fail", "pass": false, "reason": "drift"}]}
JSON
assert_rc 2 "status→verdict 字段漂移 rc 2" python3 "$TOOL" "$TMP/base.json" "$TMP/cur_drift.json"
cat > "$TMP/cur_dup.json" <<'JSON'
{"verdict": "PASS", "counts": {}, "records": [{"ar": "SMOKE-01", "status": "pass"}, {"ar": "SMOKE-01", "status": "fail"}]}
JSON
assert_rc 2 "重复 AR rc 2" python3 "$TOOL" "$TMP/cur_dup.json" "$TMP/base.json"

# --- 7. 错误路径: 文件不存在 / 非 report JSON → exit 2 ---
assert_rc 2 "nonexistent file rc 2" python3 "$TOOL" "$TMP/base.json" "$TMP/nope.json"
echo "not json" > "$TMP/bad.json"
assert_rc 2 "non-report JSON rc 2" python3 "$TOOL" "$TMP/bad.json" "$TMP/base.json"

# --- 8. --help → exit 0 + 打印 doc ---
out="$(python3 "$TOOL" --help 2>&1)"; rc=$?
assert_eq "--help rc 0" "$rc" "0"
assert_contains "--help prints 用法" "$out" "smoke suite baseline-diff"
assert_contains "--help doc 反映新语义(新出现的 fail)" "$out" "新出现的失败 AR"

assert_summary
