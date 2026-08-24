# CodeQL 告警修复：先拿污点路径，再定点切断

## 元数据

- **类型**: BestPractice
- **适用场景**: CI（GitHub Code Scanning / CodeQL）报 security 告警（如 `py/clear-text-logging-sensitive-data`），要修复时
- **创建日期**: 2026-08-24
- **来源**: PR #46 三轮 CI 返工教训（probe_console.py clear-text logging #4/#5）

## 目标与边界

- **目标**: 一次修对 CodeQL 告警，不靠盲改烧 CI 轮次。
- **边界**: 针对"数据流类"告警（taint tracking：cleartext logging、SQL injection 等）。非数据流类告警（如 license、dead code）不适用本方法论。

## 核心判定（结果导向）

修复完成的验收标准：**告警对应的污点路径中，源值不再流入汇**——要么源头不产生、要么中间不传递、要么汇不再输出。而不是"我加了 sanitize / 加了豁免注解"。

## 可用资源与边界

- **污点路径获取**：GitHub PR 告警页 → 告警详情 → "Show paths"，逐步列出 源(source)→中间节点→汇(sink) 的文件:行号。这是修复的第一手证据，向用户要或让用户贴出。
- **本地复现**（可选）：CodeQL CLI 从 `github.com/github/codeql-cli-binaries` 下载（agent 环境下载外部二进制需用户批准）。

## 已知陷阱（全部真实踩过，PR #46）

| 陷阱 | 表现 | 应对 |
|------|------|------|
| **CodeQL 按名字定源，不看值** | `os.environ.get("OB_TQ_CONSOLE_PASSWORD_PROMPT")` 值只是 `"Password:"` 提示符文本，仍被判为 password 敏感源 | env 变量名含 PASSWORD/TOKEN/SECRET 即视为源；其值不进任何日志/输出拼接 |
| **行内豁免注解不可靠** | `# codeql[py/clear-text-logging-sensitive-data]`（裸注解独占行/行尾都试过）在本仓 default-setup 下不生效，告警照报 | 别把注解当修复手段；修不动时让用户在告警页手动 dismiss 并注明理由 |
| **regex/replace 净化是污点保持** | `text.replace(secret, "<redacted>")` 对 CodeQL 无法证明净化，taint 依旧 | 净化逻辑作为纵深防御可以留，但别指望它消告警 |
| **盲改可能加重污点** | 把 password 传进净化函数（`_emit(..., secrets=(user, password))`），反而为 password 新增一条流入打印值的路径 | 修复前先明确路径；改动不应让敏感值更靠近输出 |
| **告警位置随编辑漂移** | 注解放错行导致"看似对准"，实际 sink 表达式行号随代码编辑移动 | 以告警页 Show paths 的 sink 行为准，不以 snippet 首行为准 |

## 方法论建议

修复顺序（建议，非硬性）：

1. 拿到告警先取污点路径（Show paths），确认 **source 是哪个变量、为什么敏感**（往往是名字，不是值）。
2. 选最上游的可切断点：通常是把源值从字符串拼接/日志参数里拿掉，同时保留诊断语义（如报 stage 名而非配置值）。
3. 确实是误报且切不断时，向用户说明并建议手动 dismiss，而不是堆注解。

## 输出规格

- 修复 commit message 里写清污点路径（源行→汇行）与切断点，方便 review 和下次检索。
- 通用教训同时存 agent memory（本仓实践见 memory `feedback-codeql-cleartext-taint-path-first`）。
