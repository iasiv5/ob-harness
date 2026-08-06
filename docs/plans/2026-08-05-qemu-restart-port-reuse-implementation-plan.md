# `ob start-qemu` restart 端口沿用 实施计划

## 目标

落地 [ADR-0021](../adr/0021-qemu-restart-port-reuse.md):`cmd_start_qemu` 交互确认 "kill and restart" 后沿用即将被 kill 的旧实例端口,治痛点(旧实例 IPMI 2624 restart 漂回默认 2623 撞内核残留→弹 prompt)。落 `--force` 不注入 + 两个不对称的 protocol 回归锁(软特权已弃, 见 ADR-0021 D5 翻转)。

## 架构快照

- `cmd_start_qemu` 交互确认分支(parseInt 块,`qemu_instance_load` 之后、`qemu_instance_stop` 之前读旧端口)在 stop 后、`qemu_prepare_launch` 前按 X-α(`-z` guard 注入到 `QEMU_*_PORT`)做端口复用。机制贴 `cmd_deploy_to_qemu`(`lib/qemu_commands.sh:367-370`)既有先例,加 `-z` guard 修 CLI flag 覆盖 hazard(deploy 无此场景)。
- 两个不对称写进 protocol 测试锁防回潮:(1) 交互确认分支注入 vs stale 清理 / `--force` 不注入(D4/D6);(2) 顶层 CLI flag 优先(`-z` guard 生效)。

## 全局约束

逐字继承 ADR-0021:
- 注入位置:`qemu_instance_stop` **之后**、`qemu_prepare_launch` **之前**(F1 顺序不变量:已有 `tests/orchestration/start_qemu_force_restart.sh` 锁"kill 先于 check_ports",本次改动不改该顺序)
- HTTP 端口注入判据额外含 `!= "none"`(因 `qemu_execute_launch` qemu.sh:161 PIDFILE http_port 无值填字面 `none`)
- `QEMU_*_PORT` 初始化为空串(`ob:25-28`),`-z` 对空串为真
- 退出码:本次不改 exit 契约(仍 exit seam / direct-exit module 0/1/2/3);`get_port_occupants` 增强返回值不改 exit 协议(恒 0,stdout 传占用)
- 文案:`KERNEL_RESIDUAL` / `self-residual` 一类术语仅注释与 ADR,不进用户可见 message(消息保持现有 conflict 报告形态)
- **不修 `cmd_deploy_to_qemu`**(path X 范围内不动;deploy 的不对称登记在 ADR-0021 Consequences,本计划不触它)

## 输入工件

- 设计文档:`docs/adr/0021-qemu-restart-port-reuse.md`
- 术语:`CONTEXT.md` `重启 (restart)` / `端口解析链` / `--force`(已落盘)
- 既有先例:`lib/qemu_commands.sh::cmd_deploy_to_qemu` lines 367-370(无条件赋值 `QEMU_*_PORT`)
- F1 顺序锁先例:`tests/orchestration/start_qemu_force_restart.sh`(stage running QEMU + dynamic ss 模式)
- 端口复用注入测试先例:`tests/orchestration/deploy_to_qemu.sh`(stage_running_qemu helper + "新 .pid ssh_port == 旧 .pid ssh_port" 断言)

## 文件结构与职责

-Modify: `lib/qemu_commands.sh`(符号 `cmd_start_qemu`,交互确认分支)
  - 职责:在交互确认 kill 后、`qemu_prepare_launch` 前,加四行 `-z` guard 注入(SSH/Redfish/IPMI/HTTP)
- Create: `tests/protocol/qemu_restart_port_reuse.sh`
  - 职责:protocol 层结构锁——交互确认分支**必**含 `[[ -z` guard 注入模式;`--force` 分支**不**含注入;stale 清理分支**不**含注入
- Create: `tests/orchestration/qemu_restart_port_reuse.sh`
  - 职责:orchestration 层 stub 行为锁——stage running QEMU(IPMI 2624) + dynamic ss;**仅 `--force` 场景**(交互路径 F1 降级,`-t 0` 守卫下不可 E2E 测,覆盖转交 Task 2 结构锁 + deploy 场景②);断言新 `.pid` ipmi_port == 默认 2623(非旧 2624,证明 `--force` 不注入)
- 两个不对称锁是单一 protocol 文件的多个 assert,不拆孤立任务(reviewer gate:port-reuse 语义整体可拒/可受,不细分)

## 任务清单

### Task 1: `cmd_start_qemu` 交互确认分支加端口注入

- 目标:交互确认 kill 旧实例后,`-z` guard 注入 `PIDFILE_*` 到 `QEMU_*_PORT`,让 `qemu_prepare_launch` 沿用旧端口
- Files:
  - Modify: `lib/qemu_commands.sh`(符号 `cmd_start_qemu`,定位锚点:`qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"` 在交互确认分支首次出现处之后,`qemu_prepare_launch "$MACHINE" "$image_file"` 之前)
- 验证范围:`tests/protocol/qemu_restart_port_reuse.sh`(Task 2 创建)guard 注入 assert 红→绿(TDD);交互路径 2624 行为覆盖转交 Task 2 结构锁 + deploy 场景②(F1 降级,不可 E2E 测)
- 接口契约:
  - Consumes: `qemu_instance_load` 设置的 `PIDFILE_SSH_PORT` / `PIDFILE_REDFISH_PORT` / `PIDFILE_IPMI_PORT` / `PIDFILE_HTTP_PORT`、`PIDFILE_PID`(既有 global,本任务不新增);`QEMU_SSH_PORT` 等顶层 CLI 变量(空串初始化于 `ob:25-28`)
  - Produces: 交互确认分支在 stop 后设 `QEMU_SSH_PORT` 等(非空时 prepare 走注入值,而非默认)—— 对 Task 3 orchestration 测试是依赖契约
- [ ] Step 1: 写失败检查(protocol 层 grep guard 模式缺失) — **前置: Task 2 骨架已建(TDD 红)**
- Run: `bash tests/protocol/qemu_restart_port_reuse.sh 2>&1 | tail -20`
- Expected: Task 2 骨架的 guard 注入 assert 失败(`cmd_start_qemu` 交互确认分支尚未含 `[[ -z "$QEMU_SSH_PORT" ]]` 模式)。执行序见「执行纪律」段:Task 2 先、Task 1 后
- [ ] Step 3: 写最小实现。在 `cmd_start_qemu` 交互确认分支 `qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"`(单次出现、上下文含 `read -r -p "$(echo -e "${PROMPT_PREFIX} Kill and restart? [y/N]: ")"`)之后、紧邻 `# ── Prepare launch` 注释之前插入:
```bash
                qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
                # ── Port reuse (restart 语义, ADR-0021): 沿用旧实例端口。
                # X-α: -z guard 保 CLI flag 优先(用户 restart 时 --ipmi-port 不被覆盖)。
                # deploy-to-qemu 用无条件赋值(start 场景无 CLI 冲突);start-qemu 加 guard。
                [[ -z "$QEMU_SSH_PORT" ]]    && QEMU_SSH_PORT="$PIDFILE_SSH_PORT"
                [[ -z "$QEMU_REDFISH_PORT" ]] && QEMU_REDFISH_PORT="$PIDFILE_REDFISH_PORT"
                [[ -z "$QEMU_IPMI_PORT" ]]   && QEMU_IPMI_PORT="$PIDFILE_IPMI_PORT"
                [[ -n "$PIDFILE_HTTP_PORT" && "$PIDFILE_HTTP_PORT" != "none" && -z "$QEMU_HTTP_PORT" ]] \
                    && QEMU_HTTP_PORT="$PIDFILE_HTTP_PORT"
```
- Change: 仅交互确认分支(stop 之后、prepare 之前)加 4 行注入 + 注释;`--force` 分支(stop 之后无 prepare 之前的注入块)与 stale 分支(`qemu_instance_clean_stale`,无注入)不动 —— 满足 D6 β(`--force` 不注入)与 D4(stale 不注入)
- [ ] Step 4: 跑 protocol 骨架(Task 2)确认 guard grep 通过

### Task 2: protocol 层结构锁骨架(两个不对称 + guard 模式)

- 目标:创建 protocol 测试,锁住 Task 1 的注入模式 + 两个不对称
- Files:
  - Create: `tests/protocol/qemu_restart_port_reuse.sh`
- 验证范围:`bash tests/protocol/qemu_restart_port_reuse.sh` exit 0(所有 assert 通过)
- 接口契约:
  - Consumes: `tests/protocol/qemu_commands_guard_surface.sh`(同款 `sed -n '/^cmd_start_qemu()/,/^cmd_stop_qemu()/p'` 提取函数体 + `assert_true "label" grep -Fq '...' <<< "$seg"` 模式)、`tests/lib/assert.sh`(`assert_true`/`assert_false`/`assert_summary`;真实 API 见执行纪律段)
  - Produces: protocol 测试文件(Task 1/3 的 Step 1 失败信号源)
- [ ] Step 1: 写失败检查(空文件先跑,assert 库报无测试)
- Run: `bash tests/protocol/qemu_restart_port_reuse.sh 2>&1 | tail -5`(文件未建前报 No such file;建空骨架后 assert_summary 报 0 passed)
- Expected: 当前无此文件 → 跑命令报 No such file
- [ ] Step 2: 确认失败
- [ ] Step 3: 写最小实现。参照 `tests/protocol/qemu_commands_guard_surface.sh` 的写法——用 `sed -n '/^cmd_start_qemu()/,/^cmd_stop_qemu()/p'` 提取 `cmd_start_qemu()` 到 `cmd_stop_qemu()` 段,再 `assert_true "label" grep -Fq 'pattern' <<< "$seg"` / `assert_false` 锁模式。**勿引** `assert_function_contains` / `assert_function_not_match`(`assert.sh` 无此 API,见执行纪律段)。创建文件:
```bash
#!/usr/bin/env bash
# tests/protocol/qemu_restart_port_reuse.sh — ADR-0021 restart 端口沿用结构锁。
# 锁两个不对称 + guard 模式:
#   1. cmd_start_qemu 交互确认分支含 -z guard 注入(PIDFILE_*_PORT -> QEMU_*_PORT)
#   2. --force 分支(QEMU_FORCE -eq 1 块)无注入
#   3. stale 清理分支无注入
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

QC="$(cd "$(dirname "$0")/../.." && pwd)/lib/qemu_commands.sh"
start_seg="$(sed -n '/^cmd_start_qemu()/,/^cmd_stop_qemu()/p' "$QC")"

# 1. 交互确认分支必有 guard 注入(注入模式出现 ≥1 次)
assert_true "interactive-confirm branch has -z guard port injection" \
    grep -Fq '[[ -z "$QEMU_SSH_PORT" ]]' <<< "$start_seg"

# 2. --force 分支不注入(评审 F2: 原 awk '/QEMU_FORCE -eq 1/' 因双引号阻断恒空转 → vacuous)
#   实测: lib/qemu_commands.sh:79 真实代码 `if [[ "$QEMU_FORCE" -eq 1 ]]`, 正则需容纳双引号
#   改用「正例锁 + 锚点反例」两段(BRE .* 不依赖 -E 选项、最稳, 二轮评审实跑确认):
#   写法对比(在 lib/qemu_commands.sh:79 `if [[ "$QEMU_FORCE" -eq 1 ]]` 上实跑):
#   (a) 正例: -z guard 注入模式在 start_seg 出现且仅出现 1 次(只有交互分支注入)
guard_count=$(grep -Fc '[[ -z "$QEMU_SSH_PORT" ]]' <<< "$start_seg")
assert_eq "guard injection appears exactly once (interactive branch only)" "$guard_count" "1"
#   (b) --force 反例: sed 锚点切 QEMU_FORCE(容双引号)到 elif 之间, 断言该块不含注入
force_seg="$(sed -n '/QEMU_FORCE.*-eq 1/,/^            elif/p' <<< "$start_seg")"
assert_true "force_seg is non-empty (F2 final: BRE .* matches real double-quote code)" test -n "$force_seg"
assert_false "--force branch does NOT set QEMU_SSH_PORT from PIDFILE" \
    grep -Fq 'QEMU_SSH_PORT="$PIDFILE' <<< "$force_seg""

# 3. stale 清理分支(qemu_instance_clean_stale 后无注入)
stale_seg="$(awk '/qemu_instance_clean_stale/{g=1} g{print; if(/fi[[:space:]]*$/) exit}' <<< "$start_seg")"
assert_false "stale-cleanup branch does NOT inject ports" \
    grep -Fq '[[ -z "$QEMU_SSH_PORT" ]]' <<< "$stale_seg"

assert_summary
```
- Change: 创建 protocol 测试文件,**5 个 assert**(交互注入 1 个 + guard 计数 1 个 + force_seg 非空 1 个 + --force 不注入 1 个 + stale 不注入 1 个;软特权 Task 4 已弃,D5 翻转)
- [ ] Step 4: 运行确认 Task 1 注入已生效后本测试通过
- Run: `bash tests/protocol/qemu_restart_port_reuse.sh; echo "rc=$?"`
- Expected: Task 1 完成前 → assert 1 失败(交互分支无 guard);Task 1 完成后 → 全通过(exit 0)

### Task 3: orchestration stub 行为锁(仅 `--force` 可测路径)

- 目标:**降级后**仅锁可端到端测的 `--force` 路径(`--force` 不注入旧端口)。**交互确认路径不可端到端测** —— `cmd_start_qemu` 的交互分支带 `elif [[ -t 0 ]]` 守卫(L92,仓库唯一带 `-t 0` 的 confirm),Pipe / 非 TTY 下 `[[ -t 0 ]]` 恒假 → 走 `else exit 1`,根本到不了注入点(评审 F1 实测确认;`start_qemu_force_restart.sh` 能跑通是因 `QEMU_FORCE=1` 绕开 `-t 0`,不是它解决了 TTY 问题)。故交互路径的端口复用行为**改由两条间接证据链覆盖**:(1) Task 2 protocol 层强化结构锁(注入位置在 `qemu_instance_stop` 之后、`qemu_prepare_launch` 之前);(2) `tests/orchestration/deploy_to_qemu.sh` 场景②已行为级证明「注入旧端口 → 新 `.pid` ssh_port=旧值」这条链成立(deploy 无条件赋值 / start `-z` guard,下游消费者 `qemu_prepare_launch` 完全相同)。
- Files:
  - Create: `tests/orchestration/qemu_restart_port_reuse.sh`
- 验证范围:`bash tests/orchestration/qemu_restart_port_reuse.sh` exit 0(仅 `--force` 场景断言)
- 接口契约:
  - Consumes: `tests/lib/qemu_stubs.sh`(`make_qemu_curl_fake <dir>` / `make_bitbake_env_fake <dir>` / `make_setsid_sentinel <dir> <sentinel_file>` / `make_pgrep_fake`)、`tests/lib/stub.sh`(`mkfake_bin <dir> <cmd>` + `cat > "$dir/.<cmd>.sh"` dynamic fake 模式)、**`mkfake_bin "$DB" ssh-keygen` stub**(F6:`check_ssh_hostkey_conflict` 真调 ssh-keygen/ssh,不 stub 会走真实命令,参照 `deploy_to_qemu.sh:76`)、`tests/orchestration/start_qemu_force_restart.sh`(假 harness root + dynamic ss 完整 scaffold 参照)、`tests/orchestration/deploy_to_qemu.sh`(`stage_initialized_machine` L27 / `stage_running_qemu` L53 内部 helper 定义 — 复制不 source);Task 1 产出的注入实现(交互路径)作结构锁对象,非本 task 行为测试对象
  - Produces: orchestration 行为锁(覆盖 ADR-0021 D2/D6)
- [ ] Step 1: 写失败检查(无文件先跑报 No such file)
- Run: `bash tests/orchestration/qemu_restart_port_reuse.sh 2>&1 | tail -5`
- Expected: 当前 No such file
- [ ] Step 2: 确认失败
- [ ] Step 3: 写最小实现。文件结构 = 复用 `start_qemu_force_restart.sh` 的 stage 框架(假 harness root = `$TMP`, `OB_ENTRY_DIR=$TMP`)+ `deploy_to_qemu.sh` 的 `stage_running_qemu`(IPMI 改为 2624 模拟痛点场景)。单实测场景(--force),交互路径见 F1 降级:
```bash
#!/usr/bin/env bash
# tests/orchestration/qemu_restart_port_reuse.sh — ADR-0021 restart 端口复用行为锁。
# 场景 --force 路径(唯一可端到端测): stage running QEMU(IPMI 2624)+ QEMU_FORCE=1 →
#   断言新 .pid ipmi_port == 2623(默认, 未注入旧 2624); 证明 --force 不触发 restart 注入。
# 场景 交互确认路径: F1 降级, 非 E2E 可测(-t 0 守卫), 覆盖转交 Task 2 结构锁 + deploy_to_qemu.sh 场景2。
# scaffold: 复用 start_qemu_force_restart.sh 的假 harness root + dynamic ss 模式。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
source "$(dirname "$0")/../lib/qemu_stubs.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; DB="$(mktemp -d)"; WS="$TMP/workspace"
# stage_initialized_machine / stage_running_qemu 复用 deploy_to_qemu.sh 同款(此处略写, 实施时从 deploy_to_qemu.sh 复制 helper 定义)
# ... stage initialized machine + running QEMU 78bb (ipmi_port=2624) ...

# 场景 A: 交互确认路径 — 不写端到端 assert(F1: -t 0 守卫下 pipe 进不去)
#   覆盖转交: (1) Task 2 protocol 结构锁; (2) deploy_to_qemu.sh 场景②已证明注入→新.pid 链
#   此处仅留 placeholder 注释, 不跑无效的 `printf 'y\n' | cmd_start_qemu`(会 exit 1, 非注入路径)
echo "scenario A: interactive-confirm path covered by Task 2 structure lock + deploy_to_qemu.sh scenario② (F1: -t 0 guard, not E2E testable)"

# 场景 B: --force, 不注入(端口回默认 2623 或 OB_QEMU_IPMI_PORT)
# 注: 需重 stage 一个新 running QEMU(场景 A 已 kill 旧的), 再次 stage
# ... re-stage running QEMU ipmi_port=2624 ...
QEMU_FORCE=1
( cmd_start_qemu romulus ) </dev/null >"$TMP/outB" 2>&1
new_ipmiB="$(grep '^ipmi_port=' "$QEMU_PIDS_DIR/romulus.pid" | cut -d= -f2)"
# --force 不注入, prepare 走默认 2623(若 2623 被 stage 占用则该路径走协商, 此处默认环境空闲用 2623)
assert_eq "scenario B: --force does NOT reuse old 2624 (uses default 2623)" "$new_ipmiB" "2623"

rm -rf "$TMP" "$DB"
assert_summary
```
- Change: 创建 orchestration 测试(**单实测场景: --force**;交互路径 F1 降级、不写 E2E assert)。实施注意:helper 从 deploy_to_qemu.sh 复制不共用 lib;**必加 ssh-keygen stub**(F6: check_ssh_hostkey_conflict 真调 ssh-keygen/ssh)。
- [ ] Step 4: 运行确认通过
- Run: `bash tests/orchestration/qemu_restart_port_reuse.sh; echo "rc=$?"`
- Expected: Task 1 + Task 3 完成后 exit 0,单 assert_eq 通过(场景 A 是 echo placeholder,F1 降级)

### Task 4: ~~软特权实现~~ (已弃, D5 翻转为无特权, 见 ADR-0021)

- **状态**: 已删除。二轮评审论证软特权语义反转(触发条件 pid 活着 vs 端口将释放需 pid 死),与 `ss -l` 的 LISTEN-only 行为相加 → 期望效用为零或负。ADR-0021 D5 翻转为「无特权」(候选 5 选项 A)。`lib/qemu.sh` 的 `check_ports_available` / `prompt_for_available_port` **不改**。三个不对称收为两个:(1) 交互注入 vs stale/--force/首启不注入;(2) start-qemu 带 guard vs deploy 无 guard。
- **保留此 stub** 作决策记录(为何没 Task 4),不是执行任务。
### Task 5: 全量回归

- 目标:本次改动跑完整 CI 等价回归,确保无 exit_contract / shellcheck / 既有测试退化
- Files: 无文件改动,仅跑命令
- 验证范围:`./tools/ob_check.sh` 绿 + 单跑新增四个测试绿
- 接口契约:无(纯回归)
- [ ] Step 1: 跑新增测试(Task 4 已弃,protocol 测试无软特权 assert)
- Run: `bash tests/protocol/qemu_restart_port_reuse.sh && bash tests/orchestration/qemu_restart_port_reuse.sh && echo "NEW TESTS OK"`
- Expected: 两测试 exit 0
- [ ] Step 2: 跑 ob 配套自检(AGENTS.md 要求改 `ob`/`lib/*.sh` 后必跑)
- Run: `./tools/ob_check.sh`
- Expected: 结构 / 函数登记 / shellcheck baseline / 测试四项全绿(`coverage radar` 若 ±1 浮动 = 已知机制,见 user memory `repo-coverage-radar-float.md`)
- [ ] Step 3: 跑既有 force_restart / deploy_to_qemu 回归(确认 F1 + deploy 端口复用未退化)
- Run: `bash tests/orchestration/start_qemu_force_restart.sh && bash tests/orchestration/deploy_to_qemu.sh && echo "REGRESSION OK"`
- Expected: 两测试 exit 0(`start_qemu_force_restart.sh` 的 F1 锁 + `deploy_to_qemu.sh` 的端口复用断言不受本次改动影响——本计划不触 deploy 实现)
- [ ] Step 4: 跑 start_qemu_noninteractive / start_qemu_remedy protocol 回归
- Run: `bash tests/protocol/start_qemu_noninteractive.sh && bash tests/protocol/start_qemu_remedy.sh && echo "PROTOCOL OK"`
- Expected: 两测试 exit 0

## 执行纪律

- **API 参照(已 PHASE 5 自检核实)**:`tests/lib/assert.sh` 真实导出 = `assert_reset`/`assert_eq <label> <actual> <expected>`/`assert_match`/`assert_contains <label> <haystack> <needle>`/`assert_true <label> <cmd...>`/`assert_false <label> <cmd...>`/`assert_rc`/`assert_summary`;**无** `assert_function_contains`(勿引)。protocol 层 grep 锁统一用 `assert_true "label" grep -Fq 'pattern' <<< "$seg"` 模式(参照 `tests/protocol/qemu_commands_guard_surface.sh`)
- **stub API(已核实)**:`tests/lib/stub.sh` 导出 `mkfake_bin <dir> <cmd>` + `cat > "$dir/.<cmd>.sh" <<EOF ... EOF`(dynamic fake,按 `.sh` 内逻辑返回——参照 `start_qemu_force_restart.sh` 的 `mkfake_bin "$DB" ss` + `$DB/.ss.sh`);`tests/lib/qemu_stubs.sh` 导出 `make_qemu_curl_fake <dir>` / `make_bitbake_env_fake <dir>` / `make_setsid_sentinel` / `make_pgrep_fake`
- **执行序(统一为 TDD 骨架先行)**:Task 2 先建 protocol 失败骨架(红,assert 跑出 fail)→ Task 1 实现注入(绿)→ Task 2 跑通 → Task 3 orchestration(只在可测路径,见 F1 降级;Task 4 软特权已弃、D5 翻转)→ Task 5 全量回归。删除 Task 1 Step 1/Step 2 里「Task 1 在 Task 2 之后」的矛盾表述——执行序以本段为准,Task 1 Step 1 的失败信号来自 Task 2 骨架(故 Task 2 骨架先建)
- Task 3 helper(`stage_initialized_machine` L27 / `stage_running_qemu` L53,定义在 `tests/orchestration/deploy_to_qemu.sh` 内部、**非导出**):**复制函数体定义**到新文件(不 source、不抽象共用 lib—YAGNI;减少改动面)。`stage_running_qemu` 的 `.pid` 模板里 `ipmi_port=2623` 改 `ipmi_port=2624` 模拟痛点场景
- 全程不触 `cmd_deploy_to_qemu` 实现(ADR-0021 Consequences 登记的 deploy 不对称不在本计划范围)
- 每个任务完成跑该任务的验证命令;Task 5 是收口回归,绿 = 整体交付


## 最终验证
```bash
# 单跑本次新增
bash tests/protocol/qemu_restart_port_reuse.sh
bash tests/orchestration/qemu_restart_port_reuse.sh
# 既有 F1 + deploy 端口复用未退化
bash tests/orchestration/start_qemu_force_restart.sh
bash tests/orchestration/deploy_to_qemu.sh
# 配套自检
./tools/ob_check.sh
```
全绿 = 交付完成。任一退化(尤其 `start_qemu_force_restart.sh` 的 F1、`deploy_to_qemu.sh` 的端口复用断言)= STOP 排查,本计划不应改 F1 顺序或 deploy 实现。
