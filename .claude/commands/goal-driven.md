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
你在 Claude Code 里派生 subagent 时，**必须用 agent-team feature 派生一个命名成员**（Agent 工具 `name` 参数创建可寻址成员 + SendMessage 通信），**不要派生无名后台 sidechain**：无名后台 sidechain 不连接 host client，工具调用会触发 `PreToolUse hook did not respond before its timeout (host client may be unreachable)`、约 10 分钟后失活；命名 agent-team 成员作为队友维系 host client 连接，不受此影响（实测对照：命名成员连读 4 个文件约 19 秒完成，无名 sidechain 卡约 10 分钟失活）。前提：目标会话需开启 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`，未开启则先开启再启动循环。失活处理：用**相同 `name`** 重新派生一个替代成员，或用 SendMessage 从其 transcript 复活——比无名 sidechain 的「心跳 + 重启」更稳。

你作为 master agent 有三项职责：

1. **派生（spawn）**：按上述 Claude Code 运行约束，派生一个**命名 agent-team 成员**去完成目标。
2. **评估（evaluate）**：每当 subagent 宣称完成或失败，你独立判断成功标准是否满足——满足则停止所有 subagent；不满足则逼迫该 subagent 继续。
3. **监控（monitor）**：每 5 分钟检查一次每个 subagent 的活跃度。若某 subagent 失活，先核实目标状态；若仍未达标，**重启一个同名 subagent 替代**失活的那个。

核心循环（伪码）：

    派生一个命名 agent-team 成员全权负责目标
    while (成功标准未满足) {
        每 5 分钟检查 subagent 活跃度
        if (subagent 失活 或 宣称已达成目标) {
            独立验证成功标准是否满足
            if (未满足) → 重启一个替代 subagent
            else        → 停止所有 subagent 并结束
        }
    }

**在成功标准被满足之前，不要停止 subagent；只有用户从外部手动介入时才结束这个进程。** 该过程可能消耗大量时间与 token，请确保预算充足。

---

## 第三步：交付

输出第二步的完整提示词文本后，附下面这行 tradeoff 提示，**让用户自行决定**部署到哪里——不替用户决定，绝不自动接管成 master agent：

> 部署建议：贴进**全新会话**（推荐）= 贴合模板「空上下文」本意；贴进**当前会话** = 现有上下文会被卷入 goal-driven 循环（即模板作者警告的 context pollution）。
