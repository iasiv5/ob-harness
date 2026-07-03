# CI init dry-run 编排回归门禁实施计划 (F2)

## 目标

- 让 CI 在 push/PR 时跑 `tests/integration/init_dryrun_sanity.sh`，补上 `ob init` 8 步流水线**端到端编排**（Step 1/8 → 8/8 + dry-run 输出格式）的回归保护——当前只被 protocol/orchestration 单点覆盖，集成事实无 CI 回归。

## 架构快照

- 本次方案：在 `.github/workflows/ob-tests.yml` 的 fast job 增加 一步 `bash tests/integration/init_dryrun_sanity.sh`。
- 不用 `run_all.sh --integration`：那会拖入 `integration/build_e2e.exp` 和 `manual_matrix_qemu.exp`（需真 workspace + QEMU，CI 跑不了）。本脚本独立、CI 友好，直接显式调用。
- `init_dryrun_sanity.sh` 自带临时 harness + fake OpenBMC checkout（`mktemp` + 假 `setup` 脚本），跑 `ob init <machine> -d`，断言 Step 1/8、Step 8/8、`[DRY-RUN]` 输出。`init_pipeline.sh` 每步均尊重 DRY_RUN（clone/bitbake/子仓库克隆全跳过），实测秒级 exit=0。
- 已知前提：dry-run 路径在 Step 1 前仍可能发一次 github 连通性 curl（`lib/init_pipeline.sh:27-29`，`--connect-timeout 5 --max-time 10`）；CI runner 有网络，不影响。离线/代理 CI 需评估。

## 输入工件

- 评审 finding F2（本次会话），落点：`tests/integration/init_dryrun_sanity.sh`、`tests/run_all.sh:19,32`（默认 LAYERS 不含 integration）、`.github/workflows/ob-tests.yml`。
- 实测依据：本会话 `bash tests/integration/init_dryrun_sanity.sh` → `ok   init dry-run sanity (romulus)`，exit=0，秒级。
- 无独立设计文档（改动范围小）。

## 评审决策点（交评审定）

- **D1**：步骤放哪。
  - 选项 A（推荐）= 加进现有 fast job 末尾（多 ~1-2s，与现有 .sh 测试同 job）。
  - 选项 B = 独立 `integration-sanity` job（隔离，但多一个 job 启动开销）。

## 文件结构与职责

- Modify：`.github/workflows/ob-tests.yml`（新增一步 `init dry-run sanity`）。

## 任务清单

### Task 1: 本地确认 init_dryrun_sanity.sh 绿且无真实网络 clone

- 目标：坐实脚本在干净环境秒级通过、dry-run 不发真实 clone（只可能发 github 连通性 curl）。
- Files：读 `tests/integration/init_dryrun_sanity.sh`、`lib/init_pipeline.sh`（无改动）。
- 验证范围：本地跑 exit=0、耗时 < 10s、输出含 `Step 1/8` 与 `[DRY-RUN]`。

- [ ] Step 1: 前置检查——CI 是否已跑此脚本
  - Run: `grep -n 'init_dryrun_sanity\|integration' .github/workflows/ob-tests.yml`
  - Expected: 无匹配（CI 尚未跑 integration 层）。
- [ ] Step 2: 本地实测 + 计时
  - Run: `time bash tests/integration/init_dryrun_sanity.sh`
  - Expected: 输出 `ok   init dry-run sanity (romulus)`，exit=0，real < 10s。
- [ ] Step 3: 无代码改动（前置观察）。
- [ ] Step 4: 确认 Expected 达成。
  - 若耗时异常大或卡住，说明 dry-run 路径有未预期的网络/磁盘动作，停下排查后再继续。

### Task 2: ob-tests.yml 新增 init dry-run sanity 步骤

- 目标：CI 增加一步跑 `tests/integration/init_dryrun_sanity.sh`。
- Files：Modify `.github/workflows/ob-tests.yml`。
- 验证范围：yml 语法合法、新 step 存在。

- [ ] Step 1: 前置检查——当前无此 step
  - Run: `grep -n 'init_dryrun_sanity' .github/workflows/ob-tests.yml`
  - Expected: 无匹配。
- [ ] Step 2: 确认缺失（同上）。
- [ ] Step 3: 在 fast job 的 `coverage radar` step 之前（或之后）新增 step（按 D1：A=加进 fast job；B=独立 job）
  - Change（D1=A 形态）：
    ```yaml
    - name: init dry-run sanity(8 步编排端到端,CI 友好,无真实 clone)
      run: bash tests/integration/init_dryrun_sanity.sh
    ```
  - D1=B 时改成独立 job（runs-on ubuntu-latest + checkout + 上面的 run）。
- [ ] Step 4: yml 语法校验
  - Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ob-tests.yml')); print('yaml ok')"`
  - Expected: `yaml ok`。
- [ ] Step 5: checkpoint commit
  - Run: `git add .github/workflows/ob-tests.yml && git commit -m "ci: 跑 init_dryrun_sanity 补 init 8 步编排回归(F2)"`
  - Expected: commit 成功。

### Task 3: 推分支验证 CI 实际跑通

- 目标：GitHub Actions 实测新 step 绿。
- Files：无（验证 only）。
- 验证范围：CI run 里新 step 通过，日志含 `ok   init dry-run sanity`。

- [ ] Step 1: 前置检查——本地分支状态
  - Run: `git log --oneline -1`
  - Expected: 最新 commit 是 Task 2 的。
- [ ] Step 2: 推分支触发 CI
  - Run: `git push -u origin <branch>`（若在 main 先切分支）
  - Expected: 推送成功。
- [ ] Step 3: 无代码改动。
- [ ] Step 4: 等 CI 完成、核对新 step 日志
  - Run: `gh run watch && gh run view --log 2>/dev/null | grep -E 'init dry-run sanity|Step [1-8]/8' | tail`
  - Expected: 新 step 绿，日志含 `ok   init dry-run sanity (romulus)`。
- [ ] Step 5: 无 commit。

## 执行纪律

- 开始前复查；Task 1 若显示 dry-run 有未预期网络动作，停下排查（可能需在计划里补网络 mocking 或判定 CI 不适合跑）。
- 每个任务都要跑验证。
- 若当前在 main，开始实现前先切分支。

## 最终验证

- Run: `gh run list -L 1` + 网页确认。
- Expected: 最新 run 含 `init dry-run sanity` step 且 ✓，日志含 `ok   init dry-run sanity (romulus)`。

## 审阅 Checkpoint

- 计划正文结束。请评审对 F2 取舍：做 / 不做；若做，D1 选 A（加进 fast job）还是 B（独立 job）。
