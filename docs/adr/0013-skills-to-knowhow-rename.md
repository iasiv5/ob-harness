# Rename `rules/skills/` → `rules/knowhow/`: disambiguate from `.claude/skills/` harness skills and name the artifact accurately

本仓库同时存在两套 "skill"：`rules/skills/`（agent **读**的 Markdown 文档：workflow 过程 + bestpractice 原则/经验）与 `.claude/skills/`（Claude Code harness 原生 skill，agent 通过 Skill 工具**调用**、harness 自动发现）。同一术语指两种机制——`rules/skills/` 的东西从不被当作 skill 调用——是 CONTEXT.md 始终未收录 "skill" 词条的根因。同时 "skill" 把两种不同形状（workflow 过程 vs bestpractice 原则）混为一谈，且 meta 文档（`bestpractice_01`）把单条定义为带验收标准的"能力"，与 "skill"/"knowledge" 都不完全贴合。本 ADR 记录：**`rules/skills/` 改名为 `rules/knowhow/`，伞名用 know-how（实操经验），`.claude/skills/` 保留 "skill"**。决策经 `/grill-with-docs`（grilling + domain-modeling）7 个决策点锁定。

Status: accepted

## Considered Options

1. **knowledge（原提案）** —— 拒绝。knowledge 是陈述性/静态的，**装不下带验收标准的 workflow 过程**（一个 procedure 不是"知识"）。与 meta 文档把单条定义为"能力（带验收标准 + 输出规格）"自我打架。

2. **guide** —— 拒绝（次优）。guide 描述**用途**（指引 agent），不声称内容同质，是最低摩擦的伞名。但它是功能型命名，与兄弟目录的内容型命名（`rules/`、`axioms/`）不一致；且丢失了 know-how 的"hard-won 实战经验"内涵（bestpractice 那一半本质是 battle scars）。

3. **playbook** —— 拒绝。强过程导向，盖得住 workflow，但低估 bestpractice 原则/pattern 那一半。

4. **按形状拆成两目录（`playbooks/` + `practices/`）** —— 拒绝。最忠于"两个概念"，但 bestpractice 桶本身混着原则/已知坑/pattern/元过程（`bestpractice_01` 写作指南、`bestpractice_03` 调试诊断都是过程形），硬拆要逐文件重新归类；且 blast radius 翻倍（routing、每个交叉引用改两处）。前缀 `workflow_`/`bestpractice_` 已承载两种形状的区分，无需拆目录。

5. **know-how（接受）** —— 伞名 know-how（token `knowhow`，gloss 实操经验）。know-how 本义是"实操性、怎么做"的经验，**同时盖住 workflow（怎么做）与 bestpractice（踩坑换来的经验）两种形状**——正是 knowledge 装不下的那一半；与兄弟目录内容型命名一致；不撞 `.claude/skills/`。代价：know-how 是 mass noun（不可数），单条用 "know-how 条目"（不称 "a know-how"），这也顺带消解了 meta 文档的递归（"写 know-how 条目的 know-how 条目"，而非"写 skill 的 skill"）。

## Consequences

- **物理层**：`rules/skills/` → `rules/knowhow/`（12 文件 `git mv`）；`rules/05_SKILLS_INDEX.md` → `rules/05_KNOWHOW_INDEX.md`；`bestpractice_01-skill_writing.md` → `bestpractice_01-knowhow_writing.md`。前缀 `workflow_`/`bestpractice_` **不变**（两种形状由前缀承载，不改）。
- **散文层**：所有活文件里指代 ob-harness artifact 的 "skill/Skill/技能" → "know-how/实操经验"；`.claude/skills/` 相关引用**保留 "skill"**（另一概念，见 CONTEXT.md `harness skill`）。
- **范围**：~10 个活文件、~95 处编辑；冻结历史文档（`docs/specs/**`、`docs/plans/**`，含旧的 `2026-06-05-skills-naming-*` 两篇）按惯例不动；harness skill 假阳性（`pick-one-arch-task` 引 `.claude/skills/improve-codebase-architecture`、`rules/03_WORKSPACE.md` L21/23/24、`KNOWLEDGE_BASE.md` L38）保留；axiom 里的泛指 "skill"（keqian-method skill、pi-mono Skills）保留；`ob`/`lib/`/`tools/` 代码层 0 命中。
- **术语层**：CONTEXT.md 新增 `know-how` 与 `harness skill` 两条，显式区分二者，终结 "skill" 词义不稳定。
- **副带修复**：`axioms/t09` 一条指向 `workflow_knowledge_flywheel.md` 的断链（该文件从未存在）顺手删除。
- 可逆性：改名是 working-tree 文档编辑，可回滚；但未来读者会奇怪为何不叫 "skill"，故落 ADR。
