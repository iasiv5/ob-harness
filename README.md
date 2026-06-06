# openbmc-aware-harness

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
    ┃      OpenBMC Development Environment · ob harness · 𝓲𝓪𝓼𝓲      ┃
    ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

面向 OpenBMC 固件开发的一键开发环境初始化工具。`ob init` 自动完成主仓库克隆、machine 选择、bitbake 环境初始化、子仓库拉取、lockfile 生成和 externalsrc 注入，开箱即用。

## 快速开始

### 前提条件

- Linux 环境
- `git`、`python3`
- 30 GB+ 可用磁盘空间
- 网络能访问 [GitHub](https://github.com/openbmc/openbmc.git)（或自定义 OpenBMC Git 服务器）

### 第一步：克隆仓库

```bash
git clone https://github.com/iasiv5/openbmc-aware-harness.git
cd openbmc-aware-harness
```

### 第二步：初始化 OpenBMC 开发环境

```bash
# 交互式选择 machine 和 OpenBMC 主仓源（社区/自定义）—— 推荐
./ob init

# 直接指定 machine
./ob init romulus

# 预览操作但不执行
./ob init romulus --dry-run

# 使用自定义 OpenBMC 仓库 URL，并指定 romulus machine
./ob init romulus --url https://git.example.com/openbmc.git

# 只指定自定义 OpenBMC 仓库 URL，machine 在后续交互时选择
./ob init --url https://git.example.com/openbmc.git
```

`ob init` 会自动执行以下 8 步：

1. **前置检查**：验证 OS、工具链、网络和磁盘空间
2. **克隆主仓库**：下载 OpenBMC 主仓库（社区版或自定义 URL）
3. **解析 machine**：交互选择或直接确认目标 machine
4. **初始化 bitbake**：执行 `source setup <machine>` 创建构建目录
5. **生成依赖图**：运行 `bitbake -g` 并逐 recipe 解析 SRC_URI/SRCREV
6. **拉取子仓库**：克隆全部 git 子仓库到 `workspace/src/<machine>/`
7. **生成 lockfile**：记录所有子仓库的 commit hash，写入 `workspace/configs/<machine>.lock`
8. **注入 externalsrc**：生成 `externalsrc-<machine>.inc` 并 include 到 `local.conf`

**关键行为**：
- **增量且幂等**：已有仓库不会重新克隆，重跑只会 fetch 更新和补齐缺失项
- **可中断**：Ctrl+C 后重跑会从中断处继续，不会从头开始
- **自动重试**：子仓库克隆失败时自动尝试 shallow clone → 无分支约束 clone

### 第三步：构建固件

```bash
cd workspace/openbmc
source setup <machine>
bitbake obmc-phosphor-image
```

### 第四步：开发和调试

源码位于 `workspace/src/<machine>/<repo>/`，externalsrc 已注入，改完源码后直接重编即可生效：

```bash
cd workspace/openbmc
source setup <machine>
bitbake <recipe>
```

### 查看环境状态

```bash
./ob status           # 查看 OpenBMC 源绑定状态
```

## 命令参考

```raw
ob <command> [options] [arguments]

Commands:
  init   [<machine>]    一键初始化 OpenBMC 开发环境
  status                查看当前 OpenBMC 源绑定状态

Options:
  -d, --dry-run         预览操作但不执行
  -u, --url <url>       使用自定义 OpenBMC 仓库 URL
  -v, --verbose         详细输出
  -h, --help            显示帮助

环境变量:
  OB_OPENBMC_URL        非交互模式下指定 OpenBMC 仓库 URL
```

## 仓库结构

```raw
openbmc-aware-harness/
├── ob                          # OpenBMC 开发环境初始化脚本
├── tools/                      # 工具脚本（依赖解析等）
├── CLAUDE.md                   # Claude Code 入口（指向 AGENTS.md）
├── AGENTS.md                   # AI agent 主入口，定义 session 启动读取链
├── rules/                      # AI 协作规则（agent 自动加载）
│   ├── 01_SOUL.md              # AI 身份与行为准则
│   ├── 02_USER.md              # 服务对象画像
│   ├── 03_WORKSPACE.md         # 目录路由表
│   ├── 04_COMMUNICATION.md     # 沟通规范
│   ├── 05_SKILLS_INDEX.md      # Skills 索引
│   ├── 06_AXIOMS_INDEX.md      # Axioms 索引
│   ├── axioms/                 # 决策公理（43 条）
│   └── skills/                 # 可复用能力（工作流、最佳实践）
├── docs/
│   ├── specs/                  # 设计文档
│   └── plans/                  # 实施计划
├── contexts/memory/            # AI 记忆观测日志
├── .claude/
│   ├── skills/                 # Claude Code/Copilot 自定义 skill
│   └── commands/               # Claude Code 自定义命令（/ai-heartbeat 入口）
├── .github/
│   ├── copilot-instructions.md # GitHub Copilot 入口（指向 AGENTS.md）
│   ├── hooks/                  # Session 启动 hook（AI Heartbeat 提醒）
│   └── prompts/                # Copilot slash command prompt（/ai-heartbeat）
├── periodic_jobs/ai_heartbeat/ # AI Heartbeat 心跳子系统
└── workspace/                  # 工作空间（gitignore，以下子目录由 'ob init' 自动创建）
    ├── openbmc/                #  （After ob init）OpenBMC 主仓库
    ├── src/<machine>/          #  （After ob init）子仓库源码
    ├── configs/                #  （After ob init）lockfile 和报告
    ├── downloads/              #  （After ob init）下载缓存
    └── sstate-cache/           #  （After ob init）构建状态缓存
```

## AI 协作能力

本仓库内置了一套 AI agent 协作框架：

- **rules/**：定义 AI 的身份、用户画像、目录路由和沟通风格，每轮 session 自动加载
- **rules/skills/**：可复用的工作流和最佳实践，按需引入
- **rules/axioms/**：从团队经历中提炼的决策原则，用于启发深度思考
- **AI Heartbeat**：通过 `/ai-heartbeat` slash command 手动触发的记忆积累系统，记录观测并定期反思

这些内容是给 AI agent 用的。人类开发者通常不需要手动阅读，但如果想自定义 AI 行为，可以从 `AGENTS.md` 开始。

## 致谢

本项目受 [grapeot (Yan Wang / 鸭哥)](https://github.com/grapeot) 的 [context-infrastructure](https://github.com/grapeot/context-infrastructure) 项目启发并基于其架构思路构建。感谢鸭哥在 AI 上下文工程领域的开创性探索。
