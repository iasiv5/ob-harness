# AI Heartbeat Knowledge Base (SOP)

## 0. 高层目标与设计哲学 (The Meta Goal)
- **终极意义**：你不仅仅是一个“文本摘要器”或“Git 日志分析器”。你的终极使命是**帮助系统克服“上下文腐烂（Context Rot）”**。
- **动态降维**：人类每天会产生海量的日志、会议纪要和试错代码。你的工作是从这片混沌中，提纯出真正有持久价值的“认知结晶”，从而让 Agentic 工作流在未来的任务中更加精准。
- **信息密度**：你要像一个资深的架构师一样思考。如果一条信息在未来 3 个月内不会对你或你的主人产生任何复用价值，那就果断丢弃。宁可少记，绝不凑数。

## 1. 核心执行准则 (The Agentic Way)
- **ROOT_DIR**: 所有的路径引用均相对于项目根目录 (`/path/to/your/workspace/`)。
- **文件持久化**: 你不仅仅是回答问题。你的最终交付物是修改文件。
- **自主加载**: 你必须先加载以下全局约束，确保你的行为与项目哲学一致：
  - `AGENTS.md` (工作区全局视图)
  - `rules/` 目录下的所有规范 (L3 约束)
- **当前执行入口**: SessionStart hook 只负责检查是否到期并提醒；真正的 observer / reflector 执行必须由当前 chat 中显式运行 `/ai-heartbeat` 触发。
- **提醒策略**: `periodic_jobs/ai_heartbeat/config/reminder_policy.json` 定义仓库级 versioned reminder policy。它的 schema 只保留 `windows_popup_enabled` 一个开关：开关打开时显示 modal；开关关闭时显示 8.88 秒自动消失的轻提醒窗，点击后复制 `/ai-heartbeat`。
- **状态链**: due-task 判断由 `heartbeat_preflight.py` 和 `heartbeat_state.py` 负责；observer / reflector 的 `success`、`failed`、`skipped` 由 `heartbeat_status_cli.py` 自动回写。

## 2. 扫描与过滤规则 (L1 Observer)

### 2.1 扫描方法论 (Scan Methodology)
- **降低依赖 Git**: 本项目根目录的git不包括所有文件，内部包含大量嵌套的独立 Git 仓库。基于 Git 的全局 Diff 往往无法覆盖所有子模块且逻辑碎片化。但是具体的子模块在确定理解git结构的前提下也可以使用git。
- **推荐工具**: 优先使用系统级的 `find`, `ls` 工具进行扫描。例如：`find . -name "*.md" -type f -mtime -1`。

### 2.2 Blog 内容识别
- **路径**: `contexts/blog/content/`
- **逻辑**: 绝不可仅凭文件变动列表（Git/Find）就判定为新内容。
- **校验**: 必须读取 Markdown Header 中的 `Date` 字段。仅当 `Date` 为今天或当前观测区间时，才视为有效。忽略格式重排导致的旧文章误报。

### 2.3 路径白名单与黑名单
- **忽略**: `contexts/daily_records/` (机械重复性数据)。
- **包含**: `contexts/life_record/` 及其子目录下的 `.csv` 文件。

## 3. 记忆系统分级规范 (Memory Tiering System)

### 3.1 交通灯定义 (Traffic Light Definitions)
观测记录和记忆文件必须严格遵循以下打标逻辑：

- **🔴 High (红色)**：
  - **长效规律与方法论**：跨项目通用的经验，具有极高的重用价值（如“Agent 调研必须启动 sub-agents 并辩论”）。
  - **硬性约束与底线**：必须永久遵守的规则或绝对不能触碰的红线。
  - **核心重构决策**：影响整个系统或项目架构方向的重大决策。

- **🟡 Medium (黄色)**：
  - **活跃项目状态**：当前正在进行的项目的关键技术进展或最新里程碑。
  - **核心技术难点与权衡**：在具体项目实现中遇到的、未来几周内仍需参考的决策背景或指标（如“Vatic V1.2 的 Precision 为 72.3%”）。
  - **架构局部变更**：针对特定模块的非破坏性调整。

- **🟢 Low (绿色)**：
  - **日常任务流水**：具体的执行动作、已经完成的琐碎 Todo（如“修复了某个 typo”、“参加了某次例会”）。
  - **瞬时 Debug 记录**：解决了一个具体报错的过程，但该报错不具备通用的方法论意义。
  - **临时性上下文**：只对当天或当前会话有效的背景信息。

## 4. 持久化规范 (Persistence Standards)

### 4.1 观测记录 (L1 Observer)
- **目标文件**: `contexts/memory/OBSERVATIONS.md`
- **操作**: 采用 **Append-only** 模式。在文件末尾追加最新的日期 Header，并将当日观测点写入。
- **日期格式**: 使用 `Date: YYYY-MM-DD`（Date 首字母大写，冒号后空格，ISO 日期）。
- **格式**: 严格遵循上述红黄绿交通灯 Emoji 格式，每条记录单行化。

### 4.2 反思与晋升 (L2 Reflector)
- **核心目标**: 实现从“短期观测”到“长期规则”的进化。
- **操作文件**:
  1. **规则层 (L3)**: 直接根据最新观测到的有效规律、语言风格变化、以及长效约束，修改或更新 `rules/` 下的核心规则文件 (`SOUL.md`, `USER.md`, `COMMUNICATION.md`, `WORKSPACE.md`)，并在确有必要时更新或新建 `rules/skills/` 下的真实 skill 文档。
  2. **Skills 索引与新增规范**: 当晋升目标落在 `rules/skills/` 下的真实 skill 文档时，必须遵循以下规则：
     - 新增或重写 skill 前，先读 `rules/skills/bestpractice_skill_writing.md`，按目标、验收标准、可用资源和输出规格定义 skill，不要把 skill 写成机械步骤清单。
     - 文件命名建议采用 `<category>_<name>.md`，例如 `workflow_my_process.md`、`bestpractice_my_insight.md`。
     - 修改或新增后，必须同步更新 `rules/skills/INDEX.md`，确保后续 agent 能找到。
  3. **记忆层 (L1/L2)**: 重写 `contexts/memory/OBSERVATIONS.md`。执行垃圾回收，删除已被固化进 rules 的内容以及过期的 🟢 记录。
- **职责**: 确保 `rules/` 始终代表系统的最新“进化状态”。

### 4.3 状态回写与执行边界
- **自动记账**: `/ai-heartbeat` 在 observer / reflector 结束后，必须自动调用 `heartbeat_status_cli.py` 记录 `success`、`failed` 或 `skipped`。
- **observer 幂等性**: 若 `contexts/memory/OBSERVATIONS.md` 中已存在当天 `Date: YYYY-MM-DD` 条目，observer 应记为 `skipped`，而不是重复写入。
- **策略与运行态分层**: `heartbeat_status.json` 只记录 observer / reflector 的运行态与 prompted 去重；`windows_popup_enabled` 属于 versioned reminder policy，不写入本地 state。
- **提醒表面**: 仓库 policy 开启弹窗时，hook 显示 modal；关闭弹窗时，hook 显示 8.88 秒自动消失的轻提醒窗，点击后复制 `/ai-heartbeat`。轻提醒窗不提供“今天不再提醒”的即时交互，也不会写 prompted。
- **执行边界**: hook 不直接执行任何观测或反思动作；它只提醒用户在当前 chat 中运行 `/ai-heartbeat`。

## 5. 执行角色隔离 (Role Isolation)
- **Observer (L1)** 和 **Reflector (L2)** 是独立的任务阶段。
- 在执行 **Observer** 任务时，模型应聚焦于“记录”，不要主动修改 `rules/` 目录。
- 这种隔离是为了防止在观测阶段引入未经人类确认的规则变动。

## 6. 回报机制 (Reporting)
- 在完成文件写入后，你只需在 Chat 中给出一个简短的 Summary（Walkthrough）。
- **Observer 汇报点**: 处理了哪些项目，基于 Metadata 过滤掉了多少噪音。
- **Reflector 汇报点**: 哪些观测点变成了正式规则。
