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

- **🔴 High**：跨项目通用的经验教训、硬性约束、影响系统架构的重大决策。永久保留，候选晋升为 axiom 或 know-how。
- **🟡 Medium**：活跃项目的关键进展、技术决策背景、未来几周仍需参考的信息。
- **🟢 Low**：日常任务流水、瞬时 debug 记录、临时上下文。定期垃圾回收。

## 如何加载记忆

不要全文加载这个文件（可能很大）。按需检索：

```bash
# 搜索特定主题
grep -n "关键词" contexts/memory/OBSERVATIONS.md

# 搜索最近 N 天
grep -A 20 "Date: $(date -d '-7 days' +%Y-%m-%d)" contexts/memory/OBSERVATIONS.md   # GNU date (Linux)
```

或使用 `grep_search`（正则搜关键词）或 `semantic_search`（语义搜意图）做跨日期检索。

---

<!-- 以下是记录区域，由 AI Heartbeat 本地执行器追加与整理 -->

<!-- 2026-08-18 reflector GC：删除 06-05~08-02 间已固化（ADR-0003/0004/0005/0007/0008/0009/0010/0011/0012/0015/0016/0017/0018/0019、bestpractice_06/07/08/09/10、exit_contract/ob_check/surface gate 工具本体、WORKSPACE/CONTEXT 词条）与过期流水（coverage 基线 21→12→10→7 已两轮过时、模块交付流水）共 30+ 条；保留无 repo 载体的通用方法论 3 条 + 活跃决策 1 条。-->

Date: 2026-07-07

🟡 Medium: [不跨语言 DRY 决策边界] PR#18 评审焦点:python tools/parse_bitbake_deps.py:_detect_runtime_git_host 与 bash 新原语同名同概念但维持独立不合并——双栈(bash/python)同概念重复是固有代价,跨语言共享的进程/契约开销不划算,vendor 脚本命名中期稳定、drift 风险可接受。明确边界:同语言内 DRY(收敛 bash 两处)做,跨语言 DRY 不做;可援引未来任何 bash/python 双栈同概念场景。

Date: 2026-07-21

🔴 High: [落回结果用文件树 diff 观测,非 parse 自由文本 stdout] `ob dev finish`(ADR-0009,07-17)的 patch landing 五字段(`landing_mode`/`landing_layer`/`patches`/`recipe_files`/`srcrev`)不由 parse `devtool finish` 自由文本 stdout 获得(不可靠),而由 ob 在 finish 前后快照 `landing_layer` 文件树 diff 探测(.patch 变→patch mode;.bb/.bbappend 变→srcrev mode)。可复用方法论:**上游工具自由文本 stdout 不可靠 parse 时,改用受控副作用(文件系统前后快照 diff)观测结果——单 writer 假设下可靠**。配 `landing_mode` 与 `srcrev` 解耦:landing_mode=srcrev 只表 recipe 文件被改(落点判),不保证 srcrev 非 null(纯 .bbappend 编辑/SRCREV 变量或续行写法 抽不到),即 `landing_mode:"srcrev"`+`srcrev:null` 合法。

Date: 2026-07-28

🟡 Medium: [QEMU 启动链收尾深化候选——暂缓登记,触发条件锚定] pick-one-arch-task 初始
提案(QEMU 启动编排族深化)经评审 + 实测核对,多个关键论断失实,优先级从"头号任务"下调
为"中优先级收尾,当前可暂缓"。保留的真实候选(评审一致认可):只动 lib/qemu.sh 的
qemu_prepare_launch/qemu_execute_launch/build_qemu_cmd 三件(执行编排层),把 6 个
ports/serial(QEMU_LAUNCH_*_PORT/SERIAL_LOG/SERIAL_SOCK)+ QEMU_CMD[] 全局数组共 7 个
隐式回传 channel 收为 nameref outvar(范式参考 devtool_pick 的 status_outvar /
bare_mirror 的 disposition,非 image_build 的 return rc);execute_launch 的
setsid/PID 写/SSH 轮询真实副作用留执行层,配次序回归锁(tests/orchestration/
start_qemu_force_restart.sh 已有)。绝不碰已深化的 profile 层(qemu_launch_profile.sh
是 bestpractice_10 形态 B 的 canonical 先例,reset_qemu_launch_profile 防跨用例泄漏,
不是债)。暂缓触发条件(按 ADR-0014 精神):(1) prepare/execute 出真实 friction(如端口
复用 save/restore 改形真出 bug);(2) 硬 ports 参数化 unit 测试需求出现;(3) qemu.sh 进
入高频改动区(当前 90 天 12 次,非热点;真热点是 commands.sh 67 次,与 QEMU 无关)。
adoptive 路线:profile/binary/instance/runtime 在 07-01~07-06 已集中深化过,bestpractice_10
形态 A-E 已沉淀 know-how,本候选是同路线的执行层收尾而非新方向。
🔴 High: [subagent 产出数字必须独立复核——本次评审纠正实例] pick-one-arch-task 初始
提案多失实,根因同 lessons-ob-init "别拿单值当铁证":subagent 给出"33 个 QEMU_LAUNCH_*"
"devtool_ 物理文件 11 个"等数字,我未用 grep/wc 独立复核就写进优先级论证;评审逐条
实测推翻(实测 19 个 / 12 个)。关键修正:profile 层(reset_qemu_launch_profile 清空 19
个 QEMU_LAUNCH_*)是 deepening 的成果不是债(ADR-0007 Consequences 明确);端口
save/restore 是单进程内动作非跨命令状态共享(真实载体是 PID 文件 PIDFILE_*_PORT);
image_build 是 return rc 纯执行编排无 nameref(同构应援引 devtool_pick/bare_mirror);
ADR-0011 约束( deploy 不调 cmd_*)在现状已兑现(已直接调 build_obmc_image+
qemu_prepare_launch+execute_launch),不构成深化论据。教训强化:出优先级判断/反驳别
人前,关键数字一律 sort -u|wc -l / 实跑一次独立锁死,不抄 subagent 的二手值。

Date: 2026-08-18

🔴 High: [验证 gate 的 fail-closed 对称防御 + 归因闭合——ADR-0026 全程演进的教训] ob test-qemu baseline 谱系路由四步演进的通用方法论沉淀：(1) 错配（custom build 测社区基线 → fail 无法归因）要在外层路由杜绝，WARN/事后提示只补一角（"覆盖机制本身制造归因缺口"）；(2) 防御分档必须对齐——"label 写坏→unknown 强防御"与"label 缺失→静默 fallback community 弱防御"的不对称本身就是缺口，修复即对称化（strict 读取，缺失也 unknown→exit 3 + 按成因分档 remedy：缺失指向 restore、写坏指向 corrupted，排查方向不同不共用文案）；(3) 修复范围按危害不对称切——provisioning 路径的缺失默认是 fail-safe（下载社区 binary）不收紧，只收紧归因闸门。适用于一切"凭外部状态文件做路由/判定"的系统。
🔴 High: [CI coverage 哨兵不弱化原则 + xtrace 子进程盲区的直调补偿模式] 08-18 CI 失败（coverage_radar uncovered 8>基线 7）的修复教训：外部 agent 建议 EXEMPT 豁免清单或抬基线，均拒绝——EXEMPT 会把 6 个存量低估函数一并豁免成 effective=0（哨兵失效，此后新增未覆盖函数不再被看见）；抬基线把可修复的低估固化。根因是 trace_collect 只 xtrace 测试进程自身（BASH_XTRACEFD=3），"$OB" 子进程内的函数调用（protocol 明明真实调过）抓不到——即 coverage_matrix 备注的"exit 函数 radar 低估"。正解 = protocol 测试 $() 子 shell 直调 exit-seam 函数（cmd_test_qemu -h return 0 路径 + usage 语义断言），xtrace 对同进程子 shell 可见——复用 bare_mirror"顶层调用补偿 xtrace 子 shell 低估"先例。今后 radar uncovered 涨破基线先查是不是这类盲区。
🟡 Medium: [ob test-qemu 落地并入 main（PR #42, 16891c5, 36 commits）——per-machine baseline AR probe runner] 全栈形态：每 machine baseline 目录自包含（ar_probes.yaml + applicability.yaml + runner/ probe 引擎）+ 六态 verdict（pass/fail/skip/xfail/xpass/error）+ exit 契约 0/1/2/3（1=α truth 专属"BMC 不满足 baseline"，error 属 infra 不进 α 统计）+ 凭据全链 env 不落 argv/ps。romulus 起步 5 AR（社区基线随上游分发）；本地 b865g8-a2-bytedance 建线 PASS 2/2（B865G8-CORE-* 占位待需求文档替换）。经六轮评审对撞 + grilling 两轮八项决策收口。
🟡 Medium: [谱系判定闭环 + 本地 harness 谱系事实] 演进链：优先级覆盖+谱系 WARN（旧）→ 谱系硬路由不跨谱系回退（ADR-0026, 08-17 负责人定调）→ 单维度收敛 source label（binary 与 label 完全共线非独立信号，同日复盘）→ 缺失态 fail-closed（08-18 修订注记，ADR-0007 内联修订范式）。本地 harness 谱系 = custom（172.17.8.216 openbmc-ami 源，全 manifest 唯一绑定）——romulus 想测社区基线须 cp -r tests/baseline/romulus contexts/baseline/romulus 后校准凭据（社区 root/0penBmc vs custom sysadmin 系），凭据差异本身就是"社区基线不能直接测 custom 构建"的实证。
🟡 Medium: [QEMU 侧 ADR-0021/0023/0024 连续收口（08-05~08-11）] (1) ADR-0022 resolve_qemu_port_reuse leaf-pure 模块（start/deploy 共享，cli_first 四端口对称 + HTTP none sentinel）；(2) ADR-0023 _smoke_render_verdict 从 cmd_smoke 抽取；(3) ADR-0024 qemu_instance_liveness outvar 范式（is_alive 公开名退役私有化，恒 return 0 + outvar），4 个 caller 迁移。另有非 EVB AST2700 不再强校验拆分 bootloader、/proc/stat comm 含空格稳健解析。
🟡 Medium: [4 个未合并远程分支保留待移植（用户 08-18 决定）] score-fix-loop-2026-08-07/08（含 main 没有的 ob test 聚焦校验路由 + ob doctor 前门子命令 + hooks ob/lib 改动交接前触发完整 ob_check）与 ob-harness-bh-loop-20260806/07（skills 变体：grill-with-docs 并入 grilling as variant、handoff 渐进披露、AGENTS.md 编辑后验证路由）。删前验证发现非"无用"（ob 无 doctor/test 路由、grill-with-docs 仍独立 skill），用户拍板保留全部，将来按需 cherry-pick。
🟢 Low: [know-how 新增 + 提示] (1) bestpractice_13（QEMU BMC EEPROM FRU 注入）+ bestpractice_14（QEMU 模拟缺失 GPIO expander——pca9555/9554 模型，b865g8 psu-manager SIGABRT 实战沉淀）。(2) contexts/knowhow/ 近 16 天有 b865g8 调试经验变更（bestpractice_01/02 + debug 分析），部分已沉淀 product 层（bp_13/14），余量走手动通道（workflow_04 + /sediment），reflector 不碰。(3) test-qemu 六轮评审/grilling 细节已随 commit log 入库，不重复记录。
