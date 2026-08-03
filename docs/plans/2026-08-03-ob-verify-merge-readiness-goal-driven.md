# ob-verify 合并就绪 — Goal-Driven 长程任务提示词

- **Date:** 2026-08-03
- **Source:** `/grill-with-docs` 会话共识（grilling + domain-modeling）
- **Target repo / branch:** `/bmc/iasi/ob-harness-community` · `feat/ob-verify`（领先 main 14 commit、0 behind、可干净 fast-forward）
- **部署方式:** 将下方代码块内的完整提示词贴进一个会话，即启动 goal-driven master/subagent 循环。

## 决策溯源（grilling 共识，D1–D6）

| 决策 | 选择 |
|---|---|
| D1 merge bar | 客观门禁全绿 + 生产代码 review + 重跑 dual-axis 审计 |
| D2 任务形态 | 验证 + 修复推进到达标（非纯验证出报告） |
| D3 修复边界 | 分层授权：test/tools/文档自主；生产代码仅机械修复（强制 ob_check 全绿 + 测试覆盖）；架构级取舍停下等用户 |
| D4 review 客观化 | 双盲 reviewer 共识（≥2/2 无 🔴 BLOCKER，分歧第三票仲裁） |
| D5 ob build | subagent 全权含 build（gb200nvl-obmc 当前未 build） |
| D6 审计范围 | 原 test framework + 本次新增 smoke 测试 |

**关键事实（grilling 期间查证）：**
- 当前静态门禁已绿：`ob_check`（READONLY+SKIP_TESTS）ALL GREEN rc=0 PASS=12。criteria 是"改完仍绿 + 跑完整 run_all 含 integration"，非"修到绿"。
- evidence pack 产自旧仓库 `/home/iasi/ob-harness`（reviewer-prompt-verbatim.txt 的 cwd 仍是旧路径），迁到新 cwd `/bmc/iasi/ob-harness-community`。重跑审计/review 时须校正 cwd——这正是 D1 选"重跑审计"的合理性所在。
- 生产代码改动仅 4 处：`ob`（smoke 注册 + help 的 exit-code OVERRIDE 段）、`lib/qemu_commands.sh`（cmd_smoke + 5 个 `_smoke_probe_*`）、`lib/smoke_assertions.sh`（5 个 `smoke_judge_*`，新增）、`tools/exit_contract.py`（`smoke_assertions.sh` leaf-pure 例外登记，1 行）。
- review 重点盲区（evidence pack 未覆盖）：smoke 把 exit 1 重定义为"α truth"，与全局 `exit-code 契约`（"1=失败，agent 仅 exit 1 回退"）存在张力——agent 见 smoke exit 1 会按主契约当失败回退，但 smoke exit 1 非失败。ADR-0020 的推论，已织入 criteria 4 让双盲 reviewer 独立判定。
- 已知环境约束（非缺陷）：gb200nvl-obmc image 缺 RMCP+ LAN responder，`ob smoke` 其上 IPMI 断言合法 ✗ → exit 1。`smoke_e2e.sh` 已接受该 rc=1 breakdown。验证目标 = smoke_e2e exit 0（接受 α breakdown），非追求 smoke rc=0。

---

## Goal-Driven 提示词（复制下方代码块部署）

```
你是一个 master agent。你的任务是为下面的目标创建 1 个 subagent，由它全权完成。

【目标（Goal）】
让 ob-harness-community 仓库（cwd=/bmc/iasi/ob-harness-community，当前 git 分支 feat/ob-verify，
领先 main 14 commit、0 behind、可干净 fast-forward）的 feat/ob-verify 分支达到可合并 main 的状态，
并产出完整可复现证据。该分支主线是引入 ob smoke 命令（probe-only OOB 探测，ADR-0020）+ 配套
多层测试 + 一份产自旧仓库(/home/iasi/ob-harness)的 dual-axis 审计 evidence pack。验证三条维度：
(1) 客观门禁全绿；(2) 4 处生产代码改动经双盲 reviewer 共识无阻塞级问题；(3) 重跑 dual-axis 审计
（原 test framework + 本次新增 smoke 测试）无未处理阻塞级 finding。

边界（subagent 必须遵守）：
- 修复分层授权：tests/* + tools/* + docs/* 自主改；生产代码（ob、lib/*.sh）仅限机械修复——
  必须同时满足「明确 bug + 有对应测试覆盖 + ob_check 全绿」三条件。架构级取舍必须停下等用户
  确认、不得自作主张，包括：exit-code 契约变更、leaf-pure 纯度调整、prod-layer vs test-layer
  选择、smoke 断言条数/语义变更。
- 不动 main 分支；所有改动在 feat/ob-verify working tree 内 commit 迭代（可回滚）。
- integration 需 firmware image，当前 gb200nvl-obmc 未 build；subagent 自主执行
  ob build gb200nvl-obmc（1-4h 重操作）后再跑 integration。
- 已知环境约束（非缺陷，勿当 bug 修）：gb200nvl-obmc image 缺 RMCP+ LAN responder，ob smoke
  其上 IPMI 断言合法 ✗ → exit 1（α truth，非 smoke 坏）。tests/integration/smoke_e2e.sh 已接受
  该 rc=1 breakdown。验证目标是 smoke_e2e exit 0（接受 α breakdown），不是追求 smoke rc=0。
- 改动 ob / lib/*.sh 后必须跑 bash tools/ob_check.sh 配套自检。

【成功标准（Criteria for success）】
以下 6 条全部满足才算成功，每条均可独立客观判定（退出码 / 全绿 / verdict 计数 / 产物存在性）：

1. 静态门禁：OB_CHECK_READONLY=1 OB_CHECK_SKIP_TESTS=1 bash tools/ob_check.sh 退出码 0。
2. 完整测试：bash tests/run_all.sh --full --integration 报 ALL GREEN；integration 层真实退出码
   经 marker file 确认为 0（不得用 echo $? —— evidence 13 已证 reaped-nohup 会把 rc 误捕为 127）；
   收尾后 workspace/qemu-bin/.pids/ 为空（零残留 QEMU 实例）。
3. exit-contract：python3 tools/exit_contract.py 退出码 0。
4. 双盲 reviewer 共识：spawn 2 个零上下文独立 reviewer subagent（复用
   docs/plans/evidence-test-audit-2026-08-02/reviewer-prompt-verbatim.txt 的方法论与 rubric，
   cwd 校正为 /bmc/iasi/ob-harness-community），审 4 处生产代码改动——ob 的 smoke 注册+help
   （含 exit 1 = α truth 的 OVERRIDE 声明）、lib/qemu_commands.sh 的 cmd_smoke + 5 个
   _smoke_probe_* 原语、lib/smoke_assertions.sh 的 5 个 smoke_judge_*、tools/exit_contract.py
   的 smoke_assertions.sh leaf-pure 例外登记。重点审：smoke exit 1 的 α-truth 语义与全局
   exit-code 契约（"1=失败，agent 仅 exit 1 回退"）的张力是否构成阻塞级问题。成功 =
   ≥2/2 reviewer 判定无 🔴 阻塞级 finding；1-keep/1-drop 分歧 spawn 第 3 个仲裁。
5. 重跑 dual-axis 审计：对原 test framework（tests/* + tools/<gate>）+ 本次新增 smoke 测试
   （tests/{protocol,unit,orchestration,integration}/smoke_*.sh、smoke_diff*.sh、smoke_regression*.sh）
   重跑 over-eng × cov-gap 双轴枚举，产出新 finding 表 markdown（每 finding 5 字段非空 +
   可复现 grep 证据）。成功 = 无未处理 KEEP 级 finding，或所有 KEEP 已 land 修复且 ob_check 复绿。
6. 证据归档：上述全部命令输出、reviewer verdict 原文、审计 finding 表归档到新目录
   docs/plans/evidence-ob-verify-merge-readiness-<date>/，含可复现命令，fresh agent 可重跑复现。

上述目标是该 subagent 的最终且唯一目标。subagent 可以把任务拆成更小的子任务，必要时把子任务
分配给自己或其他 subagent，并持续工作，直到成功标准被满足。

你作为 master agent 有三项职责：

1. 派生（spawn）：创建 subagent 去完成目标。
2. 评估（evaluate）：每当 subagent 宣称完成或失败，你独立判断成功标准是否满足——满足则停止
   所有 subagent；不满足则逼迫该 subagent 继续。独立验证 = 自己重跑 criteria 1-3 的命令、检查
   criteria 4-6 的产物文件存在且内容符合，不要只信 subagent 的自称。
3. 监控（monitor）：每 5 分钟检查一次每个 subagent 的活跃度。若某 subagent 失活，先核实目标状态；
   若仍未达标，重启一个同名 subagent 替代失活的那个。

核心循环（伪码）：

    创建一个 subagent 全权负责目标
    while (成功标准未满足) {
        每 5 分钟检查 subagent 活跃度
        if (subagent 失活 或 宣称已达成目标) {
            独立验证成功标准是否满足（重跑 criteria 1-3 命令 + 检查 4-6 产物）
            if (未满足) → 重启一个替代 subagent
            else        → 停止所有 subagent 并结束
        }
    }

注意：criteria 中涉及「架构级取舍」的修复点（见 Goal 边界清单），subagent 必须暂停并向你
（master agent）报告、由你转交用户，不得自行实施。这是该循环唯一的人工介入闸门。

在成功标准被满足之前，不要停止 subagent；只有用户从外部手动介入时才结束这个进程。
该过程可能消耗大量时间与 token（ob build 1-4h + 多轮 integration + 双盲 review + 审计），
请确保预算充足。
```

## 部署建议（goal-driven 模板要求的 tradeoff，由用户自行决定）

- 贴进**全新会话**（推荐）= 贴合模板「空上下文」本意，master agent 从零起循环。
- 贴进**当前会话** = 现有上下文会被卷入 goal-driven 循环（模板作者警告的 context pollution）。
