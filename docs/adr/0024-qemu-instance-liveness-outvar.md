# `QEMU instance` 存活判定：多态返回码 → outvar+恒返回码（消灭 set-e footgun）

`qemu_instance_is_alive` 用退出码 0/1/2 三态编码 running/exited/recycled，在 `ob` 的 `set -euo pipefail`（`ob:4`）下是 footgun：caller 裸调 + 读 `$?` 时，return 1/2 直接 abort，让后续 `qemu_instance_clean_stale` 走不到——已致真实 bug（`tests/orchestration/start_qemu_stale_pid.sh` 锁的就是它；reflector 在 bash 5.2.15 四上下文最小复现全 abort，见 `contexts/memory/OBSERVATIONS.md` L107）。5 个 call site（4 cmd-level `lib/qemu_commands.sh:77/225/318/557` + 1 in-module `lib/qemu_instance.sh:89`）中 4 个被迫 `if`-wrap / `|| rc=$?`，3 处重复防御注释，最新加入的 旧 smoke 命令 又复制一遍。CONTEXT.md `modified recipe selection` 旁注已把 0/1/2 判为「多态返回码在 strict mode 下有踩坑先例」，较新模块（`machine_selection_guard`、`modified recipe selection`）已 deliberately 改用 outvar+恒返回码规避——但 `is_alive` 这个先例本身一直没迁。经 `/pick-one-arch-task` → `/codebase-design` design-it-twice（拆分布尔 vs outvar 状态）→ `/grill-with-docs` 三轮决策，本 ADR 决定**完成迁移**：抽 leaf-pure `qemu_instance_liveness <machine> <outvar>`（`printf -v` 写 `running`/`exited`/`recycled`/`nopid`，恒 return 0），吸收 `qemu_instance_load`+probe 两步，私有化原 0/1/2 body 为 `_qemu_instance_probe_alive`。对齐同仓 `machine_selection_guard`（`lib/machine_selection_guard.sh`，`printf -v` + 恒 0）范式。

Status: accepted

References: CONTEXT.md `QEMU instance` / `function semantic layer` / `machine selection guard`；`lib/machine_selection_guard.sh`（outvar+恒0 范式）；[ADR-0021](0021-qemu-restart-port-reuse.md) / [ADR-0022](0022-port-reuse-resolver-module.md)（同 QEMU 簇）；[ADR-0023](0023-defer-smoke-assertion-runner.md)（防循环推荐 ADR 先例）；bestpractice_10 形态 D（instance best-effort 恒 rc 0）。

## Considered Options

1. **outvar+恒0（接受）** —— 单一 `qemu_instance_liveness <machine> <outvar>` 写 4 状态字符串、恒 return 0。结构性消灭 set-e abort 这类 bug（不是靠约定防御）；吸收 load+probe 两步舞（4 cmd caller 都先 load 再 is_alive）；`nopid` 成一等状态。代价：5 call site + 3 测试改；always-0 吞 probe 级异常；`PIDFILE_*` 成隐式副通道（见 Consequences 处置）。

2. **拆分布尔（拒绝）** —— `qemu_instance_is_alive`(布尔 0/1) + `liveness_detail`(三态 0/1/2 诊断)。4 call site 零改动、1 改名，churn 最小。拒绝理由：诊断函数**公开面仍留**被术语表点名的多态返回 footgun，第 6 个 caller 够到它就重现 abort——是半截治理（confinement 而非消灭），与 CONTEXT.md L195 判定冲突。design-it-twice 进一步 reframe：所谓「4 个布尔 caller」其实是 3 路（nopid/stale/running），A 把它劈成 `load()`+`is_alive()` 两步；B 的 `case` 是这些 caller 本就想要的形状，不是语法税。

3. **不动（拒绝）** —— 保留 0/1/2 公开接口，只还 call site 注释债。拒绝理由：friction 在复发（旧 smoke 命令 刚复制 if-wrap 注释），且与 CONTEXT.md L195 的术语判定正面冲突——要么迁（→选项1），要么推翻术语判定（grilling 无人主张）。

## Consequences

- **接口形态（grilling 定型）**：(Q2) 吸收 load——`<machine>` 入参，内部 `qemu_instance_load`+probe，`nopid`=load 失败/无记录；(Q3) 4 状态不加 `unknown`——无 caller 消费「判不准」信号（全当 stale 清），加它是 YAGNI，**corrupt/空字段 PID 需修**（评审 🔴1 揭示）：今天空字段（pid/binary/machine 空）误返 rc 0——空 string 是任意 cmdline 子串致 `[[ "$cmdline" != *""* ]]` 恒 false → false running；新 `_qemu_instance_probe_alive` 在 `/proc` 检查前加有效性防线（pid 非空且 `^[0-9]+$`、binary/machine 非空，否则 return 1）→ `exited` + `clean_stale`。bug 修正，非行为保持；(Q4) 字符串值（对齐 `machine_selection_guard` 的 `empty/nontty/ok`）；(Q6) 私有 `_qemu_instance_probe_alive` 保留 0/1/2 body 作内部 seam（leaf-pure，不污染公开面）。

- **`PIDFILE_*` 副通道（Q5）**：吸收 load 使 liveness 填 ~10 个 `PIDFILE_*` 全局。处置为**隐式 + 不变量 doc + nopid 路径主动清空**：函数注释写明「non-nopid 下 `PIDFILE_*` 已填、nopid 下已清空」。caller 在 `running` 分支立即读 `PIDFILE_SSH_PORT` 等（端口复用）/ `PIDFILE_PID`（kill）是预期数据流，非隐藏耦合；拒绝显式 second outvar（回填 ~8 字段的接口膨胀 + parse 脆弱 > 收益）。

- **exit_contract**：`qemu_instance.sh` basename 仍登记 leaf-pure（Y 白名单 `set()`）——`liveness` 恒 return 0、绝不 exit，契约不变；新增 `_qemu_instance_probe_alive` 私有，不影响 basename 契约。

- **测试（replace-don't-layer，实施计划落地）**：`tests/unit/ports.sh` 删除旧 is_alive rc 断言（liveness 接 `<machine>`，不再适用 ports.sh 的 /proc 合成 PID 直调测法）；`liveness` 四状态覆盖迁到 `tests/unit/qemu_instance.sh`（已 stage PID 文件的天然测试床），含 corrupt/空字段防线断言 + 四状态恒 return 0（rc 经 `_rc=0; ... || _rc=$?` 立即保存，running 造真实 fake 进程覆盖 probe cmdline 匹配、不用 stub）；`tests/unit/qemu_instance.sh` 的 `summarize_brief` stub（line 58 stub `is_alive`）改 stub `liveness`；旧 surface 结构测试 的结构 grep（`is_alive`/`load` in 旧 smoke 命令 body）改 grep `liveness`。`tests/orchestration/start_qemu_stale_pid.sh` 保持绿——footgun 已结构性不可能，它从「锁 live bug」变「锁 defense-in-depth」。新增 `liveness` 公开接口的 4 状态 unit（stage PID：无文件→`nopid` / `99999999`→`exited` / `$$`→`recycled` / 恒 return 0 含 bare-call set-e 安全契约）。

- **防循环推荐**：本 ADR 锁住「为什么私有化 `is_alive` 而非保留双公开名（选项2）」——未来 explorer 看到 `liveness` 恒0+outvar、旁边私有 probe 却留 0/1/2 时，**不应视为待办疏漏**（见本 ADR；同 [ADR-0023](0023-defer-smoke-assertion-runner.md) 防循环模式）。

- **CONTEXT.md 维护**：`QEMU instance` 条目补存活状态取值（`running`/`exited`/`recycled`/`nopid`，纯领域、不含 outvar 实现细节）；`modified recipe selection` 旁注 L195 的「踩坑先例（is_alive 0/1/2）」更新为「已迁出闭环，见 ADR-0024」；`重启 (restart)`（L92）与 smoke suite 前身词条（L191,现为 `smoke suite`）里的 `qemu_instance_is_alive` 函数名引用改为概念表述（存活状态 `running` / 非 `running`）——顺带偿还函数名泄漏进术语表的债。保留 L195 作反面教材的警示价值。

- **可逆性**：迁回 0/1/2 公开接口要改回 5 call site + 恢复 `is_alive` 公开名 + 还原 3 测试——成本不低，且会重新引入已消灭的 footgun（不推荐）。

- **future-candidate**：(1) 若出现第 6 个需要 exited-vs-recycled 区分的 caller，评估 `unknown`/probe-error 状态是否届时有消费方；(2) `PIDFILE_*` 副通道若在 nopid 误读上出过 bug，再评估显式 second outvar。
