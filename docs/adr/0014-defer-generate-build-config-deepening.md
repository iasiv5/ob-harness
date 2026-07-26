# `generate_build_config()` 深化暂缓：YAGNI（已覆盖 / 单调用方 / 无变更压力）与重新评估触发条件

`generate_build_config()`（[init_pipeline.sh:282-434](../../lib/init_pipeline.sh)，154 行）是 `ob init` Step 7/8 的 `.inc` 装配函数，混了 preflight resolver 校验 / backup / WSL parallelism 探测 / `ob-managed variable` assignment-state 探测 / `.inc` 装配 / mkdir 六个职责。宽缝 deletion test（整 `.inc` 装配归一为 leaf-pure module）虽通过，且 CONTEXT.md `ob-managed variable` 条目历史措辞"未把 ob-managed variable 落成完整领域 module"使该函数在架构审查中被反复推荐深化。本 ADR 记录：**现阶段不深化**——经 `/pick-one-arch-task` 两轮独立扫描（commit-message 角度 / 文件频率角度 / coverage_matrix 角度）+ grilling 质疑前提后锁定，避免未来 explorer 把"未落成 module"当待办疏漏想"补"。

Status: accepted

## Considered Options

1. **深化为 leaf-pure module（宽缝，整 `.inc` 装配归一）** —— 拒绝（现阶段）。deletion test 通过、与深化飞轮（`image_build.sh`/`status_render.sh` 同款）一致，但四条承重前提使收益不成立：
   - (a) **测试已覆盖**——`.inc` 字段端到端由 [orchestration/generate_config.sh](../../tests/orchestration/generate_config.sh) 覆盖（含"用户已设 DL_DIR/SSTATE_DIR → 不覆盖"），`exit 3` 前置 + PREMIRRORS 注入由 [protocol/premirrors_injection.sh](../../tests/protocol/premirrors_injection.sh) 覆盖。深化收益是 locality + 更快 unit 面，**不是补盲区**（"盲区"假设经 coverage_matrix 交叉校验证伪：该矩阵无留空 TODO）。
   - (b) **单一生产调用方**（[cmd_init](../../lib/commands.sh#L390)）——leverage 的"多调用方共享"收益不存在，改 `.inc` 格式本就只动一处。
   - (c) **无变更压力**——`generate_build_config` 本体最近无高频改动（最近改动是 `resolve_effective_*` 的 existing seam alignment，已完成）；`init_pipeline.sh` 不在 recently-changed 热点（最近 3 周热点是 `commands.sh`，且那是深化飞轮的良性瘦身：1364→642 行 / 4 天，非 friction）。
   - (d) **YAGNI**——无 bug、无阻塞、不解锁下一步。深化是"为深化而深化"。

2. **暂缓（接受）** —— 上述四条前提成立时，深化飞轮应优先投向有 friction / 变更压力 / 多调用方的目标，而非这个 deletion test 合格但无压力的候选。CONTEXT.md `ob-managed variable` 条目的"未落成 module"措辞同步改为指向本 ADR，消除循环推荐诱因。

3. **永久封存（"永不深化"）** —— 拒绝。太绝对。承重前提（单调用方 / 已覆盖 / 无变更压力）可能随仓库演进改变，封死会变教条。保留重新评估口子（见下）。

## Consequences

- `generate_build_config()` 维持现状（`init_pipeline.sh` 内 154 行函数，`exit 3` 在函数体内，init_pipeline.sh 为 direct-exit module）；测试维持 orchestration + protocol 层，不新增 unit 层纯函数测。
- **重新评估触发条件**（任一成立即重开本 ADR）：
  - 出现**第二个调用方**（`generate_build_config` 之外需要 `.inc` 装配逻辑）→ leverage 收益出现。
  - `.inc` 装配规则（`=`/`??=`/`?=` 操作符与 bitbake.conf 弱默认的交互、assignment-state）**开始反复出 bug** → friction 出现。
  - `init_pipeline.sh` 成为**高频改动区**（recently changed 信号），或 `.inc` 格式需要频繁演进。
  - 出现对 `.inc` 装配做**参数化 unit 测**的硬需求（如喂 assignment-state 向量断言输出片段），测试层需下沉。
- 未来 explorer 看到 `generate_build_config` 是大函数 + 历史措辞，**不应视为待办疏漏**：见本 ADR 与 CONTEXT.md `ob-managed variable` 条目（已指向本 ADR）。
- 可逆性：本 ADR 是判断记录，无代码改动；前提改变时直接重开评审，无需"撤销"。
