# Agent Runtime 路径速查

这份参考用于 `cleanup` 在终态沉淀时盘点仓库内长期知识载体。下面以 GitHub Copilot 仓库的路径为**示例**展开细节；Claude Code、Cursor、Codex、OpenCode 等其他 runtime 的等价入口见「跨 runtime 路径对照」。

默认目标是仓库内知识，不是用户全局知识。
如果用户没有明确要求，不要把扫描范围扩到用户级长期记忆或全局 skills。

## 跨 runtime 路径对照

不同 runtime 的长期知识载体位置不同。先按下表定位当前 runtime 的入口，再按后面 Copilot 示例表展开细节。非 Copilot 仓库只参考本表定位自己的入口，不要照搬后面 Copilot 示例表里的路径。

| 用途 | Claude Code | Cursor | Copilot | Codex / 通用 |
|---|---|---|---|---|
| 项目级主指令 | `CLAUDE.md` | `.cursor/rules/*.mdc` | `.github/copilot-instructions.md` | `AGENTS.md` |
| 范围化指令 / skills | `.claude/skills/`、`.claude/commands/` | `.cursor/rules/` | `.github/instructions/`、`.github/skills/` | `AGENTS.md` 片段、`.agents/skills/` |
| agents | `.claude/agents/` | — | `.github/agents/*.agent.md` | `.agents/agents/` |
| 用户级 | `~/.claude/skills/` | `~/.cursor/rules/` | `~/.copilot/skills/`、`~/.agents/skills/` | `~/.agents/skills/` |

## 项目级主指令（Copilot 示例）

以 GitHub Copilot 仓库为例，主指令入口优先看下面两个位置：

| 用途 | 路径 | 处理建议 |
|---|---|---|
| 项目级主指令 | `AGENTS.md` | 优先作为主入口；如果仓库明确采用它，就不要再把 `.github/copilot-instructions.md` 当第二主入口 |
| 项目级主指令（旧入口） | `.github/copilot-instructions.md` | 只在仓库明确采用它时使用；如果与 `AGENTS.md` 同时存在且都写实质内容，标为待整理 |

如果仓库同时存在 `AGENTS.md`、`CLAUDE.md` 和 `.github/copilot-instructions.md`，先读本仓库 / 工作区规则判断权威入口。软链、一行 include、`@AGENTS.md` 这类转发入口不算内容分叉；两份以上独立文件都承载实质规则且没有明确同源关系时，标为待整理，不要擅自合并。

## 范围化指令与工作流资产

| 类型 | 路径 |
|---|---|
| 文件级指令 | `.github/instructions/*.instructions.md` |
| 自定义 agents | `.github/agents/*.agent.md` |
| Prompts | `.github/prompts/*.prompt.md` |
| 项目级 skills | `.github/skills/<name>/SKILL.md` |
| 项目级 skills（兼容目录） | `.agents/skills/<name>/SKILL.md` |
| 项目级 skills（兼容目录） | `.claude/skills/<name>/SKILL.md` |
| Hooks | `.github/hooks/*.json` |

对 `cleanup` 来说，这些文件属于项目级长期知识面。
如果当前任务改动了这些资产本身，或它们的说明已经过期，就要把它们纳入盘点范围。

## 用户级 assets

各 runtime 的用户级 assets 常见于：

- `~/.copilot/skills/<name>/SKILL.md`
- `~/.agents/skills/<name>/SKILL.md`
- `~/.claude/skills/<name>/SKILL.md`

默认不要扫描这些路径。
只有当用户明确要求同步用户级长期知识，或者任务本身就是在改用户级 skill / agent 资产时，才把它们纳入范围。

## 插件 / marketplace 仓库的额外盘点面

如果当前仓库不是普通应用仓库，而是像 `m/plugins/<plugin>` 这样的插件 / marketplace 打包仓库（Copilot 插件或其它 runtime 的等价打包形式），还要额外盘点：

| 类型 | 路径 |
|---|---|
| 插件 README | `plugins/<plugin>/README.md` 或等价路径 |
| 插件变更记录 | `plugins/<plugin>/CHANGELOG.md` |
| 插件 manifest | `plugins/<plugin>/.github/plugin/plugin.json` |
| marketplace 元数据 | `.github/plugin/marketplace.json` |
| 插件内 assets | `plugins/<plugin>/agents/`、`commands/`、`skills/`、`instructions/`、`hooks/` |

这类仓库里，`cleanup` 不应只看代码和 docs，还要同步 published surface 的说明与元数据。

## 推荐盘点顺序（Copilot 示例）

以 GitHub Copilot 仓库为例，执行 `cleanup` 时推荐按下面顺序盘点（其他 runtime 把对应入口替换成「跨 runtime 路径对照」里的等价路径）：

1. 先确认项目级主指令到底是 `AGENTS.md`、`CLAUDE.md` 还是 `.github/copilot-instructions.md`，以及是否存在明确同源 / 转发关系
2. 再检查 `.github/instructions/` 是否有范围化规则已经过期
3. 再检查 `.github/agents/`、`.github/prompts/`、项目级 `skills/` 是否和当前事实一致
4. 再检查仓库内 README、docs、CHANGELOG 等长期知识文档
5. 如果是插件 / marketplace 仓库，再检查 plugin manifest 和 marketplace metadata
6. 只有在用户明确要求时，才扩到用户级长期知识

## 默认不要做的事

- 不要把 `AGENTS.md`、`CLAUDE.md` 和 `.github/copilot-instructions.md` 同时当成多个双主入口长期保留
- 不要默认扫描整个用户目录
- 不要把用户级长期知识当成仓库级 cleanup 的默认目标
- 不要为了“显得完整”就把所有 prompts、hooks、instructions 全部抄进长期知识摘要
