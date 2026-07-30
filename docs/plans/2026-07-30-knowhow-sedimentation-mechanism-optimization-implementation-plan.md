# know-how 沉淀机制优化实施计划

> **修订记录**：v2（2026-07-30）吸收评审 F1–F8。F1：workflow_04 取消 ≤100 硬约束、明确无论行数都配 TL;DR、瘦身规格（唯一增量=第 0 步）。F2：Task 7 保留"70% 问题"段（bp_03/bp_08 依赖，不在 axioms），删除"改指向 axioms"错误指令。F3：Task 6 改前瞻性措辞（reflector 当前不碰 contexts/knowhow，显式声明防未来扩展）。F4：Task 4 加 check-ignore 配错提醒。F5：workflow_04 开头加唯一增量声明。F6：状态说明去掉易变 git 状态断言。F7：Task 8 标题改 [记录·已剥离]。F8：Task 5 确认 grep 模式覆盖三处不一致措辞。v3（二轮评审）：F9（Task 7 基线 165→164 实跑值）/F10（Task 7 补退役判定锚点，收窄开放三选）。**v4（执行期修订·用户反馈）**：U1（Task 7）— 执行后发现 F10「删重叠」过激：axioms（V01/T02/A03）不随每会话自动加载，bp_02 作为高可达 know-how 承载操作版有独立可达性价值，重叠非冗余；改 Task 7 为**完全回退（164 行全保留）+ TL;DR 重写**（单一问题放宽为「AI 编程的系统方法论」以涵盖全部段 + 显式标注「与 axioms 重叠有意」+ 指向 T02/V01），不再删任何段。U2（Task 4 增补）— user know-how 落 `contexts/knowhow/` 后无检索入口（违背落盘即收口）；新增 `contexts/knowhow/07_USER_KNOWHOW_INDEX.md`（结构同 product 05、gitignore 不回上游）+ `rules/03_WORKSPACE.md` 登记 + workflow_04 收口强制更新 + `rules/05_KNOWHOW_INDEX.md` 文末加 user 层注入触发段（加载 05 后检查 `contexts/knowhow/07_USER_KNOWHOW_INDEX.md`，存在则读全文、不存在则跳过，借 05 自动加载带 user 层可达性，与 product 对称）。Task 1/2/3/5/6/9 按计划执行无偏离；Task 8 按计划剥离。

## 计划状态说明（必读）

本计划源于一次 `/grill-with-docs` 会话达成的共识。**本计划的执行类改动曾在一个前序会话中被越权直接执行并落地，后经用户要求已全部回退（`git checkout` 恢复 tracked + `rm` 删除新建）。所有 task 回到 `[待执行]`**；经评审通过后于 2026-07-30 执行完毕（Task 1–7、9 落地，Task 8 按计划剥离；Task 4/7 有执行期修订，见修订记录 v4 的 U1/U2，其余按计划执行）。本计划与评审说明文档本身随仓库管理（git 状态以实际为准，不作为 task 依赖）。

确认状态分两档：
- **用户明确指示**（Task 1 的清理 + /sediment 双版本）：上一会话用户直接给出执行细节。
- **grilling 共识待确认**（Task 2–8）：收敛总结后用户未逐一确认，评审 agent 可决定纳入或剥离。

## 目标

把 `/grill-with-docs` 确认的 know-how 沉淀机制优化落盘：引入 product/user 正交分发维度、补手动沉淀编排层（workflow_04 + /sediment）、清冗余、给自动化通道划边界、把决策冻结进 ADR 与 glossary。

## 架构快照

引入一个正交于"层级"（axioms/rules/knowhow/memory）的新维度——**所有权/分发范围**：

- **product**（随上游 git 分发，`rules/`）：know-how / axioms / 核心 rules。ai-heartbeat 的 reflector 可自动晋升到此。
- **user**（本地，不回上游，`contexts/knowhow/`）：用户定制经验。只走手动通道；reflector 不 GC、不晋升——否则击穿 git 边界。

由此推出**自动化两层天花板**：内容天花板 = product/user 边界（自动化只产 product）；环节天花板 = 沉淀四环节中只有"触发 + 机械收口"可自动化，"判所有权 + 写作"永远 manual-in-the-loop。

手动沉淀编排层 = `workflow_04`（判所有权→判层→写→收口），`/sediment` slash command 是其显式触发入口（Claude Code + Copilot 双版本，合同指向 workflow_04）。

## 全局约束

- know-how 写作遵循 `rules/knowhow/bestpractice_01-knowhow_writing.md`（结果确定性、enabling 非 SOP）；行数 > 100 必须有 `## TL;DR`（ADR-0015 生产者硬义务）。
- 改 `rules/knowhow/` 后必须跑 `tools/ob_check.sh`（AGENTS.md 要求；含 know-how TL;DR hard gate）。
- ADR 格式参考 `docs/adr/0015-*.md`（标题→叙事→`Status: accepted`→Context→Considered Options→Consequences）。
- CONTEXT.md 术语格式：`**term**:` + 定义段 + `_Avoid_:` 同义词，扁平挂于 `## Language` 下。
- 所有改动在 working tree，可回滚；门禁/边界一旦生效成为持续义务，故核心决策落 ADR-0017。
- 命令环境：Linux bash（当前平台）；验证命令均为仓库根目录下的 git/grep/wc/ob_check。

## 输入工件

- `/grill-with-docs` 会话共识（本计划即其冻结载体，无独立 design doc）。
- 冗余排查报告（sub-agent 产出 + 主会话逐篇验证 + 评审 agent 复核）：bp_02 高重叠、wf_03 跨界、08/09/10 健康三角。
- 现状核查：`rules/` 全 tracked（65 文件）、`.gitignore` 零 user 排除、axioms 44 条零内部信息、ai-heartbeat observer/reflector 运行态正常但 reminder 偏 Windows。

## 文件结构与职责

**Create:**
- `rules/knowhow/workflow_04-manual_sedimentation.md` —— 手动沉淀编排层（product/user 所有权判定 + 引用 bestpractice_01/12 + 落盘即收口）。`[待执行]`
- `.claude/commands/sediment.md` —— /sediment Claude Code 入口（薄壳，合同指向 workflow_04）。`[待执行]`
- `.github/prompts/sediment.prompt.md` —— /sediment Copilot 入口（带 frontmatter，合同同上）。`[待执行]`
- `docs/adr/0017-knowhow-distribution-boundary.md` —— product/user 分发边界 + 自动化两层天花板的冻结载体（Task 2 产出，被 Task 3/4/5/6 引用）。`[待执行]`
- `contexts/knowhow/.gitkeep` —— user 层载体目录骨架。`[待执行]`

**Modify:**
- `rules/knowhow/workflow_03-knowledge_flywheel.md` —— 删除（跨界，思想已被 t09/bp_08/ai-heartbeat 吸收）。`[待执行·删除]`
- `rules/axioms/t09_data_strategy_mdp.md` —— 移除"参见 wf_03"单向引用。`[待执行]`
- `rules/05_KNOWHOW_INDEX.md` —— wf_03 入口替换为 workflow_04 入口。`[待执行]`
- `rules/knowhow/bestpractice_02-ai_programming_mindset.md` —— 拆解瘦身。`[待执行]`
- `CONTEXT.md` —— 加 product/user know-how 等术语。`[待执行]`
- `.gitignore` —— 加 `contexts/knowhow/` 排除规则。`[待执行]`
- `rules/06_AXIOMS_INDEX.md`、`rules/01_SOUL.md`、`AGENTS.md` —— axioms 措辞去个人化。`[待执行]`
- `periodic_jobs/ai_heartbeat/docs/KNOWLEDGE_BASE.md` —— reflector/observer 边界显式化（§4.2/§2.2）。`[待执行]`

**接口契约（跨任务依赖）:**
- `/sediment`（两个入口）→ `workflow_04`（执行合同，路径 `rules/knowhow/workflow_04-manual_sedimentation.md`）。
- `workflow_04` → `bestpractice_01` + `bestpractice_12`（已存在，引用不重复）。
- **Task 2 产出 ADR-0017**，被 Task 3（CONTEXT 术语）、Task 4（user 载体）、Task 5（axioms 措辞）、Task 6（KNOWLEDGE_BASE 边界）引用为政策依据。
- Task 4 产出 `contexts/knowhow/` 载体 ← Task 6 KNOWLEDGE_BASE reflector 边界显式声明保护它不被未来扩展误伤。
- Task 7（bp_02 拆解）独立，不依赖 ADR。

---

## 任务清单

### Task 1: 冗余清理 + workflow_04 + /sediment 双版本（用户明确指示） `[待执行]`

- 目标：删 wf_03 + 清 t09 单向引用 + INDEX 替换入口；建 workflow_04（/sediment 执行合同）+ /sediment Claude Code/Copilot 双版本。
- 涉及文件：删 `rules/knowhow/workflow_03-knowledge_flywheel.md`；改 `rules/axioms/t09_data_strategy_mdp.md`、`rules/05_KNOWHOW_INDEX.md`；建 `rules/knowhow/workflow_04-manual_sedimentation.md`、`.claude/commands/sediment.md`、`.github/prompts/sediment.prompt.md`。
- 接口契约：
  - Consumes: `bestpractice_01` + `bestpractice_12`（workflow_04 引用，已存在）。
  - Produces: `workflow_04`（被两个 /sediment 入口引用为执行合同）。
- 验证范围：wf_03 零残留；workflow_04 有 TL;DR（无论行数）；INDEX 有 workflow_04 入口；/sediment 双版本存在。
- Step 1: 改动前检查（确认回退后现状）
  - Run: `ls rules/knowhow/workflow_03-knowledge_flywheel.md && grep -n "参见.*workflow_03" rules/axioms/t09_data_strategy_mdp.md && grep -n "workflow_03" rules/05_KNOWHOW_INDEX.md`
  - Expected: wf_03 存在；t09 命中参见行；INDEX 命中 wf_03 入口（确认回退到位、待清理对象存在）
- Step 2: 执行清理
  - Change:
    - `rm rules/knowhow/workflow_03-knowledge_flywheel.md`
    - `rules/axioms/t09_data_strategy_mdp.md` 删除末尾 `**参见**: [知识飞轮设计模式](../knowhow/workflow_03-knowledge_flywheel.md) — 知识工程中的笨方法迭代` 行（连同前置空行），保留 M01 行
    - `rules/05_KNOWHOW_INDEX.md` 把 wf_03 入口行替换为：`- [手动经验沉淀（ob 沉淀四步）](knowhow/workflow_04-manual_sedimentation.md) — 踩坑/学到经验后，走"判所有权 → 判层 → 写 → 收口"四步，把它沉淀到正确的层（product/user）与子层，落盘即收口。`
- Step 3: 建 workflow_04（编排层，**薄**；唯一增量 = 第 0 步判所有权）
  - Change: 建 `rules/knowhow/workflow_04-manual_sedimentation.md`，内容规格：
    - **开头唯一增量声明**（F5）：「本文件相对 bestpractice_12 的唯一增量：在'判层'之前插入'判所有权(product/user)'这一步；其余三步（判层/写/收口）引用 bestpractice_12 + bestpractice_01，不重复。」
    - `## TL;DR`：踩坑后四步（判所有权→判层→写→收口）+ 三条要点（①先判 product/user，判错污染上游或烂本地；②本文件唯一增量是第 0 步，其余引用 bp_12/bp_01 不重复；③自动化天花板在"判所有权 + 写"，只触发/收口可自动化）
    - 元数据：类型 Workflow / 适用场景（踩坑后沉淀）/ 创建日期 / 触发器（agent 自主走 或 /sediment）
    - 目标与边界：沉淀到正确所有权层+子层，落盘即收口；编排层不重复 bp_01/12；不替代 ai-heartbeat 自动化通道
    - 四步路径（**第 0 步详写为篇幅主体，第 1-3 步一句话引用**）：
      - 第 0 步 判所有权（product/user）：表格（product→`rules/`，user→`contexts/knowhow/`）+ 判错代价（user 塞 rules 污染上游 / product 塞 contexts 下个用户照踩）+ 自动化天花板必须人
      - 第 1 步 判层：一句话"走 `bestpractice_12` 三问路由判子层"+ 链接（不重复其内容）
      - 第 2 步 写：一句话"按 `bestpractice_01` 四件套写"+ 链接
      - 第 3 步 收口：一句话"覆盖检查→写入→更新入口→terminal 核实（bestpractice_12 收口三件套）"
    - 验收标准（精简：判过所有权/走过三问/读过 bp_01/覆盖检查/更新入口+核实/无层错配）
    - 已知陷阱（跳过第 0 步 / user 塞 rules / 期望自动化越界 / 把编排层当 SOP）
    - 与现有体系关系（bp_12/bp_01/ai-heartbeat）
    - **TL;DR 义务**（F1）：无论多少行都配 TL;DR（ADR-0015）；编排层目标尽量薄（第 0 步为主），**不卡 100**——超 100 行则 TL;DR 为硬义务（已配），`ob_check` gate 自然通过。
- Step 4: 建 /sediment 双版本（参考 ai-heartbeat 模式：薄壳 + 引用执行合同）
  - Change:
    - `.claude/commands/sediment.md`（无 frontmatter）：`# Sediment (Claude Code Entry)` + 一句"本文件只负责引用执行合同" + `## 执行合同` 段：读取 `rules/knowhow/workflow_04-manual_sedimentation.md` 按四步执行 + 两条要点（先判 product/user；判/写必须人，本命令只提供路径编排）+ 不跳过收口
    - `.github/prompts/sediment.prompt.md`（带 `--- agent: agent / description: 手动经验沉淀入口 ---` frontmatter）：标题 `# Sediment (Copilot Entry)` + 正文同 Claude Code 版
- Step 5: 改动后验证（F1：不卡 100，只验 TL;DR 存在性）
  - Run: `grep -rn "workflow_03\|knowledge_flywheel\|知识飞轮" --include="*.md" --exclude-dir=workspace --exclude-dir=docs rules/ AGENTS.md CONTEXT.md .claude/ .github/`
  - Expected: 无输出
  - Run: `grep -c "^## TL;DR" rules/knowhow/workflow_04-manual_sedimentation.md && wc -l rules/knowhow/workflow_04-manual_sedimentation.md`
  - Expected: TL;DR 计数 = 1；行数报告值（记录，**不卡 100**——编排层尽量薄但不以此阻塞）
  - Run: `grep -n "workflow_04" rules/05_KNOWHOW_INDEX.md && ls .claude/commands/sediment.md .github/prompts/sediment.prompt.md`
  - Expected: INDEX 命中 workflow_04 入口；两命令文件存在

### Task 2: ADR-0017 know-how 分发边界（grilling 共识待确认） `[待执行]`

- 目标：最先冻结 product/user 分发边界 + 自动化两层天花板，作为 Task 3–6 的政策依据。
- 涉及文件：`docs/adr/0017-knowhow-distribution-boundary.md`（新建）。
- 接口契约：
  - Consumes: `docs/adr/0015-*.md`（格式）；grilling 决策清单。
  - Produces: `docs/adr/0017-knowhow-distribution-boundary.md`，被 Task 3/4/5/6 引用。
- 验证范围：ADR 存在、`Status: accepted`、覆盖 5 个决策点（D1–D5）。
- Step 1: 改动前检查
  - Run: `ls docs/adr/0017-*.md 2>/dev/null; ls docs/adr/ | tail -3`
  - Expected: 无 0017；最新为 0016
- Step 2: 确认当前状态
  - Run: `ls docs/adr/ | wc -l`
  - Expected: 16（当前 ADR 数）
- Step 3: 写 ADR（格式参考 0015）
  - Change: 标题 + 叙事（产品定位从"home"演进为"可分发开源产品"，bestpractice_12 假设产品但无分发边界）+ `Status: accepted` + `## Context`（产品定位悬空、CONTEXT 零知识术语、rules 全 tracked、axioms 44 条零内部信息）+ `## Considered Options`：
    - D1 产品定位：团队 home / **可分发开源产品（接受）** / 完整 OEM 平台
    - D2 user 层 git 边界：独立目录+gitignore / **复用 contexts/（接受）** / 命名约定
    - D3 product 内部受众：**不拆靠元数据（接受）** / audience 标记 / 物理分层
    - D4 axioms 分发：**全分发+去个人化（接受）** / 不分发 / 筛选分发
    - D5 自动化天花板：**两层天花板（接受）**
    + `## Consequences`（`contexts/knowhow/` 载体、reflector 边界显式化、可逆性：working-tree 文档编辑可回滚，但分发边界一旦生效成为持续义务）
- Step 4: 改动后验证
  - Run: `grep -E "^Status: accepted|^## Context|^## Considered Options|^## Consequences" docs/adr/0017-knowhow-distribution-boundary.md`
  - Expected: 4 段齐全
  - Run: `grep -c "D[1-5]" docs/adr/0017-knowhow-distribution-boundary.md`
  - Expected: ≥5（5 个决策点）

### Task 3: CONTEXT.md 加分发维度术语（grilling 共识待确认） `[待执行]`

- 目标：把分发维度术语补进 glossary（当前 47 条全为 ob 代码层，零知识体系术语）。
- 涉及文件：`CONTEXT.md`（`## Language` 段末尾追加）。
- 接口契约：
  - Consumes: ADR-0017（Task 2 产出）的决策口径。
  - Produces: glossary 新增术语，供 workflow_04 / KNOWLEDGE_BASE 引用。
- 验证范围：新术语存在且 `_Avoid_` 标注术语冲突（OEM/dispatch）。
- Step 1: 改动前检查
  - Run: `grep -nE "product know-how|user know-how|ship with product|自动化天花板" CONTEXT.md`
  - Expected: 无输出（术语缺席）
- Step 2: 确认当前状态
  - Run: `grep -c "^\*\*" CONTEXT.md`
  - Expected: 当前 glossary 条目数（基线 ≈47）
- Step 3: 追加术语
  - Change: 在 `## Language` 段末尾追加（每条 `**term**:` + 定义 + `_Avoid_:`）：
    - **product know-how**: 随 ob-harness 上游 git 分发的 know-how，落在 `rules/knowhow/`（及 axioms/核心 rules），对所有使用者有效。reflector 可自动晋升到此。`_Avoid_`: 内置 know-how（含糊）
    - **user know-how**: 本地沉淀、不回上游的定制经验，落在 `contexts/knowhow/`（gitignore），仅本环境有效。只走手动通道。`_Avoid_`: OEM know-how（与 OpenBMC `meta-oem` layer 撞名）、custom know-how
    - **ship with product**: know-how 随产品上游分发的属性（product 所有权的动作面）。`_Avoid_`: 分发（与 command dispatch 撞名，如 `dev_dispatch_subcmd`）
    - **自动化天花板**: 经验沉淀中自动化不可越过的边界。两层：内容天花板 = product/user 边界（自动化只产 product）；环节天花板 = 沉淀四环节中仅"触发 + 机械收口"可自动化，"判所有权 + 写作"必须 manual-in-the-loop。
    - **contexts/knowhow（user 载体）**: user know-how 的物理落点，`contexts/` 下与 `memory/`（动态观测）平级，gitignore 不入上游。
- Step 4: 改动后验证
  - Run: `grep -nE "^\*\*product know-how\*\*|^\*\*user know-how\*\*|^\*\*ship with product\*\*|^\*\*自动化天花板\*\*" CONTEXT.md`
  - Expected: 4 条新术语各命中 1 次

### Task 4: user 层载体落地（grilling 共识待确认） `[已执行·v4 增补 user INDEX]`

- 目标：建立 `contexts/knowhow/` 作为 user know-how 物理载体，gitignore 隔离不上游。
- 涉及文件：`.gitignore`（改）、`contexts/knowhow/.gitkeep`（建）。
- 接口契约：
  - Consumes: ADR-0017 D2（Task 2 产出，复用 contexts/）。
  - Produces: `contexts/knowhow/` 目录，被 Task 6 reflector 边界显式声明保护。
- 验证范围：user 内容被 git 忽略、.gitkeep 不被忽略。
- Step 1: 改动前检查
  - Run: `ls contexts/knowhow/ 2>/dev/null; grep -n "contexts/knowhow" .gitignore`
  - Expected: 目录不存在；.gitignore 无相关规则
- Step 2: 确认当前状态
  - Run: `git ls-files contexts/ | head`
  - Expected: 仅 `contexts/memory/OBSERVATIONS.md`（当前唯一 tracked）
- Step 3: 建载体 + 加排除
  - Change: 建 `contexts/knowhow/.gitkeep`；`.gitignore` 追加：
    ```
    # user know-how：本地定制经验，不回上游（ADR-0017）
    contexts/knowhow/*
    !contexts/knowhow/.gitkeep
    ```
- Step 4: 改动后验证（F4：加 check-ignore 配错提醒）
  - Run: `touch contexts/knowhow/_probe.md && git check-ignore contexts/knowhow/_probe.md && echo "probe-ignored-ok"; git check-ignore contexts/knowhow/.gitkeep || echo "gitkeep-not-ignored-ok"; rm contexts/knowhow/_probe.md`
  - Expected: 输出 `probe-ignored-ok`（_probe.md 被忽略）和 `gitkeep-not-ignored-ok`（.gitkeep 不被忽略）
  - **安全提醒（F4）**：若 `git check-ignore _probe.md` 无输出（退出码 1，说明规则配错、_probe.md 未被忽略），**先修 `.gitignore` 再 `rm`**，不要在规则配错时直接 `rm _probe.md`——否则一旦误 `git add`，_probe.md 会污染 user 载体。

### Task 5: axioms 措辞去个人化（grilling 共识待确认） `[待执行]`

- 目标：把 axioms 定位从"个人/团队经历提炼"改为"工程实践提炼"，使可分发不暴露个人化定位。
- 涉及文件：`rules/06_AXIOMS_INDEX.md`、`rules/01_SOUL.md`、`AGENTS.md`。
- 接口契约：
  - Consumes: ADR-0017 D4（Task 2 产出，axioms 全分发+去个人化）；冗余排查确认 44 条零内部信息。
  - Produces: 无（措辞调整）。
- 验证范围：旧措辞消失、新措辞一致。
- Step 1: 改动前检查（F8：三处措辞现状不一致，grep 模式需覆盖"个人经历"与"团队经历"）
  - Run: `grep -rn "个人经历\|团队经历\|从个人" rules/06_AXIOMS_INDEX.md rules/01_SOUL.md AGENTS.md`
  - Expected: 命中 3 处——`AGENTS.md:31` 与 `06_AXIOMS_INDEX.md:3` 是"从个人经历"，`01_SOUL.md:23` 是"从用户团队经历"（三处措辞本不一致，统一替换）
- Step 3: 改措辞
  - Change: 三处"从个人/团队经历中提炼"→"提炼自工程实践的决策原则"；`06_AXIOMS_INDEX.md` 顶部补一句定位为"参考认知视角库"（非外部用户必须遵守的产品约束）。
- Step 4: 改动后验证
  - Run: `grep -rn "个人经历\|团队经历" rules/06_AXIOMS_INDEX.md rules/01_SOUL.md AGENTS.md`
  - Expected: 无输出
  - Run: `grep -rn "工程实践" rules/06_AXIOMS_INDEX.md rules/01_SOUL.md AGENTS.md`
  - Expected: 命中新措辞（≥3 处）

### Task 6: ai-heartbeat KNOWLEDGE_BASE 边界显式化（grilling 共识待确认） `[待执行]`

- 目标：把"自动化天花板"在 ai-heartbeat 执行合同里**显式化**——声明 reflector 不碰 user 层、observer 扫 user 层只提示不晋升。
- 涉及文件：`periodic_jobs/ai_heartbeat/docs/KNOWLEDGE_BASE.md`（§2.2 扫描路径表、§4.2 反思与晋升）。
- 接口契约：
  - Consumes: ADR-0017 D5（Task 2 产出，两层天花板）；Task 4 `contexts/knowhow/` 载体。
  - Produces: reflector/observer 边界明文，防止未来 reflector 扩展扫描范围时越界。
- 验证范围：§4.2 含"user 层保护声明"、§2.2 含 user 扫描规则。
- Step 1: 改动前检查（F3：reflector 当前本就不碰 contexts/knowhow，本 task 是前瞻性显式化）
  - Run: `grep -nE "contexts/knowhow|user know-how|user 层|不晋升" periodic_jobs/ai_heartbeat/docs/KNOWLEDGE_BASE.md`
  - Expected: 无输出（边界未显式声明）
  - 现状确认：§4.2 reflector GC 目标只针对 `OBSERVATIONS.md`、晋升目标只动 `rules/`；§2.2 扫描路径表无 `contexts/`。**即 reflector 当前实现本就不会碰到 `contexts/knowhow/`**——本 task 是**前瞻性显式化**（防未来扩展扫描范围越界），非修当前 bug。
- Step 3: 写边界（F3：前瞻性措辞）
  - Change: §4.2「反思与晋升」补一句显式声明：reflector 的 GC/晋升目标**只限 `rules/`（product）与 `OBSERVATIONS.md`**，**显式禁止未来扩展到 `contexts/knowhow/`（user）**——否则 user 内容被自动推到上游，击穿 git 边界（ADR-0017）。§2.2「扫描路径表」加一行 `contexts/knowhow/`：observer 可扫描其变更以提示用户手动沉淀，但**不作为 reflector 的 GC/晋升输入**。
- Step 4: 改动后验证
  - Run: `grep -nE "contexts/knowhow|不晋升|不作为.*GC|击穿" periodic_jobs/ai_heartbeat/docs/KNOWLEDGE_BASE.md`
  - Expected: 命中新边界表述

### Task 7: bp_02 拆解瘦身（grilling 共识待确认，独立） `[已执行·v4 完全回退]`

- 目标：消除 bp_02 对 axioms 的大段重复与"无单一问题定义"（违反 bestpractice_01），保留未被下游覆盖的独特内容。
- 涉及文件：`rules/knowhow/bestpractice_02-ai_programming_mindset.md`。
- 接口契约：
  - Consumes: 冗余排查报告段级定位（已验证）：重叠段 line 17-23"基础公理"（声明不重复却重复）、line 138 逐字"结果确定性 vs 过程确定性"= T02、line 67-84"认知外包"= A03/A04/V01、line 120-153"AI 落地5决策"= T02/A01。**保留段**：line 24-44"70% 问题"诊断（bp_03/bp_08 依赖，**不在任何 axiom**）、line 47-64 Reasoning vs Agentic、line 86-95 直觉拐点。不依赖 ADR。
  - Produces: 瘦身后的 bp_02。
- 验证范围：bp_02 不再逐字重复 axioms；行数显著下降；bp_03/bp_08 对 bp_02 的引用不悬空。
- Step 1: 改动前检查（确认重叠段 + 外部引用内容）
  - Run: `grep -nE "基础公理|结果确定性 vs 过程确定性|认知外包|AI 落地核心决策" rules/knowhow/bestpractice_02-ai_programming_mindset.md`
  - Expected: 命中重叠段
  - Run: `grep -rn "bestpractice_02\|ai_programming_mindset" --include="*.md" rules/ | grep -v "bestpractice_02-ai_programming_mindset.md"`
  - Expected: 命中 `bestpractice_03:119`（引用"70% 问题"诊断）、`bestpractice_08:79`（引用"70% 问题/成功标准"落地形态）——**两处引用的都是"70% 问题"段，该段计划保留，故引用无需改动**
- Step 2: 确认当前状态
  - Run: `wc -l rules/knowhow/bestpractice_02-ai_programming_mindset.md`
  - Expected: 当前 164 行（拆解前基线；实跑 `wc -l` = 164）
- Step 3: 拆解改动 **[v4 执行期修订·U1：完全回退，取代下方 v3 删段指令]**
  - **v4 实际执行（以此为准）**：用户反馈 axioms（V01/T02/A03）不随每会话自动加载，bp_02 作为高可达 know-how 承载操作版有独立可达性价值——「跨层重叠≠冗余」。故 **bp_02 完全回退到 164 行原全部内容**（基础公理 / 认知外包 / 文件系统状态机 / 三大原型 / AI 落地5决策 5 段全保留），**仅重写 TL;DR**（单一问题放宽为「AI 编程的系统方法论」以涵盖全部段 + 显式声明「与 axioms 重叠有意」+ 指向 T02/V01）。不删任何段、不改外部引用（bp_03:119 / bp_08:79 仍指向 bp_02「70% 问题」段，不悬空）。
  - ~~Change（v3 旧指令，已废弃）~~：原「删除重叠段 / 保留段 / 退役判定 F10」**被 v4 U1 取代，勿按此重跑**——否则重蹈「误删可达性内容」覆辙（评审 M1）。
- Step 4: 改动后验证
  - Run: `grep -nE "结果确定性 vs 过程确定性" rules/knowhow/bestpractice_02-ai_programming_mindset.md`
  - Expected: **有输出**（v4 完全回退，line 138 逐字保留 T02 相关表述以保可达性，见 Step 3 v4 说明；v3 旧预期「无输出」已废弃）
  - Run: `wc -l rules/knowhow/bestpractice_02-ai_programming_mindset.md`
  - Expected: **=164**（v4 完全回退，5 段全保留，不显著低于 165；v3 旧预期「显著低于 165」已废弃）
  - Run: `grep -n "70%" rules/knowhow/bestpractice_02-ai_programming_mindset.md && grep -rn "bestpractice_02" rules/knowhow/bestpractice_03-ai_debugging_diagnosis.md rules/knowhow/bestpractice_08-eval_gate_patterns.md`
  - Expected: bp_02 仍含"70%"段；bp_03:119/bp_08:79 引用仍指向 bp_02（不悬空）

### Task 8: ai-heartbeat Linux reminder surface（grilling 共识，已剥离） `[记录·已剥离]`

- 目标：修复 Linux 下 reminder surface 失效（当前 reminder 为 Windows modal + `pre-session.ps1`，observer 已 7 天、reflector 9 天未跑）。
- 范围声明：**本项是跨平台 hook feature，超出 know-how 沉淀机制优化核心，已剥离为独立计划。** 此处仅记录问题与方向，**不在本计划执行**。
- 现状证据：`periodic_jobs/ai_heartbeat/state/heartbeat_status.json` observer last success 2026-07-23、reflector 2026-07-21；PRD/SOP reminder 偏 Windows。
- 建议方向（独立计划展开）：补 Linux SessionStart hook surface（tmux/terminal notification），或至少让现有 hook 在 Linux 输出文本提示。

### Task 9: ob_check.sh 配套自检 `[待执行]`

- 目标：按 AGENTS.md 要求，改 know-how 后跑一站式自检。
- 涉及文件：无（只读验证）。
- 验证范围：ob_check 全绿（含 know-how TL;DR hard gate）。
- Step 1: 运行自检
  - Run: `tools/ob_check.sh`
  - Expected: 全绿（workflow_04 配了 TL;DR、bp_02 拆解后行数下降，know-how TL;DR gate 自然通过）

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改变目标。
- 每完成一个任务，运行该任务定义的验证。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 当前在 `main` 分支；开始执行前先与用户确认分支策略（建议切 feature 分支）。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh`
  - Expected: 全绿（extract_funcs / surface gates / know-how TL;DR gate / shellcheck baseline / exit-contract / run_all / drift advisory 全过）
- Run: `grep -rn "workflow_03\|knowledge_flywheel\|知识飞轮" --include="*.md" --exclude-dir=workspace --exclude-dir=docs rules/ AGENTS.md CONTEXT.md .claude/ .github/ periodic_jobs/`
  - Expected: 无输出（wf_03 彻底清除，含 ai-heartbeat 文档）
- Run: `git check-ignore contexts/knowhow/_probe.md 2>/dev/null && echo "user-layer-isolated-ok"; git status --short`
  - Expected: 输出 `user-layer-isolated-ok`；working tree 改动清单符合预期

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-30-knowhow-sedimentation-mechanism-optimization-implementation-plan.md`（v2，已吸收评审 F1–F8）。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。Task 2–8 属 grilling 共识但用户尚未逐一确认，评审 agent 可决定哪些纳入、哪些剥离。
