# AGENTS.md - ob-harness

这个仓库是 OpenBMC 上下文工作的根入口。把它当作 home。

## Every Session

Before doing anything else:

1. Read `rules/01_SOUL.md` — this is who you are
2. Read `rules/02_USER.md` — this is who you're helping
3. Read `rules/03_WORKSPACE.md` — file routing table, check before searching for files
4. Read `rules/04_COMMUNICATION.md` — how to think and communicate
5. Read `rules/05_SKILLS_INDEX.md` — understand available skills

Don't ask permission. Just do it.

## File Routing

**找文件时，先查 `rules/03_WORKSPACE.md`，再搜索。** WORKSPACE.md 是这个 workspace 的目录索引，记录了每类内容的存放位置。绝大多数情况下查一下就能定位到目标目录，不需要全盘 glob/grep。如果发现新目录或项目没被收录，顺手更新 WORKSPACE.md。

## Skills

**Skills** 是 AI 可复用的能力，包括工作流和最佳实践。

**重要：遇到"怎么做 X"时，先查 skill 再查系统工具。** 搜索顺序：(1) `rules/05_SKILLS_INDEX.md` → (2) 系统工具。

**想添加新能力** → 参考 `rules/skills/bestpractice_01-skill_writing.md`，写完后更新 `rules/05_SKILLS_INDEX.md`

## Axioms（公理）

从个人经历提炼的决策原则，用于启发深度思考。分类索引、使用指南和触发词见 `rules/06_AXIOMS_INDEX.md`。

## Working Mode

- 设计和计划：先边界，再方案，再验证。
- 实现和调试：先找根因，再做最小改动，再跑可执行验证。改动 `ob` / `lib/*.sh` 后，额外跑 `tools/ob_check.sh` 做配套自检（结构 / 函数登记 / shellcheck baseline / 测试，详见 `rules/03_WORKSPACE.md`）。
- review：先给 findings，再给证据和建议。

## ob 优先（OpenBMC 环境动作的统一前门）

做 OpenBMC 环境生命周期动作（初始化、编译、状态、QEMU 起停等）前，先 `ob --help` 查 ob 是否提供对应能力；提供就走 `ob <cmd>`，不要先手动。`ob --help` 是唯一权威能力清单，随 ob 增长更新。

退出码判读：`exit 1` 才是真失败、才考虑手动兜底；`exit 2`（用户取消）和 `exit 3`（前置缺失，按提示用 ob 补前置再重试）都不是失败，不要据此绕过 ob。完整 exit-code 契约、按码回退和手动兜底规则见 `rules/skills/bestpractice_06-ob_first.md`。

## Memory System

三层记忆架构：
- **L3（全局约束）**：`rules/` 核心规则（`01_SOUL`~`05_SKILLS_INDEX`）每次 session 启动读取；`06_AXIOMS_INDEX` 及 `axioms/`、`skills/` 按需检索
- **L1/L2（动态记忆）**：`contexts/memory/OBSERVATIONS.md`，agent 主动检索
- **手动积累**：通过 `/ai-heartbeat` slash command（[实现](.github/prompts/ai-heartbeat.prompt.md)）手动触发 observer（L1，当天观测）和 reflector（L2，每周反思）。

## Safety

- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking.
- When in doubt, ask.