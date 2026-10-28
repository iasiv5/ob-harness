# Sediment 知识 + 基建双轨沉淀改造实施计划

## 目标

把 `/sediment` 沉淀体系从"只沉淀知识"扩展为"知识 + 基建双轨沉淀，每次都同时判断"：合同层（`rules/knowhow/workflow_04-manual_sedimentation.md`）把"判层"扩为双轨判定，基建轨判定面对齐 `/retro` 七类全覆盖（以 ob-harness 原生落点改写）；三个 harness 入口（DSH / Claude Code / Copilot）与 `rules/05_KNOWHOW_INDEX.md` 条目同步；新术语收进 `GLOSSARY.md`。**不修改 `/retro` skill 任何内容。**

## 架构快照

- 三入口薄引用同一份执行合同——改合同一处，三入口同时生效。本次所有语义改动落在合同层，入口只同步描述与要点。
- 合同四步骨架保留：**判所有权 → 判轨道（知识 + 基建）→ 写 → 收口**。第 0 步判所有权不变（补一句基建产出默认 product 注记）；第 1 步"判层"扩为"判轨道"：知识轨沿用 bestpractice_12 三问路由（不重复），基建轨为本文件新增主体（七类判定面内联、语义自洽）。
- 基建轨与 `/retro` 的关系是"同源 + 内嵌"：`/sediment` 每次沉淀内嵌全量七类判定（等效跑一遍 retro 判定面），只读引用其文件作为细则参考，不依赖内文、不修改、不级联调用。
- 术语入库：知识轨 / 基建轨 / 双轨判定，追加到 `GLOSSARY.md` 尾部沉淀语义词条簇（`contexts/knowhow（user 载体）` 之后）。
- 纯文档编排改动，无代码、无测试框架；验证全部用 terminal 直读 + grep 断言。

## 全局约束（从 grill 共识逐字继承）

1. **硬约束**：不修改 `/retro` skill 任何内容。冻结面逐文件清点（共 3 个 git 条目）：`.claude/skills/retro/SKILL.md`、`.claude/skills/retro/agents/openai.yaml`（两个 100644 blob）+ `.dsh/skills/retro`（120000 符号链接 → `../../.claude/skills/retro`）；断言面 = `git ls-files -s`（3 行）与 `git status --porcelain`（0 行）前后对照（Task 5 Step 1/1b）。
2. **七类全覆盖**（Q1 修订版）：基建轨判定面 = retro 七类（导航 / 自动化检查 / 编码标准 / steering 瘦身 / no-op 指令 / 工具经济 / 信息可达），每类以 ob-harness 原生落点改写，不做类别合并删减。
3. **引用格式**（Q2）：仓库根相对路径 + "读取并遵循"句式——`读取并遵循 .claude/skills/retro/SKILL.md`（同 `.claude/commands/pick-one-arch-task.md` 引用 improve-codebase-architecture 的方式）。
4. **基建产出归属**（Q3）：默认 product（随上游分发）；特例——适合落盘为 harness skill 的内容，按 ob-harness 原生语义改以 know-how 落盘代替（归知识轨）。
5. **无级联提示**（Q4）：sediment 基建轨每次等效全量 retro 判定面，全文不出现"可选跑 /retro"类提示，不把 `/retro` 写进流程步骤。
6. **术语与步骤命名**：知识轨 / 基建轨 / 双轨判定；步骤名"判所有权 → 判轨道 → 写 → 收口"（仍是四步）。
7. **文案规则**：中文；沿用 workflow_04 既有行文风格（顶部 TL;DR（ADR-0015）、表格化判定清单、ADR/knowhow 相对链接）；入口文件保持"薄引用 + 编号要点"既有结构。

## 输入工件

- 设计来源：本会话 grill-with-docs 共识（Q1–Q4 结论，已获用户确认，无盘上设计文档）。
- 被改文件现状：`rules/knowhow/workflow_04-manual_sedimentation.md`（全文已读）、`.dsh/skills/sediment.md`、`.claude/commands/sediment.md`、`.github/prompts/sediment.prompt.md`（三入口全文已读）、`rules/05_KNOWHOW_INDEX.md` line 24（已读）、`rules/knowhow/bestpractice_16-multi_harness_skill_adaptation.md` line 68（已读，旧四步链在位）、`GLOSSARY.md`（尾部词条格式已读）。
- 参考件（只读）：`.claude/skills/retro/SKILL.md`（七类原文）、`.claude/commands/pick-one-arch-task.md`（引用句式范式）、`rules/knowhow/bestpractice_12-knowledge_layering.md`、`rules/knowhow/bestpractice_01-knowhow_writing.md`、`docs/adr/0017-knowhow-distribution-boundary.md`。

## 文件结构与职责

- Modify: `rules/knowhow/workflow_04-manual_sedimentation.md` — 合同主体，全文重写为双轨判定（唯一语义源）。
- Modify: `.dsh/skills/sediment.md` — DSH 入口，同步 description 与要点（与另两入口内容镜像）。
- Modify: `.claude/commands/sediment.md` — Claude Code 入口，同上。
- Modify: `.github/prompts/sediment.prompt.md` — Copilot 入口，同上。
- Modify: `rules/05_KNOWHOW_INDEX.md` — line 24 的 workflow_04 条目描述行。
- Modify: `rules/knowhow/bestpractice_16-multi_harness_skill_adaptation.md` — line 68 旧四步链引用同步（**基线扩展项**，F10，待用户 checkpoint 确认）。
- Modify: `GLOSSARY.md` — 尾部追加三个术语词条。
- **禁改**：`.claude/skills/retro/**`、`.dsh/skills/retro/**`。
- 一起变化的文件组：三个入口必须同一任务内同步（镜像一致性）；合同与 INDEX/GLOSSARY 可独立验证、独立拒收。

## 任务清单

### Task 1: 重写合同 workflow_04 为双轨判定

- 目标：合同从"只判知识层"扩为"判轨道（知识 + 基建双轨）"，基建轨七类判定面内联。
- 涉及文件：`rules/knowhow/workflow_04-manual_sedimentation.md`（全文重写）。
- 接口契约：
  - Consumes：bestpractice_12 三问路由、bestpractice_01 四件套、ADR-0017（引用，不改）。
  - Produces（后续任务逐字消费的规范用词）：`知识轨`、`基建轨`、`双轨判定`、`判所有权 → 判轨道 → 写 → 收口`、`七类判定面`、`读取并遵循 .claude/skills/retro/SKILL.md`。
- 验证范围：双轨硬规则、七类表、retro 引用句、无级联提示、TL;DR 存在。

- [ ] Step 1: 确认改动前缺失信号
- Run: `grep -c "基建轨" rules/knowhow/workflow_04-manual_sedimentation.md`
- Expected: 计数 `0`（术语尚未存在；以输出计数为准，退出码非零属预期——grep -c 计 0 时 rc=1）
- [ ] Step 2: 全文重写，新文档按以下章节骨架与逐字关键句落地
- Change:
  1. 标题：`# 手动经验沉淀：判所有权 → 判轨道（知识 + 基建）→ 写 → 收口`
  2. `## TL;DR · 30 秒决策`：引导句逐字替换（旧链清除，覆盖 L5"第 1 步判层"形态）：`踩坑/学到经验后，走四步把它沉淀到位：**第 0 步判所有权（product/user）→ 第 1 步判轨道（知识 + 基建，双轨并行判定）→ 第 2 步写 → 第 3 步收口**。四条先记住：`。四条要点——①先判 product/user 再谈落点（保留原文案）；②**双轨硬规则**（逐字）：`**每次必须双轨都判**。知识轨问"这条经验写到哪层"；基建轨按七类判定面问"哪些 agent 环境基建需要更新"。两轨独立出结论：仅知识 / 仅基建 / 双轨并行。跳过任一轨的判定即不合格。`；③本文件相对 bestpractice_12 的增量 = 第 0 步判所有权 + 第 1 步基建轨；④自动化天花板在"判所有权 + 写"（ADR-0017 D5）。
  3. `## 关于本文件（增量声明）`：增量两处——判所有权前置 + 判层扩为双轨（知识轨引用 bestpractice_12 不重复；基建轨为本文件新增主体）。
  4. `## 元数据`：类型 Workflow；创建日期 2026-07-30，追加"2026-10-28 扩为知识 + 基建双轨"；触发器保留原文。
  5. `## 目标与边界`：目标改为"一条收获，两条腿落地——知识经验沉淀到正确的所有权层 + 子层；暴露的 agent 环境基建缺口同步判定并修复。落盘即收口。"边界句中旧链"判所有权 → 判层 → 写 → 收口"改写为"判所有权 → 判轨道（知识 + 基建）→ 写 → 收口"，并补一句：不替代 ai-heartbeat 自动化通道，也不内嵌调用 `/retro`（关系见文末）。
  6. `### 第 0 步：判所有权（product / user）`：保留原文全部内容（表格、判错代价、判定要点、自动化天花板段），表格后追加一段（逐字）：`**基建产出同样过本步**：基建轨产出默认 **product**——随上游分发（AGENTS.md、rules/、三 harness 入口、仓库内 check/工具）；适合落盘为 harness skill 的内容，按 ob-harness 原生语义改以 know-how 落盘（转知识轨），基建轨不新建 skill。`
  7. `### 第 1 步：判轨道（知识 + 基建，双轨并行判定）——本文件新增主体`：
     - 开头放双轨硬规则句（同 TL;DR ②，逐字）。
     - **知识轨**段：保留原"三问路由"表述（bestpractice_12 链接、user 落 contexts/knowhow/、"不在此重复三问内容"）。
     - **基建轨**段：引导句 + 七类判定面表格（逐字）：

       | # | 类别（对齐 retro） | 判定问题 | ob-harness 原生产出 |
       |---|---|---|---|
       | 1 | 导航 | agent 找文件/信息耗时过长、反复问同一位置？ | 导航指针：AGENTS.md / rules/05_KNOWHOW_INDEX.md 等入口加一行 |
       | 2 | 自动化检查 | agent 犯的错可否被机械拦截？已有 check 未接线/静默失效？ | guardrail：tools/ob_check.sh 检查项 / shellcheck baseline / pre-commit / CI job |
       | 3 | 编码标准 | 机械违规（固定模式 / 禁用 API / 文件位置规则）？判断题规则？ | 机械违规 → 确定性检查（同 #2；建 check 优先于写规则）；判断题规则 → 知识轨 rules/ know-how 承接 |
       | 4 | steering 瘦身 | 每次加载的 steering 文件（AGENTS.md 等）过胖、该移位？ | 细则降级为按需文档指针，steering 只留导航指针 |
       | 5 | no-op 指令 | steering 里有从不改变行为的指令？ | 移除该指令 |
       | 6 | 工具经济 | 昂贵工具调用可否封装（高 token 操作反复出现）？ | ob 子命令 / 脚本封装 |
       | 7 | 信息可达 | 关键信息（日志 / 状态 / 报错原文）agent 拿不到、靠猜？ | 日志 tee / 只读通道 |

     - 表后优先级纪律句（逐字）：`优先级纪律：**能建 guardrail 的优先建 guardrail，而不是只写文字规则**——文档层没人保证每次被读，机械拦截天然生效。`
     - retro 引用句（逐字）：`七类判定面的原版细则可读取并遵循 .claude/skills/retro/SKILL.md（只读参考；本文件不修改、不依赖其内文，/retro 上游更新不影响本判定面）。`
     - `轨道结论`小节：三种——仅知识（产 know-how 文档）/ 仅基建（产基建变更）/ **双轨并行**（鼓励：既写 know-how 又修基建——文档帮人理解，基建帮 agent 不再踩）。
  8. `### 第 2 步：写（分轨）`：知识轨保留原文（bestpractice_01 四件套 + TL;DR/ADR-0015 句）；新增基建轨最小写作纪律——(1) 指针措辞前置触发词、每分支一个触发条件，steering 文件只放导航指针；(2) guardrail 优先于文字规则；(3) 细则落按需文档、指针指过去。
  9. `### 第 3 步：收口（分轨）`：知识轨保留原文三件套与 user INDEX 最小骨架代码块（逐字不动）；新增基建轨收口（逐字）：`**基建轨**：改动落盘 → terminal 直读核实生效（指针可达目标文件 / check 能跑出结果 / steering 文件核实变薄）→ **联动清理**：基建变更若使某条旧 know-how 过时，顺手更新或删除之（基建与文档不同步是新的坑源）。`
  10. `## 验收标准`：7 条——原 6 条保留，第 2 条后插入新条：`**两条轨是否都判定过**（哪怕结论是"无需基建变更"），而非只判知识轨？`（后续条目顺延编号）。
  11. `## 已知陷阱`：原 4 行保留，插入 2 行——`| 只沉知识、不判基建 | know-how 写了，但下个 agent 没读到，错误照样复发 | 第 1 步双轨硬规则：基建轨七类每次必过；能建 guardrail 就别只写文档 |` 和 `| 把双轨当二选一分流 | 判定"这是知识经验"后就跳过基建轨（或反之） | 两轨独立判定、可同时命中；"无需变更"是结论，跳过不是 |`。
  12. `## 与现有体系的关系`：bestpractice_12 / bestpractice_01 / ai-heartbeat 三条保留（微调措辞标注"知识轨"归属）；新增第 4 条（逐字）：`**/retro（会话级基建复盘）**：基建轨七类判定面与 /retro 同源；/sediment 每次沉淀内嵌全量判定（等效跑一遍 retro 判定面），不依赖、不修改、不级联调用 /retro。`
  13. 全文不出现"可选跑 /retro"、"级联"提示类表述；否定式声明（如关系段的"不级联调用 /retro"）除外——它是对级联提示的禁止声明，不是提示本身。
- [ ] Step 3: 确认通过信号（两条独立命令，勿用 && 连接）
- Run: `grep -c "基建轨" rules/knowhow/workflow_04-manual_sedimentation.md && grep -Fc '读取并遵循 .claude/skills/retro/SKILL.md' rules/knowhow/workflow_04-manual_sedimentation.md && ! grep -q "可选跑" rules/knowhow/workflow_04-manual_sedimentation.md && echo OK && grep -Fc '不级联调用 /retro' rules/knowhow/workflow_04-manual_sedimentation.md && grep -c "TL;DR" rules/knowhow/workflow_04-manual_sedimentation.md`
- Expected: 计数一 ≥5；计数二 =1；打印 OK（"可选跑"不存在——取反断言未命中即通过、命中即断链，失败可传播）；计数四 =1（"不级联调用 /retro"为否定式声明，恰要求在位）；TL;DR 计数 ≥1
- Run（旧链双形态清除断言，独立执行）: `grep -c "判所有权 → 判层" rules/knowhow/workflow_04-manual_sedimentation.md; grep -c "第 1 步判层" rules/knowhow/workflow_04-manual_sedimentation.md`
- Expected: 两个计数均为 `0`（注意 grep -c 计 0 时 rc=1 属预期，看计数不看退出码；两种形态分别覆盖 L1/L27 式与 TL;DR 引导句"第 1 步判层"式）
- [ ] Step 4: 无独立 commit（七文件统一并入 Task 5 收口提交，保证最终 diff 总览完整）

### Task 2: 三入口同步（三文件镜像，同一任务）

- 目标：三个 harness 入口的 description 与要点从"四步判层"更新为"双轨沉淀"。
- 涉及文件：`.dsh/skills/sediment.md`、`.claude/commands/sediment.md`、`.github/prompts/sediment.prompt.md`（全文替换，逐字如下，仅标注差异）。
- 接口契约：
  - Consumes：Task 1 Produces 的规范用词（知识轨 / 基建轨 / 双轨 / 七类判定面 / 判轨道）。
  - Produces：无下游依赖。
- 验证范围：三文件 description 一致、"每次都判"要点存在、无旧四步表述残留。

- [ ] Step 1: 确认改动前缺失信号
- Run: `grep -l "判轨道" .dsh/skills/sediment.md .claude/commands/sediment.md .github/prompts/sediment.prompt.md | wc -l`
- Expected: `0`
- [ ] Step 2: 三文件写入共同正文
- Change（共同正文，差异见后）：

  ```markdown
  # Sediment (<HARNESS> Entry)

  这是 <HARNESS> 的 `/sediment` slash command 入口。本文件只负责引用执行合同。

  ## 执行合同

  读取 `rules/knowhow/workflow_04-manual_sedimentation.md`，按其中的四步（判所有权 → 判轨道 → 写 → 收口）执行知识 + 基建双轨沉淀。

  三条要点：
  1. **先判所有权（product/user）**——这条经验该进 `rules/`（随上游分发）还是 `contexts/knowhow/`（本地不回上游），判错会污染上游或让下个用户照踩。
  2. **知识 + 基建双轨并行判定，每次都判**——知识轨问"这条经验写到哪层"；基建轨按七类判定面问"哪些 agent 环境基建需要更新（导航 / 自动化检查 / 编码标准 / steering 瘦身 / no-op 指令 / 工具经济 / 信息可达）"。两轨独立出结论、可同时命中；跳过任一轨的判定即不合格。
  3. **判所有权和写作必须人**——本命令只提供路径编排，不做自动判定；自动化天花板在"判所有权 + 写"（ADR-0017）。

  不要跳过收口（覆盖检查 → 写入 → 更新入口 → 核实；基建轨另核实生效并联动清理过时 know-how）。
  ```

  差异：
  - `.dsh/skills/sediment.md`：保留 frontmatter，`description:` 改为 `手动经验沉淀入口：判所有权 → 判轨道（知识 + 基建双轨）→ 写 → 收口（执行合同见 rules/knowhow/workflow_04-manual_sedimentation.md）。`；`<HARNESS>` = `DeepSeek Harness`（两处）。
  - `.claude/commands/sediment.md`：无 frontmatter（维持现状）；`<HARNESS>` = `Claude Code`（两处）。
  - `.github/prompts/sediment.prompt.md`：保留 frontmatter 的 `agent: agent`，`description:` 改为与 .dsh 相同文案；`<HARNESS>` = `VS Code Copilot`（首处）/ `Copilot`（标题处，即 `# Sediment (Copilot Entry)`）。
- [ ] Step 3: 确认通过信号
- Run: `grep -c "知识 + 基建双轨并行判定，每次都判" .dsh/skills/sediment.md .claude/commands/sediment.md .github/prompts/sediment.prompt.md && ! grep -q "判所有权 → 判层 → 写 → 收口" .dsh/skills/sediment.md .claude/commands/sediment.md .github/prompts/sediment.prompt.md && echo OK`
- Expected: 三行计数各 =1；输出 OK
- [ ] Step 4: 无独立 commit（与 Task 3/4 合并在最终 checkpoint 提交）

### Task 3: 更新 KNOWHOW_INDEX 条目与 bestpractice_16 旧链同步

- 目标：workflow_04 索引行反映双轨语义；同步 bestpractice_16:68 的旧四步链引用（**基线扩展项**：F10 评审接受项，超出 B2 原枚举面，随本计划 checkpoint 一并请用户确认）。
- 涉及文件：`rules/05_KNOWHOW_INDEX.md`（line 24 单行替换）、`rules/knowhow/bestpractice_16-multi_harness_skill_adaptation.md`（line 68 单行替换）。
- 接口契约：
  - Consumes：Task 1 的规范用词与七类类别名。
  - Produces：无下游依赖。
- 验证范围：新条目行存在、旧表述清除（含旧链双形态）。
- 执行备注（不入提交与断言面）：`contexts/knowhow/07_USER_KNOWHOW_INDEX.md:8` 存在同链（user 本地件、不回上游）——执行时随手按同一措辞同步该行，保持本环境一致；不进 Task 5 收口提交与 diff 断言。

- [ ] Step 1: 确认改动前状态
- Run: `grep -c "判轨道（知识 + 基建双轨）" rules/05_KNOWHOW_INDEX.md; grep -cF "判所有权 → 判层" rules/knowhow/bestpractice_16-multi_harness_skill_adaptation.md`
- Expected: 前者计数 `0`（以输出计数为准，退出码非零属预期）；后者 `1`（bestpractice_16:68 旧链在位）
- [ ] Step 2: 替换 line 24 条目
- Change（逐字新行）：

  ```markdown
  - [手动经验沉淀（ob 沉淀四步）](knowhow/workflow_04-manual_sedimentation.md) — 踩坑/学到经验后，走"判所有权 → 判轨道（知识 + 基建双轨）→ 写 → 收口"：知识经验沉淀到正确的所有权层与子层；暴露的 agent 环境基建缺口按七类判定面（导航 / 自动化检查 / 编码标准 / steering 瘦身 / no-op 指令 / 工具经济 / 信息可达）同步判定修复，落盘即收口。
  ```

  （链接 label `手动经验沉淀（ob 沉淀四步）` 与目标路径不变——仍是四步。）
- [ ] Step 2b: 替换 bestpractice_16 line 68
- Change（逐字新行）：

  ```markdown
  - 沉淀流程本身走 `workflow_04`（判所有权 → 判轨道（知识 + 基建）→ 写 → 收口），本文件即其手动通道产物。
  ```

- [ ] Step 3: 确认通过信号
- Run: `grep -c "判轨道（知识 + 基建双轨）" rules/05_KNOWHOW_INDEX.md && grep -c "knowhow/workflow_04-manual_sedimentation.md" rules/05_KNOWHOW_INDEX.md; grep -cF "判所有权 → 判层" rules/knowhow/bestpractice_16-multi_harness_skill_adaptation.md; grep -c "判轨道" rules/knowhow/bestpractice_16-multi_harness_skill_adaptation.md`
- Expected: 前两条 = `1` 和 `2`（line 24 条目 + line 67 原有引用）；第三条 = `0`（旧链清除）；第四条 = `1`（新链在位）
- [ ] Step 4: 无独立 commit（并入最终提交）

### Task 4: GLOSSARY 收录三个术语

- 目标：新术语按既有词条格式（正文 + `_Avoid_` 行）入库，落在尾部沉淀语义词条簇之后。
- 涉及文件：`GLOSSARY.md`（文件尾部追加）。
- 接口契约：
  - Consumes：Task 1 的规范用词；GLOSSARY 既有词条 `know-how` / `harness skill` / `product know-how` / `user know-how` / `自动化天花板`（行文对齐，不改它们）。
  - Produces：无下游依赖。
- 验证范围：三词条存在、各带 `_Avoid_`、无与既有词条冲突的定义。

- [ ] Step 1: 确认改动前缺失信号 + 采集 `_Avoid_` 基线
- Run: `grep -c "^\*\*知识轨\|^\*\*基建轨\|^\*\*双轨判定" GLOSSARY.md; grep -c "_Avoid_" GLOSSARY.md`
- Expected: 前者计数 `0`（新术语尚未存在，退出码非零属预期）；后者即基线 N（评审实测 `60`，若实测非 60 以当时读数为准并记录）
- [ ] Step 2: 在 `**contexts/knowhow（user 载体）**` 词条之后（文件尾）追加三词条
- Change（逐字）：

  ```markdown
  **知识轨（knowledge track）**:
  双轨判定中处理知识经验的轨道：判定收获要不要写成文档、写到哪层（product 走 bestpractice_12 三问路由，user 落 `contexts/knowhow/`）。产出是 know-how 文档，agent **读**。与基建轨并行判定、互不替代。
  _Avoid_: 文档轨（非术语）, 把知识轨当默认轨（双轨判定要求两轨都过）

  **基建轨（infrastructure track）**:
  双轨判定中处理 agent 环境基建的轨道：按七类判定面（导航 / 自动化检查 / 编码标准 / steering 瘦身 / no-op 指令 / 工具经济 / 信息可达）判定收获暴露的基建缺口并直接修复。产出默认随上游分发（product）；产出是环境变更（指针 / guardrail / steering 瘦身 / 工具），agent **天然生效**、不依赖阅读。适合落盘为 harness skill 的内容按 ob-harness 原生语义以 know-how 代替（归知识轨）。
  _Avoid_: 环境轨（非术语）, 在基建轨里新建 harness skill（原生语义用 know-how 代替）

  **双轨判定（dual-track triage）**:
  `/sediment` 沉淀流程的判定结构：知识轨与基建轨**每次都必须各判一遍**，结论独立（仅知识 / 仅基建 / 双轨并行），跳过任一轨即不合格。基建轨七类判定面与 `/retro` 同源（全覆盖）；`/sediment` 单条沉淀内嵌全量判定，不依赖、不修改 `/retro`。
  _Avoid_: 把双轨当二选一分流（判完知识就跳过基建）, 轨道分流（同前，是并行判定不是分流）
  ```

- [ ] Step 3: 确认通过信号
- Run: `B=$(grep -c "_Avoid_" GLOSSARY.md); grep -c "^\*\*知识轨\|^\*\*基建轨\|^\*\*双轨判定" GLOSSARY.md && echo "_Avoid_ total: $B"`
- Expected: 词条计数 = `3`；`_Avoid_` 总数 = 基线 N + 3（N 在 Step 1 实测，评审实测 60 → 改后 63；以 Step 1 读数为准）
- [ ] Step 4: 无独立 commit（并入最终提交）

### Task 5: 最终验证与收口提交

- 目标：跨文件一致性断言 + retro 未动断言 + 一次收口提交。
- 涉及文件：无新改动（只读验证 + git 提交 Task 2/3/4 的改动）。
- 接口契约：
  - Consumes：Task 1–4 全部完成。
  - Produces：收口提交。
- 验证范围：三入口与合同用词一致、GLOSSARY 与合同术语一致、retro 目录零改动、diff 总览符合文件清单。

- [ ] Step 1: retro 冻结面清点断言（逐文件清点：`.claude/skills/retro/` 恰 2 个文件 SKILL.md、agents/openai.yaml + `.dsh/skills/retro` 符号链接 mode 120000 → ../../.claude/skills/retro，共 3 个 git 条目）
- Run: `git ls-files -s .claude/skills/retro .dsh/skills/retro | tee /tmp/retro-freeze-before.txt && git status --porcelain .claude/skills/retro .dsh/skills/retro | wc -l`
- Expected: `ls-files -s` 恰 3 行（两个 100644 blob + 一个 120000 符号链接）；porcelain 计数 = `0`
- [ ] Step 1b（收口提交后复跑）: 冻结面前后对照
- Run: `git ls-files -s .claude/skills/retro .dsh/skills/retro | tee /tmp/retro-freeze-after.txt && diff /tmp/retro-freeze-before.txt /tmp/retro-freeze-after.txt && git status --porcelain .claude/skills/retro .dsh/skills/retro | wc -l`
- Expected: `diff` 无输出（前后逐条目一致）；porcelain 计数 = `0`
- [ ] Step 2: 三入口与合同术语一致性
- Run: `grep -c "七类判定面" rules/knowhow/workflow_04-manual_sedimentation.md .dsh/skills/sediment.md .claude/commands/sediment.md .github/prompts/sediment.prompt.md rules/05_KNOWHOW_INDEX.md GLOSSARY.md | awk -F: '{s+=$2} END {print s}'`
- Expected: ≥ `9`，分解下限：合同 ≥3（TL;DR 双轨硬规则句 / retro 引用句 / 关系段）、三入口各 ≥1、INDEX ≥1、GLOSSARY ≥2（基建轨 + 双轨判定词条各含一次）
- [ ] Step 3: diff 总览核对
- Run: `git diff --stat`
- Expected: 恰好 7 个文件：workflow_04、三个入口、05_KNOWHOW_INDEX.md、bestpractice_16、GLOSSARY.md；无其他文件
- [ ] Step 4: 收口提交
- Run: `git add rules/knowhow/workflow_04-manual_sedimentation.md .dsh/skills/sediment.md .claude/commands/sediment.md .github/prompts/sediment.prompt.md rules/05_KNOWHOW_INDEX.md rules/knowhow/bestpractice_16-multi_harness_skill_adaptation.md GLOSSARY.md && git commit -m "docs(sediment): 沉淀扩为知识+基建双轨——合同/三入口/索引/bestpractice_16/术语表同步（基建轨七类判定面，同源 /retro 不修改）"`
- Expected: 提交成功；`git status --porcelain` 为空（前提：开工第 0 步已把计划文档单独入库，见执行纪律）

## 执行纪律

- 当前分支为 `main`；工作区唯一脏项是计划文档本身（untracked）。**开工第 0 步：先把计划文档单独提交入库**（`git add docs/plans/2026-10-28-sediment-dual-track-implementation-plan.md && git commit -m "docs(plans): sediment 双轨沉淀改造实施计划"`，符合 docs/plans/ 计划入库惯例），此后工作区干净，Task 5 的 porcelain 断言才可满足。**开始实现前需用户明确同意在 main 上直接提交**（否则先建分支）。
- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动手。
- 按任务顺序执行（Task 1 → 2 → 3 → 4 → 5），Task 2–4 依赖 Task 1 的规范用词，不得提前。
- 每完成一个任务，运行该任务定义的验证；验证不过不进下一任务。
- 遇到阻塞、重复失败或计划与仓库现实不符（如行号漂移、文件被并发修改），立即停下说明，不猜。
- **回退方案**：任一验证不过且需修计划时，收口提交前均可无损回退现场——`git restore rules/knowhow/workflow_04-manual_sedimentation.md .dsh/skills/sediment.md .claude/commands/sediment.md .github/prompts/sediment.prompt.md rules/05_KNOWHOW_INDEX.md rules/knowhow/bestpractice_16-multi_harness_skill_adaptation.md GLOSSARY.md`（计划文档本身已在开工第 0 步入库，同样可用 git restore 回退其工作区改动）；已提交场景用 `git revert`。修完计划后按任务顺序重来。
- 全部任务完成后运行 Task 5 全部验证并输出修改摘要。
- shell 环境：bash，仓库根 `/bmc/iasi/workspace/ob-harness-ast2700-a0`。

## 最终验证

- 在 Task 5 全部 Step（含收口提交）完成后运行。注意：Task 5 Step 3 的 `git diff --stat` 是**提交前门禁**；提交后的等价复验用 `git show --stat HEAD`。
- Run: `git status --porcelain .claude/skills/retro .dsh/skills/retro | wc -l && git show --stat HEAD && grep -c "双轨" rules/knowhow/workflow_04-manual_sedimentation.md && git status --porcelain | wc -l`
- Expected: retro 断言 `0`；`git show --stat HEAD` 恰 7 文件（收口提交的完整内容）；"双轨"计数 ≥5；porcelain 总行数 = `0`（计划文档已在开工第 0 步入库）。
- 附带人工核对：通读重写后的 workflow_04 一遍，确认 TL;DR、七类表、收口三件套、user INDEX 骨架代码块完整无缺（ADR-0015 生产者义务）。

## 审阅 Checkpoint

- 计划正文结束后请求用户审阅；审阅通过前不进入实现。
- 需用户确认事项：① 计划本身（含 Task 3 的 bestpractice_16 基线扩展项）；② 是否同意在 `main` 直接提交（commit 序列 = 开工第 0 步计划文档入库 + Task 5 Step 4 收口，共两次）。
