# AGENTS.md - openbmc-aware-harness

这个仓库是 OpenBMC 上下文工作的根入口。把它当作 home。

## Every Session

Before doing anything else:

1. Read `rules/SOUL.md` — this is who you are
2. Read `rules/USER.md` — this is who you're helping
3. Read `rules/WORKSPACE.md` — file routing table, check before searching for files
4. Read `rules/COMMUNICATION.md` — how to think and communicate
5. Read `rules/SKILLS_INDEX.md` — understand available skills

Don't ask permission. Just do it.

## File Routing

**找文件时，先查 `rules/WORKSPACE.md`，再搜索。** WORKSPACE.md 是这个 workspace 的目录索引，记录了每类内容的存放位置。绝大多数情况下查一下就能定位到目标目录，不需要全盘 glob/grep。如果发现新目录或项目没被收录，顺手更新 WORKSPACE.md。

## Skills

**Skills** 是 AI 可复用的能力，包括工作流、API 指南、最佳实践等。

**重要：遇到"怎么做 X"时，先查 skill 再查系统工具。** 搜索顺序：(1) 下方速查表 → (2) `rules/SKILLS_INDEX.md` → (3) 系统工具。

**需要执行某项任务** → 先查 `rules/SKILLS_INDEX.md` 找到对应的 skill
**想添加新能力** → 参考现有 skill 格式，更新 SKILLS_INDEX.md

### 常用 Skill 速查（以 INDEX.md 为准）

**多 Agent 并行分析** → `rules/skills/bestpractice_multi_agent_analysis.md`  
- 上下文窗口隔离、Topic 分割 50% 重叠、交叉验证  
- 配合 `rules/skills/workflow_parallel_subagents.md` 的执行框架

**调用后台 Agent / 并行 Subagent** → `rules/skills/workflow_parallel_subagents.md`  
- 何时拆分任务、如何并行派出多个 subagent  
- 准备使用并行 subagent 前，先把这个 skill 读一遍
- 派出 agent 后等系统通知即可，不需要轮询

## Axioms（公理）

从个人经历提炼的决策原则，用于启发深度思考。分类索引、使用指南和触发词见 `rules/AXIOMS_INDEX.md`。

## Sub-agent 模型路由

不同工具有各自的 subagent 机制和模型选择策略。当前主用 GitHub Copilot，偶尔用 Claude Code：

- **GitHub Copilot**：subagent 由 Copilot 自动调度，无需手动配置路由
- **Claude Code**：如需指定模型或并行 subagent，参考自身配置文件

创意性工作（brainstorm、文章结构、观点碰撞）可考虑在后台跑一个独立 agent，与主线程并行推进。

## Working Mode

- 设计和计划：先边界，再方案，再验证。
- 实现和调试：先找根因，再做最小改动，再跑可执行验证。
- review：先给 findings，再给证据和建议。

## Memory System

三层记忆架构：
- **L3（全局约束）**：`rules/` 下的所有文件，每次 session 被动加载
- **L1/L2（动态记忆）**：`contexts/memory/OBSERVATIONS.md`，agent 主动检索
- **手动积累**：通过 `/ai-heartbeat` slash command（[实现](.github/prompts/ai-heartbeat.prompt.md)）手动触发 observer（L1，当天观测）和 reflector（L2，每周反思）。

## Safety

- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking.
- When in doubt, ask.