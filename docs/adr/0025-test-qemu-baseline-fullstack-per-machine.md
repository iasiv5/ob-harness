# `ob test-qemu` baseline 全栈 per-machine 独立(数据 + probe 引擎均不共享,权限隔离优先于 DRY)

`ob test-qemu` 在 QEMU 上对 BMC 的 `baseline`(开发基线/功能基线,一组带编号需求条目 AR,如 `BMC-3-1-2`)做一致性验证。经 `/grill-with-docs`(grilling + domain-modeling)五轮盘问,本 ADR 定调:每个 machine 的 baseline **全栈 per-machine 独立**——`baseline 数据`(该机测哪些 AR、各条 assert 什么)+ `probe 引擎`(执行 Redfish/IPMI/SSH 探测与断言判定的脚本)都落在该 machine 自己的目录里,不共享 AR 定义、不共享 probe 引擎。决策动因是**组织约束而非纯技术偏好**:做项目 A 的团队不一定有权限动项目 B 的代码,baseline 按项目解耦、各自独立迭代、自包含分发。在此约束下,各 machine 目录里字面相似的 probe 引擎**不是 DRY 要消灭的"同一份代码的副本"**,而是"两个权限隔离团队各自拥有的、碰巧当前相似的代码"——把它们 merge 进共享层反而制造治理耦合(改一次要 N 个团队协调放行)。代码相似是组织边界的**结果**,不是 DRY 的罪过。落点按既有分发边界二分:社区机 `tests/baseline/<machine>/`(随 ob-harness 上游),custom 机 `contexts/baseline/<machine>/`(不随上游,接 [ADR-0017](0017-knowhow-distribution-boundary.md) 的 `contexts/` 边界);每目录自包含(AR 数据 + probe 引擎 + 本地 applicability 过滤)。本 ADR 推翻早前设计草案的全局数据模型("全局 `ar_probes.yaml` + 共享 `runner/` probe 适配器");该草案已删除,设计角色由本 ADR + 实施计划接管。

Status: accepted

References: CONTEXT.md `baseline`(本次新增)/ `ob smoke` / `test layer`；[ADR-0017](0017-knowhow-distribution-boundary.md)(`contexts/` 不随上游分发边界——本 ADR 把 baseline 数据接上同一条 product/user 分发边界)；[ADR-0020](0020-ob-smoke-probe-only-smoke-prober.md)(smoke probe-only / 零 per-machine 知识,仅约束 smoke 层;test-qemu 作为新层允许 per-machine,本 ADR 把"允许"推到"全栈 per-machine 为默认")；[ADR-0023](0023-defer-smoke-assertion-runner.md)(防循环推荐 ADR 先例)。

## Considered Options

1. **全栈 per-machine(数据 + 引擎,接受)** —— 每 machine 目录自包含 AR 数据 + probe 引擎 + 本地 applicability。组织约束下自洽:自包含分发(给另一团队/环境只需给一个目录)、按项目权限解耦(改本机引擎不动他机)、独立迭代(各团队各发版节奏)。代价见 Consequences。grill Q14 用户定调,理由是"做项目 A 的同学不一定有权限弄项目 B"。

2. **数据 per-machine + 引擎共享(拒绝)** —— grill 中 agent 推荐(HTTP/IPMI 请求逻辑 machine-agnostic,共享避免重复修 bug、避免长期分叉)。拒绝理由:共享引擎层是"公共代码",其仓库归属(`tests/` 顶层?`lib/`?新建 shared?)在权限模型下无干净答案;改它需跨团队权限协调,违背"按项目解耦"的初衷;且原设计草案要求 probe 适配器 host/port 参数化为 `ob test-sut`(真机)预留,共享层与 per-machine 独立性的张力不可调和。**技术 DRY 让位于组织边界**——这是本 ADR 的核心判断。

3. **全局共享 `ar_probes.yaml` + 共享 `runner/`(拒绝)** —— 早前设计草案(全局一份 AR 定义 + per-machine `applicability/<machine>.yaml` 过滤 + 共享 probe 适配器)。拒绝理由:治理耦合(改一台机的基线要小心不影响所有机)+ 违背"每 machine baseline 自成体系独立迭代"的领域事实(grill Q13 用户定调:"每一个 machine 的功能基线都是自成体系并独立迭代的,不需要 AR 定义共享")。

## Consequences

- **代价(已知成本,接受)**:probe 引擎逻辑 bug 要修 N 次(各机各存一份 `probe_redfish.py` 等);custom 机(`contexts/baseline/<machine>/`)的修复不随上游回流给其他 custom 机;长期分叉后各机 probe 引擎行为可能微妙偏差,跨机验证结果严格不可比。这是 per-machine 独立性的固有成本,项目负责人在 grill 中明确判断接受——权限隔离是硬约束,不是偏好。

- **未来缓解(不现在做,YAGNI)**:若分叉痛到难以忍受,可把最稳定的底层(HTTP 客户端、JSON 断言原语实现、报告生成)抽成一个共享库或 vendored 依赖,默认引用、自包含分发时 vendor 进各机目录。**起步按全栈 per-machine,不预先设计这个**——等痛了再说,符合本仓 YAGNI 一贯风格。

- **applicability 内化进各机目录**:每 machine 目录只放"QEMU 可验 + 对该机 applicable"的 AR;不适用 / 硬件·host 依赖档不进该目录(留 `ob test-sut`,未实现)。原设计草案单设的全局 `applicability/<machine>.yaml` 层**降级为各机目录内的一份本地过滤**(记录"本机为何 skip 某条"的 reason + source),不再跨机共享。

- **防循环推荐(本 ADR 的主要存在价值)**:未来 explorer / architect 看到每个 machine 各有一份 `probe_redfish.py` / `probe_ipmi.py`,**不应视为待消灭的重复**、不应提议抽共享 probe 层——见本 ADR(同 [ADR-0023] 防循环模式)。这是组织边界产物,非 DRY 疏漏。grill 中 agent 两度用纯技术 DRY 推共享、两度被用户的组织约束驳回,本 ADR 锁住这个结论。

- **与 ADR-0020 划界**:ADR-0020"零 per-machine 知识"**仅约束 smoke 层**(浅冒烟,5 条哨兵,聚合 α verdict,无 per-machine profile);test-qemu 层本 ADR 确立全栈 per-machine。两层哲学不同但并存:smoke 守 per-push 绿灯(零 per-machine 保信号干净),test-qemu 做逐条深测(per-machine 承载领域差异)。不冲突。

- **CONTEXT.md 维护**:本次新增 `baseline` 术语条目(开发基线/功能基线,固件领域 ubiquitous language,= 一组 AR,被 test-qemu 验证的对象)。`ob smoke` 条目维持不变(与 baseline 正交)。

- **可逆性**:从全栈 per-machine 合并回共享引擎,要归并 N 份已分叉代码,成本随分叉深度上升;故本决策随时间趋难逆,正合 ADR 门槛(hard to reverse + surprising + real trade-off 三条全中)。

- **future-candidate**:若前提变化——出现"绝大多数 machine 共享同一份稳定 probe 引擎"且"组织上允许跨项目共享代码"(如团队合并 / 统一权限模型 / 单团队维护多 machine)——重新评估是否抽共享引擎层。届时按本 ADR 的"组织约束优先"原则重判。
