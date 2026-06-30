# QEMU launch profile as start-qemu decision seam

`ob start-qemu` 的 QEMU 启动决策收口到 `QEMU launch profile` module。`cmd_start_qemu` 只消费 `resolve_qemu_launch_profile` 的结果，不再直接编排 QB variable 解析、SoC fallback、QEMU machine name 推导和 AST2700 bootloader 校验；这样把启动画像的复杂度集中到一个 interface 后面，让调用者获得 leverage，让 SoC 规则、legacy fallback 和 remedy line 的 locality 保持在一个 module 内。

Status: accepted

Amends: ADR-0002 for `start-qemu` missing-input policy. ADR-0002 owns QB variable value source; ADR-0007 owns how `QEMU launch profile` derives `QEMU_LAUNCH_*` when QB inputs are missing. Fallback values must not be represented as `QB_*`.

## Considered Options

1. **继续串联 `resolve_qb_vars`、`detect_soc_type`、`derive_qemu_machine_name` 和 `find_ast2700_bootloaders`** — 拒绝。这个形态让 `cmd_start_qemu` 同时理解 BitBake 输出、machine conf include、deploy artifact、QEMU machine name fallback 和 AST2700 bootloader 需求，interface 几乎和 implementation 一样宽，module shallow。
2. **先新增 `resolve_qemu_launch_profile` 包住旧 public 调用，后续再清理** — 拒绝。它会留下两套有效 interface，表面 deepening，实际仍允许旧调用回流，形成半吊子工程。
3. **一次完成最终结构，并用行为锁测试、结构测试和调用次数锁控制风险** — 接受。先用测试锁住现有兼容行为与 exit-code 契约，再把启动画像解析收进 `resolve_qemu_launch_profile`，切掉旧 public 调用。

## Consequences

- `QEMU launch profile` 是启动时解析出的画像，不新增持久化 profile 文件；现阶段实现留在 `lib/qemu.sh`，不拆 `lib/qemu_launch_profile.sh`。
- `resolve_qemu_launch_profile` 入口必须先清空全部 `QEMU_LAUNCH_*` 变量，成功后再设置新的启动画像；调用者不能从上一次解析中继承 AST2700 bootloader 或 pc-bios 状态。
- `resolve_qemu_launch_profile` 成功后设置 `QEMU_LAUNCH_*` 变量；`cmd_start_qemu`、`ensure_qemu_binary`、`ensure_qemu_firmware` 和 `build_qemu_cmd` 不再直接依赖 `QB_*` 或裸 `SOC_TYPE`。`build_qemu_cmd` 仍可消费 image path、ports、serial path、`QEMU_BIN_FILE` / `QEMU_PCBIOS_DIR` 等运行时路径。
- `QB_MACHINE` 缺失时允许 legacy machine-name fallback，`QB_MEM` 缺失时表示不传 `-m` 参数；这些是 `QEMU_LAUNCH_*` 生成策略，不是 QB variable fallback，也不能回填为 `QB_*` 语义。
- SoC 证据分为 strong、machine-conf、deploy 和 legacy。deploy AST2700 证据必须是 AST2700 QEMU 启动所需 bootloader 文件组；partial AST2700 deploy evidence 只阻止 legacy AST2600 fallback，不覆盖 BitBake 或 machine-conf 的强 AST2600 证据；legacy AST2600 fallback 只在存在 firmware `.static.mtd` 且没有任何 AST2700 明确或部分证据时触发，必须 warning，并在 profile 内记录 source/confidence。
- AST2700 bootloader 解析与校验属于 launch profile 完整性；缺失时按 exit-code 契约返回 exit 3，并输出诊断行 + 恰好一行 remedy line。
- `QEMU_LAUNCH_REQUIRES_PCBIOS` 是 firmware 决策入口；`ensure_qemu_firmware` 消费该字段，不再从 SoC 重新推导 pc-bios 需求。
- 本次重构的完成标准包括 `resolve_qemu_launch_profile` 行为测试、exit-code/remedy protocol 测试、旧调用清零结构测试，以及 `bitbake -e` 调用次数锁。
