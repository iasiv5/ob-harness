# `ob test-qemu` baseline 目录按谱系硬路由（不做 contexts→tests 优先级覆盖，归因闭合优先于灵活性）

`ob test-qemu` 定位被测 machine 的 baseline 目录时，曾实现为**优先级覆盖**：
`contexts/baseline/<machine>/`（custom，优先）→ `tests/baseline/<machine>/`（community，
随上游）→ 都缺 exit 3；另在 custom 谱系（source label 或 QEMU binary 为 custom）命中
社区 `tests/baseline/` 时打一条不可消音的谱系 WARN，"安静的唯一出路是数据接管"。
本 ADR 把定位语义改为**谱系硬路由**：community 谱系**只查**`tests/baseline/<machine>/`，
custom 谱系**只查**`contexts/baseline/<machine>/`，各找各的、**不跨谱系回退**，本谱系
目录缺失即 exit 3 + 按谱系指名 remedy。谱系 WARN 随之退役——路由化后"custom 谱系命中
社区基线"的错配不可能出现，无事可警告。

**谱系判定收敛为 source label 单维度**（负责人复盘定调）：label 是唯一权威事实源——
一个 harness 绑定唯一 source（repo.sh source conflict 保护，label 不可变），QEMU binary
目录由 label 派生（`derive_qemu_paths`: `qemu-bin/$label`），provisioning 由 label 分派
（`ensure_qemu_binary` 二分），launch 无 binary override——(label, binary 路径) 在 ob
体系内**完全共线**，binary 路径维度是冗余信号；且它防不住的真威胁恰恰防不住
（`OB_QEMU_BINARY_URL` 指向自编 URL 下载替换 community/ 目录内容时路径不变，路径判定
照样误判 community，反成假安全感）。`test_qemu_lineage` 按字面二值判定；非二值或缺失
（manifest 缺失/字段空，2026-08-18 修订，见 Consequences）→
"unknown"（防御，cmd 层 exit 3，不静默归类）。

决策由仓库负责人定调（2026-08-17）：两目录不是优先级并列，社区基线随 ob-harness 发布
到 upstream、custom 基线不上 GitHub；本地 openbmc 仓库是社区版本时默认查 `tests/baseline/`，
不存在就报错，存在就用该 machine-specific baseline 测；custom 基线同构。这是对
[ADR-0025](0025-test-qemu-baseline-fullstack-per-machine.md)"落点二分"本意的回归：
ADR-0025 说的是"社区机 tests/、custom 机 contexts/"，从未要求优先级覆盖——覆盖是
实现层的发挥，且发挥错了方向。

Status: accepted

References: [ADR-0025](0025-test-qemu-baseline-fullstack-per-machine.md)（落点二分——本 ADR
是其路由语义的精化）；`lib/qemu.sh` derive_qemu_paths / `lib/qemu_binary.sh` ensure_qemu_binary
（label→binary 目录/provisioning 的派生链，单维度判定的共线依据）；[ADR-0017](0017-knowhow-distribution-boundary.md)（`contexts/` 不随上游
分发的边界）；CONTEXT.md `baseline` / `ob test-qemu`（谱系路由术语）；`lib/qemu_commands.sh`
`test_qemu_lineage` / `test_qemu_resolve_baseline_dir`（leaf-pure 路由 helper，protocol 可直测）。

## Considered Options

1. **谱系硬路由（接受）** —— 谱系决定目录，不跨谱系回退。custom build 的 fail 归因恒闭合
   （要么上游基线管社区 build，要么自己的 contexts 基线管 custom build，不存在"custom
   build 拿社区基线测出 fail 却不知归因谁"的中间态）。缺失即 exit 3，remedy 按谱系指名
   应建目录——需求显式化（custom 谱系必须提供 contexts 基线才能测），而不是 WARN 提示
   后放行。

2. **优先级覆盖 + 谱系 WARN（原实现，拒绝）** —— `contexts/` 优先命中使"校准覆盖"成为
   任何谱系可用的捷径：community 谱系也能用 contexts 目录静默改写社区基线的 verdict，
   社区分发的 `tests/baseline/` 结论从此对本机不可信（测的不一定是它）。WARN 只在
   "custom 谱系 × 社区目录"象限告警，管不住"community 谱系 × contexts 覆盖"象限——
   覆盖机制本身制造了归因缺口，WARN 只补了其中一角。

3. **谱系路由 + 覆盖逃生门（如 `--baseline-dir` flag，拒绝）** —— 保留路由默认 + 显式
   flag 跨谱系。拒绝理由：逃生门会重新打开归因缺口（CI 里一个 flag 就能悄悄用社区基线
   测 custom build），且当前无真实用例（YAGNI）；真要跨谱线比对，复制目录到本谱系名下
   即可，动作显式且可审计。

## Consequences

- **custom 谱系的硬需求**：custom build（custom source label，即非
  `github.com/openbmc/openbmc` 的源）必须提供 `contexts/baseline/<machine>/` 才能跑
  test-qemu，缺失 exit 3。remedy 指名目录 +
  README 接入指引（`cp -r` 社区目录起步再校准）。这是把原 WARN 的"数据接管"建议
  升格为前置条件。
- **community 谱系的目录卫生**：`contexts/baseline/<machine>/` 在 community 谱系下不再
  被消费（原实现优先命中）。历史遗留的 contexts 目录（如临时校准实验）不再生效——
  社区 build 的 verdict 只由随上游分发的 `tests/baseline/` 拥有，结论可跨环境复现。
- **谱系判定的边界**：source label 经 `test_qemu_resolve_lineage` strict 读取——manifest
  缺失/source_label 字段空**不 fallback community 而判 unknown**（exit 3 + 按成因 remedy），
  与字面非二值同档 fail-closed 防御（**2026-08-18 修订**：原"经 `read_source_label` 缺失
  fallback community（沿仓库既有口径）"的取舍撤销——写坏有 unknown 强防御、缺失却静默
  community 弱防御，两档不对称是归因缺口：manifest 被外力删除 + 旧 custom 实例存活时，
  社区基线会测 custom build。谱系是 baseline 路由的归因闸门，缺失态 fail-closed。
  `read_source_label` 的 community fallback 本体保留——binary provisioning 等其他消费方
  的缺失默认是 fail-safe 方向，无归因问题，不在本闸门管辖）。manifest 由 `ob init` 写入，
  `derive_source_label` 二值：URL 归一化等于 `github.com/openbmc/openbmc` → community，
  否则 custom。binary 不作为独立信号（与 label 共线，见上）。内容级 binary 替换
  （自编 URL 下载进 community/）超出 label 可判域——provisioning 信任边界问题，不归
  谱系判定管。
- **测试面**：protocol 层直测 `test_qemu_lineage`（3 分支）+ 路由（community/custom
  各自命中、不跨谱系回退、缺失 MISSING、非法谱系值防御）；cmd 层 MISSING remedy 需
  先过 liveness，属 integration（沿既有分层）。
- **可逆性**：从硬路由退回覆盖只需恢复定位序 + WARN，成本低于本变更（无数据迁移）；
  但语义上"社区基线结论可信"一旦确立，退回是产品语义倒退，实际不可逆——正合 ADR
  门槛（surprising：推翻已测试锁定的覆盖行为；real trade-off：归因闭合 vs 灵活性）。

- **future-candidate**：若未来出现"同机双谱系"场景（同一 machine 名下社区与 custom
  build 并存、都要测），当前路由按谱系二选一即可服务（换 build 重跑），无需扩展；
  若出现"custom 基线想回馈上游"的流程需求，走目录级 cp + PR，不走路由层。
