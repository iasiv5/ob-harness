# Bash strict mode 下的管道退出码陷阱

## 元数据

- **类型**: BestPractice
- **适用场景**: 在 `set -euo pipefail`（pipefail）下编写 Bash 脚本的管道命令时
- **创建日期**: 2026-06-22

---

## 目标

写脚本的人在 strict mode（`set -euo pipefail`）下用管道（`cmd | grep ...`、`cmd | awk ...`）时，能避免"管道下游命令无匹配/提前退出返回非零，被 pipefail 当成硬错误导致脚本意外中止"这一类 bug。

## 问题本质

`pipefail` 让管道的退出码 = 最后一个非零的管道组件退出码。`grep` 在无匹配时返回 1、`head` 在提前关闭管道时返回非零、`awk 'cond{exit 1}'` 等都是**预期的控制流信号**，但在 `pipefail` 眼里它们和"命令崩溃"不可区分，于是触发 `set -e` 把整个脚本干掉。

这不是 strict mode 的 bug，是它的设计——pipefail 无法区分"信号性非零"和"失败性非零"。判定权力必须交回给写脚本的人。

## 适用边界

- **适用**：strict mode（至少启用了 `pipefail`，通常还带 `set -e`）下的 Bash 脚本，且管道中存在"可能正常返回非零"的下游命令（grep/awk/head/sed 等）。
- **不适用**：未启用 pipefail 的脚本；或者管道下游命令的非零退出码本身就代表真实失败（如 `curl | jq`，curl 失败应当炸）。

## 处置模式

按"这个非零退出码是不是预期的控制流信号"分三类：

1. **纯布尔判断（最常见）**：用 `grep -q`/`awk` 只想知道"有没有匹配"，非零是正常。用 `if` 包裹或显式 `|| true` 吸收：

```bash
# 坏：无匹配时 grep 返回 1，pipefail 触发 set -e，脚本退出
cmd | grep -q "needle"

# 好：if 把退出码当布尔消费掉
if cmd | grep -q "needle"; then
    echo "hit"
fi

# 好：显式吸收（当你不想分支、只想要副作用）
cmd | grep -q "needle" || true
```

2. **保留输出、允许无匹配**：需要下游的输出，但下游空结果是合法状态。在管道末尾 `|| true`，或单独关闭 pipefail：

```bash
# 需要 grep 的过滤输出，但"过滤后为空"不应是 fatal
cmd | grep "pattern" || true

# 或局部放宽（仅这一段），用完恢复
set +o pipefail
cmd | some_filter
set -o pipefail
```

3. **下游命令的提前关闭**（如 `head -n1`、`sort | head`）：下游提前 close stdin 导致上游收到 SIGPIPE 返回非零。这通常不是错误，用 `|| true` 吸收或 `set +o pipefail` 局部放宽。

## 验收标准

一个无上下文 agent 据此自检 strict mode 脚本：

1. 脚本中每个 `| grep` / `| awk` / `| head` / `| sed` 管道，下游的非零退出码是否被正确处理（`if` 包裹 / `|| true` / 局部 `set +o pipefail`）？
2. 是否存在"裸 `cmd | grep -q`（没有被 if/|| 包裹）"的模式？这类一律是 bug 嫌疑。
3. 局部 `set +o pipefail ... set -o pipefail` 是否成对出现、且范围最小（只覆盖问题管道，不殃及正常管道）？

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|------|------|------|
| 只想着 `set -e` 忘了 `pipefail` | 单独 `set -e` 不炸管道，一旦加 `pipefail` 才炸；排查时容易误判根因 | 判定管道异常先确认 `set -o` 当前状态（`set -o | grep pipefail`） |
| 用 `\|\| true` 一刀切 | 把真实失败的管道（如 `curl` 挂了）也吞掉，隐藏 bug | 仅对"下游非零是预期信号"的管道用；对"上游失败必须 fatal"的管道保留 pipefail 语义 |
| 局部放宽忘了恢复 | `set +o pipefail` 后漏 `set -o pipefail`，后续管道全失去保护 | 局部放宽必须成对，且范围收紧到单条管道；优先用 `\|\| true` / `if` 不动全局开关 |

## 与现有 skill 的关系

- `workflow_01-obmc_env_init.md` 记录的「BitBake `??=` 优先级陷阱」是 strict mode 之外的另一类"看起来赋值了实际没生效"的 shell 相邻陷阱，可互为补充。
