#!/usr/bin/env bash
# tools/ob_check.sh — ob 改动后一站式配套自检。
# 聚合: extract_funcs GAPS / reorder mismatch / shellcheck baseline(multiset) / run_all。
# 固定顺序: extract_funcs → reorder → baseline → run_all (GAPS=0 是 reorder 前提)。
# 用法: tools/ob_check.sh
#       OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh    # 跳过 run_all(被 run_all 递归调用时用,如 smoke)
#       OB_CHECK_READONLY=1 tools/ob_check.sh      # 只报告不改文件(smoke/CI 用,避免经 run_all 架空 baseline 门禁)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1   # 切到仓库根

PASS=0; FAIL=0; FAILED_NAMES=()
ok()  { PASS=$((PASS+1)); echo "✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "✗ $1"; FAILED_NAMES+=("$1"); }

# ── 1. extract_funcs GAPS(GAPS=0 是后续 reorder 的前提) ──
gaps=$(python3 tools/extract_funcs.py ob 2>/dev/null | awk '/^GAPS/{print $2}')
if [[ "${gaps:-?}" == "0" ]]; then
    ok "extract_funcs GAPS=0"
else
    bad "extract_funcs GAPS=${gaps:-?}(函数间有顶层语句,先清理)"
fi

# ── 2. reorder mismatch(集合比较: 保"不漏"不保"归对§"; 会产生 /tmp/ob_new 副作用) ──
reorder_err=$(python3 tools/reorder.py ob 2>&1 >/dev/null) || true
if [[ -z "$reorder_err" ]]; then
    ok "reorder 无 mismatch"
elif [[ "$reorder_err" == *"AssertionError"*"missing="* ]]; then
    bad "reorder 漏登记(新函数未加进 §dict): $(printf '%s' "$reorder_err" | grep -o 'missing=[^ ]*')"
else
    bad "reorder 异常(非漏登记,多半是上一步 GAPS>0 致边界解析崩): $reorder_err"
fi

# ── 3. shellcheck baseline multiset 判定(避免架空 CI 硬门禁) ──
shellcheck -f gcc ob > /tmp/ob_check_sc.new 2>&1 || true
verdict=$(OB_NEW=/tmp/ob_check_sc.new python3 - <<'PY'
import re, os
from collections import Counter
def parse(fn):
    c = Counter()
    for line in open(fn):
        s = re.sub(r'^ob:\d+:\d+:\s*', '', line.rstrip())
        if '[SC' in s:
            c[s] += 1
    return c
base = parse('tests/.shellcheck-baseline')
new  = parse(os.environ['OB_NEW'])
excess = new - base   # multiset 差: new 多出来的(含同类型+1 / 全新类型)
if not excess:
    print("REGEN" if new != base else "CLEAN")
else:
    print("NEW_ALERT")
    for k, v in excess.items():
        print("  +{} {}".format(v, k))
PY
)
decision="${verdict%%$'\n'*}"
case "$decision" in
    CLEAN)
        ok "shellcheck baseline 一致" ;;
    REGEN)
        if [[ "${OB_CHECK_READONLY:-0}" == "1" ]]; then
            ok "shellcheck baseline 良性差异(行号平移/告警减少);只读模式不重生成,手动: shellcheck -f gcc ob > tests/.shellcheck-baseline"
        else
            cp /tmp/ob_check_sc.new tests/.shellcheck-baseline
            ok "shellcheck baseline 自动重生成(行号平移/告警减少);请 git diff 确认后 commit"
        fi ;;
    NEW_ALERT)
        bad "shellcheck 新增告警(含同类型实例),未自动改;先修告警或显式重生成+git diff 确认:"
        printf '%s\n' "$verdict" | tail -n +2 ;;
    *)
        bad "shellcheck baseline 判定异常: $verdict" ;;
esac

# ── 4. run_all(除非 OB_CHECK_SKIP_TESTS=1,避免被 run_all 递归调用时死循环) ──
if [[ "${OB_CHECK_SKIP_TESTS:-0}" == "1" ]]; then
    echo "• skip run_all (OB_CHECK_SKIP_TESTS=1)"
else
    if bash tests/run_all.sh >/tmp/ob_check_runall.out 2>&1; then
        ok "run_all ALL GREEN"
    else
        bad "run_all 失败"
        tail -20 /tmp/ob_check_runall.out
    fi
    echo "  注: 本次跑 run_all 快速子集(.sh);未跑 .exp/integration;改了交互/退出码请 tests/run_all.sh --full"
fi

# ── 汇总 ──
echo ""
if (( FAIL > 0 )); then
    echo "FAIL=$FAIL PASS=$PASS"
    printf '  %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
echo "ALL GREEN (PASS=$PASS)"
exit 0
