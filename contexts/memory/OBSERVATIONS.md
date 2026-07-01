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
🟢 Low: [memo] 评审方读取工具在本环境会返回伪影（不存在的英文 Exit codes 块），被当"铁证"误判 R5——已记入用户记忆；凡用读取结果断言事实须第二来源实时复核。

Date: 2026-06-24

🔴 High: [深模块抽取模式：code 追上领域模型] `machine_state` 模块引入（commit 0d17f76，~1813 行，`!` breaking）是把"散落在 cmd_status/cmd_build/cmd_start_qemu/cmd_init/repo.sh 的 Machine lifecycle state 判断（snapshot/init-done marker/deploy image 查找）"收敛到一个深 module seam 的范例。可复用方法论：当 CONTEXT.md/ADR 已确立 canonical term 但代码层滞后（仍读写旧名、状态判断穿透存储 implementation）时，新增深模块收敛迫使上下层一致，而非到处打补丁。配套设计约束（module 不直接 exit）由扩展后的 `exit_contract.py` 做静态门禁——Y 规则从"按函数"改为"按 basename 配置 leaf-pure module"（当前 util.sh/machine_state.sh）。
🔴 High: [领域术语硬切迁移纪律] 06-23 两次 breaking rename（`source_lock`→`source_manifest`、`<machine>.lock`→`<machine>.snapshot`）均走"硬切不兼容、不提示"策略。决策前提：CONTEXT.md 已确立 canonical term + ADR 背书 + 旧名有歧义（lock 既像文件锁又像状态记录）。硬切 vs 兼容的取舍——当术语已是文档化唯一正名且旧含义带歧义时，硬切比保留别名更清晰，但必须配套测试同步重建（source_lock.sh 删→source_manifest.sh 建，含 sample 文件）和 ob_check baseline 重生成。旧 `<machine>.lock` 仅可在 `ob init <machine>` 过程中清理，DRY_RUN 时只预览。
🟡 Medium: [ob modularize 收口] function semantic layer 物化为 lib/*.sh 文件边界的工作以 PR #8 merge（49426d4）收口。lib/ 现为六文件：util.sh(L3 底层)/repo.sh(仓库·machine 解析)/qemu.sh(QEMU runtime)/machine_state.sh(lifecycle)/init_pipeline.sh(init 流水线)/commands.sh(cmd_* 编排)。结构边界从注释锚点转为文件名，CONTEXT.md 已登记 L1-L3 角色↔文件映射。这是 06-16 ob 大重构（4251 行/92 函数）之后的结构固化里程碑。
🟡 Medium: [extract_funcs 多文件稳定性] lib 拆分引入新约束"lib 函数间不得有顶层语句"，`tools/extract_funcs.py` 修复"拦截 lib 函数间顶层语句"（commit 967b0d8）并配 unit test 锁定。反映 extract_funcs 从单文件解析升级为多文件 boundary 感知——lib 物化为文件边界后，函数归类工具必须感知文件边界，否则会把函数间顶层代码误归入相邻函数。

Date: 2026-06-25

🔴 High: [V6 概率乘公理确立] 新增 `rules/axioms/v06_probability_multiplication.md`（来源：克谦方法论 Iron Law + 本仓库 eval 实践锚定）。核心：多环节产出最终质量 = 各环节成功率乘积（非平均、非最差），`0.99^51=0.60` 直接崩。三条可操作推论：(1) action↔eval 对偶——每个 action 必须配可执行 eval，否则黑箱环节相乘必崩，让概率乘的分母里没有黑箱；(2) 不追求"一次完美"而追求每环可修复迭代，成功率 0.7 的环节跑 N 轮有效成功率→`1-(0.3)^N`；(3) 缓存飞轮反直觉——严格门禁逼 agent 反复访问同段 context→高缓存命中→修复 token 近乎免费，"手动省 token"反概率乘（换低质量+返工更高总成本）。明确与 X5 精度级联区分（X5 对象连续精度量/解药精度预算，V6 对象离散成败/解药 action-eval 对偶），并定位为 V2 可验证性的数学根基。
🟡 Medium: [bestpractice_08 eval 门禁模式库] 新增 `rules/skills/bestpractice_08-eval_gate_patterns.md`：把散落的本仓库 eval 实践反向归纳为 4 种可复用门禁模式——模式1 Action-Eval 对（实例 `exit_contract.py` 的 X/Y/Z 三纪律逐 action 钉死）、模式2 阶段门禁（`ob_check.sh` 改完 ob/lib 一站式 4 项自检，含 baseline 新增告警不静默吸收纪律）、模式3 持续监控（CI shellcheck 行号无关判定 + reflector L2 反思）、模式4 CICD 集成式复盘（`run_all` 四层测试 + `coverage_radar` 盲区透明化）。核心原则锚定 V6；是 bestpractice_02 feedback loop 的落地形态，与 bestpractice_06 ob 优先同属"可机器验证的纪律"族。
🟡 Medium: [cache_hit_rate 观测工具 + 缓存飞轮实测] fc98a05 引入 `tools/cache_hit_rate.py` 观测缓存命中率（飞轮健康度信号：命中率持续走低=门禁在松或 context 在碎），6bce2de 重做输出报告+补输出维度+澄清 GLM 缓存口径（缓存命中 token 近乎免费的口径边界）。本仓库实测长会话收敛 95-98%、项目整体 96%。
🟢 Low: [ADR 格式审查收尾] d89089f 按 ADR-FORMAT 审五条 ADR 后做克制瘦身：0003 主体删 stale 的 ob build 缺口（v1.2 已修非交互直构）+ 删"消费侧契约"changelog 段并入主体；0005 把 `[ob:188-189]` 失效行号→`lib/util.sh` 符号（可复用小纪律：文档内代码引用用符号不用行号，抗漂移）；CONTEXT.md remedy line 补”恰好一条命令、不串接“约束。

Date: 2026-07-01

🔴 High: [深模块抽取范例 II：QEMU launch profile] commit 0cae680（ADR-0007 背书、CONTEXT.md 登记 `QEMU launch profile`/`QB variable` 术语）继 06-24 machine_state 之后第二个同构深模块抽取：把分散的 `resolve_qb_vars`/`detect_soc_type`/`derive_qemu_machine_name`/`find_ast2700_bootloaders` 收敛为单一入口 `resolve_qemu_launch_profile`（`lib/qemu.sh`），`cmd_start_qemu` 只调这一个。设计要点：(1) 统一决策变量命名空间 `QEMU_LAUNCH_*` 替换散落的 `QB_*`/`SOC_TYPE`/`BOOTLOADER_*`，下游 `build_qemu_cmd`/`ensure_qemu_firmware`/启动横幅只消费不判断、不再做运行时 SoC 分支；(2) 入口必 `reset_qemu_launch_profile` 清空全部 `QEMU_LAUNCH_*`，防跨 machine/跨用例状态泄漏（AST2700 后再解析 AST2600 时 bootloader 必须空）；(3) 证据驱动 SoC 识别——QB_SYSTEM_NAME/machine conf include chain/deploy artifacts 三路证据带 source+confidence 汇总，冲突 exit 1/缺失 exit 3，取代原 detect_soc_type 隐式优先级；(4) legacy AST2600 fallback 保留但必 warning 且记 source。方法论：当决策散落多 helper、调用者各自做运行时分支时，抽“画像”深模块+统一决策变量+结构回归锁，比到处补丁清晰；与 06-24 同构（CONTEXT.md/ADR 已立 canonical term 但代码滞后→新增深模块迫使上下层一致）。
🔴 High: [重构/优化的回归锁方法论落地] 两处同族实践。(a) profile 重构配结构回归锁 `tests/protocol/qemu_launch_profile_structure.sh`：锁旧 public 调用清零、下游不再读旧决策变量、`build_qemu_cmd` 不再查 bootloader、`cmd_start_qemu` 必调新 interface，防收敛后旧路径悄悄回潮。(b) 新 skill `rules/skills/bestpractice_09-nonfunctional_regression_locks.md`（commit 3878f7e）把“不改输出但声称优化”的改动（perf/去重/缓存）钉成可回归硬约束：模式1 调用次数断言（恰 N 次）、模式2 零调用断言（被消除函数计数文件不存在）。bash 手法：monkey-patch `eval "$(declare -f orig | sed '1s/^orig/_shadow/')"` 重定义 wrapper 计数（关键是 `1` 只改首行防误伤 body，`^` 是保险）；计数写文件不写变量（子 shell `$()`/`< <()` 内变量累加会丢，与 bestpractice_07 同源）；期望值钉死 `==N` 非 `>=N`。适用边界：输出断言已能区分对/错时不再加调用次数断言（避免耦合实现细节）。上游公理 V2 可验证性 / V6 概率乘。
🟡 Medium: [QEMU launch profile 内两项实现决策] (1) qemuboot.conf 优先快路径：`resolve_qemu_launch_profile` 优先读 deploy 产物 `*.qemuboot.conf` 取最终启动值，缺失才回退慢速 `bitbake -e`，避免每次 start-qemu 都跑 bitbake 解析（属“改达成路径”的非功能性优化，正是 bestpractice_09 适用场景）；(2) QEMU binary 机型覆盖：已安装 binary 若支持 machine 前缀派生的 `<prefix>-bmc` 机型（如 `sample-bmc`）则覆盖 qemuboot/bitbake 给的通用机型（如 `ast2700a1-evb`），让社区 QEMU 也能驱动带前缀的自定义 machine（CONTEXT.md `QEMU launch profile` 条目已登记）。
🟡 Medium: [machine_state 固件镜像就绪状态] commit 74aea90（PR #10，merge 07e2ef8）扩展 machine_state 增加“固件镜像就绪”判断（`lib/machine_state.sh`+183 / `lib/commands.sh`+245 / `lib/repo.sh`+36，含 unit/protocol 测试同步）。配套 perf 5154242 复用 records 把 `cmd_status` 对 records 的 3 次 discovery 压成 1 次——此优化的测试（`tests/protocol/status_machine_state.sh` 计数断言 + `tests/unit/repo_previously_initialized.sh` 零调用断言）即是 bestpractice_09 的来源实例。
