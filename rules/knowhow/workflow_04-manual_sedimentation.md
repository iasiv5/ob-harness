# 手动经验沉淀：判所有权 → 判轨道（知识 + 基建）→ 写 → 收口

## TL;DR · 30 秒决策

踩坑/学到经验后，走四步把它沉淀到位：**第 0 步判所有权（product/user）→ 第 1 步判轨道（知识 + 基建，双轨并行判定）→ 第 2 步写 → 第 3 步收口**。四条先记住：

1. **先判 product/user，再判子层**。判错代价大——把 user 经验塞进 `rules/` 会污染上游、推给所有用户；把 product 经验塞进 `contexts/knowhow/` 则下个用户照踩。
2. **每次必须双轨都判**。知识轨问"这条经验写到哪层"；基建轨按七类判定面问"哪些 agent 环境基建需要更新"。两轨独立出结论：仅知识 / 仅基建 / 双轨并行。跳过任一轨的判定即不合格。
3. **本文件的增量 = 第 0 步（判所有权）+ 第 1 步的基建轨**。知识轨三问引用 bestpractice_12，写作细则引用 bestpractice_01，不重复。
4. **自动化天花板在"判所有权 + 判轨道 + 写"**。沉淀四环节中只有"触发 + 机械收口"可自动化；判所有权、判轨道（双轨的轨道结论）和写作永远 manual-in-the-loop（ADR-0017 D5 枚举"判所有权 + 写"，判轨道为本文件扩轨新增的判定环节，ADR 修订时补枚举）。

---

## 关于本文件（增量声明 + TL;DR 声明）

本文件相对 [`bestpractice_12`](bestpractice_12-knowledge_layering.md) 的增量有两处：一是"判轨道"之前插入"判所有权（product/user）"；二是把传统"判层"扩为**双轨判定**——知识轨沿用 bestpractice_12 三问，基建轨为本文件新增主体。知识轨判层细则见 bestpractice_12、写作细则见 [`bestpractice_01`](bestpractice_01-knowhow_writing.md)，本文件不重复。作为编排层，本文件尽量薄；无论行数多少都配了顶部 TL;DR（ADR-0015 生产者义务），不卡 100 行。

## 元数据

- **类型**: Workflow
- **适用场景**: 踩坑/学到经验后，要把经验沉淀进 ob-harness（知识文档或环境基建）时
- **创建日期**: 2026-07-30（2026-10-28 扩为知识 + 基建双轨）
- **触发器**: agent 在会话中自主走，或经 `/sediment` slash command 显式触发

## 目标与边界

- **目标**：一条收获，两条腿落地——知识经验沉淀到正确的所有权层 + 子层；暴露的 agent 环境基建缺口同步判定并修复。落盘即收口。
- **边界**：本文件是**编排层**——只编排"判所有权 → 判轨道（知识 + 基建）→ 写 → 收口"的顺序与判定，知识轨判层细则在 bestpractice_12、写作细则在 bestpractice_01，本文件不重复。不替代 ai-heartbeat 自动化通道（其边界见 ADR-0017 两层天花板），也不内嵌调用 `/retro`（关系见文末）。

## 沉淀路径

### 第 0 步：判所有权（product / user）

先判定这条经验属于谁，再谈子层。正交于"层级"（axioms/rules/knowhow/memory）的是**所有权 / 分发范围**：

| 所有权 | 物理落点 | 回上游? | 谁受益 | 典型经验 |
|--------|----------|:-------:|--------|----------|
| **product**（随产品分发） | `rules/`（axioms / 核心 rules / knowhow） | ✅ | 所有使用 ob-harness 的用户 | 源于 ob-harness 自身、别的环境会同样复发 |
| **user**（本地） | `contexts/knowhow/`（gitignore，不回上游） | ❌ | 仅本环境 | 本机/本项目定制、与具体环境绑定的偏好 |

**基建产出同样过本步**：基建轨产出默认 **product**——随上游分发（AGENTS.md、rules/、三 harness 入口、仓库内 check/工具）；适合落盘为 harness skill 的内容，按 ob-harness 原生语义改以 know-how 落盘（转知识轨），基建轨不新建 skill。

**判错代价**（两个方向都会出错）：
- **把 user 经验塞进 `rules/`（product）**：污染上游，推给所有用户——别人拿到一条只对你有效的定制经验，信噪比下降；更糟的是它会被自动晋升/分发链路放大。
- **把 product 经验塞进 `contexts/knowhow/`（user）**：下个用户/新环境照踩——这条经验没随仓库分发，gitignore 把它挡在上游之外。

**判定要点**：问"换个环境、换个用户，这条经验还成立、还会被需要吗？"成立且需要 → product；否则 → user。

**自动化天花板（硬边界）**：判所有权**必须人**。自动化通道（ai-heartbeat reflector）只能产 product、只动 `rules/` + `OBSERVATIONS.md`，**绝不**碰 `contexts/knowhow/`（user）——否则 user 内容被自动推到上游，击穿 git 边界（ADR-0017 D5）。本步不可自动化、不可委托给 reflector。

### 第 1 步：判轨道（知识 + 基建，双轨并行判定）——本文件新增主体

**每次必须双轨都判**。知识轨问"这条经验写到哪层"；基建轨按七类判定面问"哪些 agent 环境基建需要更新"。两轨独立出结论：仅知识 / 仅基建 / 双轨并行。跳过任一轨的判定即不合格。

**知识轨**：这条收获要不要写成文档？写到哪层？走 [`bestpractice_12`](bestpractice_12-knowledge_layering.md) 的"三问路由"判 product 经验进哪个子层（axioms / knowhow / OBSERVATIONS）；user 经验进 `contexts/knowhow/` 按主题组织。**不在此重复三问内容。**

**基建轨**：这条收获暴露了 agent 环境基建的缺口吗？逐项过七类判定面，命中即产出基建变更：

| # | 类别（对齐 retro） | 判定问题 | ob-harness 原生产出 |
|---|---|---|---|
| 1 | 导航 | agent 找文件/信息耗时过长、反复问同一位置？ | 导航指针：AGENTS.md / rules/05_KNOWHOW_INDEX.md 等入口加一行 |
| 2 | 自动化检查 | agent 犯的错可否被机械拦截？已有 check 未接线/静默失效？ | guardrail：tools/ob_check.sh 检查项 / shellcheck baseline / pre-commit / CI job |
| 3 | 编码标准 | 机械违规（固定模式 / 禁用 API / 文件位置规则）？判断题规则？ | 机械违规 → 确定性检查（同 #2；建 check 优先于写规则）；判断题规则 → 知识轨 rules/ know-how 承接 |
| 4 | steering 瘦身 | 每次加载的 steering 文件（AGENTS.md 等）过胖、该移位？ | 细则降级为按需文档指针，steering 只留导航指针 |
| 5 | no-op 指令 | steering 里有从不改变行为的指令？ | 移除该指令 |
| 6 | 工具经济 | 昂贵工具调用可否封装（高 token 操作反复出现）？ | ob 子命令 / 脚本封装 |
| 7 | 信息可达 | 关键信息（日志 / 状态 / 报错原文）agent 拿不到、靠猜？ | 日志 tee / 只读通道 |

优先级纪律：**能建 guardrail 的优先建 guardrail，而不是只写文字规则**——文档层没人保证每次被读，机械拦截天然生效。

七类判定面的原版细则可读取并遵循 .claude/skills/retro/SKILL.md（只读参考；本文件不修改、不依赖其内文，/retro 上游更新不影响本判定面）。

**轨道结论**（三选一，可双选）：

- **仅知识**：产出 know-how 文档，走第 2/3 步知识轨。
- **仅基建**：产出基建变更（指针 / guardrail / steering 瘦身 / 工具），走第 2/3 步基建轨。
- **双轨并行**（鼓励）：既写 know-how 又修基建——文档帮人理解，基建帮 agent 不再踩。

### 第 2 步：写（分轨）

- **知识轨**：按 [`bestpractice_01`](bestpractice_01-knowhow_writing.md) 的四件套（目标 / 验收标准 / 可用资源 / 输出规格，结果确定性优先）写那一层的内容；长文件（>100 行）顶部配 TL;DR（ADR-0015）。**不在此重复写作细则。**
- **基建轨**：最小写作纪律——(1) 指针措辞前置触发词、每分支一个触发条件，steering 文件只放导航指针；(2) guardrail 优先于文字规则，机械违规一律建确定性检查；(3) 细则落按需文档、指针指过去。

### 第 3 步：收口（分轨）

- **知识轨**：走 [`bestpractice_12`](bestpractice_12-knowledge_layering.md) "落盘即收口"三件套——覆盖检查 → 写入 → 更新入口 → terminal 直读磁盘核实。**入口分两处**：product 经验更新 `rules/05_KNOWHOW_INDEX.md`；**user 经验必须更新 `contexts/knowhow/07_USER_KNOWHOW_INDEX.md`**（本地 INDEX，格式同 product 的 05、不回上游；新环境首次沉淀时按下方骨架自建）——否则 agent 按需检索时找不到，等于没沉淀。**子仓库收口**：部分环境的 `contexts/knowhow/` 是独立 git 子仓库（探测：`git -C contexts/knowhow rev-parse --git-dir`）——此时 user 沉淀须在**子仓库内 commit** 才算收口，否则经验滞留本地、外层仓库看不到任何待办痕迹。

  **`user INDEX 最小骨架`**（新环境首次沉淀 user know-how 时，照此建 `contexts/knowhow/07_USER_KNOWHOW_INDEX.md`）：
  ```markdown
  # User Know-how Index
  本环境本地 user know-how 索引（不回上游，见 ADR-0017）。结构同 product 的 rules/05_KNOWHOW_INDEX.md。
  ## 分类索引
  ### Workflow（工作流）
  - [标题](<file>.md) — 一句话场景说明
  ### BestPractice（最佳实践）
  - [标题](<file>.md) — 一句话场景说明
  ```

- **基建轨**：改动落盘 → terminal 直读核实生效（指针可达目标文件 / check 能跑出结果 / steering 文件核实变薄）→ **联动清理**：基建变更若使某条旧 know-how 过时，顺手更新或删除之（基建与文档不同步是新的坑源）。

## 验收标准

1. 是否**判过所有权**（product/user），而非默认全塞进 `rules/`？
2. **两条轨是否都判定过**（哪怕结论是"无需基建变更"），而非只判知识轨？
3. product 经验是否走过 bestpractice_12 三问路由定子层？
4. 写之前是否读过 bestpractice_01（知识轨）/ 写作纪律（基建轨）？
5. 是否做了覆盖检查（grep 候选落点，确认不是已有内容的换皮）？
6. 是否更新了入口（product 进 KNOWHOW_INDEX）并用 terminal 核实内容生效？基建变更是否核实生效？
7. 是否避免了层错配（user 塞 rules / product 塞 contexts）？

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|------|------|------|
| 跳过第 0 步直接判层 | 默认所有经验都进 `rules/`，本机定制污染上游 | 第 0 步是硬前置——先问"换环境还成立吗" |
| 把 user 经验塞进 rules | 已 commit 的内容 gitignore 挡不住，污染推给所有用户 | user 经验一律落 `contexts/knowhow/`；提交前确认不在 `rules/` |
| **只沉知识、不判基建** | know-how 写了，但下个 agent 没读到，错误照样复发 | 第 1 步双轨硬规则：基建轨七类每次必过；能建 guardrail 就别只写文档 |
| **把双轨当二选一分流** | 判定"这是知识经验"后就跳过基建轨（或反之） | 两轨独立判定、可同时命中；"无需变更"是结论，跳过不是 |
| 期望自动化越界 | 想让 reflector 自动判 product/user / 判轨道并自动改基建 | 判所有权、判轨道 + 写作永远 manual-in-the-loop（判轨道为扩轨新增，ADR-0017 D5 枚举待修订）；reflector 只产 product |
| 把编排层当 SOP 逐行执行 | 把四步当机械清单照抄 | 四步是判定顺序 + 边界；知识轨判层细则在 bestpractice_12，写作细则在 bestpractice_01 |

## 与现有体系的关系

- **[bestpractice_12](bestpractice_12-knowledge_layering.md)（知识轨判层）**：本文件是它的前置——先判所有权（product/user），再把它的三问用作知识轨路由。不重复三问内容。
- **[bestpractice_01](bestpractice_01-knowhow_writing.md)（知识轨写作）**：本文件只编排"写到哪层"，知识轨"那一层怎么写"交给它。
- **ai-heartbeat（自动化通道）**：本文件是手动通道的编排层；自动化通道的边界（只产 product、不碰 user）由 ADR-0017 + KNOWLEDGE_BASE §4.2 显式约束，两者互补不重叠。
- **/retro（会话级基建复盘）**：基建轨七类判定面与 /retro 同源；/sediment 每次沉淀内嵌全量判定（等效跑一遍 retro 判定面），不依赖、不修改、不级联调用 /retro。
