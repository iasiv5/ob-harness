# ob-harness

```raw
      ██████╗ ██████╗ ███████╗ ███╗   ██╗ ██████╗ ███╗   ███╗ ██████╗
     ██╔═══██╗██╔══██╗██╔════╝ ████╗  ██║ ██╔══██╗████╗ ████║██╔════╝ 
     ██║   ██║██████╔╝█████╗   ██╔██╗ ██║ ██████╔╝██╔████╔██║██║      
     ██║   ██║██╔═══╝ ██╔══╝   ██║╚██╗██║ ██╔══██╗██║╚██╔╝██║██║      
     ╚██████╔╝██║     ███████╗ ██║ ╚████║ ██████╔╝██║ ╚═╝ ██║╚██████╗ 
      ╚═════╝ ╚═╝     ╚══════╝ ╚═╝  ╚═══╝ ╚═════╝ ╚═╝     ╚═╝ ╚═════╝ 
     ██╗  ██╗  █████╗  █████╗   ███╗   ██╗ ███████╗ ███████╗ ███████╗ 
     ██║  ██║ ██╔══██╗ ██╔══██╗ ████╗  ██║ ██╔════╝ ██╔════╝ ██╔════╝ 
     ███████║ ███████║ ██████╔╝ ██╔██╗ ██║ █████╗   ███████╗ ███████╗ 
     ██╔══██║ ██╔══██║ ██╔══██╗ ██║╚██╗██║ ██╔══╝   ╚════██║ ╚════██║ 
     ██║  ██║ ██║  ██║ ██║  ██║ ██║ ╚████║ ███████╗ ███████║ ███████║ 
     ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝  ╚═══╝ ╚══════╝ ╚══════╝ ╚══════╝ 
    ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
    ┃      OpenBMC Development Environment · ob-harness · 𝓲𝓪𝓼𝓲      ┃
    ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

OpenBMC 固件开发工作台。`ob` CLI 覆盖环境初始化、镜像构建、工作区状态管理和 QEMU 仿真；内置 AI Agent 上下文框架，用 Claude Code 或 GitHub Copilot 等任意 Coding Agent 打开仓库即可用自然语言驱动开发任务。

## 开始

> **前提条件**：Linux + `git` + `python3` + 100+ GB 磁盘 + 网络访问 OpenBMC Git 服务器（社区版：[GitHub](https://github.com/openbmc/openbmc.git)）

```bash
git clone https://github.com/iasiv5/ob-harness.git
cd ob-harness
```

## 场景索引

| # | 场景 | 脚本命令 | AI prompt |
|---|------|---------|-----------|
| 1 | 初始化 machine 开发环境 | `./ob init [machine]` | "帮我初始化 romulus 的开发环境" |
| 2 | 构建固件镜像 | `./ob build` | "帮我构建 romulus 的镜像" |
| 3 | 查看工作区状态 | `./ob status` | "看看环境状态" |
| 4 | 排查构建失败或运行异常 | — | "bitbake 编译报错了" |
| 5 | 设计新功能或讨论方案 | — | "帮我设计一个 sensor 监控接口" |
| 6 | 把设计方案拆成可执行任务 | — | "把这个设计拆成任务" |
| 7 | 给仓库添加新的自动化能力 | — | "帮我写一个新的 skill" |
| 8 | 在 QEMU 中启动 BMC 实例 | `./ob start-qemu [machine]` | "在 QEMU 里启动 romulus" |
| 9 | 停止 QEMU 实例 | `./ob stop-qemu [machine\|--all]` | "停掉 romulus 的 QEMU" |

> **提示**：不需要记忆上面的 AI prompt。直接用自然语言描述需求，agent 会自动匹配对应的能力。

## 入口 1：AI Agent

用 Claude Code 或 GitHub Copilot 打开本仓库，在输入框里直接描述需求即可。

### 工作原理

- **Session 启动**：agent 自动读取项目规则（身份、沟通风格、目录路由、技能索引），理解仓库上下文
- **能力路由**：遇到“怎么做 X”时，agent 先查技能索引再行动，而不是凭猜测
- **ob 优先**：所有 OpenBMC 环境动作（初始化、编译、状态、QEMU 起停）统一走 `ob` 这个前门——agent 先查 `ob --help`，有就走 `ob <cmd>`，不绕过手撸 bitbake。退出码 `3` 是「前置缺失」不是失败，agent 会照提示补前置再重试，所以你常看到它「遇错重试」而非「报错停下」。
- **质量闭环**：`ob` 的改动由四层测试（protocol / unit / orchestration / integration）+ 质量门禁（exit 契约 / `ob_check` / 覆盖率雷达）兜底，GitHub Actions CI 自动跑。
- **文档落盘**：设计文档和实施计划自动归档到 `docs/`，可追溯可回查
- **记忆积累**：通过 `/ai-heartbeat` 让 AI 持续学习项目变化和团队决策
- **决策公理**：从团队经历中提炼的决策原则，辅助深度分析

入口配置在 `AGENTS.md` 和 `.github/copilot-instructions.md`，感兴趣可以翻看源码。

## 入口 2：ob CLI

不想用 agent？`ob` 可以完全独立运行——**不消耗 token、不需要 agent 参与**，适合确定性的重复操作或想省 token 的场景。支持两种用法：

- **交互式菜单**：不带参数运行 `./ob`，进入命令的交互选择界面
- **CLI 模式**：带参数运行，直接执行指定命令（便于脚本化）

```raw
./ob [command] [options] [arguments]

Commands:
  init         [<machine>]    初始化 OpenBMC 开发环境
  build        [<machine>]    构建已初始化 machine 的镜像（省略则交互选择）
  status                      查看工作区源码绑定状态
  start-qemu   [<machine>]    用已构建的镜像在 QEMU 中启动 BMC
  stop-qemu    [<machine>]    停止运行中的 QEMU 实例

Global Options:
  -d, --dry-run         预览操作但不执行
  -s, --skip-deps       复用已有 deps.json，跳过依赖解析（仅 init）
  -u, --url <url>       使用自定义 OpenBMC 仓库 URL（仅 init）
  -v, --verbose         详细输出
  -h, --help            显示帮助

start-qemu Options:
  --ssh-port <port>       SSH 端口转发    (默认 2222)
  --redfish-port <port>   Redfish 端口转发 (默认 2443)
  --ipmi-port <port>      IPMI 端口转发    (默认 2623, UDP)
  --http-port <port>      HTTP 端口转发    (无默认，设置即启用)
  --serial-log <path>     串口日志路径     (默认 ~/tmp/qemu-<machine>-serial.log)
  --no-wait               不等待 BMC 就绪
  --force                 不确认直接杀掉已有实例

stop-qemu Options:
  --force                 不确认直接停止
  --all                   停止所有运行中的 QEMU 实例

Exit Codes:
  0   成功（或良性无操作）
  1   失败 — 损坏或用法错误（如未知选项）
  2   用户取消（不算失败）
  3   前置缺失（如 machine 未初始化 / 未构建）；按提示用 ob 补前置后重试

Environment Variables (优先级低于命令行选项):
  OB_OPENBMC_URL        非交互指定 OpenBMC 仓库 URL
  OB_QEMU_SSH_PORT      SSH 端口覆盖
  OB_QEMU_REDFISH_PORT  Redfish 端口覆盖
  OB_QEMU_IPMI_PORT     IPMI 端口覆盖
  OB_QEMU_HTTP_PORT     HTTP 端口覆盖
  OB_QEMU_SERIAL_LOG    串口日志路径覆盖
  OB_QEMU_BINARY_URL    自定义 QEMU binary 下载 URL
  OB_NPM_REGISTRY       覆盖 npm registry URL（置空可禁用自动检测）

Examples:
  ob init                          # 列出 machine 交互选择
  ob init romulus                  # 初始化 romulus
  ob build romulus                 # 非交互构建 romulus
  ob start-qemu romulus            # 在 QEMU 中启动 romulus
  ob start-qemu romulus --ssh-port 22223
  ob stop-qemu romulus             # 停止 romulus 的 QEMU 实例
  ob stop-qemu --all               # 停止所有运行中的实例
```

## 致谢

本项目受 [grapeot (Yan Wang / 鸭哥)](https://github.com/grapeot) 的 [context-infrastructure](https://github.com/grapeot/context-infrastructure) 项目启发并基于其架构思路构建。感谢鸭哥在 AI 上下文工程领域的开创性探索。

## 版本历史

### v1.3 — 开发中 (unreleased)

**🏗 架构演进**
- `ob` 模块化：单文件拆为 `lib/{util,repo,qemu,machine_state,init_pipeline,commands}.sh` 六文件，按职能切分（结构边界从注释锚点转为文件名）。
- 新增 `machine_state` 模块，统一 machine 生命周期状态。

**⚠️ Breaking**
- `openbmc-source.lock` → `openbmc-source.manifest`（source manifest）；`<machine>.lock` 命名废弃，旧脚本需适配（术语见 `CONTEXT.md`）。

**✨ 新增**
- `tools/cache_hit_rate.py`（缓存飞轮观测）、`tools/exit_contract.py`（exit 纪律静态断言）、`bestpractice_08`（质量门禁与 eval 模式库）。

### v1.2 — 2026-06-21

**✨ 新增**
- `ob build <machine>` 非交互直构：原仅交互菜单选择，现可 `ob build romulus` 一步直构，便于脚本 / agent 调用。
- `ob start-qemu` 串口交互登录：BMC 起来后可直接在串口 console 登录调试。
- `ob start-qemu` 只列出已构建的 machine，避免选到没镜像的机器白跑。

**🛠 改进**
- 退出码契约成文：全部子命令统一 `0` 成功 / `1` 失败 / `2` 用户取消 / `3` 前置缺失，写进 `ob --help`；exit 3 时给一行 remedy line（如 `Run 'ob init romulus' first.`），AI agent 据此稳定回退、不再瞎猜。
- `ob start-qemu` PID 检测改 serial socket + 启动用户过滤，修复多用户共享环境误杀他人 QEMU 的风险；并主动检测、清理陈旧 SSH host key。
- 交互菜单支持 `0` 取消，不再死循环。
- `ob build` 修复 `DL_DIR`/`SSTATE_DIR` 用 `??=` 被默认值压过失效的问题（改条件强赋值）；生成的 `.inc` 增补 `BB_HASHSERVE_DB_DIR`。

**🏗 内部质量**（本轮主体工作）
- `ob` 大重构：抽公共函数、统一退出码、按 §1–§7 分区重排、删死码。
- 测试体系从零搭建：protocol / unit / orchestration / integration 四层 + `run_all.sh` + 覆盖率矩阵与雷达 + GitHub Actions CI + shellcheck baseline。
- 新增 `tools/ob_check.sh`：改完 `ob` 后一站式自检（结构 / 函数登记 / shellcheck baseline / 测试）。
- 确立 ob-first 约定：OpenBMC 环境动作统一走 `ob` 前门（见 AGENTS.md 与 ADR 0003）。

### v1.1 — 2026-06-12

- 新增 `ob start-qemu` / `ob stop-qemu`：在 QEMU 中启停 BMC 实例（SoC 自动检测、Jenkins 更新检查、端口与 PID 管理、多架构支持）。

### v1.0

- 首发：`ob init` / `ob build` / `ob status` + 内置 AI Agent 上下文框架。
