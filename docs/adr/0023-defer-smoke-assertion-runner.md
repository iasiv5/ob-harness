# smoke 断言 runner / spec 抽取暂缓——等第二个 adapter

`cmd_smoke`（[lib/qemu_commands.sh](../../lib/qemu_commands.sh)）内 5 条断言的编排（probe → judge → accumulate(total/passed/failed_*) → RAW 格式化）看似 5 个 adapter，但**非同构**：stanza 3（SoftwareVersion）复用 stanza 2（Managers）的 probe body；stanza 4（IPMI）有条件追加 RAW（"possible cause: …RMCP+/LAN responder"）。`/pick-one-arch-task` + 独立评审 + `/grill-with-docs` 考虑过抽 spec-driven runner（声明每条断言的 probe/judge/name/raw 模板，循环聚合 verdict），**现暂缓**——避免未来 explorer 看到 5 段重复编排、想"为什么 smoke 不抽 runner"而循环推荐。verdict **渲染**（summary + breakdown + α-banner）已单独抽成 `_smoke_render_verdict`（深一层接口 + fast-test 覆盖），runner 仅指 probe→judge→accumulate 的聚合循环。

Status: accepted

## Considered Options

1. **现在抽 runner（拒绝，现阶段）** —— 5 条非同构 → spec 须表达 probe 共享（swversion 借 managers body）与条件 RAW 分支（IPMI cause），spec interface 复杂度 ≈ inline 5 段，deletion test fail（spec 自己变成复杂度而非集中它）。当前仅 1 个 caller（`cmd_smoke`），无第二个 adapter 驱动；codebase-design「one adapter = hypothetical seam, two = real」未满足。

2. **暂缓（接受）** —— 先抽 `_smoke_render_verdict`（纯 verdict 渲染，return 0/1，fast-test 覆盖）拿 testability 收益；5 段 probe→judge→accumulate→RAW 编排维持内联（非同构部分）。runner 留第二个 adapter 出现时再 design-it-twice。

3. **永不抽 runner（拒绝）** —— 太绝对。第二个 target adapter（如真机 BMC target）或第 6 条断言出现时 runner 收益可能成立，保留重开口子（见 Consequences 触发条件）。

## Consequences

- `cmd_smoke` 内 5 段 probe→judge→accumulate→RAW 编排维持**内联**；`_smoke_render_verdict` 已抽出 verdict 渲染（见 `tests/unit/smoke_verdict.sh`）。
- **重新评估触发条件**（任一成立即重开本 ADR）：
  - 出现**第 6 条断言或新的 probe/judge 类型**（如 PLDM、HTTPS）——更多同形断言累积，spec 的 dedup 收益开始可衡量。
  - 出现**第二个 target adapter**（如真机 BMC target，不再只是 QEMU PID-file 端口模型）——codebase-design「two adapters = real seam」满足，spec 表达力 vs interface 复杂度的取舍才有第二条 driver 可判（与本 ADR 主论点对齐）。
  - 5 段编排**进入高频改动区**（反复改 → dedup 收益出现）。
- 未来 explorer 看到 `cmd_smoke` 内 5 段重复编排、未抽 runner，**不应视为待办疏漏**：见本 ADR。
- 可逆性：本 ADR 是判断记录，无强制代码约束；前提改变时直接重开评审，无需"撤销"。
