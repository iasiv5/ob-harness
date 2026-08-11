# `ob smoke`：probe-only smoke 探针（不拥有 QEMU 生命周期、strict verdict α）

`ob verify` 初版（feat/ob-verify）以 `cmd_verify` 自带 QEMU bring-up（`qemu_prepare_launch`+`qemu_execute_launch`）+ EXIT-trap teardown + image-ready machine 解析 + 既有实例冲突处理，把 smoke 逻辑和 `cmd_start_qemu` 的 bring-up 机器绑死（~50 行内联副本，是 `command machine resolution` seam [ADR-0019] 排除在外的 image-ready 协议的第二次出现）。经 `/grill-with-docs` 四项决策锁定（定位 / 边界 / 就绪门 / verdict 语义）：把 verify 重构改名 `ob smoke`，定为 **probe-only**——不 boot、不 teardown，只对**已在跑**的 `QEMU instance` 做 OOB 接口 smoke 探测；verdict 取 **α（纯报真相，strict 全过）**，回归判定（baseline diff）归 caller。本 ADR 记这条 load-bearing 决策。术语见 CONTEXT.md `ob smoke`。

Status: accepted

Amends: 新增 CONTEXT.md `ob smoke` 术语；`ob verify` 改名 `ob smoke`（"verify" 过载退役）。
References: [ADR-0019](0019-command-machine-resolution-seam.md)（image-ready 族 seam——probe-only 使 smoke **不**成为第二个 image-ready adapter，不触发 ADR-0019 的 start_qemu 接 seam 重开条件）、[ADR-0003](0003-ob-first-front-door.md)（ob 优先——smoke 复用 start-qemu/stop-qemu 管生命周期，不自造）、[ADR-0011](0011-ob-deploy-to-qemu-toplevel-ownership.md)（smoke 与 deploy-to-qemu 同族顶层命令、正交组合 E2E）。

## Considered Options

1. **probe-only + α（接受）**——smoke 不拥有 QEMU 生命周期；前置 = instance 在跑（否则 exit 3 + remedy 指向 start-qemu）；从 PID file 读端口；自带 sshpass-independent 就绪门；verdict 纯报真相、strict 全过，零 per-machine 知识。deletion test 真过：删掉 bring-up/teardown，复杂度不重现（start-qemu/stop-qemu 本就 own 生命周期），smoke 从 ~150 行缩到 ~40 行。E2E 靠组合（start→smoke→stop），每段独立 → 比 smoke 自包揽生命周期**更**解耦。agent 的 modify→verify 回归由改前/改后两次 smoke 的 baseline diff 服务，**机器无关、零 per-machine 知识**。
2. **own lifecycle（拒绝，即 verify 初版）**——smoke 自带 bring-up+teardown。问题：抄死 `cmd_start_qemu` 的 image-ready 解析+bring-up+冲突 ~50 行（`command machine resolution` [ADR-0019] 排除 image-ready 族外的第二次出现）；和 start/stop 生命周期重叠；smoke 接口被 bring-up 参数污染（port override 等）变浅。候选 A 的耦合即源于此。
3. **probe-only + β（`--allow-fail`/expected-profile，拒绝）**——smoke 接受 caller 声明的「预期缺席接口」，exit code = 无意外失败。问题：期望知识总得来自某处——flag 形式 caller 须记每 machine 缺啥（脆）、config 形式 ob 拥有 image-profile 数据（耦合 machine，违解耦原则）；且 agent 的 modify→verify 主回路用 α 的改前/改后 diff 即可机器无关地判回归，不需要 per-machine 期望。α 的 smoke 接口更小更深（零期望参数，"interface is the test surface"）。
4. **probe-only 不带就绪门（拒绝）**——纯探，信 start-qemu 已 gate。问题：start-qemu 的 BMC-ready 等待 sshpass-dependent 且**超时只 warn 不算失败**，返回 0 不保证 ready → smoke 在 boot 窗口期错红（flaky）。错红是 smoke gate 最不能忍的失败模式。故 smoke 自带一个 sshpass-independent TCP 就绪门（"就绪"属"通不通"= smoke 的 remit，不属"boot"= start-qemu 的 remit，没越界）。

## Consequences

- **scope**：`ob smoke <machine>` 单命令；machine arg required（MVP 无交互选号）。probe-only：`qemu_instance_liveness`（含 load+probe）→ 读 PID file 端口 → 就绪门 → 3 断言 → verdict。无 bring-up / 无 teardown / 无 EXIT trap。
- **候选 A 消失**：不 boot 就不需要 image-ready machine 解析 / init+image 前置 / 既有实例冲突处理 / teardown——`cmd_verify` 与 `cmd_start_qemu` 的 ~50 行副本整块删除。这是比"抽 image-ready seam"更彻底的解：**删掉对耦合的需求**，而非把耦合抽出来。（candidate A 的真 seam 抽取仍可作为未来 start_qemu/deploy-to-qemu 的事，与 smoke 无关。）
- **不触发 ADR-0019 重开**：ADR-0019 把 start_qemu 接 resolution seam 列为 future-candidate，重开触发 = "出现第二个 image-ready 命令"。smoke 因 probe-only **不** boot、**不**做 image-ready 解析 → 不是第二个 image-ready adapter → 不触发该重开条件。若将来 smoke 重扩为 own-lifecycle，则相反。
- **verdict α 的代价（已接受）**：smoke exit code 在异质 image 上"严格但不直接可作 gate"——交互式跑 gb200nvl 永远 exit 1（breakdown 自解释：Redfish✓ IPMI✗ SSH✓ + raw）；CI 须 diff smoke 输出 vs baseline（baseline-diff 是 CI 的活，不是 smoke 的）。这是用"smoke 纯工具化"换"零 per-machine 知识 + 更深 module"的刻意 trade-off。
- **候选 B 顺带收**：重写时把 probe 的 `_VF_*` module-global 回值改成 nameref outvar（对齐 `resolve_command_machine` 模式），probe 降到 protocol 层直测。候选 C（assertion registry）/ D（凭据 seam）仍 speculative，defer（YAGNI：3 断言无变异；单 vendor）。
- **exit_contract**：`verify_assertions.sh` → `smoke_assertions.sh`（`LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 改 key，空例外集，leaf-pure 守 no-direct-exit）。
- **已知环境约束（不改断言）**：gb200nvl-obmc image 不含 `phosphor-ipmi-netbridged`（RMCP+ IPMI-over-LAN 不可用），smoke 上其 IPMI 断言合法 ✗ + exit 1。断言保持严格（在装 RMCP+ 的 image 上 pass，由 stubbed 测试验证）。这是 α 的真相输出，不是缺陷。
- **可逆性**：重写有测试网（protocol/orchestration stub + integration skip-77）兜底；决策逆转 = 重开本 ADR + 把 bring-up/teardown 加回（即回到 verify 初版形态）。
- **future-candidate（不违本 ADR）**：(1) smoke 无 machine arg 时交互选**在跑**的 instance（qemu_instance 列表）；(2) 真机 BMC target（非 QEMU）；(3) 断言扩深（Redfish Managers / sensor）— **已落地（2026-08-02）**：新增 Redfish Managers 资源可达 + Redfish SoftwareVersion 固件版本上报两条断言（一个 `_smoke_probe_redfish_managers` probe 喂两个 leaf-pure judge），断言总数 3 → 5，verdict/breakdown/RAW 形态与 α 不变；(4) baseline-diff 伴生（CI 闸门闭环）— **已落地（2026-08-02），并已演进（2026-08-02）为可一键跑的 temporal CI 闸门**：
  - **diff 引擎**（`tools/smoke_diff.py`）：对两次 smoke 输出按断言名配对，把 `✓→✗`（同名退化）与 **baseline 无此名 + current ✗**（新出现的失败断言）两类都判回归（exit 0 放行 / exit 1 拦截）——语义严格化：一个全新的 ✗ 理应拦截，不再仅作 info。`✗→✓` 改善、`✓→✓`/`✗→✗` 不变、新出现的 ✓、消失的断言名仍作 info（不算回归）。配 `tests/unit/smoke_diff.sh` 自测覆盖新语义。
  - **temporal CI 闸门**（`tools/smoke_regression.sh <machine> -- <change-cmd...>`）：把「伴生工具」推进为「可一键跑的闸门」——校验目标 machine 有在跑的 QEMU 实例（ob smoke 自带前置，exit 3 透传）→ 捕获 baseline smoke 快照（**运行时临时产物 `mktemp`，非版本管理**）→ 执行 `<change-cmd>` → 重采 current → 调 smoke_diff.py → 按 exit 0/1 透传为 gate 的 exit 0/1。**不拥有 QEMU 生命周期**（同 smoke 的 probe-only 假设）。
  - **α-safety 不变量**（最关键）：baseline/current 均为运行时临时产物（`mktemp`/`$TMPDIR`，同机改前/改后两次 smoke 的时序比对），**绝不**引入受版本管理、以具体 machine 命名的 baseline/profile 文件——那是 option-3 明确拒绝的「per-machine expected-profile」（spatial 期望）。本闸门仍是 option-1 背书的 **temporal diff**（机器无关、零 per-machine 知识），范畴内深化不违 ADR。`tests/unit/smoke_regression_alpha_safety.sh` grep 守此不变量。
  - **契约锁**：`tests/unit/smoke_diff_contract.sh` 把真实 judge 产线（source `lib/smoke_assertions.sh` 调每个 judge 捕实际 stdout）喂给 `smoke_diff.py`，断言全部 N 条 ✓/✗ 断言行解析、未解析行数 = 0，防 judge echo 格式被改（前导字符/✓ 渲染/断言名）而 diff 静默假通过。`tests/orchestration/smoke_regression.sh` 用 PATH-stub 注入固定 fixture 断言 gate 链路 exit 0/1/3。
  - smoke 自身仍保持 α 纯报真相、零 per-machine 知识，回归判定归 caller（gate 是 caller 侧工具，非 smoke 行为变化）。
