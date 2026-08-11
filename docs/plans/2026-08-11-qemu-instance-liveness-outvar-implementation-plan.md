# qemu_instance liveness outvar 接口实施计划

## 目标

落实 [ADR-0024](../adr/0024-qemu-instance-liveness-outvar.md)：把 `qemu_instance_is_alive` 的 0/1/2 多态返回码（`set -euo` footgun）迁移为单一 leaf-pure `qemu_instance_liveness <machine> <outvar>`（`printf -v` 写 `running`/`exited`/`recycled`/`nopid`，恒 return 0），吸收 `qemu_instance_load`+probe 两步，私有化原 0/1/2 body。消灭 footgun 这类 bug（非 confinement），对齐 `machine_selection_guard` 范式。

## 架构快照

- `qemu_instance.sh` 新增公开 `qemu_instance_liveness`（吸收 load + probe + rc→status 映射 + 恒 return 0）+ 私有 `_qemu_instance_probe_alive`（is_alive body 0/1/2 + 输入有效性防线修正空字段 false-running）；`is_alive` 公开名删除。
- 5 个 call site（`qemu_instance.sh:89` summarize_brief in-module + `qemu_commands.sh:77/225/318/557` 四个 cmd）改用 `liveness` 的 `case "$_liv"`，吸收原 `load→probe` 两步与 nopid 分支。
- 迁移用「过渡 wrapper」策略：Task 1 加 liveness 时保留 `is_alive` wrapper（调 probe、0/1/2 不变）保现有 caller/测试绿；Task 3 在所有 caller 迁完后删 wrapper + 调测试。每 task 都可独立验证绿。

## 全局约束

- **leaf-pure**：`qemu_instance.sh` 是 `exit_contract.py` Y 白名单 basename（`'qemu_instance.sh': set()`）；`liveness`/`_probe_alive` 绝不 `exit`，恒 return。
- **set -euo pipefail**（`ob:4`）：liveness 内部 `load` 失败与 probe 非零都用条件位或 `|| _rc=$?` 消费，外部恒 return 0。
- **outvar 写法**：`printf -v "$status_outvar" '%s' <status>`（镜像 `lib/machine_selection_guard.sh`，非 `local -n` nameref，避循环引用）。
- **行为保持**（除一项修正）：4 cmd 的 exit code（0/1/2/3）+ remedy + `clean_stale` 触发不变；`summarize_brief` 输出（`✅ running`/`⚠️ stale`）不变；**例外**：corrupt/空字段 PID file 今天 `is_alive '' '' ''` 误返 rc 0（false running），新接口加字段防线→`exited`，bug 修正非行为保持（评审 🔴1）
- **文案规则**：CONTEXT.md 不含实现细节（函数名），用概念表述。
- 无额外版本/平台约束。

## 输入工件

- 设计决策：[docs/adr/0024-qemu-instance-liveness-outvar.md](../adr/0024-qemu-instance-liveness-outvar.md)（grill-with-docs 三轮共识）
- 现状接口：`lib/qemu_instance.sh:50-68`（is_alive 0/1/2）、call site 见下

## 接口契约

```
qemu_instance_liveness <machine> <status_outvar>     # 公开, leaf-pure, 恒 return 0
  1. 清空 PIDFILE_*（PIDFILE_PID/USER/MACHINE/BINARY/STARTED_AT/SSH_PORT/REDFISH_PORT/IPMI_PORT/HTTP_PORT/SERIAL_LOG=""）
  2. qemu_instance_load "$machine"（条件位消费 rc）:
     失败 → printf -v "$status_outvar" '%s' nopid; return 0   # PIDFILE_* 已清空, nopid 路径保持清空
  3. _qemu_instance_probe_alive "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE"（|| _rc=$?）:
     0→running / 1→exited / 2→recycled / *→exited(防御)
  4. printf -v "$status_outvar" '%s' <status>; return 0

_qemu_instance_probe_alive <pid> <binary> <machine>  # 私有, is_alive body 0/1/2 + 输入有效性防线
  防线(先于 /proc 检查; 修正空字段 false-running, 评审 🔴1): pid 非空且 ^[0-9]+$、binary/machine 非空, 否则 return 1(exited)
  /proc/$pid 不存在→1(exited); cmdline 不含 binary 或 machine→2(recycled); 都含→0(running)

qemu_instance_is_alive                                # 退役(过渡 wrapper 在 Task 1 加, Task 3 删)
```

## 文件结构与职责

- Modify: `lib/qemu_instance.sh` — 新增 `qemu_instance_liveness` + `_qemu_instance_probe_alive`；is_alive body 迁入私有 probe；`summarize_brief` 改用 liveness；`list` 注释 + `summarize_brief` 注释更新
- Modify: `lib/qemu_commands.sh` — 4 call site（cmd_start_qemu 冲突块 / cmd_stop_qemu 循环 / cmd_deploy_to_qemu 探测 / cmd_smoke 前置）改 liveness
- Modify: `tests/unit/qemu_instance.sh` — 新增 liveness 4 状态 + 恒 return 0 断言；路径 B stub 由 is_alive 改 liveness
- Modify: `tests/unit/ports.sh` — 删 is_alive rc 断言（L28-30）+ 注释（L3）
- Modify: `tests/protocol/smoke_surface.sh` — cmd_smoke body-grep（L64 is_alive→liveness、L65 load 删除）+ 注释（L9、L104）
- Modify: `CONTEXT.md` — L92（重启）/ L191（smoke）is_alive 函数名引用改概念表述
- Modify: `tools/coverage_matrix.md` — L69（PID 校验→liveness）、L81（instance module 加 liveness）
- Modify: `tools/coverage_radar.py` L15 / `tools/trace_collect.sh` L7 — 注释核实更新（grep 确认是否硬编码函数列表）
- Modify: `rules/03_WORKSPACE.md` — qemu_instance.sh 职责描述补 liveness
- Modify: `docs/adr/0020-ob-smoke-probe-only-smoke-prober.md` — :19 smoke probe 流程描述 `qemu_instance_is_alive` → `qemu_instance_liveness`（当前机制引用，非历史 rationale；Task 4 Step 1 核查）
- Verify-only: `tests/orchestration/start_qemu_stale_pid.sh`、`tests/orchestration/start_qemu_force_restart.sh`、`tests/protocol/start_qemu_noninteractive.sh`、`tests/protocol/smoke_exit_contract.sh` — 验证仍绿（不改行为；smoke_exit_contract L10 注释随 Task 4 更新）
- 不动: `tools/exit_contract.py`（`'qemu_instance.sh': set()` 不变）

## 任务清单

### Task 1: lib/qemu_instance.sh — 新增 liveness/probe + summarize_brief 改用 liveness（含 liveness unit）

- 目标：新增 `qemu_instance_liveness` + 私有 `_qemu_instance_probe_alive`，加 `is_alive` 过渡 wrapper，`summarize_brief` 改用 liveness；现有 caller/测试不受影响仍绿
- 涉及文件：`lib/qemu_instance.sh`、`tests/unit/qemu_instance.sh`
- 接口契约
  - Consumes: ADR-0024 接口契约（见上）
  - Produces: `qemu_instance_liveness` / `_qemu_instance_probe_alive`（公开 + 私有）；`is_alive` 过渡 wrapper（保 0/1/2）；`summarize_brief` 消费 liveness

- [ ] Step 1: 写失败测试——在 `tests/unit/qemu_instance.sh` `assert_summary` 前追加 liveness 断言段
  - Change: 在 `# --- qemu_instance_summarize_full` 段之前插入：
    ```
    # --- qemu_instance_liveness (ADR-0024: outvar status, 恒 return 0) ---
    rm -f "$PIDS_DIR"/*.pid
    printf 'pid=99999999\nbinary=qemu-system-arm\nmachine=romulus\nssh_port=2222\n' > "$PIDS_DIR/romulus.pid"
    _rc=0; _liv=""; qemu_instance_liveness romulus _liv || _rc=$?
    assert_eq "liveness exited status"    "$_liv" "exited"
    assert_eq "liveness exited returns 0" "$_rc" "0"
    printf 'pid=%s\nbinary=qemu-system-arm\nmachine=recyc\nssh_port=2222\n' "$$" > "$PIDS_DIR/recyc.pid"
    _rc=0; qemu_instance_liveness recyc _liv || _rc=$?
    assert_eq "liveness recycled status"    "$_liv" "recycled"
    assert_eq "liveness recycled returns 0" "$_rc" "0"
    _rc=0; qemu_instance_liveness nonexist _liv || _rc=$?
    assert_eq "liveness nopid status"    "$_liv" "nopid"
    assert_eq "liveness nopid returns 0" "$_rc" "0"
    # corrupt/空字段 PID file: 防线须落 exited(修正今天 false-running, 评审 🔴1)
    printf 'pid=\nbinary=\nmachine=\n' > "$PIDS_DIR/corrupt.pid"
    _rc=0; qemu_instance_liveness corrupt _liv || _rc=$?
    assert_eq "liveness corrupt → exited (not running)" "$_liv" "exited"
    assert_eq "liveness corrupt returns 0" "$_rc" "0"
    # running: 真实 fake 进程(argv[0]=<binary> <machine>, 过 probe cmdline 匹配; 评审 🔴2 不用 stub)
    printf '#!/usr/bin/env bash\nexec -a "qemu-system-arm fakerun" sleep 30\n' > "$TMP/fakeqemu"; chmod +x "$TMP/fakeqemu"
    "$TMP/fakeqemu" & _fake_pid=$!
    # 等 exec -a 完成: 子进程从 bash script 进入 sleep 有窗口期, cmdline 未就绪会判 recycled(评审 🟡2)
    for _ in $(seq 1 50); do
        _cl="$(tr '\0' ' ' < "/proc/$_fake_pid/cmdline" 2>/dev/null || true)"
        [[ "$_cl" == *qemu-system-arm* && "$_cl" == *fakerun* ]] && break
        sleep 0.1
    done
    printf 'pid=%s\nbinary=qemu-system-arm\nmachine=fakerun\nssh_port=2222\n' "$_fake_pid" > "$PIDS_DIR/fakerun.pid"
    _rc=0; qemu_instance_liveness fakerun _liv || _rc=$?
    assert_eq "liveness running status"    "$_liv" "running"
    assert_eq "liveness running returns 0" "$_rc" "0"
    kill "$_fake_pid" 2>/dev/null || true
    ```
- [ ] Step 2: 运行并确认失败
  - Run: `bash tests/unit/qemu_instance.sh`
  - Expected: 失败，输出含 `liveness exited status` 断言失败（`qemu_instance_liveness: command not found` 或 status 为空；corrupt/running 断言在实现前亦失败）
- [ ] Step 3: 写最小实现——改 `lib/qemu_instance.sh`
  - Change:
    1. 将 `qemu_instance_is_alive()` body（L50-68）改名为 `_qemu_instance_probe_alive()`，并在 `/proc/$pid` 检查**之前**加输入有效性防线：`[[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ || -z "$expected_binary" || -z "$expected_machine" ]] && return 1`（修正空字段 false-running——空 pid 今天命中 `/proc/` + 空 string 子串匹配 → 误 rc 0；防线让其落 1→exited→clean_stale，评审 🔴1）
    2. 在其后新增 `qemu_instance_liveness()`（按接口契约：先清空 PIDFILE_* → load（条件位）失败 nopid+return 0 → probe（`|| _rc=$?`）→ case 映射 → `printf -v "$2"` → return 0）
    3. 新增 `qemu_instance_is_alive()` 过渡 wrapper：`_qemu_instance_probe_alive "$@"`（保 0/1/2，供 Task 2/3 迁移期间现有 caller/测试用）
    4. `qemu_instance_summarize_brief`（L82-95）改为：调 `qemu_instance_liveness "$machine" _liv` → `case` 出 mark（`running`→`✅ running`、`nopid`→`⚠️ stale` 直接 echo+return、`exited|recycled`→`⚠️ stale`）
    5. 更新 `list` 注释（L126）与 `summarize_brief` 注释里 `qemu_instance_is_alive` 提法为 `qemu_instance_liveness`
- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/unit/qemu_instance.sh`
  - Expected: rc=0（`assert_summary` 报告 0 failures，含新 liveness 断言 + 既有 summarize 4 路径仍绿）
- [ ] Step 5: checkpoint commit（`refactor(qemu_instance): add liveness outvar module + probe privatize, summarize_brief migrated`）

### Task 2: lib/qemu_commands.sh — 4 call site 迁 liveness（同步 smoke_surface body-grep）

- 目标：4 个 cmd call site 由 `load→is_alive` 两步改 `qemu_instance_liveness` 单步 + `case "$_liv"`；同步改 `smoke_surface.sh` 的 cmd_smoke body-grep（body 与 grep 必须同步绿）
- 涉及文件：`lib/qemu_commands.sh`、`tests/protocol/smoke_surface.sh`
- 接口契约
  - Consumes: `qemu_instance_liveness`（Task 1 产出）；`PIDFILE_*` 副通道不变量（running 分支 caller 读 PIDFILE_SSH_PORT 等仍成立）
  - Produces: 4 caller 全部经 liveness；`is_alive` 公开名此时仅被 Task 1 wrapper + `ports.sh`/`qemu_instance.sh L58 stub` 引用（Task 3 清）

- [ ] Step 1: 确认 baseline 绿
  - Run: `bash tests/protocol/smoke_surface.sh && bash tests/orchestration/start_qemu_stale_pid.sh && bash tests/orchestration/start_qemu_force_restart.sh && bash tests/protocol/start_qemu_noninteractive.sh && bash tests/protocol/smoke_exit_contract.sh`
  - Expected: rc=0（五个测试迁移前全绿，作 baseline）
- [ ] Step 2: 改 4 call site（`lib/qemu_commands.sh`）
  - Change:
    1. **cmd_start_qemu 冲突块（L70-109）**：删 `if qemu_instance_load "$MACHINE"; then if qemu_instance_is_alive ...` 双层，改 `local _liv=""; qemu_instance_liveness "$MACHINE" _liv; case "$_liv" in running) ...原 running 分支(--force/confirm/nontty exit1)...; exited|recycled) qemu_instance_clean_stale "$MACHINE"; nopid) ;; esac`（running 分支内对 `PIDFILE_*`/`resolve_qemu_port_reuse` 的引用不变）
    2. **cmd_stop_qemu 循环（L217-246）**：删 `if ! qemu_instance_load; then continue` + `qemu_instance_is_alive || pid_status=$?; case 0/1/2`，改 `qemu_instance_liveness "$MACHINE" _liv; case "$_liv" in nopid) info "No PID file..."; continue; exited) ...exited 分支(clean_stale+continue)...; recycled) ...recycled 分支...; running) ...confirm+stop...; esac`（DRY_RUN 三态文案映射到 exited/recycled/running 三臂）
    3. **cmd_deploy_to_qemu 探测（L314-327）**：同 start 模式（`qemu_running=1` + 捕获 old_*_port 在 running 分支；exited|recycled → clean_stale；nopid → 落空）
    4. **cmd_smoke 前置（L548-562）**：删 `if ! qemu_instance_load; exit3` + `if ! qemu_instance_is_alive; clean+exit3` 两段，改 `qemu_instance_liveness "$MACHINE" _liv; case "$_liv" in nopid) error "No QEMU instance running...(no PID file)."; exit 3; exited|recycled) qemu_instance_clean_stale "$MACHINE"; error "...not running (stale PID file cleaned)."; exit 3; running) ;; esac`（remedy 文案不变）
- [ ] Step 3: 同步改 `tests/protocol/smoke_surface.sh` body-grep
  - Change:
    1. L64 `assert_true "...qemu_instance_is_alive..." grep -q 'qemu_instance_is_alive'` → `assert_true "...qemu_instance_liveness(只探活实例)" grep -q 'qemu_instance_liveness'`
    2. L65 `assert_true "...qemu_instance_load..." grep -q 'qemu_instance_load'` → 删除该断言（cmd_smoke 不再直接调 load，liveness 吸收；探活不变量由 L64 liveness 锁覆盖）
    3. 注释 L9（`调 qemu_instance_is_alive`）→ `调 qemu_instance_liveness`；注释 L104（`qemu_instance_is_alive return 1`）→ `liveness = exited`
- [ ] Step 4: 运行并确认通过
  - Run: `bash tests/protocol/smoke_surface.sh && bash tests/orchestration/start_qemu_stale_pid.sh && bash tests/orchestration/start_qemu_force_restart.sh && bash tests/protocol/start_qemu_noninteractive.sh && bash tests/protocol/smoke_exit_contract.sh`
  - Expected: rc=0（cmd_smoke body-grep 锁新 liveness；start/stop/deploy 行为不变；stale_pid/force_restart/noninteractive 经 liveness 仍触原路径）
- [ ] Step 5: checkpoint commit（`refactor(qemu_commands): migrate 4 callers to qemu_instance_liveness`）

### Task 3: 删 is_alive 过渡 wrapper + 测试清理 + surface 锁

- 目标：所有 production caller 已迁（Task 2），删 `is_alive` 公开名，清理残留测试引用，加 surface 锁防回潮
- 涉及文件：`lib/qemu_instance.sh`、`tests/unit/ports.sh`、`tests/unit/qemu_instance.sh`
- 接口契约
  - Consumes: Task 2 产出（4 caller 经 liveness）；Task 1 的 is_alive wrapper
  - Produces: production 零 `qemu_instance_is_alive` 引用；`_qemu_instance_probe_alive` 私有留存

- [ ] Step 1: 确认 production caller 已迁（不含过渡 wrapper 所在文件，否则必命中 wrapper 假失败，评审 🔴3）
  - Run: `! grep -rn 'qemu_instance_is_alive' lib/qemu_commands.sh ob`
  - Expected: rc=0（4 cmd caller 已全迁；qemu_instance.sh 的过渡 wrapper + 测试残留留给 Step 2/3）
- [ ] Step 2: 删 wrapper + 清测试
  - Change:
    1. `lib/qemu_instance.sh`：删 `qemu_instance_is_alive()` 过渡 wrapper（Task 1 Step 3.3 加的）
    2. `tests/unit/ports.sh`：删 L28-30（`# --- qemu_instance_is_alive` 段 + 两条 rc 断言）+ L3 注释里 `/ qemu_instance_is_alive`
    3. `tests/unit/qemu_instance.sh` L58：`qemu_instance_is_alive() { return 0; }` stub → `qemu_instance_liveness() { printf -v "$2" '%s' running; return 0; }`（路径 B running，因 is_alive 已删；stub 改 liveness，summarize_brief 内部调 liveness 命中 stub）
- [ ] Step 3: surface 锁 + 私有 probe 留存验证
  - Run: `! grep -rn 'qemu_instance_is_alive' lib/ ob && grep -q '_qemu_instance_probe_alive' lib/qemu_instance.sh`
  - Expected: rc=0（wrapper 已在 Step 2 删，lib/ob 全清零；私有 probe 存在）
- [ ] Step 4: 测试通过 + exit_contract/extract_funcs 自检
  - Run: `bash tests/unit/ports.sh && bash tests/unit/qemu_instance.sh`
  - Expected: rc=0
  - Run: `OB_CHECK_SKIP_TESTS=1 bash tools/ob_check.sh`
  - Expected: 全 ✓（extract_funcs lib 三段清——is_alive 删除后无顶层残留；exit-contract `'qemu_instance.sh': set()` 仍过——liveness/_probe_alive 均无 `exit`）
- [ ] Step 5: checkpoint commit（`refactor(qemu_instance): retire is_alive public name, privatize probe`）

### Task 4: 文档维护（CONTEXT / coverage_matrix / radar / trace / WORKSPACE / 注释）

- 目标：文档与代码一致；CONTEXT.md 清函数名泄漏；coverage 矩阵指向新接口
- 涉及文件：`CONTEXT.md`、`docs/adr/0020-ob-smoke-probe-only-smoke-prober.md`（:19 流程）、`tools/coverage_matrix.md`、`tools/coverage_radar.py`、`tools/trace_collect.sh`、`rules/03_WORKSPACE.md`、`tests/protocol/smoke_exit_contract.sh`（L10 注释）、`tests/orchestration/start_qemu_force_restart.sh`（L42 注释）

- [ ] Step 1: CONTEXT.md L92/L191 + ADR 死指针核查更新（评审 🟡2：函数退役后 grep adr 旧符号，区分历史 rationale 保留 vs 当前机制引用更新）
  - Run: `grep -rn 'qemu_instance_is_alive' docs/adr/`
  - Expected: 输出命中 ADR 行（ADR-0024 自身是决策说明→保留；ADR-0020:19 是 smoke 当前机制流程→更新；其余历史 rationale→保留）
  - Change:
    - L92（`重启 (restart)` 条目）：`（\`qemu_instance_is_alive\` alive）` → `（存活状态为 \`running\`）`；`（\`is_alive\` 返 exited/recycled...` → `（存活状态为 \`exited\`/\`recycled\`...`
    - L191（`ob smoke` 条目）：`（\`qemu_instance_is_alive\` 非 alive）` → `（存活状态非 \`running\`）`
    - ADR-0020:19（smoke probe 当前机制流程，非历史 rationale）: 把 `qemu_instance_load → qemu_instance_is_alive → 读 PID file 端口` 改为 `qemu_instance_liveness（含 load+probe）→ 读 PID file 端口`
- [ ] Step 2: coverage_matrix.md
  - Change:
    - L69 `| PID 校验 | qemu_instance_is_alive | unit/ports.sh | |` → `| instance 存活状态 | qemu_instance_liveness | unit/qemu_instance.sh | running/exited/recycled/nopid; ADR-0024 |`
    - L81 instance module 行函数列表加 `qemu_instance_liveness`
- [ ] Step 3: radar/trace 注释核实更新
  - Run: `grep -n 'qemu_instance_is_alive' tools/coverage_radar.py tools/trace_collect.sh`
  - Expected: 输出含 `is_alive` 的行号与内容（据此判断是硬编码采集列表还是仅注释举例，决定 Change 改法；此步为核实非门禁）
  - Change: 若为硬编码函数采集列表，改 `qemu_instance_liveness`（`_qemu_instance_probe_alive` 仅当工具采集私有函数时保留）；若仅注释举例，注释更新为 `qemu_instance_liveness`
- [ ] Step 4: WORKSPACE.md + 测试注释
  - Change:
    - `rules/03_WORKSPACE.md` L11 `qemu_instance.sh` 职责描述：`list/load/is_alive/summarize...` → 补 `qemu_instance_liveness`（outvar 存活状态）、`is_alive` 标注已退役为私有 `_qemu_instance_probe_alive`
    - `tests/protocol/smoke_exit_contract.sh` L10 注释 + `tests/orchestration/start_qemu_force_restart.sh` L42 注释：`qemu_instance_is_alive` 提法更新
- [ ] Step 5: CONTEXT 函数名清零验证
  - Run: `! grep -n 'qemu_instance_is_alive' CONTEXT.md`
  - Expected: rc=0（CONTEXT.md 零 `qemu_instance_is_alive` 函数名引用——L195 已改概念表述「存活探测」、L92/L191 经 Step 1 改概念表述）
- [ ] Step 6: checkpoint commit（`docs(qemu_instance): sync CONTEXT/coverage/WORKSPACE to liveness interface`）

### Task 5: 最终验证

- [ ] Step 1: ob_check 一站式自检（含 run_all）
  - Run: `bash tools/ob_check.sh`
  - Expected: 全 ✓（extract_funcs / surface gates / exit-contract / run_all protocol+unit+orchestration 全清）
- [ ] Step 2: 全量回归（含 .exp）
  - Run: `bash tests/run_all.sh --full`
  - Expected: 全绿（protocol/unit/orchestration 的 .sh + .exp；不进 integration）
- [ ] Step 3: 输出修改摘要（新增 liveness、5 call site 迁移、is_alive 退役、文档同步）

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项/矛盾/命名不一致/验证命令无效先修计划
- 按任务顺序执行，不无声跳步/合并/改目标
- 每完成一任务跑该任务验证（Run 命令以 test/`! grep` 收尾，rc 即验证信号——勿用 echo 吞 rc）
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜
- 当前在 `main`：实现前先与用户确认是否开分支
- 全部任务完成后跑 Task 5 最终验证并输出摘要
- 改动 `ob`/`lib/*.sh` 后 ob_check 是配套自检（Task 3/5 已含）

## 最终验证

- `bash tools/ob_check.sh` → 全 ✓
- `bash tests/run_all.sh --full` → protocol/unit/orchestration 全绿
- `! grep -rn 'qemu_instance_is_alive' lib/ ob` → rc=0（公开名从 production 清零，私有 probe 留存）
- `! grep -n 'qemu_instance_is_alive' CONTEXT.md` → rc=0（CONTEXT.md 零函数名引用）

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-08-11-qemu-instance-liveness-outvar-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
