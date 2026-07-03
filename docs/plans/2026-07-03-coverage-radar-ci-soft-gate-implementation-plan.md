# Coverage Radar CI 阻断门禁实施计划 (F4) — 阶段2

## 目标

- F5（radar scope 修复 + CI 告警）落地且 CI 告警跑稳定后，把 coverage step 从**告警**（`|| true`）升级为**阻断**（退化即 fail PR），让 ob+lib 函数级覆盖率退化被 CI 硬拦。
- 本计划是原 F4 的**阶段2**；阶段1（`--fail-if-uncovered` + `UNCOVERED` 展示 + CI 告警 + docstring）已并入 F5，避免落 ob-only 临时口径（评审指出 F4 阶段1 写死 `N0=1` 与"F5 先"执行序冲突）。

## 架构快照

- **前置**：F5 已合并——radar 全集 = ob+lib（~134）、CI coverage step 已是告警形态（`--fail-if-uncovered N5 || true`）、N5 已记录。
- **方案**：CI coverage step 去掉 `|| true`，`uncovered > N5` 即 exit 1 fail PR。新增 ob/lib 函数要么加测试、要么显式调高 N5 并在 commit message 说明理由。

## 输入工件

- 评审认可"阻断依赖 F5"+ 建议"F4 阶段2 等 F5 后跑几轮 CI 观察再议"。
- 前置计划：[F5](2026-07-03-coverage-radar-scope-fix-implementation-plan.md)。

## 评审决策点（交评审定）

- **D1**：阻断时机。A（推荐）= F5 合并后 CI 告警跑 ≥3 轮绿、N5 稳定再升阻断；B = F5 合并立即升。
- **D2**：升阻断 vs 保持告警。A = 升阻断（退化须人为调基线）；B = 保持告警（若 N5 因 exit 函数 radar 低估有良性波动，阻断会误伤，此时保持告警更稳）。

## 文件结构与职责

- Modify：`.github/workflows/ob-tests.yml`（coverage step 去 `|| true`）。

## 任务清单

### Task 1: 确认 F5 前置 + 告警稳定性

- 目标：F5 已进 main，CI 告警近 N 轮绿，N5 稳定。
- Files：无（核对 only）。
- 验证范围：F5 已合并；近 3 轮 CI coverage step ✓；N5 不波动。

- [ ] Step 1: 确认 F5 已合并
  - Run: `git log --oneline main | grep -iE 'F5|radar.*ob\+lib|scope 修复' | head -3`
  - Expected: 命中 F5 相关 commit。
- [ ] Step 2: CI 告警近 3 轮绿
  - Run: `gh run list -L 5 -w 'ob tests' 2>/dev/null | head` + 网页确认 coverage step 均 ✓
  - Expected: 近 3+ 轮 coverage step ✓（`|| true` 下不阻断，但要确认未触发告警输出）。
- [ ] Step 3: N5 稳定性
  - Run: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - 2>/dev/null | grep UNCOVERED`
  - Expected: `UNCOVERED N5` 与 F5 Task 5 记录一致、多次跑稳定。
- [ ] Step 4: 判断——若 N5 因 exit 函数 radar 低估有良性波动，先评估是否适合阻断（波动会误伤 PR，此时选 D2=B 保持告警）。

### Task 2: CI coverage step 升阻断

- 目标：去 `|| true`，退化 fail。
- Files：Modify `.github/workflows/ob-tests.yml`。
- 验证范围：yml 语法合法、coverage step 无 `|| true`。

- [ ] Step 1: 写失败检查——当前为告警形态
  - Run: `grep -A3 'coverage radar' .github/workflows/ob-tests.yml`
  - Expected: 含 `|| true`（告警形态）。
- [ ] Step 2: 确认现状（同上）。
- [ ] Step 3: 改 coverage step 去 `|| true`
  - Change：
    ```yaml
    - name: coverage radar 阻断(ob+lib 口径;退化即 fail;新增 ob/lib 函数需加测试或显式调 N5 并说明)
      run: |
        tools/trace_collect.sh | python3 tools/coverage_radar.py - --fail-if-uncovered N5
    ```
    `N5` 用 F5 实测值。
- [ ] Step 4: yml 语法校验
  - Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ob-tests.yml')); print('yaml ok')"`
  - Expected: `yaml ok`。
- [ ] Step 5: checkpoint commit
  - Run: `git add .github/workflows/ob-tests.yml && git commit -m "ci: coverage step 升阻断(ob+lib 口径 N5)(F4 阶段2)"`
  - Expected: commit 成功。

### Task 3: 推分支验证阻断双向生效

- 目标：构造未覆盖上升确认 CI fail；还原后 CI 恢复 ✓。
- Files：临时改动（后还原）。
- 验证范围：退化时 coverage step ✗；正常时 ✓。

- [ ] Step 1: 本地构造 uncovered > N5（如临时给 lib 加一个无测试的新函数，或临时禁用一个高价值测试）
  - Run: 改动后 `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - --fail-if-uncovered N5; echo "rc=$?"`
  - Expected: `rc=1`（本地先确认退化被捕获）。
- [ ] Step 2: 推分支，CI coverage step 应 ✗
  - Run: `git push -u origin <branch>` + `gh run watch`
  - Expected: coverage step ✗（阻断生效）。
- [ ] Step 3: 还原改动（`git checkout -- lib/` 或删临时函数），CI 恢复 ✓
  - Run: `gh run watch`
  - Expected: coverage step ✓。
- [ ] Step 4: 确认阻断双向生效。
- [ ] Step 5: 无 commit（验证 only，改动已还原）。

## 执行纪律

- 硬前置 F5；F5 未合并、CI 告警未稳定前不启动 F4。
- D1 观察 ≥3 轮再升，避免 N5 未稳定就阻断误伤 PR。
- radar 对 exit 函数（check_ports_available/parse_args/require_path 等 bash -c 子进程）的低估是良性的——**若 N5 因此波动，阻断会误伤**，此时保持告警（D2=B）更稳，不要硬上阻断。
- 新增 ob/lib 函数导致 uncovered 上升时，CI 会 fail——预期行为：加测试，或显式调高 N5 并说明。
- 若当前在 main，开始实现前先切分支。

## 最终验证

- Run: 推含临时未覆盖函数的分支 → CI coverage step ✗；还原分支 → ✓。
- Expected: 阻断双向生效；N5 稳定无良性波动误伤。

## 审阅 Checkpoint

- 计划正文结束。请评审对 F4 阶段2 取舍：做 / 不做 / 何时做；D1（A 观察 ≥3 轮 / B 立即）；D2（A 阻断 / B 保持告警）。确认硬前置 = F5。
