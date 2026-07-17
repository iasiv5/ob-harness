# ob dev 的 cleanup/收尾语义作为故障安全不变量

ob dev 的 `modify` 会创建 externalsrc 与 `.bbappend` 这类开发态副作用，任何收尾动作——integration harness 的失败回滚、未来的 `reset`（丢弃）与 `finish`（落回 recipe）——都要清理它们。`ob dev` 把这套 cleanup/收尾语义收口为一条故障安全不变量：cleanup target 必须由权威 `devtool status` 重新确认、不靠缓存或推断；cleanup-needed 标志在副作用可能发生之前（`modify` 之前）设置，覆盖"副作用先于后续校验失败"的窗口；`status`/`list` 失败是真失败、降级为空结果会伪装成 benign skip；环境不具备或无可清理目标用显式 77 SKIP 与 pass/fail 区分。这样把 round-4 评审在 integration harness 上撞出的几个 🔴（status 失败误清用户 workspace、list 失败被当空列表跳过、modify 部分成功后失败仍残留）固化为通则，供 `reset`/`finish` 复用，避免下一个收尾命令重踩同样的清理陷阱。

Status: accepted

## Considered Options

1. **cleanup target 靠推断或缓存判定**（`modify` 成功就假定该 recipe 需要清理）—— 拒绝。`status` 可能失败、srctree 可能已被用户手动 `devtool reset`，推断会误清一个不再属于本次操作的 workspace（round-4 🔴1）。
2. **cleanup-needed 在 `modify` 成功之后设置** —— 拒绝。`modify` 的副作用（externalsrc/`.bbappend` 创建）可能在后续 `status`/srctree 校验失败之前已经发生；事后设置会漏掉"副作用先于失败"窗口，留下脏 workspace（round-4 的 partial-fail 场景）。
3. **`status`/`list` 失败降级为空结果继续** —— 拒绝。空候选会被当作"无可清理目标"跳过，把真实的 harness 失败伪装成 benign skip（round-4 🔴2）。
4. **故障安全通则：权威 recheck + 副作用前置标志 + 失败即止 + 显式 SKIP** —— 接受。

## Consequences

- 任何 ob dev 收尾命令（`reset`/`finish`）必须遵循本不变量：cleanup target 由 `devtool status` 权威 recheck，不读缓存、不靠调用方传入的 recipe 名直接清。
- 产生副作用的命令（`modify`）执行前必须置 cleanup-needed 标志；收尾动作在 EXIT/trap 上据该标志 + recheck 结果决定是否清理。
- `status`/`list` 失败一律 exit 非 0（真失败），不得降级为空结果。
- 环境不具备（无 initialized machine）或无可清理目标（候选均已 modified）以 `exit 77` 显式 SKIP 表达，与 pass/fail 区分。**77 是 integration harness 的测试协议码，不属于 ob 主 exit-code 契约（0/1/2/3）**；ob dev 产品命令（`reset`/`finish`）的退出码仍遵循主契约。
- `tests/integration/ob_dev.sh`（`ob_dev_integration_main` / `ob_dev_integration_cleanup`）是本不变量的 reference implementation，`tests/unit/ob_dev_integration_safety.sh` 用 fault-inject（status-fail / list-fail / modify-partial-fail）作为回归锁。
- `reset` 的"丢弃"与 `finish` 的"落回"在清理阶段共享本通则；二者在"清理什么、保留什么"上的差异（reset 解除 externalsrc 绑定、finish 额外生成 patch / 更新 SRCREV 落回 layer）是各自命令语义，不 override 本不变量的安全约束。
- **已知回归缺口（2026-07-17 评审 🟡1）**：`ob_dev_integration_safety.sh` 的 fault-inject 覆盖 status-fail / list-fail / modify-partial-fail / reset-fail，但 `finish` 独有的 phase=finish/landing/postcondition 失败路径未注入——因 fake 环境不支持 reset 成功路径（bbappend locate + attic 归档模拟成本高）；finish 失败的 cleanup 复用 `ob_dev_integration_cleanup`（已由 reset 路径 fault-inject 锁定），finish 独有的 layer 残留在无 JSON（phase!=0 不发布）时无法自动回滚（固有限制，需用户手动检查 layer）；finish 真实端到端由 `ob_dev.sh` integration 兜底。待 fake 框架支持 reset 成功路径后补 finish-partial-fail fault-inject。
