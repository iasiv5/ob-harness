# Memory Observations

这是三层记忆系统的动态记忆日志。observer 会把当天观测追加到这里；reflector 会回看这里的近期内容，清理低价值项，并据此产出规则晋升与报告。触发方式是在 VS Code Copilot chat 中运行 `/ai-heartbeat` slash command（定义在 `.github/prompts/ai-heartbeat.prompt.md`）。

## 格式说明

每个日期条目格式如下：

```raw
Date: YYYY-MM-DD

🔴 High: [方法论/约束] 描述
🟡 Medium: [项目状态/决策] 描述
🟢 Low: [任务流水] 描述
```

### 优先级定义

- **🔴 High**：跨项目通用的经验教训、硬性约束、影响系统架构的重大决策。永久保留，候选晋升为 axiom 或 skill。
- **🟡 Medium**：活跃项目的关键进展、技术决策背景、未来几周仍需参考的信息。
- **🟢 Low**：日常任务流水、瞬时 debug 记录、临时上下文。定期垃圾回收。

## 如何加载记忆

不要全文加载这个文件（可能很大）。按需检索：

```bash
# 搜索特定主题
grep -n "关键词" contexts/memory/OBSERVATIONS.md

# 搜索最近 N 天
grep -A 20 "Date: $(date -v-7d +%Y-%m-%d)" contexts/memory/OBSERVATIONS.md
```

或使用 `grep_search`（正则搜关键词）或 `semantic_search`（语义搜意图）做跨日期检索。

---

<!-- 以下是记录区域，由 AI Heartbeat 本地执行器追加与整理 -->

Date: 2026-06-01

🟡 Medium: [AI Heartbeat 执行边界] `periodic_jobs/ai_heartbeat/src/v0/heartbeat_preflight.py`、`heartbeat_state.py` 和 `heartbeat_status_cli.py` 已形成 due-task 判定与自动记账链；hook 只提醒，observer/reflector 必须由当前 chat 显式运行 `/ai-heartbeat` 并在完成后写回 success/skipped/failed。

Date: 2026-06-03

🟡 Medium: [ob 工具演进] `ob` 脚本从 `tools/ob` 迁移至仓库根目录，支持根目录直接 `./ob init`；新增 machine 校验关卡（大下载前拦截无效 machine）、TTY 交互式 machine 选择、`ob status` 子命令；single-source lock 设计落地（`openbmc-source.lock` + git origin 篡改检测），确保一个 harness 只绑定一个 OpenBMC 主仓来源。

Date: 2026-06-05

🔴 High: [Tinfoil 替代 N+1 查询模式] `tools/parse_bitbake_deps.py` 用 BitBake Tinfoil API（单进程）替代逐 recipe `bitbake -e` 子进程调用，SRC_URI/SRCREV 查询耗时从 ~17 min 降至 ~3.5 min（5x 提速）；关键设计决策：保留 `bitbake -g` 生成 `pn-buildlist`（~569 个 build target），Tinfoil 仅查询该列表而非 `all_recipes()`（~4492 个），避免引入 8x 噪音。
🟡 Medium: [ob init 本地镜像加速] `ob` 脚本新增 git reference/mirror 智能路由：读取 `local.conf` 的 `OB_GIT_REFERENCE_DIR`，自动检测 BitBake mirror 路径（`gitsrcname` 命名），clone 时 `--reference-if-able` 利用本地已有对象；新增 `is_private_url()` 检测私有/内网 URL（RFC 1918 + BitBake 变量引用 + runtime init script），用于智能路由 clone URL。
🟡 Medium: [AI Heartbeat SOP 抽离] 执行合同从平台入口文件剥离为独立 `periodic_jobs/ai_heartbeat/docs/AI_HEARTBEAT_SOP.md`；新增 Claude Code 入口 `.claude/commands/ai-heartbeat.md`，实现跨平台（PowerShell/Bash）统一调用路径。

Date: 2026-06-06

🟡 Medium: [ob init 企业级适配] `ob init` 新增两项关键修复：(1) `inject_externalsrc()` 不再无条件覆盖 local.conf 中已有的 DL_DIR/SSTATE_DIR（如 OEM 模板指向 NFS 共享缓存），改为仅在未定义时写入默认值；同时补写之前遗漏的 `INHERIT += "externalsrc"` 到 .inc 文件。(2) 自动检测 GitLab IP（优先级：meta-* 中的 git-mirror-url.sh → git remote origin URL），自动配置 `git config --global url.git@<ip>:.insteadOf https://<ip>/` 解决 recipe 用 HTTPS 但服务器仅开放 SSH 的场景，并在 local.conf 中自动填充 GITLAB_IP。
🟡 Medium: [docs/ 隔离策略] 新增 `.vscode/settings.json` 通过 `files.exclude` 将 `docs/specs/` 和 `docs/plans/` 排除出资源管理器、文本搜索与语义索引；`03_WORKSPACE.md` 新增 4 条历史文档使用指引（定位为决策记录非现状、不随 session 加载、事实优先级低于代码、按文件名日期取最新）。这是防止历史设计文档通过语义检索污染 agent 当前判断的系统性防护。

Date: 2026-06-08

🔴 High: [BitBake 操作符优先级陷阱] OE-core 在 `bitbake.conf` 用 `?=` 设置 `BB_NUMBER_THREADS`/`PARALLEL_MAKE`，`ob init` 原来用 `??=` 写入自定义值——但 `??=` 弱于 `?=`，被 OE-core 默认值覆盖。修复：改为 `?=`。教训：在 BitBake 中覆盖上游 `?=` 赋值时，必须用 `?=`（同级后写者胜）或 `=`（强覆盖），`??=` 只适用于"没任何人设过"的场景。此规律适用于所有需要覆盖 OE-core 默认值的 `.inc` 配置。→ 已晋升至 `rules/skills/workflow_01-obmc_env_init.md`「已知陷阱」。
🟡 Medium: [ob build 命令] `ob build` 落地：发现 `configs/<machine>.init-done` 文件列出已完成 init 的 machine，交互选择后执行 `bitbake obmc-phosphor-image`；引入 ADR 0001 记录 init-done marker 的设计决策（不复用 report.txt 或 lockfile 存在性，因为语义不匹配且有 Ctrl+C 截断风险）；machine 确认流程用三遍醒目警告 + Y/N 显式确认防止误触。
🟡 Medium: [ob 交互菜单] `ob` 无参数运行进入 `cmd_menu()` 交互循环：init/build/status/clear/quit 五选项，首屏全 logo 后续 brand line，每个命令执行后 pause + Enter 继续；`ob init <machine>`、`ob build` 等 CLI 模式仍可用。
🟡 Medium: [WSL 自动并行度] `detect_wsl` + `calc_parallelism`（`(MemTotal+SwapTotal)/4`，cap at nproc）写入 `BB_NUMBER_THREADS`/`PARALLEL_MAKE` 到 .inc 文件，解决 WSL swap 慢导致 OOM 的问题。

Date: 2026-06-11

🔴 High: [Bash strict mode 裸管道陷阱] `set -euo pipefail` 下裸管道（如 `cmd | grep -q`）中 grep 无匹配时返回 1，被 pipefail 捕获导致脚本意外退出。修复模式：用 `cmd | grep -q || true` 或 `if cmd | grep -q; then ...` 包裹。适用于所有在 strict mode 下使用管道的 Bash 脚本。
🟡 Medium: [ob start-qemu 演进] `ob` 新增 start-qemu / stop-qemu 子命令（+925 行），经历三阶段演进：(1) 初始实现含 ADR 0002（QB 变量通过 `bitbake -e` 提取）；(2) 拆分 community（QEMU 官方二进制）与 custom（企业定制镜像）两条独立路径；(3) 多架构支持（aarch64/arm/riscv64）与 SoC 感知重构（+1134 行），通过 SoC 类型自动选择 QEMU 目标机器。
🟡 Medium: [npm 注册表自动探测] `ob` 新增 npm registry 自动探测：读取 `npm config get registry` 并注入 BitBake `NPM_REGISTRY` 变量，替代硬编码 registry URL；新增 skill `bestpractice_05-npm_network_timeout_in_yocto.md` 记录 Yocto 编译中 npm ETIMEDOUT 的诊断与修复策略。配套实现计划 `2026-06-10-npm-registry-auto-detection-implementation-plan.md`。
🟡 Medium: [设计文档与实施计划产出] 06-08 至 06-11 期间新增 1 篇设计文档（qemu-binary-url-config）和 5 篇实施计划（start-qemu、npm-registry、ob-init-previously-initialized、qemu-binary-url-config、qemu-custom-refactor），反映 ob 工具进入密集功能迭代期。
🟢 Low: [init-done source_label 修复] `ob init` 写入 init-done marker 时 `source_label` 字段为空，已修复。
🟢 Low: [Skill 致谢分离] `.claude/skills/` 下 SKILL.md 的致谢段落拆至独立 ATTRIBUTIONS.md，精简 skill 文档主体。

Date: 2026-06-12

🟡 Medium: [QEMU 社区更新检查] `ob start-qemu` community 路径新增 Jenkins build number 级别更新检查：自动比对本地 manifest 的 `build_number` 与 Jenkins `lastSuccessfulBuild`，检测到更新时三行 warn + Y/N 交互确认；更新失败安全回退旧 binary 不打断启动；非 TTY / Jenkins 不可达 / manifest 无 build_number 均静默跳过。配套实施计划 `2026-06-12-qemu-community-update-check-implementation-plan.md`。
🟡 Medium: [QEMU 串口交互登录] `ob start-qemu` 支持串口交互登录：启动 QEMU 后自动连接 serial console，用户可直接在终端与 BMC 交互；同时改进 machine 列表只显示已完成构建的 machine（通过检查 image 文件存在性），避免选择未构建的 machine 导致启动失败。
🟡 Medium: [QEMU binary 断点续传] `ob start-qemu` 下载 QEMU binary 时使用 `curl -C -` 支持断点续传，解决大文件下载中断后需重新下载的问题。
🟢 Low: [ob init 空目录修复] `ob init` 不再无条件创建 `workspace/downloads` 空目录，改为按需创建。
🟢 Low: [VSCode files.exclude 修正] `.vscode/settings.json` 排除目录名从 `docs/plan`/`docs/spec` 修正为实际目录名 `docs/plans`/`docs/specs`（复数形式），`docs/adr` 保持可见。
