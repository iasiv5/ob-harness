---
name: ai-heartbeat
description: 智能执行 AI Heartbeat 的 observer / reflector，并自动回写状态。
---

# AI Heartbeat (DeepSeek Harness Entry)

这是 DeepSeek Harness 的 `/ai-heartbeat` 斜杠命令入口。本文件只负责 OS 探测和引用执行合同。

## OS 探测

确定当前操作系统对应的 Python 解释器路径（`<PYTHON>`）：

1. 先尝试 `python --version`：如果成功，则 `<PYTHON> = python`
2. 如果 python 不可用，尝试 `.\.venv\Scripts\python.exe --version`：如果成功，则 `<PYTHON> = .\.venv\Scripts\python.exe`
3. 如果两者都不可用，停止并提示用户确保 Python 可用（Linux: 确保 python 在 PATH；Windows: 激活 .venv）

## 执行合同

读取 `periodic_jobs/ai_heartbeat/docs/AI_HEARTBEAT_SOP.md`。

将其中所有 `<PYTHON>` 替换为上面确定的值，然后按完整合同执行。

不要跳过或省略合同中的任何步骤。
