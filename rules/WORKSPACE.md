# WORKSPACE.md - 目录路由速查

目标：让 AI 每轮 session 都能快速知道"去哪里找/放什么"。**找任何文件前先查这里。**

## 路由规则

### 项目与代码
- 工具脚本（依赖解析等）：`tools/`
- OpenBMC 环境初始化工具：根目录 `ob`（`./ob init [<machine>]` 一键初始化）
- OpenBMC 工作区（主仓库、子仓库源码、lockfile）：`workspace/`（整体 gitignore，仅保留 `.gitkeep`）

### 系统与规则
- 可复用技术方案 / Skill：`rules/skills/`（索引见 `rules/SKILLS_INDEX.md`）
- 核心公理（Axioms）：`rules/axioms/`（索引见 `rules/AXIOMS_INDEX.md`）
- 记忆系统：`contexts/memory/`
- AI Heartbeat 心跳子系统（PRD、源码、测试、配置）：`periodic_jobs/ai_heartbeat/`
- GitHub Copilot 入口与 hooks：`.github/`
- GitHub Copilot/Claude Code 仓库级自定义 skills：`.claude/skills/`
- 设计文档：`docs/specs/`（通过 `/brainstorming` skill 触发后自动落盘）
- 实施计划：`docs/plans/`（通过 `/writing-plans` skill 触发后自动落盘）

## 命名规则
- 目录和文件名：小写 + 下划线 (snake_case)
- 临时一次性项目：`tmp_<name>/`

## 查找原则

- 先查本表，再搜索。
- 如果问题涉及外部 OpenBMC 源码树，在计划或上下文里明确源码根目录，不要假设它已经在本仓内。

<!-- 随着你的项目增长，在这里添加活跃项目的快捷路由 -->
<!-- 格式：- `romulus bmcweb recipe` → `workspace/src/romulus/bmcweb` (说明) -->