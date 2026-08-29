# 多 harness 的 skill / 斜杠命令适配：单一物理来源 + 最小桥接 + 入口解耦

## TL;DR · 30 秒决策

本仓库的 skill 与斜杠命令要同时服务 Claude Code / GitHub Copilot / DeepSeek Harness (DSH) 三家，适配结构三句话：

1. **skill 实体只有一个物理来源**：`.claude/skills/<name>/`（Claude Code 和 Copilot 都从这里读）；DSH 不读 `.claude/`，靠 `.dsh/skills/<name>` 相对符号链接桥接。**新增第 10 个 skill = 实体 + 一条链接**：`ln -sfn ../../.claude/skills/<name> .dsh/skills/<name>`。
2. **新增斜杠命令**：`.claude/commands/<n>.md` + `.github/prompts/<n>.prompt.md` + `.dsh/skills/<n>.md` 三入口，DSH 入口是带 `name`/`description` frontmatter 的 skill 文件（DSH 里命令就是 skill，`/name` 即调用）。
3. **三个入口互不引用**（尤其不引用 `.claude/commands/` 这类 Claude Code 专属入口文件）：共同事实只允许是中立合同（`periodic_jobs/` SOP、`rules/knowhow/` workflow）或 skill 物理文件本身；拿掉任何一家 harness 的入口文件，另外两家不受影响。

## 元数据

- **类型**: BestPractice
- **适用场景**: 给 ob-harness 新增/修改 skill 或斜杠命令；排查"DSH 认不到某 skill/命令"；三家 harness 入口同步
- **创建日期**: 2026-08-29
- **来源**: 为 ob-harness 接入 DSH 的适配会话：9 个 skill 符号链接 + 4 个斜杠命令三入口落地，DSH 源码（`dsh-skill-filesystem`）机制实测

## 目标与边界

- **目标**：skill/命令在三家 harness 中都可发现、可调用，且维护动作最小、互相零耦合。
- **边界**：只管本仓库的 skill/命令适配层。DSH 用户级技能目录（`~/.agents/skills`，SkillHub 安装位置）不在本文件范围。

## 事实层：DSH 的发现机制（源码实测，行为依据）

同名 skill 按 rank 升序取胜，小者赢：

| rank | 来源 | 路径 |
|---|---|---|
| 100 | project-dsh | `<git root>/.dsh/skills/` |
| 200 | project-agents | `<git root>/.agents/skills/` |
| 400 | user-dsh | `~/.dsh/skills/` |
| 500 | user-agents | `~/.agents/skills/` |

要点：

1. `<git root>` = 从 session cwd 向上第一个含 `.git` 的目录；DSH **不读** `.claude/`。
2. 条目两种形态：目录（内含 `SKILL.md`）或裸 `.md` 文件；frontmatter 必须有 `name`（kebab-case：`^[a-z0-9]+(-[a-z0-9]+)*$`）和 `description`；未知字段（如 `argument-hint`）被忽略。
3. 符号链接会被跟随（枚举时 `stat` 目标），项目根下符号链接到的 skill 与实体等价。
4. 文件 watcher 实时生效：会话中新增/修改 skill 立即进目录，无需重启。
5. 斜杠命令即 skill：`/name` 输入框菜单、消息内手打 `/name`、模型按目录主动加载，三入口同一注册表；带 `disable-model-invocation: true` 的 skill 只有用户 `/name` 入口、模型目录不列（这是设计不是故障）。

## 设计原则

1. **单一物理来源**：skill 实体放 `.claude/skills/`（两家直接读），只给 DSH 一份符号链接——桥接成本 = 1 家 × N 条，任何"实体挪到中立目录、两家都做链接"的方案都更贵。
2. **入口解耦**：每个 harness 的命令入口自包含（adapter 内联 + 引用中立合同），不引用其他 harness 的入口文件。引用对象只有两类：中立合同文件、skill 物理文件（如 pick-one-arch-task 三家一致指向 `.claude/skills/improve-codebase-architecture/SKILL.md`）。
3. **无中立合同的命令**（如 goal-driven，模板内联）：每家入口内联一份完整副本是现行模式，但已知漂移代价（两份已漂 15 行）；**新增命令时优先抽中立合同**再让三入口引用，不要新增第三份内联。

## 验收标准

1. 新增 skill 后：`.claude/skills/<name>/SKILL.md` 存在且 frontmatter 合规；`.dsh/skills/<name>` 符号链接存在且指向正确；DSH 会话目录里能看到该名字。
2. 新增命令后：三入口齐备；DSH 入口 frontmatter 的 name 与命令名一致（`/name` 才能命中）。
3. 任何一家 harness 的入口文件被删除，另外两家的命令仍可执行（不因缺文件而断）。

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|------|------|------|
| 整目录符号链接（`.dsh/skills -> .claude/skills`） | `ATTRIBUTIONS.md` 等裸 `.md` 被当 skill 候选解析，产生 warn 噪音；目录里混入的杂 `.md` 都会进候选 | 逐 skill 做链接，`.dsh/skills/` 里只放链接和命令入口 |
| DSH 行为与用户级同名 skill 不一致 | `~/.agents/skills` 也有 codebase-design 等 5 个同名 skill，按 rank 项目版(100)永远覆盖用户版(500) | 调试"为什么不是用户级那份行为"时先想 rank 覆盖，再看文件内容 |
| 以为 `disable-model-invocation` 的 skill 没生效 | 模型目录里不列，但 `/name` 用户入口正常 | 这是 frontmatter 设计语义，不是注册失败 |
| DSH 入口写成"读 `.claude/commands/` 的包装" | 与 Claude Code 入口文件耦合，删除其入口会连坐 DSH | 入口只引用中立合同或物理 skill 文件（本仓库已修正过一版） |
| frontmatter 用驼峰（`disableModelInvocation` 等） | DSH 直接拒绝该文件（要求 kebab-case 键） | 用 `disable-model-invocation` / `user-invocable` |

## 与现有体系的关系

- 目录路由与维护命令速查见 `rules/03_WORKSPACE.md` 的 `.dsh/skills/` 条目（本文件讲 why 与机制，那边讲 where）。
- know-how 编号不回收不重排（[ADR-0018](../../docs/adr/0018-knowhow-numbering-stability.md)）；本文件为 bestpractice_16。
- 沉淀流程本身走 `workflow_04`（判所有权 → 判层 → 写 → 收口），本文件即其手动通道产物。
