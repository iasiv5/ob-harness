# machine_state 分离 init 完成状态与 firmware image readiness

`machine_state` 用正交的 init state 和 firmware image readiness 表达 machine 状态，不再把 `built` / `image=yes` 或 `machine_state_records` 当作公共状态 interface。`firmware-image-ready machine` 必须同时满足 ADR-0001 的 `init-done marker` 和 OpenBMC firmware image artifact；没有 initialized machine state 的 artifact 归类为 `orphan firmware image artifact`，只在 `ob status` diagnostics 中解释。这样 build/start/status 的状态判断收口在 `machine_state` interface 后面，同时保留对 Ctrl+C 中断 `ob init` 或历史 build 残留 artifact 的可见性。

Status: accepted

## Considered Options

1. **单一 lifecycle enum** — 拒绝。它会隐藏 initialized 但无 firmware image、partial init 但有 firmware image artifact、orphan firmware image artifact 等有诊断价值的组合。
2. **把 `.static.mtd` 存在直接视为 built/ready** — 拒绝。它会绕过 ADR-0001 的 `init-done marker` 完成信号，让 stale artifact 伪装成 ready machine state。
3. **保留公共 record 字段解析（`machine_state_list_records` + `machine_state_record_field`）** — 拒绝。它会继续让 `commands.sh`、`repo.sh` 和测试耦合底层字段名，削弱 `machine_state` 作为 lifecycle 决策 module 的职责。
4. **records + 过滤后的 machine-name lists** — 拒绝。即使把 `machine_state_records` 限定为展示/诊断 surface，也会让 `commands.sh`、`repo.sh` 和测试继续解析 machine-state record 字段，无法证明新 interface 真正接管了 lifecycle state 解释权。
5. **明确状态查询 + facts interface** — 接受。`machine_state` 对外提供 initialized、firmware-image-ready、orphan artifact 和展示 facts 等明确状态 interface；facts interface 不得输出需要调用者二次解析的 record / `key=value` 行。若内部仍需 record-like 枚举，只能作为 `machine_state.sh` 的私有实现细节，生产代码不得调用或解析。

## Consequences

- `machine_state_records` 不再是 public interface；`commands.sh`、`repo.sh` 和其他生产代码不得解析 machine-state record 字段。
- `machine_state` 的 public interface 必须表达 lifecycle state 结论和 facts，而不是要求调用者组合 `init_state`、`snapshot_state`、`firmware_image_ready`、`firmware_image_orphaned` 等原始字段。
- 第一阶段优先用小查询函数和 machine-name list 迁移旧调用点；只有 `ob status` 等展示路径出现明显重复时，才引入 nameref facts collector，避免过早设计大而浅的聚合 interface。
- `firmware-image-ready machine` 必须满足 initialized 且存在 firmware image artifact。artifact-only 或 partial-init 场景不能进入 firmware-image-ready 结果，只能作为 orphan firmware image artifact facts 暴露给 `ob status` diagnostics。
- `ob status` 不把 orphan firmware image artifact 放进主 Machines 表，而是在 Diagnostics 小节报告，并给出 `ob init <machine>` 的恢复路径；展示文案、emoji、tips、remedy line 和 exit-code 契约仍属于命令编排层，不下沉到 `machine_state`。
- 测试必须从 `build=succeeded`、`image=yes`、`init=done`、公共 record 字段和 record parser 迁移到新状态词汇、明确状态 interface、facts interface；`tools/ob_check.sh` 必须包含“生产代码不再调用 public records surface”的静态门禁。
