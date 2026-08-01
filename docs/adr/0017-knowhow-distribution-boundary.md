# know-how 分发边界：product/user 正交分发维度 + 自动化两层天花板

`/grill-with-docs` 把一个长期悬空的问题显式化：`bestpractice_12` 通篇假设 ob-harness 是"产品"（反复出现"使用 ob-harness 产品的所有 agent"），但从未定义"产品"的分发边界——什么随上游 git 分发、什么只留本地。AGENTS.md 自称"home"，与 rules 全 tracked、随上游分发的实际行为矛盾。本 ADR 引入一个正交于"层级"（axioms/rules/knowhow/memory）的新维度——**所有权 / 分发范围**（product / user），并据此给自动化通道（ai-heartbeat）划两层天花板。5 个决策点经 grilling 锁定，本 ADR 是其唯一冻结载体；Task 3（术语）/ 4（user 载体）/ 5（axioms 措辞）/ 6（reflector 边界）/ Task 1（workflow_04 手动编排）均以本 ADR 为政策依据。

Status: accepted

## Context

四条根因驱动这次决策：

1. **产品定位悬空。** AGENTS.md 把 ob-harness 定位为"home"（"把它当作 home"），而 `bestpractice_12` 假设它是"产品"。两者都没回答"产品分发给谁、分发什么"——这导致一条经验该不该随上游，长期靠直觉而非规则判定。

2. **CONTEXT 零知识体系术语。** CONTEXT.md glossary 当前 47 条术语全为 ob 代码层（命令、子命令、退出码契约），没有任何描述"知识体系分发"的术语。product/user know-how、分发属性等概念在 glossary 里缺席，无法被一致引用。

3. **rules 全 tracked、零 user 排除。** 现状 `rules/` 65 文件全 tracked（随上游分发），`.gitignore` 对 user 内容零排除——即当前机制下没有"user 只留本地"的通道，任何写入 rules 的内容都会被推上游。

4. **axioms 具备全分发前提。** 冗余排查逐条核查 44 条 axioms，确认零内部信息（无机器名 / 人名 / 内部 URL），具备随上游全分发的前提；仅措辞偏个人化（"个人经历提炼"）需去个人化。

## Considered Options

**D1 —— ob-harness 的产品定位是什么？**

1. **团队 home（AGENTS.md 现状）** —— 拒绝。它把 ob-harness 定位为"我们自己人的工作区"，但 rules 全 tracked + 随上游分发的实际行为已经超出"home"语义；"home"无法支撑"哪些内容随分发"的判定。
2. **可分发开源产品（接受）** —— ob-harness 是随上游 git 分发、面向多用户 / 多环境的产品。`rules/`（axioms / 核心 rules / knowhow）是产品内容，随上游分发；`contexts/` 是本地内容，不回上游。
3. **完整 OEM 平台** —— 拒绝。ob-harness 是 OpenBMC 工作的 harness（规则 / know-how / 工具编排），不是 OEM 平台本身（OpenBMC `meta-oem` layer）。混淆两者是范围扩张。

**D2 —— user 层 know-how 如何不回上游？**

1. **独立顶层目录 + gitignore** —— 拒绝。多一棵顶层目录增加认知负担，且与现有 `contexts/` 语义重叠。
2. **复用 `contexts/`（接受）** —— 在 `contexts/` 下建 `knowhow/`，与 `contexts/memory/`（L1/L2 动态观测）平级；`.gitignore` 排除其内容、保留 `.gitkeep` 作骨架。
3. **命名约定（不 gitignore，靠文件名前缀区分）** —— 拒绝。命名约定无强制力，一次误 `git add` 即污染上游；只有 gitignore 是硬边界。

**D3 —— product 层（rules/）内部要不要按受众物理拆分？**

1. **不拆，靠 know-how 元数据自然区分（接受）** —— `rules/` 内不按"给谁看"物理分层，靠每条 know-how 的"适用场景"元数据自然路由。避免目录碎片化。
2. **audience 标记** —— 拒绝。给每条 know-how 额外标"受众"是维护负担，且 ob-harness 的 product 内容受众统一（所有使用者），无细分驱动。
3. **物理分层（rules/for-devs/、rules/for-ops/）** —— 拒绝。在无实际受众差异驱动前拆分是过早设计。

**D4 —— axioms 随上游分发到什么程度？**

1. **全分发 + 去个人化（接受）** —— 44 条已核查零内部信息，全随上游分发；措辞从"个人 / 团队经历提炼"统一改"工程实践提炼"，去掉个人化定位使其可分发，同时定位为"参考认知视角库"（非外部用户必须遵守的硬约束）。
2. **不分发（axioms 留本地）** —— 拒绝。axioms 是决策启发，是产品价值的一部分；不分发则新用户 / 新环境失去决策参考。
3. **筛选分发** —— 拒绝。44 条已零内部信息，无筛选必要；筛选引入"哪条该发"的持续判定负担。

**D5 —— 自动化通道（ai-heartbeat）的边界划在哪？**

1. **无边界（reflector 全自动判 product/user + 晋升 user 内容）** —— 拒绝。击穿 git 边界——user 内容会被自动推到上游。
2. **单层天花板（只限内容 或 只限环节）** —— 拒绝。只限内容不环节：仍可能自动"写"出错内容；只限环节不内容：reflector 仍可能碰 user 层。两层缺一不可。
3. **两层天花板（接受）** —— ① 内容天花板 = product/user 边界：自动化只产 product，**绝不**碰 `contexts/knowhow/`（user）；② 环节天花板 = 沉淀四环节中仅"触发 + 机械收口"可自动化，"判所有权 + 写作"永远 manual-in-the-loop。

## Consequences

- **user 载体落地（Task 4）**：`contexts/knowhow/` 建立，`.gitignore` 排除其内容、保留 `.gitkeep`。user know-how 有了不回上游的物理落点。
- **reflector 边界显式化（Task 6）**：`periodic_jobs/ai_heartbeat/docs/KNOWLEDGE_BASE.md` §4.2 显式声明 reflector 的 GC / 晋升目标只限 `rules/`（product）+ `OBSERVATIONS.md`，**显式禁止**未来扩展到 `contexts/knowhow/`（user）——防止 reflector 扫描范围扩展时越界、把 user 内容推上游。§2.2 扫描路径表加 `contexts/knowhow/`：observer 可扫描其变更提示用户手动沉淀，但不作为 reflector 的 GC / 晋升输入。
- **术语入 glossary（Task 3）**：CONTEXT.md 加 product know-how / user know-how / ship with product / 自动化天花板 / contexts/knowhow（user 载体）等术语，带 `_Avoid_` 标注术语冲突（user know-how 避开 `OEM`——仓库里 OEM = OpenBMC `meta-oem` layer；ship with product 避开"分发"——仓库里"分发" = command dispatch 如 `dev_dispatch_subcmd`）。
- **axioms 去个人化（Task 5）**：`06_AXIOMS_INDEX` / `01_SOUL` / `AGENTS.md` 三处"个人 / 团队经历"统一改"工程实践提炼"，配合 D4 全分发。
- **手动通道编排（Task 1）**：`workflow_04` 把 D5 两层天花板落地到手动沉淀流程（第 0 步判所有权必须人），`/sediment` 双版本是其显式触发入口。
- **可逆性**：本 ADR 触发的全是 working-tree 文档编辑，可回滚；但 product/user 分发边界一旦生效，"什么随上游、什么留本地"成为持续约束（gitignore 规则、reflector 边界声明都是持续义务），故落 ADR 冻结。
