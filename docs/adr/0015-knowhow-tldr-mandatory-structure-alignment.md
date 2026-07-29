# Know-how TL;DR 强制化：长 know-how 必须配 TL;DR，消费速则②升级为生产者硬义务

`/grill-with-docs` 复盘发现，know-how 体系的"消费者规则（怎么读 know-how）"与"生产者义务（一份 know-how 必须长成什么样）"被混为一谈：消费速则②要求"长文件先找 TL;DR"，但这是消费者软措辞——没有生产者义务时，消费者只会持续扑空。本 ADR 把消费速则②升级为生产者**硬义务**：`rules/knowhow/*.md` 行数 > 100 必须有 `## TL;DR` 段；短文件（≤100 行）整篇可扫完，对消费速则①的"读尾段陷阱"约束豁免。决策经 grilling 8 个决策点锁定，本 ADR 是这些实质决策**唯一的冻结载体**（proposal 自标"未立项草稿"，不作为冻结来源；会话口头共识不持久）。下游 9 个存量长文件补 TL;DR、2 个文件做尾段归位、ob_check 加 hard gate、新增 advisory 漂移预警，均以本 ADR 为政策依据。

Status: accepted

## Context

两条根因：

1. **消费者规则 ≠ 生产者义务（术语区分，记入本 ADR 防未来重复纠结）。** 消费速则①②③回答"读 know-how 时怎么做"（消费者视角：先读 TL;DR、读到尾部陷阱段才算读够、前半截能力清单不安全）。但它不约束"作者写 know-how 时必须放什么"（生产者视角）。把消费者"该先找 TL;DR"当成生产者"必须配 TL;DR"，是两个视角的偷换。修复必须在生产者侧立义务，否则消费者规则永远扑空。

2. **存量欠债。** 9 个 >100 行的长文件当时没有 TL;DR；只立规则不补存量，则规则对存量持续失效。

## Considered Options

**D1 —— 把"长 know-how 配 TL;DR"立成什么力度的约束？**

1. **消费者软规则——只改消费速则②措辞、不动存量** —— 拒绝。这正是现状，消费者持续扑空，不解决问题。

2. **生产者硬义务（接受）** —— 行数 > 100 的 `rules/knowhow/*.md` 必须有 `## TL;DR`，ob_check 加 hard gate 强制。给 know-how 体系引入第一份生产者合规负担。

3. **新文件鼓励 / 存量不动** —— 拒绝。新文件配 TL;DR、存量欠债不补，则规则对存量持续扑空，且规则本身失去权威。

**D5 —— "只改消费速则②措辞、不动存量"是否可作为 D1 选项 1 的等价表述单独留作一个被接受的轻量路径？** —— 拒绝。它与选定的硬义务方向相悖（硬义务要求存量也补），且放弃存量结构对齐价值。D1 选项 1 已吸收此语义。

## Consequences

- **触发线**：行数阈值 = 100（`wc -l`）；行数 > 100 且 basename 不在豁免清单的 `rules/knowhow/*.md` 必须有 `## TL;DR`（ob_check 门禁 grep 此字面量）。豁免清单照搬 `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 模式，内联在 `ob_check.sh` 显式枚举（初始为空，机制预留）。短文件（≤100 行）对消费速则①的"读尾段陷阱"约束豁免（整篇可扫完）。

- **D2 同步机制 + advisory 手段收敛。** TL;DR 与正文一致性靠三件套兜底：hard lint（ob_check 存在性，Task 8）+ advisory 漂移预警（Task 9）+ 人工 review。advisory **v1 选 git diff 结构检测、LLM 语义判断降为 v2 可选**——理由：本仓库无任何调 LLM 的工具先例（`cache_hit_rate.py` / `coverage_radar.py` / `exit_contract.py` 全是纯 python3 只读），引入 LLM API 是首个 LLM 依赖，不应在文档对齐计划里悄悄引入；最高发漂移（正文改了、TL;DR 忘改）零依赖即可捕获；v1 的语义盲区（正文换措辞、TL;DR 仍引旧措辞，字面段未动则无信号）留待 v2 LLM 兜底。advisory 工具定位（独立、只读、不阻断、与 `cache_hit_rate.py` / `coverage_radar.py` 同类）不变。

- **advisory 触发责任（防 orphan）。** drift_check 接入 ob_check 第 5 项（run_all 之后、汇总之前），随 ob_check 自动跑——因 ob_check 已加 know-how hard gate（1e），"改 know-how 后跑 ob_check"即顺带漂移预警，零额外记忆成本；drift flag 不进 FAIL 计数、`OB_CHECK_SKIP_DRIFT=1` 或 `OB_CHECK_SKIP_TESTS=1` 可跳过（后者让 smoke 反递归守护连带跳过 drift，保持 smoke"纯代码自检三段"语义）。区别于 `cache_hit_rate.py` / `coverage_radar.py` 那类需人单独记得跑的纯人工观测工具。

- **D3 一次性取舍。** 全补一次性（9 文件），接受"机制/标准未实战验证即套用 9 文件、可能整体返工"的风险。缓解：hard gate（Task 8）放在所有 TL;DR 补完后加、初始即全绿；两式提炼标准（Task 3）先于批量补写定稿。

- **提炼标准 = 分两式。** ①路由/决策型文件 → TL;DR 写决策路由（命中即停），样例见 `bestpractice_12` 三问路由；②线性/原则型文件 → TL;DR 写"这文件解决什么 + 1-2 条最该先知道的陷阱/边界"。定义写入 `bestpractice_01` 消费者视角节，附样例。

- **陷阱段归位口径（统一规则）。** 消费速则①要求"读到尾部陷阱段才算读够"。"靠尾部"指陷阱段落在**靠尾部约束区域**而非物理最末——变更日志 / 与其他 know-how 的关系段惯例性位于物理最末，是显式例外。这解释 `bestpractice_03` 的陷阱段（常见问题与解决）靠尾但非最末（变更日志在最末），与 `bestpractice_02` 的陷阱段落在物理最末的差异，避免未来 reviewer 用"物理最末"标准卡 `bestpractice_03`。

- **文案同步。** 消费速则②与 `bestpractice_01` 消费者视角节须前后一致（硬义务口径），三处相互引用 ADR-0015。

- 可逆性：全是 working-tree 文档/工具编辑，可回滚；但门禁一旦生效，未来补长文件 TL;DR 成为持续义务，故落 ADR。
