# ob smoke 收编为 ob test-qemu --suite smoke

`ob smoke` 作为独立顶层命令退役，其 5 条可达性断言收编为 `ob test-qemu --suite smoke`（每 machine 必备的专用 suite，`ar_probes.d/smoke.yaml`，5 个 AR）。动机三合一：命令面收敛（`ob --help` smoke 专属段落消失）、凭据统一（旧 smoke 硬编码 `root:0penBmc`，收编后走 `ar_probes.yaml` 按接口分栏的 auth，不落 argv——顺带修掉定制 machine 上 IPMI 探针因硬编码凭据恒 ✗ 的问题）、结构统一（兑现 ADR-0025 v2 增补预留的方向）。`ob smoke` 命令直接删除，不留别名、不留双轨。

## Considered Options

- **别名/转发过渡一个时期**：否决——越干净越好，人类与 agent 一律迁新入口。
- **半合并（只收编 3 条 Redfish 断言，IPMI/SSH 留旧路径）**：否决——两套并存正是要消除的状态，且 IPMI 探测是定制 machine 上有真实价值的部分。
- **推迟，等 runner 演化（沿 ADR-0023"等第二个 adapter"）**：否决——suite 机制（布局 v2 分片）与 auth 四栏（`auth.redfish/ipmi/ssh/console`，ipmi/ssh 本就预留）已就位，条件成熟。

## Consequences

- **runner probe-type 扩展**：`tests/baseline/runner` 在 redfish 之外新增 `ipmi`（ipmitool over LAN）与 `ssh_tcp`（TCP 就绪门语义，凭据无关，retry-with-timeout 由 AR 字段控制）两个 probe-type，属一次性翻译成本（旧 smoke bash 段约 270 行删除）。
- **输出与 exit 码完全同构**：`--suite smoke` 与其他 suite 同一 AR 五态输出，无任何 smoke 特判；smoke 旧的 ✓/✗ stdout 契约与 α exit 1 例外（全仓唯一）消灭，`tools/smoke_diff.py` 重写为解析 AR 五态格式，`tools/smoke_regression.sh` temporal gate 保留 caller 侧（ADR-0020 的 regression 判定归 caller 定位不变）。
- **smoke 从零 per-machine 变 per-machine 数据文件**：ADR-0020 的"零 per-machine"约束修订为仅约束 temporal gate（caller 侧）。
- **exit 3 触发面变宽**：凭据/PyYAML/谱系缺失时旧 smoke 能跑、新 suite exit 3——接受（硬编码能跑是 bug 不是特性）。
- **不设默认 suite**：`ob test-qemu` 无参数仍跑全量 applicable AR，smoke 只是显式 suite。
- **测试迁移**：旧 smoke_* 测试簇（protocol/orchestration/integration 四层 13+ 文件）按新语义并入 test-qemu 既有分层后删除；smoke_diff 单测随 diff 工具保留、改断言格式。
- 本 ADR 是决策记录；CONTEXT.md 词条（`ob smoke` → `smoke suite`、`ob test-qemu`/`baseline` 的"正交姊妹"表述）与 ADR-0020/0023/0025 的就地修订随实施落地（glossary 与代码同步变更，不超前描述不存在的命令面）。ADR 按活文档原则就地修订，不做 superseded-by 链。

> **历史注记（2026-08-21）**：收编时点为 5 AR（决策原文保留）。此后 smoke 门扩容：+SMOKE-05 SSH TCP / SMOKE-06 console / SMOKE-07 Web UI（7 AR，2026-08-20），+SMOKE-08 Web 登录 + 登录后会话资源（8 AR，2026-08-21，`request.login` 数据驱动登录块）。当前门规模以 `tests/baseline/romulus/ar_probes.d/smoke.yaml` 头注释为准。
