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

Date: 2026-06-22

🔴 High: [ob 优先约定确立] 确立"ob 优先"作为 OpenBMC 环境动作的统一前门：agent 做 OpenBMC 生命周期动作（init/build/status/start-qemu/stop-qemu）前，先查 `ob --help`（唯一权威能力清单，由 `tests/protocol/usage_dispatch_sync.sh` 断言与 dispatch 一致防漂移），提供就走 `ob <cmd>`，不手动兜底。退出码回退语义固化：exit 1=真失败才考虑手动、exit 2=用户取消、exit 3=前置缺失用 ob 补前置（禁止据此转手动）。两层落地：常驻守卫在 `AGENTS.md` Working Mode，完整协议在 `rules/skills/bestpractice_06-ob_first.md`。配套 ADR-0003 与 `#remedy line`（exit 3 恒带一行含字面 ob 命令的补救提示，术语登记在 `CONTEXT.md`）。
🔴 High: [exit 纪律静态守护] 新增 `tools/exit_contract.py`（只读静态体检）：X=每个真 bash `exit` 字面值 ∈ {0,1,2,3}（唯一允许非字面是 `require_path` 的 `exit "$code"`）；Y=§2 函数绝不 exit（对偶式自维护）；Z=exit-3 remedy 覆盖（require_path 精确+direct exit 3 弱守）。已被 `tools/ob_check.sh` 自动调用为静态检查 step，配套 protocol 自测。这是 exit-code 契约从"死约定"升级为"可机器验证的纪律"。
🔴 High: [Bash 退出码传播真理] 确立"CLI 退出码完全由 `cmd_*` 的 exit 决定，`main` return 仅语义清理无行为变化"——这是 06-16 重构（ob 4251 行、92 函数、5 子命令+menu）的核心设计结论。经两轮评审（含一次评审方读取工具伪影致 R5 误判后撤回），收尾 5 项（F1 ensure_qemu_binary_community URL 两分支需显式区分"非 TTY 缺配置→3"与"交互主动留空→2"；F2 head/tail 未决 3 已闭环——写入端去重保证单 key 单条）。
🟡 Medium: [PREMIRRORS 注入 + exit code 变量判定] `ob init` 生成 inc 时注入 PREMIRRORS（GNU `ftpmirror.gnu.org` → 清华 tuna，实测从 ~3.6KB/s 提到 ~2.6MB/s，解决 gcc 单包卡 6 小时）。设计决策（ADR-0004）：用 PREMIRRORS 不覆盖 `GNU_MIRROR` 变量——因空值禁用安全（PREMIRRORS="" 干净禁用，GNU_MIRROR="" 会坍缩路径）+ 来源透明（fetcher 层重写不改 SRC_URI/SPDX）。DL_DIR/SSTATE_DIR/PREMIRRORS 三变量"用户是否配置"判定统一从 `-n`（值非空）改 `read_local_conf_var` exit code（ADR-0005）：有赋值行=用户接管含空值，无赋值行=ob 写默认；社区模板从不赋空值，"禁用 ob 注入"=`PREMIRRORS = ""`（直觉）。
🟡 Medium: [ob 测试覆盖体系] 建四层分层测试（语义名 `protocol`/`unit`/`orchestration`/`integration`，曾用 L0-L3 因与 ob function semantic layer 撞名而改）。覆盖率定义=分层各司其职非单一行覆盖：unit ~40 函数冲函数级 ≥95%、protocol 覆盖子命令×分支退出码、orchestration 覆盖高价值编排、integration 兜端到端。覆盖度用两核心层交叉校验：checklist（语义）× xtrace 雷达（结构，`tools/coverage_radar.py`）；kcov 降为可选附录。盲区透明化（按五档列全 92 函数自动化归属，不制造覆盖率虚高）。不改 ob 加 mock seam（最小改动+隔离靠 PATH 注入+函数 override）。
🟡 Medium: [ob_check 一站式自检] 新增 `tools/ob_check.sh`：聚合 4 项配套自检（extract_funcs GAPS / reorder.py mismatch / shellcheck baseline / run_all），`OB_CHECK_SKIP_TESTS=1` 可跳 run_all。baseline 判定式重生成——纯行号平移/告警减少自动修复，新增告警机器报错不静默吸收（不架空 CI 硬门禁）。规则钩子落 `AGENTS.md` Working Mode（改动 ob 脚本后额外跑 ob_check.sh）+ `rules/03_WORKSPACE.md` 路由登记。起因：06-20 加双轨 host key 检测漏同步 CI 配套被用户指出后才补。
🟡 Medium: [ob build 非交互 + README v1.2] `ob build` 支持非交互路径（收敛 exit-3 remedy 协议）；README 同步到 v1.2（ob CLI 现状 + release notes，入口1 加"ob 优先"心智模型、入口2 加 token-free 卖点，前提磁盘 100+GB）。CI shellcheck 防退化改用 ob_check.sh 行号无关判定。
🟡 Medium: [QEMU host key 双轨检测] `ob start-qemu` 失效 host key 检测改双轨（原单轨），同步 CI 配套机制。`ob init` 生成 inc 新增 `BB_HASHSERVE_DB_DIR` 配置；DL_DIR/SSTATE_DIR 改条件强赋值修复 `??=` 被默认值压过失效。
🟢 Low: [设计文档/ADR 密集产出] 06-13~06-22 新增 ADR 0003/0004/0005、设计文档 5 篇（ob-refactor 复审 v2-final / ob-test-coverage / ob-change-check / qemu-binary-url / hostkey-detection）、实施计划约 7 篇（start-qemu-hostkey、confirm-banner、ob-refactor、ob-test-system、ob-build-noninteractive、ob-change-check、ob-first、readme-sync、exit-contract-check、premirrors-injection）。反映 ob 工具从功能迭代期进入纪律化/可验证化阶段。
🟢 Low: [memo] 评审方读取工具在本环境会返回伪影（不存在的英文 Exit codes 块），被当"铁证"误判 R5——已记入用户记忆；凡用读取结果断言事实须第二来源实时复核。
