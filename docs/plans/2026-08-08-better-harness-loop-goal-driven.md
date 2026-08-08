# ob-harness 打分→修复→再打分收敛循环 — Goal-Driven 长程任务提示词

- **Date:** 2026-08-08
- **Source:** `/grilling` 会话共识（grilling design tree，frontier 清空、用户全确认）
- **Target repo / branch:** `/home/iasi/ob-harness` · `better-harness/score-fix-loop-2026-08-08`（从 main `89008b9` 切出）
- **Skill:** `/better-harness:better-harness`（provider `claude`、mode `html`、host-root `.claude/better-harness`）
- **部署方式:** 将下方代码块内的完整提示词贴进一个会话，即启动 goal-driven master/subagent 循环。

## 决策溯源（grilling 共识）

| 决策 | 选择 |
|---|---|
| Q0 已有循环处置 | **F 全新重来**：从当前 main 切新分支重跑；旧分支 `better-harness/score-fix-loop-2026-08-07` 原样留着（已 push origin，安全） |
| Q5 F 的纯度 | **F1 pure greenfield**：不读、不参考旧分支修复，所有修复独立再推导、再验证 |
| Q6 编排 | **α**：master 在本会话驱动循环到收敛，并产出本提示词作为可复用交付物 |
| Q7 停止条件 | 最新 findings ≤ 1，或已产出 5 份报告（第 1 轮基线计为第 1 份）；封顶时未修的记为 residual |
| Q7 修复契约 | Mode A 默认（topology 不 complete 退 Mode B）；每条 verified 一个 commit；触 ob/lib 必跑 ob_check exit 0；verifier 只用 foreground 子 agent |
| Q7 深度/语种 | normal / 中文 / 三域（Session+Project+Agent-Customize）/ 30 天窗口，审阅聚焦当前 main 状态 |
| Q7 批准粒度 | 全程自动 + 每轮 commit，最后一次性 review |
| Q8 交付物 | `.claude/better-harness/loop-summary.md`（中文）+ 本提示词落盘 |

**关键事实（grilling 期间查证）：**
- main `89008b9` 当前**没有** `ob doctor` / `ob test` / `cmd_doctor` / `cmd_test`（grep 实证）→ 全新跑，循环几乎必然把"ob 缺 doctor/preflight""无聚焦校验路由"等重新找出来。这是 F 的确定成本。
- `.claude/better-harness/` 是 gitignore 的（`.gitignore:20`）、host-root 由 skill 固定 → 循环产物不进 git；旧 run 产物已 `mv` 归档到 `.claude/better-harness.archive-2026-08-07/`。
- `/better-harness:better-harness` **无内置循环**——重复打分由外部（即本提示词）驱动；同 outcome 窗口内的修复不复评 5 维 Loop-Effectiveness 分。
- 无名 background sidechain 不连 host client、约 10 分钟失活 → review/verifier 子 agent 必须 foreground。

---

## Goal-Driven 提示词（复制下方代码块部署）

```
你是一个 master agent。你的任务是为下面的目标创建 1 个 subagent，由它全权完成。

【目标（Goal）】
让 /home/iasi/ob-harness 仓库（cwd=/home/iasi/ob-harness，当前 git 分支
better-harness/score-fix-loop-2026-08-08，从 main 89008b9 切出）的 coding-agent harness
达到"经 /better-harness:better-harness 审查后无可执行缺口"的收敛状态，并产出完整可复现
证据。harness 范围 = AGENTS.md / rules/ / .claude/skills/ / .claude/hooks/ / .claude/commands/
/ ob / lib/*.sh / .claude/ 等塑造 agent 行为的产物。

做法：持续跑 /better-harness:better-harness 的"打分 → 按 findings 修复 → 复评"循环，每轮全量
审查（Session + Project + Agent-Customize 三域、normal 深度、30 天窗口、locale 中文），直到
停止条件命中。

边界（subagent 必须遵守）：
- 只改 harness 产物及其测试；不碰无关代码。
- 所有提交只进 better-harness/score-fix-loop-2026-08-08 分支；不动 main、不 git reset/rebase
  已提交产物、不 force-push。
- pure greenfield：不读、不参考旧分支 better-harness/score-fix-loop-2026-08-07 的修复，所有
  修复独立再推导、再验证。
- 触及 ob / lib/*.sh 的修复必须跑 tools/ob_check.sh 且退出码 0（结构 / 函数登记 /
  shellcheck baseline / 测试）。
- review/verify 子 agent 用命名 agent-team 成员或 foreground 派生，绝不派无名 background
  sidechain（~10min 失活）；per-finding verifier 恰好 1 个只读 foreground 子 agent。

【成功标准（Criteria for success）】
以下 4 条全部满足才算成功，每条均可独立客观判定（退出码 / 计数 / 产物存在性）：

1. 收敛停止：最新一轮 .claude/better-harness/findings.json 的 findings.length ≤ 1，或
   .claude/better-harness/runs/ 下已产出 5 份 review 报告（第 1 轮基线计为第 1 份）。
2. ob/lib 守卫：每条触及 ob 或 lib/*.sh 的修复，tools/ob_check.sh 退出码 0。
3. 提交完整性：每条应用并 verified 的修复 ↔ 分支上恰好一个 commit（Conventional Commits，
   scope=owner face，footer "round N, finding <id>"）；partial/blocked 进 backlog 不 commit。
4. 收口产物：.claude/better-harness/loop-summary.md 存在且非空，含每轮 5 维
   Loop-Effectiveness 分 + findings 数轨迹、每条修复 commit↔finding↔verified/partial/
   blocked↔ob_check、停止时 residual findings、停止理由。

上述目标是该 subagent 的最终且唯一目标。subagent 可以把任务拆成更小的子任务，必要时把子任务
分配给自己或其他 subagent，并持续工作，直到成功标准被满足。

【Claude Code 运行约束】

派生方式：派一个命名 agent-team 成员（Agent 工具 name 参数创建可寻址成员 + SendMessage 通信）。
前提：目标会话开启 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1（通常需重启 Claude Code 才生效）；
未开则提示用户重启会话再跑。
- 为何只派命名成员：无名后台 sidechain 不连 host client，工具调用触发
  "PreToolUse hook did not respond before its timeout"、约 10 分钟后失活；命名成员维系 host
  client 连接，不受此影响。

失活判定与恢复（master 在每个 heartbeat tick 探活 subagent 后，按下表处置）：

| subagent 状态 | 判定 | 处置 |
|---|---|---|
| 仍在跑 | 产物 / turn 在推进 | 空转，等下个 tick |
| 失活 | 429 收 failed 通知 / turn 结束 / 产物久不更新 | fresh 重派同名成员（读 state 文件干净起步） |
| 活着、仅 idle | 确证在等输入（罕见） | SendMessage 唤醒 |

> 429 在 Claude Code 里是杀进程（收 failed 通知）、不是挂起，故按失活判定表处置，不做 SendMessage 唤醒。

恢复路径取舍（实测）：优先 fresh 重派。transcript 复活虽保留旧上下文，但对状态化循环是双刃剑——
复活带的 in-context 旧状态可能盖过 state 文件真相、reset 掉已 commit 的产物。若非用复活不可，
唤醒消息须强约束："以 state 文件为权威、先对账再动作、不得动已 commit 的产物"。

你作为 master agent 有三项职责：

1. 派生（spawn）：按上述约束，派生一个命名 agent-team 成员去完成目标。
2. 评估（evaluate）：每当 subagent 宣称完成或失败，你独立验证成功标准是否满足——满足则停止
   所有 subagent；不满足则逼迫该 subagent 继续。验证不止重跑 criteria 谓词，还要双向对账
   交付物完整性：(a) 记录声称的产物真在工作树 / diff 里、commit 非悬空；(b) git 里的实际
   commit 都已被 state 登记。
3. 监控（monitor）：用 durable recurring heartbeat 自驱动；每个 tick 探活 subagent——仍在跑
   则空转、失活则按失活判定表处置、宣称达成则独立验证、终态则 CronDelete 清理并停。

核心循环（durable heartbeat 驱动）：

    派生一个命名 agent-team 成员全权负责目标
    CronCreate 排一个 durable recurring heartbeat（每 5 分钟、off-minute、durable:true）
    每个 heartbeat tick（探活 subagent 后）：
      仍在跑      → 空转退出，等下个 tick
      失活        → 按失活判定表处置（fresh 重派 / 唤醒）
      宣称达成    → 独立验证：重跑 criteria 谓词 + 双向对账交付物完整性
        满足   → summary + CronDelete + 停所有 subagent + 结束
        未满足 → fresh 重派替代成员
    （无论 429 还是 turn 中断，durable heartbeat 都按点唤醒 master 续作）

【持续监控与自愈（durable heartbeat）】

REPL 内 sleep 长轮询的 master 一旦遇到任何中断（429 限流 / 会话关闭重启 / turn 自然结束）监控就
断了、不自动续。改用 Claude Code 原生 durable 调度，持久化到 .claude/scheduled_tasks.json、不随
单次 turn 死。
- 启动时 CronCreate(cron:"<每 5 分钟、避开 :00/:30，如 2-59/5 * * * *>", durable:true,
  recurring:true, prompt:"<自包含 heartbeat：探活 subagent → 按失活判定表处置 / 宣称达成则验
  criteria / 终态则 CronDelete + 停>")。
- 自愈链：任何原因把 master turn 打成 idle → 下个 cron 匹配时 durable tick 触发 → 429 未刷新则
  这 tick 也 429、再 idle、下个 tick 再试，刷新了就续；非额度中断直接续——无需人敲"继续"。
- 边界：tick 仅在会话 idle + 活着时触发；关闭期间不触发但重开补跑；7 天自动过期；终态/手动结束
  必须 CronDelete。

进度记录本（state 文件）：本循环跨多轮、跨 429，必须配 state 文件。最小 schema（原子写）：
{ status, currentRound, lastUpdateEpoch, reportsProduced,
  committedFixes:[{round,findingId,commit,scope}], backlog:[{round,findingId,status,reason}],
  latestFindingsPath, latestFindingsCount }
— lastUpdateEpoch 是 heartbeat 判失活的核心字段，committedFixes 是双向对账的依据。

在成功标准满足前持续驱动 subagent；只有用户从外部手动介入时才结束这个进程。终态时产出一份
summary（每轮计数、commit↔finding 对账、残留缺口、停止原因、ob_check 等守卫结果）。终态或手动
结束时记得 CronDelete 清理 heartbeat，别留遗孤调度。该过程可能消耗大量时间与 token，请确保预算
充足。
```

## 部署建议（goal-driven 模板要求的 tradeoff，由用户自行决定）

- 贴进**全新会话**（推荐）= 贴合模板「空上下文」本意，master agent 从零起循环、durable heartbeat 自愈扛 429。
- 贴进**当前会话** = 现有上下文会被卷入 goal-driven 循环（模板作者警告的 context pollution）。

> 本会话采用 α 路径：master 直接在本会话驱动循环（无需 CronCreate，turn 内连续执行；遇 429 靠 state 文件断点续做），收敛后产出 loop-summary.md 与本提示词。本文件即上述"可部署提示词"交付物，留作日后在新会话复跑之用。
