---
name: sediment
description: 手动经验沉淀入口：判所有权 → 判轨道（知识 + 基建双轨）→ 写 → 收口（执行合同见 rules/knowhow/workflow_04-manual_sedimentation.md）。
---

# Sediment (DeepSeek Harness Entry)

这是 DeepSeek Harness 的 `/sediment` 斜杠命令入口。本文件只负责引用执行合同。

## 执行合同

读取 `rules/knowhow/workflow_04-manual_sedimentation.md`，按其中的四步（判所有权 → 判轨道 → 写 → 收口）执行知识 + 基建双轨沉淀。

三条要点：
1. **先判所有权（product/user）**——这条经验该进 `rules/`（随上游分发）还是 `contexts/knowhow/`（本地不回上游），判错会污染上游或让下个用户照踩。
2. **知识 + 基建双轨并行判定，每次都判**——知识轨问"这条经验写到哪层"；基建轨按七类判定面问"哪些 agent 环境基建需要更新（导航 / 自动化检查 / 编码标准 / steering 瘦身 / no-op 指令 / 工具经济 / 信息可达）"。两轨独立出结论、可同时命中；跳过任一轨的判定即不合格。
3. **判所有权和写作必须人**——本命令只提供路径编排，不做自动判定；自动化天花板在"判所有权 + 写"（ADR-0017）。

不要跳过收口（覆盖检查 → 写入 → 更新入口 → 核实；基建轨另核实生效并联动清理过时 know-how）。
