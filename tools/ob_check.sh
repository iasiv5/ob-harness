#!/usr/bin/env bash
# tools/ob_check.sh — ob/lib 改动后一站式配套自检。
# 聚合: extract_funcs(ob GAPS + lib 三段) / machine_state public surface gate / shellcheck baseline(flat 合成 + 纯文本 multiset) / exit-contract(多文件) / run_all。
# 固定顺序: extract_funcs → machine_state gate → baseline → exit-contract → run_all。
# OB_SOURCES = ob + lib/*.sh(nullglob);用于 extract_funcs/exit_contract。shellcheck 用合成 flat(保留单文件可见性,避 per-file SC2034 假阳)。
# 用法: tools/ob_check.sh
#       OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh    # 跳过 run_all(被 run_all 递归调用时用,如 smoke)
#       OB_CHECK_READONLY=1 tools/ob_check.sh      # 只报告不改文件(smoke/CI 用,避免经 run_all 架空 baseline 门禁)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1   # 切到仓库根

# OB_SOURCES 契约: 入口 ob + lib 分区(nullglob 防 lib 空时展开成字面量)
OB_SOURCES=(ob)
shopt -s nullglob
OB_SOURCES+=(lib/*.sh)
shopt -u nullglob

PASS=0; FAIL=0; FAILED_NAMES=()
ok()  { PASS=$((PASS+1)); echo "✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "✗ $1"; FAILED_NAMES+=("$1"); }

# ── 1. extract_funcs: ob GAPS=0 + lib 三段纯函数定义 ──
ob_gaps=$(python3 tools/extract_funcs.py ob 2>/dev/null | awk '/^GAPS/{print $2}')
if [[ "${ob_gaps:-?}" == "0" ]]; then
    ok "extract_funcs ob GAPS=0"
else
    bad "extract_funcs ob GAPS=${ob_gaps:-?}(函数间有顶层语句,先清理)"
fi
lib_count=$((${#OB_SOURCES[@]} - 1))   # lib 文件数(跳过 ob)
lib_violations=0
for f in "${OB_SOURCES[@]:1}"; do
    if ! python3 tools/extract_funcs.py "$f" >/dev/null 2>&1; then
        bad "extract_funcs lib 三段违规: $f"
        python3 tools/extract_funcs.py "$f" 2>&1 | grep -E '_(TOPLEVEL)|^GAP' | head -3
        lib_violations=$((lib_violations+1))
    fi
done
if [[ "$lib_violations" == "0" ]]; then
    if [[ "$lib_count" == "0" ]]; then
        ok "extract_funcs lib 三段全清(无 lib 文件,跳过)"
    else
        ok "extract_funcs lib 三段全清($lib_count 个 lib 文件)"
    fi
fi

# ── 1b. machine_state public records surface 门禁 ──
machine_state_surface_re='(^|[^[:alnum:]_])(machine_state_records|_commands_machine_record_field|_commands_record_has_discovery_source|_commands_collect_machine_state_records|_repo_machine_record_field)($|[^[:alnum:]_])'
machine_state_surface_hits=$(grep -RInE "$machine_state_surface_re" lib/*.sh 2>/dev/null | grep -v '^lib/machine_state.sh:' || true)
if [[ -n "$machine_state_surface_hits" ]]; then
    bad "machine-state public records surface still in use"
    printf '%s\n' "$machine_state_surface_hits"
else
    ok "machine-state public records surface removed"
fi

# ── 1c. machine selection 旧 surface 清零门禁 ──
# 生产代码不得内联机器选择：不直调 select_from_list / 不引用 SELECT_FROM_LIST_CHOICE
# （机器选择走 pick_machine）；repo.sh 不定义 resolve_machine。正则扫注释，故旧名注释也要清。
machine_select_legacy_re='select_from_list|SELECT_FROM_LIST_CHOICE|(^|[^[:alnum:]_])resolve_machine($|[^[:alnum:]_])'
machine_select_legacy_hits=$(grep -RInE "$machine_select_legacy_re" lib/*.sh 2>/dev/null || true)
if [[ -n "$machine_select_legacy_hits" ]]; then
    bad "machine selection legacy surface still in use (must go through pick_machine)"
    printf '%s\n' "$machine_select_legacy_hits"
else
    ok "machine selection legacy surface removed"
fi

# ── 1c-bis. detect_runtime_git_host 生产调用不得用 $()(缓存穿透 subshell) ──
# direct call 契约:生产代码必须 detect_runtime_git_host >/dev/null;读 ${_RUNTIME_GIT_HOST:-};
# $() 在 subshell 执行,函数内全局缓存回不到调用者,缓存静默失效。tests/ 允许 $()。
_subshell_hits=$(grep -RnF "\$(detect_runtime_git_host)" lib/ ob 2>/dev/null || true)
if [[ -n "$_subshell_hits" ]]; then
    bad "detect_runtime_git_host subshell caller(缓存失效):"
    printf '%s\n' "$_subshell_hits"
else
    ok "detect_runtime_git_host 生产调用全 direct call"
fi

# ── 1c-ter. bare mirror legacy state surface 清零门禁 ──
# 旧 provisioning 状态 token (STATUS_MIRROR_NEW / STATUS_MIRROR_EXISTING / STATUS_FAILED /
# MIRROR_BASE) 不得回流到任何 production Bash(含 owner bare_mirror.sh)。
# 精确 token 正则,不误报 _BARE_MIRROR_* 私有名;比仅靠 review 拒绝 owner 回退更强。
bare_mirror_legacy_re='(^|[^[:alnum:]_])(STATUS_MIRROR_NEW|STATUS_MIRROR_EXISTING|STATUS_FAILED|MIRROR_BASE)($|[^[:alnum:]_])'
bare_mirror_legacy_hits=$(grep -RInE "$bare_mirror_legacy_re" ob lib/*.sh 2>/dev/null || true)
if [[ -n "$bare_mirror_legacy_hits" ]]; then
    bad "bare mirror legacy state surface still in use"
    printf '%s\n' "$bare_mirror_legacy_hits"
else
    ok "bare mirror state owned by module"
fi

# ── 1d. 交互 prompt 文案契约（.exp expect 依赖这些源码字符串；read -p 非 tty 不输出，故静态守）──
_prompt_bad=""
grep -q 'Select a machine for' lib/machine_picker.sh 2>/dev/null || _prompt_bad="${_prompt_bad} pick_machine('Select a machine for')"
grep -q '0 to cancel' lib/machine_picker.sh 2>/dev/null || _prompt_bad="${_prompt_bad} pick_machine('0 to cancel')"
grep -q 'Type (Y/y) to confirm' lib/util.sh 2>/dev/null || _prompt_bad="${_prompt_bad} confirm_action('Type (Y/y) to confirm')"
if [[ -n "$_prompt_bad" ]]; then
    bad "交互 prompt 文案契约破坏（.exp expect 依赖）：$_prompt_bad"
else
    ok "交互 prompt 文案契约一致"
fi

# ── 2. shellcheck baseline(合成 flat + 纯文本 multiset;不 per-file 避 SC2034 跨文件假阳) ──
flat=/tmp/ob_check_sc.flat
: > "$flat"
for f in "${OB_SOURCES[@]}"; do cat "$f" >> "$flat"; done
shellcheck -f gcc "$flat" > /tmp/ob_check_sc.new 2>&1 || true
verdict=$(OB_NEW=/tmp/ob_check_sc.new python3 - <<'PY'
import re, os
from collections import Counter
def parse(fn):
    c = Counter()
    for line in open(fn):
        s = re.sub(r'^[^:]+:\d+:\d+:\s*', '', line.rstrip())   # 去文件名+行列号,纯文本
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
            ok "shellcheck baseline 良性差异(行号平移/告警减少);只读模式不重生成,手动: 见上方 flat 合成命令"
        else
            cp /tmp/ob_check_sc.new tests/.shellcheck-baseline
            ok "shellcheck baseline 自动重生成(flat);请 git diff 确认后 commit"
        fi ;;
    NEW_ALERT)
        bad "shellcheck 新增告警(含同类型实例),未自动改;先修告警或显式重生成+git diff 确认:"
        printf '%s\n' "$verdict" | tail -n +2 ;;
    *)
        bad "shellcheck baseline 判定异常: $verdict" ;;
esac

# ── 3. exit-contract(多文件:默认扫 ob + lib/*.sh) ──
if python3 tools/exit_contract.py >/tmp/ob_check_ec.out 2>&1; then
    yz=$(grep -oE 'Y: (PASS|n/a)' /tmp/ob_check_ec.out | head -1)
    ok "exit-contract ok (X/Y/Z green; $yz)"
else
    bad "exit-contract 违反(详 /tmp/ob_check_ec.out):"
    cat /tmp/ob_check_ec.out
fi

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
