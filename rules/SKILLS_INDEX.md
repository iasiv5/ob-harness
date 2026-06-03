# Skills Index

本索引指向可复用的 Skills（技能）—— AI 可以调用的工具、工作流程和最佳实践。

- **想使用某个能力** → 浏览下方分类，找到对应的 skill 文件
- **想添加新 skill** → 见底部[「如何添加你自己的 Skill」](#如何添加你自己的-skill)

---

## 分类索引

### API Guide（API 指南）

调用外部系统或工具的操作手册。

- [AI CLI Agent 实用指南](skills/ai_agent_cli_guide.md) — 理解 CLI agent 的工作方式、限制和文件响应模式。

### Workflow（工作流）

特定任务的完整工作流程。

- [并行 Subagent 工作流](skills/workflow_parallel_subagents.md) — 当问题可以拆成多个独立定位面时使用。
  - **必读**：初次使用并行 subagent 前，必须先读此 skill
  - **禁止轮询**：agent 运行期间不要反复调用 `background_output`，系统会自动通知
  - 判断标准：任务可拆分为 ≥2 个子任务，每个 ≥5 tool calls
  - 核心参数：并行度 ≤5，调研 overlap 30-50%，代码 overlap 0-20%
- [OpenBMC 开发环境初始化](skills/workflow_obmc_env_init.md) — 一键初始化 OpenBMC 开发环境，clone 子仓库，注入 externalsrc 配置。

### BestPractice（最佳实践）

通用的最佳实践和经验教训。

- [AI 编程核心方法论](skills/bestpractice_ai_programming_mindset.md) — 先确认问题、成功标准和验证方式。
- [AI 辅助调试诊断](skills/bestpractice_ai_debugging_diagnosis.md) — 遇到构建、运行或接口异常时优先参考。
- [Skill 写作指南（Meta-Skill）](skills/bestpractice_skill_writing.md) — 创建或重写 skill 时使用，强调结果确定性、验收标准和边界条件
- [分阶段工作法](skills/bestpractice_staged_approach.md) — 用隔离、处理、验证闭环收口。
- [多 Agent 并行 analysis](skills/bestpractice_multi_agent_analysis.md) — 适合跨模块分析和问题分治。
- [产品/技术决策逆向工程](skills/bestpractice_product_decision_analysis.md) — 用于方案比较、架构取舍和设计复盘。
- [时间敏感信息验证](skills/bestpractice_temporal_info_verification.md) — 用于处理版本、spec 和发布时间不确定的问题。

---

## 如何添加你自己的 Skill

创建或重写 skill 前，先读 [`bestpractice_skill_writing.md`](skills/bestpractice_skill_writing.md)。它说明如何用目标、验收标准、可用资源和输出规格定义一个 skill，而不是把 skill 写成机械步骤清单。

文件命名建议采用 `<category>_<name>.md`，例如 `workflow_my_process.md`、`bestpractice_my_insight.md`。写完后在本 INDEX 的对应分类下添加入口，确保后续 agent 能找到。

## Progressive Disclosure

Skills 采用渐进式披露原则：
- **SKILLS_INDEX.md** 提供概览，快速定位
- **具体 skill 文件** 包含完整的操作步骤和示例