# `端口解析链` leaf-pure module：抽端口复用 resolver + 统一 deploy 到 cli_first

`ob start-qemu`（restart）与 `ob deploy-to-qemu`（build-first restart）各自内联一份「读旧实例 `PIDFILE_*` 端口 → 注入 `QEMU_*_PORT`」的端口复用 ritual，且规则不对称：start 用 `-z` guard（CLI flag 优先，X-α），deploy 用无条件赋值（旧实例压 CLI，X-β）。该不对称是 [ADR-0021](0021-qemu-restart-port-reuse.md) 在 path-X 注入机制下的物理强制结果——注入到 CLI flag 层使旧实例必然高于 env，grill 一轮想要的 `env > 旧实例`（β 序）当时物理不可达；0021 自己把"deploy 对齐 guard"登记为 future-candidate。同时 `ob` 的共享 option parse（`ob:176-187`）对 deploy 也接受 `--ssh-port` 等 flag，但 deploy 无条件注入静默丢弃该 flag（latent bug，未文档化、零已知消费者，grill Q4 确认）。经 `/pick-one-arch-task` + `/grill-with-docs` 决策：(1) **Narrow** 抽 leaf-pure resolver module（新文件，仅拥有注入+guard+HTTP sentinel，prepare 基础链不动）；(2) **Unify** deploy 统一到 cli_first（修 latent silent-drop；module 化使 0021 future-candidate 触发条件满足）；(3) HTTP `none` sentinel **Keep**（module 加 `!= none` guard，不连根拔 PIDFILE 格式）。本 ADR 记这条 load-bearing 决策。术语见 CONTEXT.md `端口解析链`。

Status: accepted

Amends: [ADR-0021](0021-qemu-restart-port-reuse.md) 的 deploy guard 不对称（X-β old_first）→ 统一为 cli_first。ADR-0021 的核心决策（restart 注入旧实例端口复用）**不变**；被修订的是其 Consequences「两个不对称」之 (b)（start 带 guard vs deploy 无 guard）——该不对称随本 ADR 消除，0021 内嵌的 deploy 注入代码块与 `qemu_commands.sh` 行号反映 pre-0022 状态。
References: [ADR-0021](0021-qemu-restart-port-reuse.md)（端口复用机制本体 + future-candidate #1）、[ADR-0007](0007-qemu-launch-profile-start-qemu-decision-seam.md)（`QEMU launch profile`——本 module 紧邻其后的端口解析，不改 launch profile 接口）、[ADR-0019](0019-command-machine-resolution-seam.md)（leaf-pure module + return 契约 + `Amends:` 跨 ADR 修订先例）、[ADR-0010](0010-ob-dev-dispatch-leaf-pure-exit.md) / [ADR-0012](0012-ob-dev-subcmd-handler-leaf-pure-exit.md)（leaf-pure Y 规则 + exit_contract basename 登记先例）。

## Considered Options

1. **Narrow + Unify（接受）**——抽 leaf-pure module 仅拥有「旧实例注入 + cli_first guard + HTTP sentinel」，产出 resolved `QEMU_*_PORT`；prepare 的基础链 `${QEMU_*:-${OB_*:-default}}`（`lib/qemu.sh:97-100`）不动；start/deploy 两调用点（`lib/qemu_commands.sh:100-104` / `:375-378`）各换一次 module 调用，deploy 同步采用 cli_first。优点：只动重复+不对称的痛点代码（minimal-change / 根因优先）；module 化让被机制逼出来的妥协（old>env、deploy 无 guard）变得可逆；修 deploy silent-drop；两 sibling 命令同形。代价：deploy 对未文档化的 `--ssh-port` 路径从"静默丢"变为"honor"（行为变更，grill Q4 确认零消费者、无受害方）。
2. **Wide（拒绝）**——module 拥有整条链（含 prepare 基础链），直接产 `QEMU_LAUNCH_*`，prepare 只剩 interactive+check。拒绝理由：基础链 `${QEMU_*:-${OB_*:-default}}` 今天不重复、不对称、也不是痛点，单一出处行为正确；搬它属"与当前问题无关的重排"，违 minimal-change，且触碰 [ADR-0007](0007-qemu-launch-profile-start-qemu-decision-seam.md) 紧邻的 prepare，杠杆不抵风险。
3. **Preserve（拒绝）**——保留 start/deploy 双规则，module 带 `guard_mode` 参数，protocol gate 锁调用点接线。拒绝理由：把刻意不对称永远背下去、deploy silent-drop 不修；module 化已使统一近乎免费，preserve 是放弃红利。
4. **Eliminate HTTP sentinel（拒绝，留 future-candidate）**——改 `lib/qemu.sh:160` 空值存空串/省略字段，同步改所有 PIDFILE reader（restart 注入、smoke、status）。拒绝理由：是 PIDFILE 序列化格式的根因，不在端口解析链这条线上，牵动 smoke/status 等无辜消费者，属另一条 ADR 级改动；module 一个 `!= none` guard 比 PIDFILE 格式迁移便宜得多（YAGNI）。留 future-candidate，等 PIDFILE 格式真要动时一起。

## Consequences

- **module 边界（Narrow）**：leaf-pure module 只做来源优先级解析——纯数据转换（cli/env/old + restart 旗标）→ resolved `QEMU_*_PORT`，含 HTTP `none` sentinel 跳过。**不含** interactive 协商（`resolve_qemu_ports_interactive`，`lib/qemu.sh:332`，含 `prompt_for_available_port` 的 exit 1）与可用性检查（`check_ports_available`，`lib/qemu.sh:252`，exit 3）——这两层有 exit，留在 `qemu_prepare_launch` 消费 module 产出。module 函数绝不 exit（leaf-pure Y 规则）。
- **文件落点（load-bearing）**：module 落**新文件**，不进 `lib/qemu.sh`。理由：`exit_contract` 的 Y 规则按 **basename** 判 leaf-pure，而 qemu.sh 是 direct-exit module（exit 1 at `lib/qemu.sh:135`/:309、exit 3 at `:252`）——leaf-pure 函数塞进去会被文件级契约污染，必须独立文件才能登记 `set()`。命名走 `<domain>_<noun>.sh` 惯例（对照 `lib/machine_resolve.sh`）；具体名在实施计划定（候选 `lib/qemu_port_reuse.sh`，函数 `resolve_qemu_port_reuse`）。
- **deploy 行为变更（Unify）**：`ob deploy-to-qemu --ssh-port N`（QEMU 在跑）从静默丢改为 honor。无 CLI flag 时（common case）行为不变——`-z` guard 放行、照旧复用旧端口。零已知消费者（grill Q4），无受害方。
- **端口解析链序不变**：Unify 不改链序（仍 `CLI > 旧实例(注入) > env > 默认`，old 高于 env 是 path-X 注入的物理结果）；它改的是 deploy 是否 guard CLI flag。
- **β 重排解锁（future-candidate，非本 ADR scope）**：`env > 旧实例` 的 β 序（ADR-0021 grill 一轮选 β、因 path-X 物理不可达放弃）由本 module 化解锁——届时改 module 内部排序即可，不再受"注入到 CLI 层"机制约束。本 ADR 忠实抽取、不改链序。
- **exit_contract**：登记新 basename `'qemu_port_reuse.sh': set()`（Y 白名单 leaf-pure，函数不直接 exit）。qemu.sh 契约不变。
- **CONTEXT.md**：`端口解析链` 术语订正——链序对齐实现（old > env，非 env > old）、HTTP opt-in 无默认、start/deploy 注入机制的不对称细节移出 glossary 归 ADR（0021 历史 / 0022 现行）。
- **测试（实施计划落地）**：新 unit 矩阵（cli_first：CLI set/unset × old set/unset × HTTP none 变体）；protocol surface gate 锁 production 不再内联注入 ritual（interface-shrink，bestpractice_10 形态 A）+ 锁两调用点都经 module（防对称化/内联回潮）；既有 `tests/protocol/qemu_restart_port_reuse.sh`（改写为值断言）+ `tests/orchestration/start_qemu_force_restart.sh`（F1 顺序不变量）保持绿。
- **可逆性**：module 抽取 + Unify 有既有 protocol/orchestration 测试网兜底；deploy honor-flag 的回退即删 module 调用回内联（但会重现 silent-drop，不推荐）。术语订正由本 ADR + CONTEXT 改动记录。
- **future-candidate**：(1) `env > 旧实例` β 重排（module 化已解锁）；(2) HTTP sentinel 连根拔（随 PIDFILE 格式迁移，见选项 4）；(3) Wide——若基础链出现重复/痛点再回头把整条链并进 module。
