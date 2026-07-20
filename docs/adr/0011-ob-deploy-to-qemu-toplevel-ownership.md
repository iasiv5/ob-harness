# ob deploy-to-qemu 归属 ob 顶层 QEMU 生命周期层，非 ob dev

`ob deploy-to-qemu <machine>`（image 级重建 `ob build` 整个 image + QEMU 重启，做干净验证）放在 ob 顶层 QEMU 生命周期命令族（与 `start-qemu` / `stop-qemu` 同级），**不**放在 `ob dev`（recipe 级开发层）。理由：deploy 是 image 级动作（编整个 `obmc-phosphor-image`，1-4 小时）且碰运行态（stop + start QEMU），与 `ob dev` 的两条边界（单 recipe + 不碰运行态）冲突；其编排对象（build + QEMU 起停）也属 ob 顶层能力。`ob dev deploy` stub 已退役（commit a0837c4），不复活。

Status: accepted

## Considered Options

1. **ob 顶层 QEMU 生命周期层（与 `start-qemu` / `stop-qemu` 同族）** —— 接受。deploy 碰运行态（stop + start QEMU，释放 / 占用端口，写 / 删 `.pid`）+ image 级（`ob build` 整个 image），这两条都是 ob 顶层 QEMU 命令族的职责。编排对象（`build_env_enter` + `bitbake` + `qemu_instance_*` + `qemu_prepare_launch` / `qemu_execute_launch`）也全是 ob 顶层 / 通用底层 module，无 `ob dev`（devtool workspace）依赖。命名 `ob deploy-to-qemu <machine>`（`-to-qemu` 后缀编码 v1 target 是 QEMU），融入 QEMU 命令族。

2. **`ob dev deploy`（recipe 级开发层）** —— 拒绝。`ob dev` 的领域边界是 recipe 级开发（devtool modify / build / reset / finish，单 recipe，不碰运行态）——见 [CONTEXT.md](../../CONTEXT.md) `ob dev porcelain stdout` / `ob dev build`。deploy 碰运行态（重启 QEMU）+ image 级（编整个 image，不是单 recipe），两条都破 `ob dev` 边界。且 deploy 的语义是"让 target 跑上新代码做验证"，抽象层级高于 recipe 开发。曾以 `ob dev deploy` stub 占位（误判 deploy 属 dev），grilling 纠正后退役。

3. **独立顶层命令族 `ob deploy`（不带 `-to-qemu`）** —— 拒绝（v1）。v1 target 固定 QEMU，`-to-qemu` 后缀显式编码 target，为未来真机部署（`-to-bmc` 或 target 配置模型）留命名空间。无后缀的 `ob deploy` 暗示多 target 抽象，v1 不需要。

## Consequences

- `ob deploy-to-qemu` 是 ob 顶层 cmd_*（L1 exit seam，`lib/commands.sh::cmd_deploy_to_qemu`），与 `cmd_start_qemu` / `cmd_stop_qemu` 同级；进 `ob --help` Commands 清单，agent 经 ob 优先原则（ADR-0003）发现。
- `ob dev` 保持 recipe 级 + 不碰运行态边界——`ob dev build`（单 recipe 编译）与 `ob deploy-to-qemu`（image 级重建 + QEMU 重启）正交：前者是 fast inner-loop 单 recipe 反馈（秒-分钟），后者是 image 级干净验证（1-4h + 重启）。workflow_02 引导两步模式：`ob dev build` 快速预失败 → `ob deploy-to-qemu` 完整验证。
- deploy-to-qemu 的编排复用 ob 顶层 / 通用底层 module（`build_env_enter` / `qemu_instance_*` / `qemu_prepare_launch` / `qemu_execute_launch`），**不依赖 `ob dev`（devtool workspace）**——故与 ADR-0008（dev cleanup fail-safe）/ ADR-0009（dev workspace single-writer）无关。
- 本 ADR 不约束未来 deploy target 扩展（真机部署）的命名——若未来加真机 target，重开评审（可能 `ob deploy-to-bmc` 或抽象 target 配置模型，届时 v1 的 `-to-qemu` 后缀价值兑现）。
