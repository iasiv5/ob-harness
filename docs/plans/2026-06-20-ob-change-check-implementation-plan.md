# ob 改动配套自检机制 实施计划

## 目标

实现 `tools/ob_check.sh` 一站式自检脚本 + 配套规则钩子 + 冒烟测试，让 agent 改完 ob 一条命令完成全部配套验证（结构 / 函数登记 / shellcheck baseline / 测试），显著降低漏同步 CI 配套的概率。

## 架构快照

- `tools/ob_check.sh` 是编排层，聚合现有 tools/ 与 tests/ 的只读检查，自身不引入新门禁。
- 固定执行顺序 `extract_funcs → reorder → baseline → run_all`：extract_funcs 的 GAPS=0 是 reorder 的前提（否则 reorder 内部 `max([])` 会崩）。
- baseline 项用 `python3` 内联 `Counter` 做多重集比对（`new - base` 非空即新增，含同类型实例），仅"纯行号平移/告警减少"自动重生成，新增告警机器报错不自动改——这是不架空 CI baseline 硬门禁的关键。
- `OB_CHECK_SKIP_TESTS=1` 跳过 run_all 项，供 smoke 在 run_all 递归调用时避免死循环；`OB_CHECK_READONLY=1` 让 baseline 项只报告不 `cp`，供 smoke/CI 只读，避免 run_all→smoke→ob_check 自动改 baseline 架空 CI 门禁。
- CI workflow 不动：smoke 放 protocol 层被 run_all 自动覆盖，靠它防 ob_check 脚本腐烂。

## 输入工件

- 设计文档：`docs/specs/2026-06-20-ob-change-check-design.md`（v2，含 multiset，已批准）

## 文件结构与职责

- Create: `tools/ob_check.sh` — 一站式自检入口，4 项检查 + multiset baseline 判定 + skip 开关
- Create: `tests/protocol/ob_check_smoke.sh` — 冒烟测试，断言 ob_check 对当前 ob exit 0
- Modify: `AGENTS.md`（`## Working Mode` 段）— 加"改 ob 后跑 ob_check"行为钩子
- Modify: `rules/03_WORKSPACE.md`（tools 路由 + tests 路由）— 登记 ob_check.sh；修正过时 tests 路由为 run_all 分层

环境前提：`bash`、`python3`、`shellcheck`（CI 已装；本地均已有，前面轮次验证过）。

## 任务清单

### Task 1: 创建 tools/ob_check.sh

- 目标：创建一站式自检脚本，4 项检查 + multiset baseline 判定 + skip 开关，对当前干净 ob 跑通 exit 0。
- Files
  - Create: `tools/ob_check.sh`
- 验证范围：`bash tools/ob_check.sh` 对当前 ob 输出 ALL GREEN 且 exit 0；构造新增同类型告警时 baseline 项报错。

- [ ] Step 1: 写失败检查（脚本不存在）
- Run: `test -x tools/ob_check.sh && echo exists || echo missing`
- Expected: `missing`

- [ ] Step 2: 确认当前失败
- Run: `bash tools/ob_check.sh; echo "rc=$?"`
- Expected: `No such file` 类错误，rc 非 0

- [ ] Step 3: 写最小实现
- Change: 创建 `tools/ob_check.sh`，内容如下（`chmod +x`）：

```bash
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
```

- [ ] Step 4a: 确认干净 ob 通过
- Run: `bash tools/ob_check.sh; echo "rc=$?"`
- Expected: 4 项 ✓ + `ALL GREEN (PASS=4)`，rc=0
- Run: `shellcheck tools/ob_check.sh; echo "rc=$?"`（脚本自身干净，它不在 ob baseline 范围）
- Expected: 无告警，rc=0

- [ ] Step 4b: 确认 multiset 能拦"新增同类型告警"（评审指出的关键场景）
- Change: 临时往 `ob` 注入一处 SC2012——在 `check_ssh_hostkey_conflict` 函数体内 `local port="$1"` 那行之后插入一行 `    ls /tmp >/dev/null  # ob_check multiset 探针`（`ls` 触发 SC2012，baseline 已有 4 处 → 第 5 处；不赋值故不引入 SC2034）。务必插在函数体内，勿插函数外（否则 GAPS>0 连带 extract_funcs/reorder 变红，掩盖 baseline 验证意图）。
- Run: `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash tools/ob_check.sh; echo "rc=$?"`（skip+readonly 聚焦 baseline 项，避免注入版 ob 多跑一遍 run_all、也不污染 baseline）
- Expected: baseline 项输出 `✗ shellcheck 新增告警(含同类型实例)...` 并列出 `+1 ... SC2012`，rc=1（证明 multiset 没有像 set 那样漏放）
- Change: 撤销注入 `git checkout -- ob`
- Run: `bash tools/ob_check.sh; echo "rc=$?"`
- Expected: 再次 ALL GREEN，rc=0

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add tools/ob_check.sh && git commit -m "feat(ob-check): 新增 ob 改动后一站式配套自检脚本"`
- Expected: commit 成功

### Task 2: 创建 tests/protocol/ob_check_smoke.sh

- 目标：冒烟测试，断言 ob_check 对当前 ob（只读模式）exit 0；放 protocol 层被 run_all 覆盖，防脚本腐烂；用 skip+readonly 双开关避免递归且不架空 baseline 门禁。
- Files
  - Create: `tests/protocol/ob_check_smoke.sh`
- 验证范围：单独跑 smoke exit 0；`run_all.sh` 扫到它不卡死（递归切断）；smoke 跑完 `tests/.shellcheck-baseline` 无变化（只读未架空门禁）。

- [ ] Step 1: 写失败检查（smoke 不存在）
- Run: `test -f tests/protocol/ob_check_smoke.sh && echo exists || echo missing`
- Expected: `missing`

- [ ] Step 2: 确认当前失败
- Run: `bash tests/protocol/ob_check_smoke.sh; echo "rc=$?"`
- Expected: `No such file`，rc 非 0

- [ ] Step 3: 写最小实现
- Change: 创建 `tests/protocol/ob_check_smoke.sh`（`chmod +x`），用 lib 的 `assert_rc` + `assert_summary`；`OB_DIR` 自算（不 source ob，避免加载 4000+ 行 ob 的副作用）；**必设** `OB_CHECK_SKIP_TESTS=1`（避 run_all 递归）+ `OB_CHECK_READONLY=1`（只报告不改 baseline，否则 run_all→smoke→ob_check 会自动 cp 覆写 `.shellcheck-baseline`，架空 CI baseline 门禁）：

```bash
#!/usr/bin/env bash
# ob_check.sh 冒烟测试 — 对当前 ob 跑 ob_check(只读) 断言 exit 0,防脚本腐烂。
# 必设 OB_CHECK_SKIP_TESTS=1(避 run_all 递归) + OB_CHECK_READONLY=1(只报告不改 baseline,
# 否则 run_all→smoke→ob_check 自动 cp 覆写 .shellcheck-baseline,架空 CI baseline 门禁)。
# 覆盖边界: smoke 走 skip,ob_check 里"调用 run_all.sh 那段"不执行——该路径写错靠 CI 直接
#           bash tests/run_all.sh 兜底;smoke 实际只覆盖 extract_funcs/reorder/baseline 三段。
set -uo pipefail
OB_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

assert_rc 0 "ob_check clean ob (read-only)" \
    env OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash "$OB_DIR/tools/ob_check.sh"

assert_summary
```

- [ ] Step 4: 确认通过、不递归、且 baseline 未被改（回归护栏）
- Run: `bash tests/protocol/ob_check_smoke.sh; echo "rc=$?"`
- Expected: `ok   ob_check clean ob (read-only)` + `PASS=1 FAIL=0`，rc=0
- Run: `cp tests/.shellcheck-baseline /tmp/ob_chk_base_before; timeout 60 bash tests/run_all.sh >/dev/null 2>&1; diff -q tests/.shellcheck-baseline /tmp/ob_chk_base_before && echo "baseline unchanged" || echo "BASELINE CHANGED"`
- Expected: `baseline unchanged`；run_all 末尾 ALL GREEN、60s 内完成（递归切断）。
  注: 干净仓库 ob↔baseline 走 CLEAN 分支(本就不写),故此 `unchanged` 当前 **vacuously true**——它不实证 READONLY 的 REGEN 拦截路径,而是回归护栏(防将来误给任意分支引入无条件 cp)。READONLY 生效的真实保证来自骨架 REGEN 分支的 `if OB_CHECK_READONLY` 代码审查;构造真 REGEN 场景实测(给 ob 加注释致行号平移让 baseline 滞后)属 YAGNI,本轮不做。

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add tests/protocol/ob_check_smoke.sh && git commit -m "test(ob-check): 加 ob_check 冒烟测试(protocol 层, skip 避递归)"`
- Expected: commit 成功

### Task 3: 更新 AGENTS.md Working Mode 钩子

- 目标：在 `## Working Mode` 的"实现和调试"项补 ob 钩子，让 agent 改 ob 时被触发去跑 ob_check。
- Files
  - Modify: `AGENTS.md`（`## Working Mode` 段）
- 验证范围：grep 确认钩子存在。

- [ ] Step 1: 写失败检查（钩子不存在）
- Run: `grep -c 'ob_check.sh' AGENTS.md`
- Expected: `0`

- [ ] Step 2: 确认当前失败
- Run: `grep 'ob_check' AGENTS.md || echo "not found"`
- Expected: `not found`

- [ ] Step 3: 写最小实现
- Change: 在 `AGENTS.md` 的 `## Working Mode` 段，把"实现和调试"那条改为：

```markdown
- 实现和调试：先找根因，再做最小改动，再跑可执行验证。改动 `ob` 脚本后，额外跑 `tools/ob_check.sh` 做配套自检（结构 / 函数登记 / shellcheck baseline / 测试，详见 `rules/03_WORKSPACE.md`）。
```

- [ ] Step 4: 确认通过
- Run: `grep 'ob_check.sh' AGENTS.md`
- Expected: 命中那一行

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add AGENTS.md && git commit -m "docs(ob-check): AGENTS.md Working Mode 加'改 ob 后跑 ob_check'钩子"`
- Expected: commit 成功

### Task 4: 更新 WORKSPACE.md 文件路由

- 目标：tools 路由登记 ob_check.sh；修正过时 tests 路由（当前仍写 smoke_ob.sh / manual_matrix.exp，未反映 run_all 分层）。
- Files
  - Modify: `rules/03_WORKSPACE.md`（`### 项目与代码` 的 tools 行 + tests 行）
- 验证范围：grep 确认 ob_check.sh 已登记、tests 路由已反映 run_all 分层。

- [ ] Step 1: 写失败检查
- Run: `grep -c 'ob_check.sh' rules/03_WORKSPACE.md; grep -c 'run_all' rules/03_WORKSPACE.md`
- Expected: `0`（ob_check 未登记）；`0`（tests 路由未提 run_all 分层）

- [ ] Step 2: 确认当前失败
- Run: `grep 'ob_check\|run_all' rules/03_WORKSPACE.md || echo "not found"`
- Expected: `not found`

- [ ] Step 3: 写最小实现
- Change: 在 `rules/03_WORKSPACE.md` 的 `### 项目与代码` 段：
  - tools 行追加 ob_check.sh 登记：在 `extract_funcs.py + reorder.py ... 见各脚本 docstring` 后接 `；`ob_check.sh` 改 ob 后一站式配套自检（聚合 extract_funcs/reorder/shellcheck baseline/run_all），改完 ob 必跑`
  - tests 行改为反映 run_all 分层：`测试入口与分层调度：`tests/run_all.sh`（默认跑 protocol/unit/orchestration 的 .sh；`--full` 加 .exp 交互矩阵；`--integration` 加 E2E）；分层目录 `tests/{protocol,unit,orchestration,integration,lib}/`，何时用见 `run_all.sh` 顶部`

- [ ] Step 4: 确认通过
- Run: `grep 'ob_check.sh' rules/03_WORKSPACE.md && grep 'run_all' rules/03_WORKSPACE.md`
- Expected: 两处均命中

- [ ] Step 5: 可选 checkpoint commit
- Run: `git add rules/03_WORKSPACE.md && git commit -m "docs(workspace): 登记 ob_check.sh + 修正过时 tests 路由为 run_all 分层"`
- Expected: commit 成功

### Task 5: 最终验证

- 目标：端到端确认整套机制可用、CI 门禁会过。
- Files: 无（仅验证）
- 验证范围：run_all 含 smoke 全绿；ob_check 干净 ob 全绿；baseline 一致。

- [ ] Step 1: 跑完整 run_all（含新 smoke）
- Run: `bash tests/run_all.sh 2>&1 | tail -8; echo "rc=${PIPESTATUS[0]}"`
- Expected: 各层 `ok`，末尾 `ALL GREEN`，rc=0；`ob_check_smoke.sh` 出现在 protocol 层 ok 列表

- [ ] Step 2: 跑 ob_check 完整（含 run_all 项）
- Run: `bash tools/ob_check.sh; echo "rc=$?"`
- Expected: `ALL GREEN (PASS=4)`，rc=0

- [ ] Step 3: 确认 baseline 一致（ob 未被 Task 1b 的注入污染）
- Run: `shellcheck -f gcc ob > /tmp/sc.final 2>&1 || true; diff -u tests/.shellcheck-baseline /tmp/sc.final; echo "rc=$?"`
- Expected: diff 为空，rc=0（CI baseline 门禁会过）

- [ ] Step 4: 确认改动文件集
- Run: `git status --short`
- Expected: 新增 `tools/ob_check.sh`、`tests/protocol/ob_check_smoke.sh`；修改 `AGENTS.md`、`rules/03_WORKSPACE.md`（`docs/specs` 与 `docs/plans` 视是否一并提交而定）

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动手。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证；验证不过不算完成。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不要猜。
- 当前分支 `refactor/ob-cleanup`（非 main），可直接实现，无需另开分支。
- Task 1 Step 4b 的注入测试务必 `git checkout -- ob` 撤销，勿把探针留在 ob 里。

## 最终验证

- `bash tests/run_all.sh` → ALL GREEN（含 `ob_check_smoke.sh`，且不递归卡死）
- `bash tools/ob_check.sh` → ALL GREEN (PASS=4)
- `diff -u tests/.shellcheck-baseline <(shellcheck -f gcc ob)` → 空（CI baseline 门禁会过）
- `shellcheck tools/ob_check.sh` → 无告警（脚本自身干净）
- `git status --short` → 改动文件集符合预期，ob 无残留探针

## 审阅 Checkpoint

- 计划正文结束。请先确认这份计划；如果没问题，下一步可按计划由普通编码 agent 或人工继续执行。
- 审阅通过前不进入实现。
