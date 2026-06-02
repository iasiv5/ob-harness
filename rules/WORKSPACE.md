# WORKSPACE.md - 目录路由速查

目标：让 AI 每轮 session 都能快速知道"去哪里找/放什么"。**找任何文件前先查这里。**

## 路由规则

### 项目与代码
- 写代码 / 跑脚本 / 一次性项目：`adhoc_jobs/<project>/`
- 工具脚本（邮件、语义搜索、分享报告等）：`tools/`
- OpenBMC 环境初始化工具：根目录 `ob`（`./ob init [<machine>]` 一键初始化）
- OpenBMC 工作区（主仓库、子仓库源码、lockfile）：`workspace/`（整体 gitignore，仅保留 `.gitkeep`）

### 系统与规则
- 可复用技术方案 / Skill：`rules/skills/`
- 核心公理（Axioms）：`rules/axioms/`
- 记忆系统：`contexts/memory/` 

## 命名规则
- 目录和文件名：小写 + 下划线 (snake_case)
- 临时一次性项目：`tmp_<name>/`

### 设计与计划（使用 /brainstorming 和 /writing-plans skills 触发后自动落盘）
- 设计文档：`docs/specs/`
- 实施计划：`docs/plans/`

## 查找原则

- 先查本表，再搜索。
- 如果问题涉及外部 OpenBMC 源码树，在计划或上下文里明确源码根目录，不要假设它已经在本仓内。

<!-- 随着你的项目增长，在这里添加活跃项目的快捷路由 -->
<!-- 格式：- `project-name` → `adhoc_jobs/project_name/` (说明) -->