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

Date: 2026-06-05

🔴 High: [Tinfoil 替代 N+1 查询模式] `tools/parse_bitbake_deps.py` 用 BitBake Tinfoil API（单进程）替代逐 recipe `bitbake -e` 子进程调用，SRC_URI/SRCREV 查询耗时从 ~17 min 降至 ~3.5 min（5x 提速）；关键设计决策：保留 `bitbake -g` 生成 `pn-buildlist`（~569 个 build target），Tinfoil 仅查询该列表而非 `all_recipes()`（~4492 个），避免引入 8x 噪音。
🟡 Medium: [ob init 本地镜像加速] `ob` 脚本新增 git reference/mirror 智能路由：读取 `local.conf` 的 `OB_GIT_REFERENCE_DIR`，自动检测 BitBake mirror 路径（`gitsrcname` 命名），clone 时 `--reference-if-able` 利用本地已有对象；新增 `is_private_url()` 检测私有/内网 URL（RFC 1918 + BitBake 变量引用 + runtime init script），用于智能路由 clone URL。

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
