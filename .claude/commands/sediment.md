# Sediment (Claude Code Entry)

这是 Claude Code 的 `/sediment` slash command 入口。本文件只负责引用执行合同。

## 执行合同

读取 `rules/knowhow/workflow_04-manual_sedimentation.md`，按其中的四步（判所有权 → 判层 → 写 → 收口）执行经验沉淀。

两条要点：
1. **先判所有权（product/user）**——这条经验该进 `rules/`（随上游分发）还是 `contexts/knowhow/`（本地不回上游），判错会污染上游或让下个用户照踩。
2. **判所有权和写作必须人**——本命令只提供路径编排，不做自动判定；自动化天花板在"判所有权 + 写"（ADR-0017）。

不要跳过收口（覆盖检查 → 写入 → 更新入口 → 核实）。
