# Goal-Driven Prompt Assembler (Claude Code Entry)

这是 Claude Code 的 `/goal-driven` slash command 入口。

它是一个**模板组装器（纯生产者）**：把 lidangzzz Goal-Driven 提示词模板，结合用户当场的 goal 与 criteria，组装成一份可直接部署的完整提示词文本。**组装器本身不运行 master/subagent 循环**——循环由用户把产物粘进目标会话后自行启动。

## 第一步：进料——拿到合规的 goal + criteria

1. **优先从用户随命令给出的信息里识别** goal 与 criteria（可能是命令参数，也可能是一段同时含目标与标准的描述，用户或用「验收标准：」「criteria:」之类分隔）。
2. **任一缺失、或无法提炼成规范的 goal/criteria，就分两步交互追问用户（一次只问一个）**：
   - 先问：当前的 **goal** 具体是什么？
   - 再问：这个 goal 的**验收标准（criteria）**是什么？
3. **可验证性门禁**——这是判定「规范」的唯一标准：
   - **goal** 必须是「具体交付物 + 边界」：一个 subagent 能分解、能推进、能收敛的东西。反例（不合规）：「优化代码」「探索一下」——没有交付物。正例：「用 Rust 实现一个支持这 N 条 SQL 子集的 SQLite」。
   - **criteria** 必须含**至少一条可客观判定的谓词**：能跑出 0/1 退出码、测试套件全绿、构建零 warning、指标达阈值、输出匹配某 spec。反例（不合规）：「代码干净、架构优雅」——无可判定谓词。正例：「`make test` 全通过，且二进制以 0 warning 构建」。
   - 理由：Goal-Driven 循环唯一诚实的终止条件，是 master agent 能独立验证 criteria 已满足；criteria 不可验证，循环要么永不停止、要么自欺达标。
4. **不合规时引导改写，不要空白重问**：针对不合规的那个字段，主动提议一个**可验证的改写**，让用户确认或微调。例如把「代码干净」改写为「`make test` 全通过 + 0 warning 构建」，请用户拍板。

## 第二步：组装——填入模板正文

用第一步得到的实际 goal、criteria **替换**下面模板两处 `[[[[[ ]]]]]` 占位，输出替换后的完整提示词文本。模板按 lidangzzz/goal-driven 的结构复述（来源 https://github.com/lidangzzz/goal-driven ；上游未声明 license，本模板为按结构自主复述，非逐字搬运）：

---

你是一个 **master agent**。你的任务是为下面的目标创建 **1 个 subagent**，由它全权完成。

**【目标（Goal）】**
[[[[[ 在这里替换为用户给出的 goal ]]]]]

**【成功标准（Criteria for success）】**
[[[[[ 在这里替换为用户给出的 criteria ]]]]]

上述目标是该 subagent 的**最终且唯一目标**。subagent 可以把任务拆成更小的子任务，必要时把子任务分配给自己或其他 subagent，并持续工作，直到成功标准被满足。

**【Claude Code 运行约束——派生方式】**
你在 Claude Code 里派生 subagent 时，**必须用 agent-team feature 派生一个命名成员**（Agent 工具 `name` 参数创建可寻址成员 + SendMessage 通信），**不要派生无名后台 sidechain**：无名后台 sidechain 不连接 host client，工具调用会触发 `PreToolUse hook did not respond before its timeout (host client may be unreachable)`、约 10 分钟后失活；命名 agent-team 成员作为队友维系 host client 连接，不受此影响（实测对照：命名成员连读 4 个文件约 19 秒完成，无名 sidechain 卡约 10 分钟失活）。前提：目标会话需开启 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`，未开启则先开启再启动循环。失活处理：用**相同 `name`** 重新派生一个替代成员，或用 SendMessage 从其 transcript 复活——比无名 sidechain 的「心跳 + 重启」更稳。**两种恢复路径的取舍（实测）**：transcript 复活保留旧上下文，对**状态化循环**（带断点 state 文件、跨 429/多 turn）是双刃剑——复活的 in-context 旧状态可能盖过 state 文件真相、并在「整理」时 reset 掉已 commit 的产物（曾发生：复活 driver 把已修 commit reset 成悬空、记录仍标 verified）。这类情况优先 **fresh 重派**（读 state 文件干净起步）；若用复活，唤醒消息须强约束「以 state 文件为权威、先对账再动作、不得动已 commit 的产物」。**429/turn-end 一律按失活处理 → fresh 重派**：Claude Code 里 429 是杀进程（收 `failed` 通知）、不是挂起，故不做 SendMessage 唤醒；仅当确证进程仍活着、只是 idle（如等输入）时才 SendMessage 唤醒（实操罕见）。另：`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` 多需重启 Claude Code 生效，运行中的会话未必能就地 toggle——未开启则提示用户重启会话再跑，勿假定可就地修。

你作为 master agent 有三项职责：

1. **派生（spawn）**：按上述 Claude Code 运行约束，派生一个**命名 agent-team 成员**去完成目标。
2. **评估（evaluate）**：每当 subagent 宣称完成或失败，你独立判断成功标准是否满足——满足则停止所有 subagent；不满足则逼迫该 subagent 继续。**独立验证不止于重跑 criteria 谓词，还要双向对账交付物完整性**：既查记录声称的产物真在工作树/diff 里、commit 非悬空（实测：记录全绿但产物被 reset 缺失），也反向查 git 里的实际 commit 都已被 state 登记（实测：429 死前提了 commit 却没 checkpoint 进 state，git>state 滞后）。
3. **监控（monitor）**：用 **durable recurring heartbeat** 自驱动（机制与「为何禁 REPL `sleep`」见下「持续监控与自愈」）；每个 tick 探活 subagent——仍在跑则空转、失活则 fresh 重派、宣称达成则独立验证、终态则 CronDelete 清理并停。

核心循环（伪码，durable heartbeat 驱动）：

    派生一个命名 agent-team 成员全权负责目标
    CronCreate 排一个 durable recurring heartbeat（每 5 分钟、off-minute、durable:true）
    每个 heartbeat tick（durable 按点触发，非 REPL sleep）：
      subagent 仍在跑                                   → 空转退出，等下个 tick
      subagent 失活（429 终止/turn 结束/failed 通知/产物久不更新） → fresh 重派同名 subagent（读 state 续做）
      subagent 宣称已达成 → 独立验证：重跑 criteria 谓词 + 双向对账交付物完整性
        满足   → 产出 summary + CronDelete 清理 + 停止所有 subagent + 结束
        未满足 → fresh 重派替代 subagent
    （无论 429 还是 turn 中断，durable heartbeat 都按点唤醒 master 续作）

**【持续监控与自愈（durable heartbeat）】**
REPL 内 `sleep` 长轮询的 master 一旦遇到任何中断——5h rolling 额度撞 429（master 与 subagent 共用账号、同时被限流）、会话被关掉/重启、master turn 自然结束——监控就断了、不自动续。改用 Claude Code 原生 durable 调度（CLI 与 VS Code 均可用，**不依赖 `claude -p`**，已 PoC 验证 idle 后按点触发），持久化到 `.claude/scheduled_tasks.json`、不随单次 turn 死：无论有没有额度限制，都让监控扛得住中断。

- **启动时** `CronCreate(cron:"<每 5 分钟、避开 :00/:30，如 2-59/5 * * * *>", durable:true, recurring:true, prompt:"<自包含 heartbeat：探活 subagent→idle 则 SendMessage 唤醒/失活则重派/宣称达成则验 criteria/终态则 CronDelete+停>")`。
- **自愈链**：任何原因把 master turn 打成 idle（429 限流 / 会话打断 / turn 结束）→ 下个 cron 匹配时 durable tick 触发 → 若是 429 且额度没刷新，这 tick 也 429、再 idle、下个 tick 再试，刷新了就续；若是非额度中断，直接续 → **无需人敲「继续」**。
- **边界**：tick 仅在会话 idle+活着时触发；关闭期间不触发但重开补跑；7 天自动过期；终态/手动结束必须 `CronDelete`。
- **进度记录本（state 文件）是否需要，由 master 按 goal 形态自评，不强制**：criteria 每次可重跑、subagent 进度在代码/git/产物里、agent-team 同名成员自带上下文——满足这些的短循环可不配 state 文件；但跨 429/多 turn 的长循环里 in-context 状态不可靠（实测：429 击杀后上下文丢失，靠 state 文件才断点续做），这种情况建议配 state 文件（原子写 + schema 一致性）。建议最小 schema（原子写）：`{ status, currentRound, lastUpdateEpoch, reportsProduced, committedFixes:[{round,findingId,commit,scope}], backlog:[{round,findingId,status,reason}], latestFindingsPath, latestFindingsCount }`——`lastUpdateEpoch` 是 heartbeat 判失活的核心字段，`committedFixes` 是双向对账的依据。

**在成功标准被满足之前，不要停止 subagent；只有用户从外部手动介入时才结束这个进程。** 终态时产出一份 summary（每轮计数、commit↔finding 对账、残留缺口、停止原因、ob_check 等守卫结果）。终态或手动结束时记得 `CronDelete` 清理 heartbeat，别留遗孤调度。 该过程可能消耗大量时间与 token，请确保预算充足。

---

## 第三步：交付

输出第二步的完整提示词文本后，附下面这行 tradeoff 提示，**让用户自行决定**部署到哪里——不替用户决定，绝不自动接管成 master agent：

> 部署建议：贴进**全新会话**（推荐）= 贴合模板「空上下文」本意；贴进**当前会话** = 现有上下文会被卷入 goal-driven 循环（即模板作者警告的 context pollution）。
