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

🟡 Medium: [ob init 工具状态] `ob init <machine>` 的设计、计划和主脚本已经落地到 `docs/specs/2026-05-31-obmc-env-init-design.md`、`docs/plans/2026-05-31-obmc-env-init-implementation-plan.md`、`tools/ob` 与 `tools/parse_bitbake_deps.py`；当前实现覆盖主仓库准备、OpenBMC `source setup`、`bitbake -g`、逐 recipe `bitbake -e` 解析、子仓库 clone/fetch、lockfile 与 externalsrc 注入。
🟡 Medium: [AI Heartbeat 执行边界] `periodic_jobs/ai_heartbeat/src/v0/heartbeat_preflight.py`、`heartbeat_state.py` 和 `heartbeat_status_cli.py` 已形成 due-task 判定与自动记账链；hook 只提醒，observer/reflector 必须由当前 chat 显式运行 `/ai-heartbeat` 并在完成后写回 success/skipped/failed。

Date: 2026-06-03

🟡 Medium: [ob 工具演进] `ob` 脚本从 `tools/ob` 迁移至仓库根目录，支持根目录直接 `./ob init`；新增 machine 校验关卡（大下载前拦截无效 machine）、TTY 交互式 machine 选择、`ob status` 子命令；single-source lock 设计落地（`openbmc-source.lock` + git origin 篡改检测），确保一个 harness 只绑定一个 OpenBMC 主仓来源。
🟡 Medium: [rules 体系精简] 入口文件加数字前缀（`01_SOUL.md`~`06_AXIOMS_INDEX.md`）统一加载顺序；axioms/skills INDEX 提升至 `rules/` 层；删除 5 个低价值 skill（multi_agent_analysis、product_decision_analysis、staged_approach、parallel_subagents、ai_agent_cli_guide），净减 895 行。
🟡 Medium: [文档清理] README 重写为人类使用手册（克隆→初始化→构建全流程）；内部文档做事实修正（路由表补齐、幽灵路径替换）；新增 `docs/specs/2026-06-03-doc-audit-cleanup-design.md` 和对应实施计划。
🟢 Low: [ob UX 改进] 新增启动 logo、步骤标题函数、连通性探针说明；源选择菜单加序号及 `--obmc-url` 命令提示；下载提示分层重构。

Date: 2026-06-05

🔴 High: [Tinfoil 替代 N+1 查询模式] `tools/parse_bitbake_deps.py` 用 BitBake Tinfoil API（单进程）替代逐 recipe `bitbake -e` 子进程调用，SRC_URI/SRCREV 查询耗时从 ~17 min 降至 ~3.5 min（5x 提速）；关键设计决策：保留 `bitbake -g` 生成 `pn-buildlist`（~569 个 build target），Tinfoil 仅查询该列表而非 `all_recipes()`（~4492 个），避免引入 8x 噪音。
🟡 Medium: [ob init 本地镜像加速] `ob` 脚本新增 git reference/mirror 智能路由：读取 `local.conf` 的 `OB_GIT_REFERENCE_DIR`，自动检测 BitBake mirror 路径（`gitsrcname` 命名），clone 时 `--reference-if-able` 利用本地已有对象；新增 `is_private_url()` 检测私有/内网 URL（RFC 1918 + BitBake 变量引用 + runtime init script），用于智能路由 clone URL。
🟡 Medium: [AI Heartbeat SOP 抽离] 执行合同从平台入口文件剥离为独立 `periodic_jobs/ai_heartbeat/docs/AI_HEARTBEAT_SOP.md`；新增 Claude Code 入口 `.claude/commands/ai-heartbeat.md`，实现跨平台（PowerShell/Bash）统一调用路径。
🟡 Medium: [ob 命令行简化] `ob` 脚本选项统一为短格式（`-m`/`-u`/`-v`/`-n`/`-s`），`--skip-deps` 降级为隐性应急选项不再暴露在 `--help`。
🟢 Low: [文档新增] 新增设计文档 `docs/specs/2026-06-04-tinfoil-deps-optimization-design.md` 和实施计划 `docs/plans/2026-06-04-tinfoil-deps-optimization-implementation-plan.md`。

Date: 2026-06-06

🟡 Medium: [ob init 企业级适配] `ob init` 新增两项关键修复：(1) `inject_externalsrc()` 不再无条件覆盖 local.conf 中已有的 DL_DIR/SSTATE_DIR（如 OEM 模板指向 NFS 共享缓存），改为仅在未定义时写入默认值；同时补写之前遗漏的 `INHERIT += "externalsrc"` 到 .inc 文件。(2) 自动检测 GitLab IP（优先级：meta-* 中的 git-mirror-url.sh → git remote origin URL），自动配置 `git config --global url.git@<ip>:.insteadOf https://<ip>/` 解决 recipe 用 HTTPS 但服务器仅开放 SSH 的场景，并在 local.conf 中自动填充 GITLAB_IP。
🟡 Medium: [docs/ 隔离策略] 新增 `.vscode/settings.json` 通过 `files.exclude` 将 `docs/specs/` 和 `docs/plans/` 排除出资源管理器、文本搜索与语义索引；`03_WORKSPACE.md` 新增 4 条历史文档使用指引（定位为决策记录非现状、不随 session 加载、事实优先级低于代码、按文件名日期取最新）。这是防止历史设计文档通过语义检索污染 agent 当前判断的系统性防护。
🟡 Medium: [文档同步] CLI 选项引用全面同步：`--obmc-url`→`--url`、`--skip-fetch`→`--skip-deps`、`-n`→`-d`；README 更新 banner、磁盘要求 25→30GB、目录树结构；`workflow_01-obmc_env_init.md` skill 同步所有接口变更。
🟢 Low: [ob banner] Logo 文案从 "OpenBMC Dev Environment Initializer" 改为 "OpenBMC Development Environment · ob harness"。
