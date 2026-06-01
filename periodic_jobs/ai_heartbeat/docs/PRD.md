# AI Heartbeat: 渐进式披露记忆系统产品需求文档 (PRD)

## 1. 产品概述

### 1.1 愿景
构建一个**Agentic 驱动的、全局统一但按需披露的观测记忆系统**。彻底摆脱由外部脚本“拼凑 Prompt 并喂给 AI”的低级模式，转而让当前 chat 中的 Agent 在接收到简单的“路径与目标”后，自主探索文件系统、分配子任务并提纯观测结果。系统遵循 **Progressive Disclosure** 理念：记忆池是全局的，但 Agent 接收到的上下文始终保持稀疏（Sparse）和高密度（High Density）。

### 1.2 核心价值主张
- **Agentic 自主探索**: 自动化层只负责到期审计和会前提醒；真正的 observer / reflector 由当前 chat 中显式运行 `/ai-heartbeat` 后自主完成。
- **版本化提醒策略**: 仓库通过 `periodic_jobs/ai_heartbeat/config/reminder_policy.json` 定义默认 reminder policy；当前 schema 只保留 `windows_popup_enabled`，不把 UI 偏好混进本地运行态。
- **渐进式披露 (Progressive Disclosure)**: 默认不加载详细记忆，仅由 Agent 根据当前任务逻辑主动检索相关的 L1/L2 观测点。
- **全局分层架构**: 
  - **L3**: 全局硬性约束（存放在 `rules/`，全局被动加载）。
  - **L1/L2**: 动态观测日志（存放在全局记忆池，Agent 主动检索）。
- **抗噪设计**: 利用 AI 的语义理解能力识别真正的“新内容”。例如，针对 300+ 篇 Blog 的格式变动，AI 应通过检查元数据（Metadata）中的创建日期来识别真正的新文章。

### 1.3 目标用户
- **当前 chat 中的 Agent**: 作为记忆的生产者和核心消费者。
- **开发者**: 仅作为系统边界的定义者和记忆日志的最终审计者。

---

## 2. 核心设计原则 (The Agentic Way)

### 2.1 拒绝 Push 模式，拥抱 Pull 模式
传统的系统试图把所有 Context “推送”给模型。本系统要求 Agent 具备“拉取”意识。提醒层只负责说“该做心跳了”，真正的执行命令 `/ai-heartbeat` 负责让 Agent 自己决定读什么、读多少。

### 2.2 记忆稀疏性假设 (Sparse Context Assumption)
我们假设：对于任何给定任务，真正相关的记忆是极少数的。因此，全局记忆池（OBSERVATIONS.md）允许不断增长，但 Agent 必须能够通过标签（Tags）或关键字进行高效的局部加载。

### 2.3 零摩擦资产化
记忆日志采用纯文本追加模式。它不仅是 Agent 的运行状态机，也是开发者的知识资产。

---

## 3. 功能需求：三层分级体系

### 3.1 L3: 全局约束与哲学 (Global Constraints)
- **内容**: 存放于 `rules/SOUL.md` 和 `rules/USER.md`。
- **硬性约束**: 必须包含语言风格约束（不准用大词、不准用营销词、不准用引号、尽量避免 "not" 负向句式）、应对策略等。
- **加载方式**: Session 启动时被动全局加载。

### 3.2 L1: 每日观测与心跳 (Daily Observation)
- **内容**: 过去 24 小时的关键事件、技术决策、真实的错误修复经验。
- **打标格式**: `🔴 High (方法论/约束)`、`🟡 Medium (项目状态/决策)`、`🟢 Low (任务流水)`。
- **产生方式**: 用户在当前 chat 中运行 `/ai-heartbeat`。命令先读取 `heartbeat_preflight.py --command-spec` 的结果，再由 Agent 自主处理（包括读文件、检查 Metadata、过滤噪音和写入观测）。

### 3.3 L2: 记忆蒸馏与反思 (Weekly Reflection)
- **职责**: 垃圾回收。
- **逻辑**: 每周运行，AI 自主读取 L1 记忆池，删除过期的 🟢，合并同主题的 🟡，将共性经验晋升为 🔴。

---

## 4. 关键业务流 (User Story)

### 4.1 显式触发的心跳任务
1. **触发**: SessionStart hook 自动检查 observer / reflector 是否到期，并按仓库 policy 决定提醒 surface。Windows 默认弹出 modal；若 policy 关闭弹窗，则显示一个 8.88 秒自动消失的轻提醒窗。
2. **入口**: 用户在当前 chat 中显式运行 `/ai-heartbeat`。
3. **决策**: 命令先读取 `heartbeat_preflight.py --command-spec`，判断本次应执行 observer、reflector、两者串行，还是无需执行。
4. **执行**: Agent 按目标自主读取文件、过滤噪音、生成观测或执行反思。
5. **幂等**: 若 observer 对应逻辑日期已存在条目，则本次记为 `skipped`，不重复写入。
6. **状态回写**: observer / reflector 的 `success`、`failed`、`skipped` 由 `heartbeat_status_cli.py` 自动记录。
7. **轻提醒窗语义**: 轻提醒窗不写 `last_prompted_on`，不提供“今天不再提醒”；用户点击轻提醒窗时，把 `/ai-heartbeat` 复制到剪贴板。

---

## 5. 技术约束与集成

- **主执行入口**: 仓库级自定义命令 `/ai-heartbeat`。
- **会前提醒挂载点**: `.github/hooks/ai-heartbeat.session-start.json` -> `.github/hooks/pre-session.ps1`。
- **提醒与状态链**: `heartbeat_preflight.py`、`heartbeat_state.py`、`heartbeat_status_cli.py`。
- **提醒策略文件**: `periodic_jobs/ai_heartbeat/config/reminder_policy.json`，schema 只保留 `windows_popup_enabled`。
- **运行态边界**: `heartbeat_status.json` 继续只记录 observer / reflector 的运行态与 prompted 去重，不承载 popup policy。
- **记忆存储**: Markdown 文件（支持 Git 版本控制）。
