# `cmd_init` intake 抽取：`machine_selection_guard` 第 3 消费（empty/nontty 复用）暂缓——控制流不同形与重新评估触发条件

`cmd_init`（[commands.sh:255-394](../../lib/commands.sh)）是最后一个未抽瘦的 `cmd_*` god-function；其机器解析前置（L268-306）经 `/pick-one-arch-task` + 独立评审 + grilling 锁定抽成独立 leaf-pure module `lib/init_intake.sh`（Phase 1，intake-layer 抽取，与 `devtool_intake.sh` 同构，详见对应 implementation plan）。但 intake 内的 empty/nontty 检测**不复用** `machine_selection_guard`（即不让 init 成为 guard 的第 3 个消费者）——本 ADR 记录这个 Phase 2 子动作**现暂缓**，避免未来 explorer 看到 `init_intake` 内仍内联 empty/nontty 检测、想"为什么 init 不像 build/dev 那样复用 guard"而循环推荐。

Status: accepted

## Considered Options

1. **Phase 1+2 合并：intake 抽出同时复用 guard（empty/nontty 检测改调 `machine_selection_guard`）** —— 拒绝（现阶段）。技术可行（guard 泛化消费 list_fn，init 喂 `list_available_machines` 即可），但四条承重前提使合并收益不成立：
   - (a) **控制流不同形**——init 现状是 empty 前置（[commands.sh:274](../../lib/commands.sh#L274)，无条件、早于 arg 校验）+ nontty 后置（[commands.sh:290](../../lib/commands.sh#L290)，仅 else 分支、需 pick 时才查）；guard 是 empty+nontty 合并前置、一次返回三态。复用须把 empty 从"无条件前置"重塑为"else 内查"，control-flow 重塑耦合进接口收敛，回归风险叠加（empty 的 remedy 文案、`$MACHINE` 给定 + 空列表的走法都须逐一验证）。
   - (b) **list_fn 语义不同**——init 喂 `list_available_machines`（仓库所有可选 machine），build/dev 喂 `machine_state_initialized_machines`（已 init）。empty 分支 remedy 文案不同（init = `No machines found in $OPENBMC_DIR / re-clone`；build/dev = `No initialized machines / Run 'ob init'`）。guard 只回 status、文案留 caller，故技术可复用，但须独立验证 guard 在 `list_available_machines` 输入下三态判定/文案映射不回归。
   - (c) **Phase 1 收益不依赖 guard 复用**——testability 升级（init 选择矩阵 5 态从 `.exp`/PTY 升到 unit）只需 intake 原样保留控制流即可达成；guard 第 3 消费是 seam 深度证明的**红利**，非本体收益。
   - (d) **YAGNI**——dedup 收益（消除 intake 内 ~2 段 inline empty/nontty 检测）可能 < control-flow 重塑成本；init 控制流与 guard 不同形，复用不是机械替换。

2. **暂缓（接受）** —— Phase 1 纯接口收敛（intake 原样保留 empty 前置 + nontty 后置，不调 guard），行为字节级不变，testability 升级独立验收。guard 第 3 消费留 Phase 2，锚定触发条件；前提改变时重开。

3. **永久不接 guard（"init 永不复用 guard"）** —— 拒绝。太绝对。control-flow 重塑可能在未来被证明干净，或 guard 复用价值随第 4 个消费者出现而上升。保留重开口子（见下）。

## Consequences

- `lib/init_intake.sh` 内 empty/nontty 检测维持**内联原样**（empty 前置 + nontty 后置 else），不调 `machine_selection_guard`；`machine_selection_guard` 消费方维持 cmd_build / cmd_dev 两处。
- Phase 1（intake 抽取 + testability 升级）独立进行、独立验收（既有 `.exp` 字节级回归锁 + 新增 init 选择矩阵 5 态 unit）。
- **重新评估触发条件**（任一成立即重开本 ADR）：
  - control-flow 重塑被**证明干净**（empty 前置/后置语义差异消解，行为字节级可锁）。
  - guard 在 `list_available_machines` 输入下三态判定/文案经**独立验证不回归**。
  - `init_intake` 内 empty/nontty 检测**进入高频改动区**（反复改 → dedup 收益出现）。
  - 出现 guard 的**第 4 个消费方**（guard 复用价值上升，init 加入边际成本下降）。
- 未来 explorer 看到 `init_intake` 内内联 empty/nontty 检测、未复用 guard，**不应视为待办疏漏**：见本 ADR 与 CONTEXT.md `ob init command intake` 条目（已指向本 ADR）。
- 可逆性：本 ADR 是判断记录，无代码改动；Phase 2 前提改变时直接重开评审，无需"撤销"。
