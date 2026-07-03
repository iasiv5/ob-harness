# CI 交互矩阵(.exp)回归门禁实施计划 (F1)

## 目标

- 让 CI 在 push/PR 时跑 `tests/protocol/manual_matrix.exp`，补上 exit-code 契约（0/1/2/3）的**动态**回归保护，覆盖当前 fast job 与静态 `exit_contract.py` 都抓不到的 TTY 交互 / 非-TTY / 菜单退出码运行时路径。

## 架构快照

- 本次方案：在 `.github/workflows/ob-tests.yml` 增加一个 `slow` job，跑 `bash tests/run_all.sh --full`。
- `--full` 在当前 LAYERS（protocol/unit/orchestration）下只多跑 `protocol/manual_matrix.exp`（unit/orchestration 无 `.exp`）。该脚本对无 workspace 环境做了 skip 处理（`tests/protocol/manual_matrix.exp:95-98`，取消分支 auto-skip），CI 干净 runner 上跑 6 个无依赖断言、SKIP 3 个需 workspace 的取消分支。
- 不改 `run_all.sh`、不改 `manual_matrix.exp`；只在 CI 加 job。
- 静态 `exit_contract.py`（查 exit 字面值）与动态 `manual_matrix.exp`（查运行时退出码）互补，不互替——这是本计划的存在理由。

## 输入工件

- 评审 finding F1（本次会话），落点：`.github/workflows/ob-tests.yml`（fast job `run: bash tests/run_all.sh` 无 `--full`）、`tests/run_all.sh:32`（`.exp` 需 `--full`）、`tests/protocol/manual_matrix.exp:48-65`（6 个无 workspace 断言）。
- 无独立设计文档（改动范围小、方案单一）。

## 评审决策点（交评审定）

- **D1**：slow job 与 fast job 的关系。
  - 选项 A（推荐）= 独立并行 job（均阻断，CI 总时长取 max）。
  - 选项 B = `needs: fast`（fast 绿才跑 slow，省 slow 额度）。

## 文件结构与职责

- Modify：`.github/workflows/ob-tests.yml`（新增 `slow` job）。

## 任务清单

### Task 1: 本地确认 run_all.sh --full 通过（含 manual_matrix.exp）

- 目标：确认 `--full` 在仓库根能完整跑通，manual_matrix.exp 不 FAIL（取消分支按本地 workspace 有无自动跑或 SKIP，均接受）。
- Files：读 `tests/protocol/manual_matrix.exp`（无改动）。
- 验证范围：`bash tests/run_all.sh --full` 输出 ALL GREEN，manual_matrix.exp 标 ok。

- [ ] Step 1: 前置检查——CI 当前不跑 --full
  - Run: `grep -n -- '--full' .github/workflows/ob-tests.yml || echo "CI 未跑 --full"`
  - Expected: `CI 未跑 --full`（确认门禁缺口存在）。
- [ ] Step 2: 本地跑 --full（评审已实测通过）
  - Run: `bash tests/run_all.sh --full 2>&1 | tail -8`
  - Expected: 末尾 `ALL GREEN`，protocol 层 `manual_matrix.exp` 标 ok（本地有 init-done machine 时取消分支真跑、无则 SKIP，两种都算通过）。
  - 注：本地无 expect 时 `sudo apt-get install -y expect`；跑不了则跳过，结论改由 Task 3 CI 实测坐实。
- [ ] Step 3: 无代码改动（前置观察）。
- [ ] Step 4: 确认 Expected 达成。

### Task 2: ob-tests.yml 新增 slow job

- 目标：CI 增加 slow job 跑 `tests/run_all.sh --full`。
- Files：Modify `.github/workflows/ob-tests.yml`。
- 验证范围：yml 语法合法、slow job 定义存在。

- [ ] Step 1: 前置检查——当前无 slow job
  - Run: `grep -nE 'slow:|--full' .github/workflows/ob-tests.yml`
  - Expected: 无 slow job 输出（只有 fast job）。
- [ ] Step 2: 确认缺失（同上命令，无匹配）。
- [ ] Step 3: 在 `jobs:` 下 `fast` 之后新增 `slow` job
  - Change：
    ```yaml
    slow:
      name: protocol .exp 交互矩阵(--full)
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - name: install expect
          run: sudo apt-get update && sudo apt-get install -y expect
        - name: run_all --full(跑 .exp 交互矩阵;无 workspace 的取消分支自动 skip)
          run: bash tests/run_all.sh --full
    ```
  - 按评审 D1 决定是否加 `needs: fast`。
- [ ] Step 4: yml 语法校验
  - Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ob-tests.yml')); print('yaml ok')"`
  - Expected: `yaml ok`。
- [ ] Step 5: checkpoint commit
  - Run: `git add .github/workflows/ob-tests.yml && git commit -m "ci: 加 slow job 跑 --full 补 exit-code 动态协议回归(F1)"`
  - Expected: commit 成功。

### Task 3: 推分支验证 CI slow job 实际跑通

- 目标：GitHub Actions 实测 slow job 绿。
- Files：无（验证 only）。
- 验证范围：CI run 里 slow job 通过，日志含 `PASS=6 FAIL=0 SKIP=3`。

- [ ] Step 1: 前置检查——本地分支状态
  - Run: `git log --oneline -1; git status -sb`
  - Expected: 最新 commit 是 Task 2 的。
- [ ] Step 2: 推分支触发 CI
  - Run: `git push -u origin <branch>`（分支名按惯例，如 `ci/exp-matrix`；若在 main 先切分支）
  - Expected: 推送成功，触发 ob-tests.yml。
- [ ] Step 3: 无代码改动。
- [ ] Step 4: 等 CI 完成、核对 slow job 日志
  - Run: `gh run watch && gh run view --log 2>/dev/null | grep -E 'PASS=|FAIL|manual_matrix' | tail`
  - Expected: slow job 绿，日志含 `PASS=6 FAIL=0 SKIP=3`（或 PASS≥6 FAIL=0）。
- [ ] Step 5: 无 commit。

## 执行纪律

- 开始前复查整份计划；若 Task 1 本地跑不了 expect，不要凭空结论——改由 Task 3 CI 日志坐实"无 workspace 应 SKIP 不 FAIL"。
- 每个任务都要跑验证。
- 若 CI slow job 因 pty/expect 问题挂，立即停下说明，不要猜（CI runner 的 pty 支持需实测）。
- 若当前在 main，开始实现前先切分支。

## 最终验证

- Run: `gh run list -L 1` + 网页确认。
- Expected: 最新 run 的 fast + slow job 均 ✓；slow 日志含 `PASS=6 FAIL=0 SKIP=3`。

## 审阅 Checkpoint

- 计划正文结束。请评审对 F1 取舍：做 / 不做；若做，D1 选 A（并行）还是 B（needs: fast）。
