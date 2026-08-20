# baseline runner 单副本在主仓（子仓只承载数据 + 数据生产线，schema_version 门禁耦合两仓）

`ob test-qemu` 的 runner 引擎（run.sh / runner.py / plan.py / probe_redfish.py /
assemble.py / report.py 六文件）曾按 [ADR-0025](0025-test-qemu-baseline-fullstack-per-machine.md)
全栈 per-machine 落在每个 baseline 目录里（社区机 `tests/baseline/<machine>/runner/`、
custom 机 `contexts/baseline/<machine>/runner/`）。实践中两份引擎**逐字节一致、靠人工
同步**（子仓 sync commit `3100279` 自证"六文件同步(与 romulus 逐字节一致)"）——因为
引擎层实际零 machine 定制（凭据/端口/QEMU 参数全在数据 YAML 与 ob cmd 层，runner 以
`OB_TQ_*` env 钩子 + argv 注入消费）。本 ADR 定调：**runner 六文件归一为主仓单副本
`tests/baseline/runner/`**，machine 差异只存在于数据 YAML；`contexts/baseline/<machine>/`
收窄为**纯数据 + 数据生产线**（ar_probes.yaml / applicability.yaml + gen_baseline.py /
reconcile.py 等 corpus→YAML 工具），不再含运行时代码。

对 ADR-0025 的关系是**修订其引擎不共享结论、保留其数据 per-machine 结论**：0025 拒绝
共享引擎的核心理由是组织约束（"做项目 A 的团队不一定有权限动项目 B 的代码"）。该前提
在本仓不成立——romulus 与 b865g8 由同一维护者驱动，"两份权限隔离团队各自的代码"实为
同一人手动双向同步的同一份代码，0025 所防的治理耦合不存在，反而每改一次 runner 要双写
两仓（b865g8 python 化同步即双写实证）。0025 的数据侧结论（每机 baseline 数据自成体系、
独立迭代、落点二分）原样保留；[ADR-0026](0026-test-qemu-baseline-lineage-routing.md)
的谱系硬路由语义不变，仅路由标的从"runner+数据一体目录"收窄为"纯数据目录"（runner
目录固定 `tests/baseline/runner/`，由 `cmd_test_qemu` 以 `OB_TQ_AR_PROBES` /
`OB_TQ_APPL` env 注入数据路径，复用 runner 既有 env 钩子，引擎零参数化改动）。

**两仓耦合由 `schema_version` 门禁承担**：runner 与数据分属两个 git 仓后，失去"同一份
plan.py 白名单校验两份数据"的免费保障。方案是两份 YAML 顶层声明 `schema_version: N`，
plan.py 校验（`type(v) is not int or v not in {支持集}`——bool 是 int 子类，`true` 不得
因 `True == 1` 穿透为版本 1），不匹配 exit 3（数据错不进 α truth）。custom 谱系的
gen_baseline.py 生成时盖章，数据生产线自带保障。

Status: accepted（2026-08-20，/grill-with-docs 十问定案）

References: [ADR-0025](0025-test-qemu-baseline-fullstack-per-machine.md)（本 ADR 修订其
"probe 引擎不共享"结论，保留数据 per-machine 与落点二分）；[ADR-0026](0026-test-qemu-baseline-lineage-routing.md)（谱系硬路由不变，标的收窄为数据目录）；
[ADR-0017](0017-knowhow-distribution-boundary.md)（`contexts/` 不随上游分发——runner 是
代码必须随上游分发，这是单副本只能落主仓的根因）；CONTEXT.md `baseline` / `ob test-qemu`。

## Considered Options

1. **主仓单副本 + env 注入（接受）** —— runner 归一 `tests/baseline/runner/`，
   `cmd_test_qemu` 路由出数据目录后以 env 注入。消除人工同步纪律与未来分叉风险；
   新 machine 接入 = 只建数据目录。
2. **维持逐字节人工同步（拒绝）** —— 现状。双写成本每次改动实付（b865g8 python 化
   同步 commit 为证），且同步是纪律不是机制，一次漏同步即静默分叉。
3. **runner 加 `--data-dir` 显式参数（拒绝）** —— agent 面对的接口是 `ob test-qemu`，
   参数只发生在 ob 内部，env 钩子已存在且零改动；`--data-dir` 是净负债（多一个参数面
   要测试，无调用方收益）。
4. **子仓保留 stub run.sh 转发主仓（拒绝）** —— 调用方唯一（`ob test-qemu`），路由改完
   旧路径无人引用；stub 制造"两条路都对"的假象。

## Consequences

- **custom 谱系子仓失去自包含可跑性**：脱离主仓 clone 的 `contexts/baseline/` 无法独立
  执行 baseline。可接受——调用方唯一且是 ob，该性质无消费方。
- **schema 演进流程**：主仓 runner 改 schema → 支持集更新 → 子仓数据跟进盖章；不匹配
  exit 3 + remedy，fail-closed。
- **0025 的自包含分发故事弱化**：给另一团队/环境接 custom 机 baseline 现在需要
  主仓（代码）+ 子仓（数据）两件。社区机不受影响（tests/ 自包含）。
- **可逆性**：退回 per-machine = 子仓 cp 六文件回去，成本低；但"单副本"确立后回退同样
  是语义倒退（重新引入同步纪律），正合 ADR 门槛（surprising：两仓分布 + 版本门禁的组合
  后人会问；real trade-off：单副本 vs 子仓自包含）。
