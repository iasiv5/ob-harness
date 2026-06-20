# ob 优先（OpenBMC 环境动作统一前门）实施计划

## 目标

把"ob 优先"约定固化进 harness：agent 做 OpenBMC 环境生命周期动作前，先 `ob --help` 查 ob 是否提供对应能力，提供就走 `ob <cmd>`，仅当 `exit 1` 真实失败且 ob 确无此能力时才手动兜底。落点覆盖常驻约定层（AGENTS.md）、按需细节层（新 skill）、能力清单审核与防漂移（ob usage() + 测试）、provenance（CONTEXT.md 术语 + ADR）。

## 架构快照

- **单一能力清单**：`ob --help`（`usage()` heredoc）是唯一权威能力清单。本次审核修正它，并新增一个 `tests/protocol/` 测试断言 `usage()` Commands 段 ↔ dispatch `case "$COMMAND"` 子命令集合一致，随 ob 增长防漂移。该测试被 `run_all`（→ `ob_check.sh` §4 → CI `ob-tests.yml`）三处覆盖。
- **两层落点**：常驻层 AGENTS.md「Working Mode」放约 5 行守卫 + 指针（每会话加载）；完整 exit-code 契约 / 按码回退 / 严格度协议落到新建 `rules/skills/bestpractice_06-ob_first.md`（按需检索），匹配 harness 既有渐进式披露范式。
- **exit-code 契约（实据，源自 ob 现状，非本次发明）**：0=成功/良性无操作；1=真实失败（坏了或用法错）；2=用户主动取消（非失败）；3=前置缺失（缺 machine/TTY/未 init/未 build，修复方式是用 ob 补前置）。四档在 `cmd_init`/`cmd_build`/`cmd_start_qemu`/`cmd_stop_qemu` 一致。
- **shellcheck baseline 注意**：CI 用 `diff -u tests/.shellcheck-baseline` 精确比对（含行号）。改 `usage()` 会下移其后代码的行号，必须经 `tools/ob_check.sh` 自动重生成 baseline 并 git diff 确认，否则 CI baseline 步骤会因行号平移失败。
- **范围与后续**：`ob build` 纯交互（非 TTY → `exit 3`，[ob](../../ob) `cmd_build`）是"ob 作为 agent 前门"的已知缺口。本次**不改 ob 代码**，仅在新 skill 的"已知缺口"段登记 + 给出 exit-3 不转手动的处置；非交互 build 路径留作后续 ob 功能项。不手动改 `contexts/memory/OBSERVATIONS.md`（由 ai-heartbeat 维护）。

## 输入工件

- 本会话 grilling 收口结论（session memory `ob-first-design.md`，6 题 + 附加项全部锁定）
- 待产出 `docs/adr/0003-ob-first-front-door.md`（本计划 Task 8 产出，记录决策与被否备选）
- 设计经 grilling + domain-modeling 敲定，无独立 `docs/specs/` 设计稿

## 文件结构与职责

- Modify: `ob`（`usage()` heredoc，§7 入口）— 补 `-s/--skip-deps`、标注 `--url` 为 init-only、新增 `Exit Codes:` 段
- Create: `tests/protocol/usage_dispatch_sync.sh` — 断言 `usage()` Commands ↔ dispatch 子命令集合一致；支持 `OB_FILE` 覆盖以便漂移演示
- Modify: `AGENTS.md`（`## Working Mode` 后）— 新增 `## ob 优先` 常驻守卫 + 指针
- Create: `rules/skills/bestpractice_06-ob_first.md` — 完整协议（enabling 式）
- Modify: `rules/05_SKILLS_INDEX.md`（BestPractice 分类）— 登记第 6 条
- Modify: `rules/03_WORKSPACE.md`（`ob` 路由项）— +1 行交叉引用
- Modify: `rules/skills/workflow_01-obmc_env_init.md`（可用资源段）— +1 行指针
- Modify: `CONTEXT.md`（Language 段）— 新增 `ob 优先`、`exit-code 契约` 两术语
- Create: `docs/adr/0003-ob-first-front-door.md` — 决策记录（仿 0001 格式）

环境前提：`bash`、`python3`、`shellcheck`、`git`（本地与 CI 均已具备）。所有验证命令在仓库根执行。

## 任务清单

### Task 1: 审核修正 ob usage()

- 目标：把 `ob --help` 修成准确的权威能力清单——补漏掉的 `--skip-deps`、标注 `--url` 适用范围、写入 exit-code 契约。
- Files: Modify `ob`（`usage()`）
- 验证范围：`./ob --help` 输出含 `--skip-deps` 与 `Exit Codes` 段；`ob_check.sh` ALL GREEN。

- [ ] Step 1: 确认当前漂移（`--skip-deps` 缺失）
- Run: `./ob --help | grep -- '--skip-deps' && echo FOUND || echo MISSING`
- Expected: `MISSING`（证实 usage() 与实现脱钩）

- [ ] Step 2: 编辑 `usage()`
- Change: 在 Global Options 加 `-s, --skip-deps  Reuse existing deps.json, skip dependency resolution (init only)`；把 `--url` 行尾标注 `(init only)`；在 `Environment Variables` 段前新增：
  Exit Codes:
    0   Success (or benign no-op)
    1   Failure — broken, or usage error (e.g. unknown option)
    2   Cancelled by user (not a failure)
    3   Precondition missing (e.g. machine not initialized / not built);
        satisfy it via ob (run the suggested 'ob ...' first), then retry

- [ ] Step 3: 确认 `--help` 更新生效
- Run: `./ob --help | grep -E -- '--skip-deps|Exit Codes:'`
- Expected: 两行都命中

- [ ] Step 4: 跑配套自检（含 baseline 自动重生成）
- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`；若提示 `shellcheck baseline 自动重生成`，`git diff tests/.shellcheck-baseline` 确认仅行号平移
- [ ] Step 5: checkpoint commit（ob + baseline）

### Task 2: 新增 usage↔dispatch 防漂移测试

- 目标：固化"`ob --help` 子命令集合 == dispatch 子命令集合"不变量，随 ob 增长（如未来 `ob dev`）自动拦截漂移。
- Files: Create `tests/protocol/usage_dispatch_sync.sh`
- 验证范围：对干净 ob 通过；注入漂移时失败并报告差异；被 `run_all` 自动发现。

- [ ] Step 1: 写测试脚本
- Change: 创建 `tests/protocol/usage_dispatch_sync.sh`：从 `${OB_FILE:-ob}` 提取两个集合——(a) dispatch `case "$COMMAND" in` 与其结尾 `esac` 之间的 `<cmd>)` 标签（排除 `*)`）；(b) `usage()` 输出里 `Commands:` 段下的命令名。集合不等则打印缺失/多余项并 `exit 1`，相等 `exit 0`。脚本头部 `set -uo pipefail`，对齐其他 protocol 测试风格。
- [ ] Step 2: 对当前 ob 运行
- Run: `bash tests/protocol/usage_dispatch_sync.sh; echo "rc=$?"`
- Expected: `rc=0`（init/build/status/start-qemu/stop-qemu 两侧一致）

- [ ] Step 3: 漂移注入演示（证明有牙）
- Run: `cp ob /tmp/ob.drift && sed -i 's/^        init)/        zzz)\n            :\n            ;;\n        init)/' /tmp/ob.drift && OB_FILE=/tmp/ob.drift bash tests/protocol/usage_dispatch_sync.sh; echo "rc=$?"`
- Expected: `rc=1`，输出含 `zzz`（dispatch 多出、usage 缺失）
- [ ] Step 4: 清理临时文件
- Run: `rm -f /tmp/ob.drift`
- Expected: 无输出，rc=0

- [ ] Step 5: 确认被 run_all 收录且全绿
- Run: `bash tests/run_all.sh`
- Expected: `ALL GREEN`，`=== protocol ===` 段含 `ok   usage_dispatch_sync.sh`
- [ ] Step 6: checkpoint commit（新测试）

### Task 3: AGENTS.md 常驻守卫

- 目标：在每会话加载的 AGENTS.md 放最小 always-on 守卫 + 指针，使"先走 ob、不误回退"不依赖加载 skill。
- Files: Modify `AGENTS.md`
- 验证范围：新增节存在且含指向 bestpractice_06 的指针。

- [ ] Step 1: 确认当前缺失
- Run: `grep -q 'ob 优先' AGENTS.md && echo PRESENT || echo MISSING`
- Expected: `MISSING`
- [ ] Step 2: 在 `## Working Mode` 之后插入新节
- Change: 新增
  ## ob 优先（OpenBMC 环境动作的统一前门）

  做 OpenBMC 环境生命周期动作（初始化、编译、状态、QEMU 起停等）前，先 `ob --help` 查 ob 是否提供对应能力；提供就走 `ob <cmd>`，不要先手动。`ob --help` 是唯一权威能力清单，随 ob 增长更新。

  退出码判读：`exit 1` 才是真失败、才考虑手动兜底；`exit 2`（用户取消）和 `exit 3`（前置缺失，按提示用 ob 补前置再重试）都不是失败，不要据此绕过 ob。完整 exit-code 契约、按码回退和手动兜底规则见 `rules/skills/bestpractice_06-ob_first.md`。
```raw
- [ ] Step 3: 确认落地
- Run: `grep -c 'bestpractice_06-ob_first' AGENTS.md`
- Expected: 输出 `1`（指针存在）

### Task 4: 新建 rules/skills/bestpractice_06-ob_first.md

- 目标：承载完整 ob 优先协议，enabling 式（目标/边界/验收/资源/陷阱），非 SOP。
- Files: Create `rules/skills/bestpractice_06-ob_first.md`
- 验证范围：文件存在且覆盖 scope、`ob --help` 发现机制、exit-code 契约、按码回退、严格度(c)+SOUL 确认复用、绕过记录+回流反馈环、已知缺口（build 纯交互）、planned 命令不进 --help。

- [ ] Step 1: 确认当前缺失
- Run: `test -f rules/skills/bestpractice_06-ob_first.md && echo EXISTS || echo MISSING`
- Expected: `MISSING`
- [ ] Step 2: 写 skill（含元数据块：类型 BestPractice / 适用场景 / 创建日期 2026-06-20）
- Change: 按 bestpractice_01 的 enabling 原则组织内容，覆盖上列验收范围；exit-code 契约用表格；"已知缺口"段写明 `ob build` 纯交互、agent 遇 exit 3 不转手动跑裸 bitbake、记为 ob 待补项。
- [ ] Step 3: 校验关键锚点齐全
- Run: `grep -E 'ob --help|exit 1|exit 2|exit 3|已知缺口|ob build' rules/skills/bestpractice_06-ob_first.md | wc -l`
- Expected: 输出 ≥ `5`

### Task 5: 登记 05_SKILLS_INDEX.md

- 目标：让新 skill 可被发现。
- Files: Modify `rules/05_SKILLS_INDEX.md`
- 验证范围：BestPractice 分类下出现第 6 条且链接正确。

- [ ] Step 1: 确认当前缺失
- Run: `grep -q 'bestpractice_06-ob_first' rules/05_SKILLS_INDEX.md && echo PRESENT || echo MISSING`
- Expected: `MISSING`
- [ ] Step 2: 在 BestPractice 列表末尾加一条
- Change: `- [ob 优先（统一前门）](skills/bestpractice_06-ob_first.md) — 做 OpenBMC 环境动作前，先查 ob 是否提供该能力并优先调用。`
- [ ] Step 3: 确认落地
- Run: `grep -c 'bestpractice_06-ob_first' rules/05_SKILLS_INDEX.md`
- Expected: 输出 `1`

### Task 6: 交叉引用（03_WORKSPACE.md + workflow_01）

- 目标：在 ob 路由项与 init/build 入口各放一行指针，提高命中率。
- Files: Modify `rules/03_WORKSPACE.md`、`rules/skills/workflow_01-obmc_env_init.md`
- 验证范围：两文件各含一处指向 bestpractice_06 的引用。

- [ ] Step 1: `rules/03_WORKSPACE.md` 的 `ob` 路由项追加：`（环境生命周期动作先走 ob，见 rules/skills/bestpractice_06-ob_first.md）`
- [ ] Step 2: `rules/skills/workflow_01-obmc_env_init.md` 可用资源段追加一行：`> ob 优先调用约定（先查 ob 再手动）见 bestpractice_06-ob_first.md。`
- [ ] Step 3: 确认两处落地
- Run: `grep -l 'bestpractice_06-ob_first' rules/03_WORKSPACE.md rules/skills/workflow_01-obmc_env_init.md | wc -l`
- Expected: 输出 `2`

### Task 7: CONTEXT.md 两术语

- 目标：固化 `ob 优先`、`exit-code 契约` 两个 glossary 术语（仅定义，不放实现细节）。
- Files: Modify `CONTEXT.md`
- 验证范围：两术语均出现在 Language 段，格式含 `_Avoid_`。

- [ ] Step 1: 确认当前缺失
- Run: `grep -q '^\*\*ob 优先' CONTEXT.md && echo PRESENT || echo MISSING`
- Expected: `MISSING`
- [ ] Step 2: 在 Language 段追加两条（沿用现有 `**term**: / 定义 / _Avoid_:` 格式）
- Change: `ob 优先 (ob-first)` 与 `exit-code 契约`，定义对齐架构快照里的措辞；`exit-code 契约` 补充现有 `function semantic layer` 条目里关于 exit 3 的说法。
- [ ] Step 3: 确认两术语落地
- Run: `grep -E '^\*\*(ob 优先|exit-code 契约)' CONTEXT.md | wc -l`
- Expected: 输出 `2`

### Task 8: 写 ADR 0003

- 目标：记录 ob 优先决策的背景、权衡和被否备选。
- Files: Create `docs/adr/0003-ob-first-front-door.md`
- 验证范围：文件存在，含 `Status: accepted` 与 `## Considered Options`。

- [ ] Step 1: 确认当前缺失
- Run: `test -f docs/adr/0003-ob-first-front-door.md && echo EXISTS || echo MISSING`
- Expected: `MISSING`
- [ ] Step 2: 写 ADR（仿 0001：标题 + 决策散文段 + `Status: accepted` + `## Considered Options` 编号备选）
- Change: 决策=ob 作为 OpenBMC 环境动作统一前门；背景=ob 在长大（ob dev 已规划）、agent 是默认调用方、A12 AI 原生范式；机制=`ob --help` 单源 + 防漂移测试 + 按码回退；被否备选=放任直连最短路径 / 软偏好 / 结构化 JSON 双清单 / SessionStart hook / PreToolUse 拦截 hook。
- [ ] Step 3: 确认格式
- Run: `grep -E 'Status: accepted|Considered Options' docs/adr/0003-ob-first-front-door.md | wc -l`
- Expected: 输出 `2`
- [ ] Step 4: checkpoint commit（约定层 + provenance）

## 执行纪律

- 开始实现前先复查本计划。
- 每个 Task 按其 Run/Expected 验证；未达预期立即停下排查，不跳过。
- 改 `ob` 后必跑 `tools/ob_check.sh`（Task 1 已含），baseline 若被重生成需 git diff 确认仅行号平移。
- 不手动改 `contexts/memory/OBSERVATIONS.md`。
- 不在本计划内改 `ob build` 的交互行为（已划为后续项）。

## 最终验证

- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`（extract_funcs GAPS=0 / reorder 无 mismatch / shellcheck baseline 一致或良性重生成 / run_all 含新 `usage_dispatch_sync.sh` 全绿）
- Run: `./ob --help | grep -E -- '--skip-deps|Exit Codes:'`
- Expected: 两行命中
- Run: `grep -l 'bestpractice_06-ob_first' AGENTS.md rules/05_SKILLS_INDEX.md rules/03_WORKSPACE.md rules/skills/workflow_01-obmc_env_init.md | wc -l`
- Expected: 输出 `4`
- 编辑过的文件用编辑器诊断检查，无新增报错。

## 审阅 Checkpoint

- 计划已写好并保存到 `docs/plans/2026-06-20-ob-first-front-door-implementation-plan.md`。
- 请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。

```