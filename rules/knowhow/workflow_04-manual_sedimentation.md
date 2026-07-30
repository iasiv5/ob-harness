# 手动经验沉淀：判所有权 → 判层 → 写 → 收口

## TL;DR · 30 秒决策

踩坑/学到经验后，走四步把它沉淀到正确的层：**第 0 步判所有权（product/user）→ 第 1 步判层 → 第 2 步写 → 第 3 步收口**。三条先记住：

1. **先判 product/user，再判子层**。判错代价大——把 user 经验塞进 `rules/` 会污染上游、推给所有用户；把 product 经验塞进 `contexts/knowhow/` 则下个用户照踩。
2. **本文件相对 bestpractice_12 的唯一增量是第 0 步（判所有权）**。第 1-3 步（判层/写/收口）引用 `bestpractice_12` + `bestpractice_01`，不重复。
3. **自动化天花板在"判所有权 + 写"**。沉淀四环节中只有"触发 + 机械收口"可自动化；判所有权和写作永远 manual-in-the-loop（ADR-0017 D5）。

---

## 关于本文件（唯一增量 + TL;DR 声明）

本文件相对 [`bestpractice_12`](bestpractice_12-knowledge_layering.md) 的唯一增量：在"判层"之前插入"判所有权（product/user）"这一步；其余三步（判层/写/收口）引用 bestpractice_12 + [`bestpractice_01`](bestpractice_01-knowhow_writing.md)，不重复。作为编排层，本文件尽量薄（第 0 步为主体）；无论行数多少都配了顶部 TL;DR（ADR-0015 生产者义务），不卡 100 行。

## 元数据

- **类型**: Workflow
- **适用场景**: 踩坑/学到经验后，要把经验沉淀进 ob-harness 时
- **创建日期**: 2026-07-30
- **触发器**: agent 在会话中自主走，或经 `/sediment` slash command 显式触发

## 目标与边界

- **目标**：把一条经验沉淀到正确的所有权层（product/user）+ 子层，落盘即收口。
- **边界**：本文件是**编排层**——只编排"判所有权 → 判层 → 写 → 收口"的顺序与判定，不重复 bestpractice_12（判层细则）和 bestpractice_01（写作细则）的内容。不替代 ai-heartbeat 自动化通道（其边界见 ADR-0017 两层天花板）。

## 沉淀路径

### 第 0 步：判所有权（product / user）——本文件主体

先判定这条经验属于谁，再谈子层。正交于"层级"（axioms/rules/knowhow/memory）的是**所有权 / 分发范围**：

| 所有权 | 物理落点 | 回上游? | 谁受益 | 典型经验 |
|--------|----------|:-------:|--------|----------|
| **product**（随产品分发） | `rules/`（axioms / 核心 rules / knowhow） | ✅ | 所有使用 ob-harness 的用户 | 源于 ob-harness 自身、别的环境会同样复发 |
| **user**（本地） | `contexts/knowhow/`（gitignore，不回上游） | ❌ | 仅本环境 | 本机/本项目定制、与具体环境绑定的偏好 |

**判错代价**（两个方向都会出错）：
- **把 user 经验塞进 `rules/`（product）**：污染上游，推给所有用户——别人拿到一条只对你有效的定制经验，信噪比下降；更糟的是它会被自动晋升/分发链路放大。
- **把 product 经验塞进 `contexts/knowhow/`（user）**：下个用户/新环境照踩——这条经验没随仓库分发，gitignore 把它挡在上游之外。

**判定要点**：问"换个环境、换个用户，这条经验还成立、还会被需要吗？"成立且需要 → product；否则 → user。

**自动化天花板（硬边界）**：判所有权**必须人**。自动化通道（ai-heartbeat reflector）只能产 product、只动 `rules/` + `OBSERVATIONS.md`，**绝不**碰 `contexts/knowhow/`（user）——否则 user 内容被自动推到上游，击穿 git 边界（ADR-0017 D5）。本步不可自动化、不可委托给 reflector。

### 第 1 步：判层（子层路由）

走 [`bestpractice_12`](bestpractice_12-knowledge_layering.md) 的"三问路由"判 product 经验进哪个子层（axioms / knowhow / OBSERVATIONS）；user 经验进 `contexts/knowhow/` 下按主题组织。**不在此重复三问内容。**

### 第 2 步：写

按 [`bestpractice_01`](bestpractice_01-knowhow_writing.md) 的四件套（目标 / 验收标准 / 可用资源 / 输出规格，结果确定性优先）写那一层的内容；长文件（>100 行）顶部配 TL;DR（ADR-0015）。**不在此重复写作细则。**

### 第 3 步：收口

走 [`bestpractice_12`](bestpractice_12-knowledge_layering.md) "落盘即收口"三件套——覆盖检查 → 写入 → 更新入口 → terminal 直读磁盘核实。**入口分两处**：product 经验更新 `rules/05_KNOWHOW_INDEX.md`；**user 经验必须更新 `contexts/knowhow/07_USER_KNOWHOW_INDEX.md`**（本地 INDEX，格式同 product 的 05、不回上游；新环境首次沉淀时按下方骨架自建）——否则 agent 按需检索时找不到，等于没沉淀。

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

## 验收标准

1. 是否**判过所有权**（product/user），而非默认全塞进 `rules/`？
2. product 经验是否走过 bestpractice_12 三问路由定子层？
3. 写之前是否读过 bestpractice_01？
4. 是否做了覆盖检查（grep 候选落点，确认不是已有内容的换皮）？
5. 是否更新了入口（product 进 KNOWHOW_INDEX）并用 terminal 核实内容生效？
6. 是否避免了层错配（user 塞 rules / product 塞 contexts）？

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|------|------|------|
| 跳过第 0 步直接判层 | 默认所有经验都进 `rules/`，本机定制污染上游 | 第 0 步是硬前置——先问"换环境还成立吗" |
| 把 user 经验塞进 rules | 已 commit 的内容 gitignore 挡不住，污染推给所有用户 | user 经验一律落 `contexts/knowhow/`；提交前确认不在 `rules/` |
| 期望自动化越界 | 想让 reflector 自动判 product/user 并晋升 user 内容 | 判所有权 + 写作永远 manual-in-the-loop（ADR-0017 D5）；reflector 只产 product |
| 把编排层当 SOP 逐行执行 | 把四步当机械清单照抄 | 四步是判定顺序 + 边界；写作细则在 bestpractice_01，判层细则在 bestpractice_12 |

## 与现有体系的关系

- **[bestpractice_12](bestpractice_12-knowledge_layering.md)（判层）**：本文件是它的前置——先判所有权（product/user），再走它的三问判子层。不重复三问内容。
- **[bestpractice_01](bestpractice_01-knowhow_writing.md)（写作）**：本文件只编排"写到哪层"，"那一层怎么写"交给 bestpractice_01。
- **ai-heartbeat（自动化通道）**：本文件是手动通道的编排层；自动化通道的边界（只产 product、不碰 user）由 ADR-0017 + KNOWLEDGE_BASE §4.2 显式约束，两者互补不重叠。
