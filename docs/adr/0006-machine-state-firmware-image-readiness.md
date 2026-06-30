# machine_state 分离 init 完成状态与 firmware image readiness

`machine_state` 用正交的 init state 和 firmware image readiness 表达 machine 状态，不再把 `built` / `image=yes` 作为公共 record 字段。`firmware-image-ready machine` 必须同时满足 ADR-0001 的 `init-done marker` 和 OpenBMC firmware image artifact；没有 initialized machine state 的 artifact 归类为 `orphan firmware image artifact`，只在 `ob status` diagnostics 中解释。这样 build/start 的决策收口在 `machine_state` interface 后面，同时保留对 Ctrl+C 中断 `ob init` 或历史 build 残留 artifact 的可见性。

Status: accepted

## Considered Options

1. **单一 lifecycle enum** — 拒绝。它会隐藏 initialized 但无 firmware image、partial init 但有 firmware image artifact、orphan firmware image artifact 等有诊断价值的组合。
2. **把 `.static.mtd` 存在直接视为 built/ready** — 拒绝。它会绕过 ADR-0001 的 `init-done marker` 完成信号，让 stale artifact 伪装成 ready machine state。
3. **保留公共 record 字段解析（`machine_state_list_records` + `machine_state_record_field`）** — 拒绝。它会继续让 `commands.sh`、`repo.sh` 和测试耦合底层字段名，削弱 `machine_state` 作为 lifecycle 决策 module 的职责。
4. **records + 过滤后的 machine-name lists** — 接受。`machine_state_records` 是展示/诊断 surface；`machine_state_initialized_machines` 和 `machine_state_firmware_image_ready_machines` 是决策 surface。

## Consequences

- 公共 record 字段使用 `init_state`、`snapshot_state`、`firmware_image_ready`、`firmware_image_orphaned`、`firmware_image_path`、`firmware_image_mtime` 和 `discovered_by`；旧 `build` / `image` 字段不做兼容保留。
- `firmware_image_ready=yes` 必须满足 `init_state=initialized` 且存在 firmware image artifact。artifact-only 或 partial-init 场景保持 `firmware_image_ready=no`，并可设置 `firmware_image_orphaned=yes`。
- `ob status` 不把 orphan firmware image artifact 放进主 Machines 表，而是在 Diagnostics 小节报告，并给出 `ob init <machine>` 的恢复路径。
- 测试必须从 `build=succeeded`、`image=yes`、`init=done` 和公共 `machine_state_record_field` 迁移到新状态词汇与过滤后的 machine list 行为。
