# 交互选择→exit-code 编排收口实施计划

## 目标

把 `lib/commands.sh` 中 5 处手写的「`select_from_list` / `confirm_action` 的 rc → exit-code 映射 + cancel 文案」收口到单一 exit-seam helper `exit_on_user_cancel`。零行为变化重构：退出码、cancel 文案字节级、控制流都不变。

## 架构快照

- 新增 `exit_on_user_cancel <rc> <verb>`：消费交互函数的 rc（`0=ok / 2=cancel / 1=read-fail`），rc 2 时 `warn "<verb> cancelled by user."` 并 `exit 2`，其他非 0 `exit 1`，0 时静默 return。
- 归属 `lib/commands.sh`（与既有 `status_section_*`、`_qemu_post_launch` 同构的 cmd_ 共享 exit-seam helper）；**不**进 `util.sh`（leaf-pure，受 `exit_contract` Y 规则约束）。
- 5 个收口点用 helper 替换手写 `if [[ rc -eq 2 ]]; then warn ...; exit 2; elif [[ rc -ne 0 ]]; then exit 1; fi` 块；cancel 文案由 verb 参数生成，与原 5 处文案字节级一致。
- `resolve_machine`（`lib/repo.sh`）本轮不动；其交互 rc→exit 收口留作下一轮，连同 repo.sh 纯化与回迁 commands.sh（呼应架构审查 #5）。
- 默认测试套件原本不锁 `cancel→exit 2`（仅 `.exp` 矩阵覆盖、默认跳过），本计划借机在 `interact.sh` 补 unit 回归锁，并对 rc=2 断言 cancel 文案子串（锁 helper 拼接逻辑）。

## 输入工件

- 设计共识：grill-with-docs 会话结晶（6 个决策 + 函数签名，见本仓会话上文）。
- 评审修订：纳入第 5 处 `confirm_action` cancel 映射（cmd_start_qemu confirm）；删 per-file shellcheck 验证（仓库已有 SC2164/SC2153/SC2012 历史告警，per-file 非门禁，baseline 比较在 ob_check.sh）；加 cancel 文案测试锁与 verb 字面值断言。
- 受影响代码：`lib/commands.sh`（`cmd_build` / `cmd_start_qemu` / `cmd_stop_qemu`）。
- 测试基建：`tests/unit/interact.sh` + `tests/lib/{assert.sh,ob_loader.sh}`；`warn()` 在 `util.sh:10` 输出到 **stdout**（消息部分无内嵌颜色码，子串断言可靠）。
- 验证工具：`tools/ob_check.sh`、`tests/run_all.sh`（见 `rules/03_WORKSPACE.md`）。

## 文件结构与职责

- **Modify** `lib/commands.sh`
  - 新增 `exit_on_user_cancel`，插入位置：`status_section_tips()` 之后、`cmd_status()` 定义之前。
  - 收口 `cmd_build` 的 select rc 块（约 339–346）与 confirm rc 块（约 361–368），verb 均为 `Build`。
  - 收口 `cmd_start_qemu` 的 select rc 块（约 511–518，verb `Start QEMU`）与 confirm rc 块（约 632–640，verb `QEMU start`）。
  - 收口 `cmd_stop_qemu` 的 select rc 块（约 822–829，verb `Stop QEMU`）。
- **Modify** `tests/unit/interact.sh`
  - 新增 `exit_on_user_cancel` 的 unit case：rc 0→0 / 2→2（含 cancel 文案子串断言）/ 1→1。
  - 更新顶部注释覆盖范围说明。
- **不改动**：`lib/util.sh`（leaf-pure 边界）、`lib/repo.sh`（`resolve_machine` 本轮不动）、`CONTEXT.md`、`docs/adr/`（本轮无 surprising 决策）。

## 任务清单

### Preflight: 环境与分支确认

- 目标：实现前透明化当前分支与工作区状态，明确 commit 边界。
- Run: `git branch --show-current && git status --short`
- Expected: 记录当前分支（当前为 `main`）与工作区是否干净。按 SOUL 自主执行契约，working tree 内 commit 是安全迭代手段；但本计划默认**不自行 commit**——实现阶段只编辑文件，commit 仅在用户明确要求时执行（见各 Task 末）。若用户要求隔离再建分支。

### Task 1: 新增 exit_on_user_cancel helper

- 目标：在 `commands.sh` 新增 helper，并用 `interact.sh` unit 测试锁住其 rc→exit 契约与 cancel 文案拼接。
- Files:
  - Modify: `lib/commands.sh`（新增 `exit_on_user_cancel`）
  - Modify: `tests/unit/interact.sh`（新增 case + 顶部注释）
- 验证范围：`bash tests/unit/interact.sh` 新增 case 全 PASS，FAIL=0，退出码 0。

**Step 1: 写失败测试（先加 unit case，helper 尚不存在）**

在 `tests/unit/interact.sh` 的 `# --- confirm_action ---` 段之后、`# --- prompt_for_absolute_path ---` 段之前插入。注意 `warn()` 走 stdout，用 `$(...)` 捕获即可（无需 `2>&1`）：

```bash
# --- exit_on_user_cancel: 消费 select_from_list/confirm_action 的 rc ---
# 会 exit,用 $(...) 子 shell 跑,父 shell 捕 $?;函数已由 ob_loader source 进当前 shell。
out=$( exit_on_user_cancel 0 "Build" ); assert_eq "exit rc0 returns 0" "$?" 0
out=$( exit_on_user_cancel 2 "Build" ); assert_eq "exit rc2 exits 2" "$?" 2
assert_contains "exit rc2 cancel msg" "$out" "Build cancelled by user."
out=$( exit_on_user_cancel 1 "Build" ); assert_eq "exit rc1 exits 1" "$?" 1
```

并把顶部注释第 3 行覆盖范围补上 `exit_on_user_cancel`。

- Run: `bash tests/unit/interact.sh`
- Expected: 新 case FAIL（helper 未定义 → 子 shell `command not found` → rc 127），`assert_summary` FAIL 非 0，退出码非 0。

**Step 2: 实现 helper**

在 `lib/commands.sh` 的 `status_section_tips()` 函数结束后、`cmd_status()` 定义前插入：

```bash

# exit_on_user_cancel <rc> <verb>
# 消费 select_from_list / confirm_action 的 rc (0=ok / 2=cancel / 1=read-fail)。
# rc 0 → return 0 继续下行;rc 2 → warn "<verb> cancelled by user." + exit 2;
# 否则 exit 1(read-fail 的 error 已由 L3 调用方 select_from_list/confirm_action 打印)。
# L1 exit-seam helper;调用方负责先 `|| rc=$?` 捕获 rc 再传入。
exit_on_user_cancel() {
    local rc="$1" verb="$2"
    if   [[ "$rc" -eq 2 ]]; then
        warn "$verb cancelled by user."
        exit 2
    elif [[ "$rc" -ne 0 ]]; then
        exit 1
    fi
}
```

- Change: 新增 helper 定义；未触碰任何调用点。

**Step 3: 运行并确认通过**

- Run: `bash tests/unit/interact.sh`
- Expected: 输出含 `ok   exit rc0 returns 0` / `ok   exit rc2 exits 2` / `ok   exit rc2 cancel msg` / `ok   exit rc1 exits 1`，FAIL=0，退出码 0。

**Step 4: checkpoint commit（仅用户明确要求时执行，否则跳过）**

- Run: `git add lib/commands.sh tests/unit/interact.sh && git commit -m "feat(ob): add exit_on_user_cancel helper + unit tests"`
- Expected: 仅在用户明确要求提交时执行；否则跳过本步。

### Task 2: 收口 cmd_build 的 select + confirm rc 映射

- 目标：`cmd_build` 内 select rc 块与 confirm rc 块两处手写映射，替换为 `exit_on_user_cancel`，verb 均为 `Build`。
- Files: Modify `lib/commands.sh`（`cmd_build`）
- 验证范围：`cmd_build` 内两处硬编码 `warn "Build cancelled by user."` 消失；两处 `exit_on_user_cancel ... "Build"` 出现且 verb 字面值正确。

**Step 1: 改动前检查**

- Run: `grep -nE 'warn "Build cancelled' lib/commands.sh`
- Expected: 命中 2 行（select 块约 342、confirm 块约 364）。

**Step 2: 替换 select rc 块**

将

```bash
        local sfl_rc=0
        select_from_list "Select a machine to build [1-${total}]" "$total" || sfl_rc=$?
        if [[ "$sfl_rc" -eq 2 ]]; then
            warn "Build cancelled by user."
            exit 2
        elif [[ "$sfl_rc" -ne 0 ]]; then
            exit 1
        fi
        local chosen="${machines[$((SELECT_FROM_LIST_CHOICE - 1))]}"
```

改为

```bash
        local sfl_rc=0
        select_from_list "Select a machine to build [1-${total}]" "$total" || sfl_rc=$?
        exit_on_user_cancel "$sfl_rc" "Build"
        local chosen="${machines[$((SELECT_FROM_LIST_CHOICE - 1))]}"
```

**Step 3: 替换 confirm rc 块**

将

```bash
        local ca_rc=0
        confirm_action "build" "$MACHINE" || ca_rc=$?
        if [[ "$ca_rc" -eq 2 ]]; then
            warn "Build cancelled by user."
            exit 2
        elif [[ "$ca_rc" -ne 0 ]]; then
            exit 1
        fi
```

改为

```bash
        local ca_rc=0
        confirm_action "build" "$MACHINE" || ca_rc=$?
        exit_on_user_cancel "$ca_rc" "Build"
```

- Change: `cmd_build` 两处手写 if-elif-exit 块各缩为一行 helper 调用；`interactive_selection` 守卫与 `|| rc=$?` 捕获保留不变。

**Step 4: 改动后验证（verb 字面值 + 文案消失）**

- Run: `grep -nF 'exit_on_user_cancel "$sfl_rc" "Build"' lib/commands.sh`
- Expected: 命中 1 行（select 点）。
- Run: `grep -nF 'exit_on_user_cancel "$ca_rc" "Build"' lib/commands.sh`
- Expected: 命中 1 行（confirm 点）。
- Run: `grep -nE 'warn "Build cancelled' lib/commands.sh`
- Expected: 无命中。

### Task 3: 收口 cmd_start_qemu 的 select + confirm rc 映射

- 目标：`cmd_start_qemu` 内 select rc 块（verb `Start QEMU`）与 confirm rc 块（verb `QEMU start`）两处手写映射替换为 `exit_on_user_cancel`。两处 verb 不同，必须各自保留以保文案字节级不变。
- Files: Modify `lib/commands.sh`（`cmd_start_qemu`）
- 验证范围：两处硬编码 cancel warn 消失；两处 helper 调用出现，verb 分别精确为 `Start QEMU` / `QEMU start`。

**Step 1: 改动前检查**

- Run: `grep -nE 'warn "(Start QEMU|QEMU start) cancelled' lib/commands.sh`
- Expected: 命中 2 行（select 约 514、confirm 约 636）。

**Step 2: 替换 select rc 块**

将

```bash
        local sfl_rc=0
        select_from_list "Select a machine [1-${total}]" "$total" || sfl_rc=$?
        if [[ "$sfl_rc" -eq 2 ]]; then
            warn "Start QEMU cancelled by user."
            exit 2
        elif [[ "$sfl_rc" -ne 0 ]]; then
            exit 1
        fi
        MACHINE="${machines[$((SELECT_FROM_LIST_CHOICE - 1))]}"
```

改为

```bash
        local sfl_rc=0
        select_from_list "Select a machine [1-${total}]" "$total" || sfl_rc=$?
        exit_on_user_cancel "$sfl_rc" "Start QEMU"
        MACHINE="${machines[$((SELECT_FROM_LIST_CHOICE - 1))]}"
```

**Step 3: 替换 confirm rc 块（安全确认，函数体顶层 4 空格缩进）**

将

```bash
    # ── Safety confirmation (same pattern as ob init / ob build) ──
    local ca_rc=0
    confirm_action "start QEMU for" "$MACHINE" || ca_rc=$?
    if [[ "$ca_rc" -eq 2 ]]; then
        warn "QEMU start cancelled by user."
        exit 2
    elif [[ "$ca_rc" -ne 0 ]]; then
        exit 1
    fi
```

改为

```bash
    # ── Safety confirmation (same pattern as ob init / ob build) ──
    local ca_rc=0
    confirm_action "start QEMU for" "$MACHINE" || ca_rc=$?
    exit_on_user_cancel "$ca_rc" "QEMU start"
```

- Change: select 与 confirm 两处手写块各缩为一行 helper 调用；`confirm_action "start QEMU for"` 调用本身、3 秒倒计时、launch 等保留不变。

**Step 4: 改动后验证（verb 字面值 + 文案消失）**

- Run: `grep -nF 'exit_on_user_cancel "$sfl_rc" "Start QEMU"' lib/commands.sh`
- Expected: 命中 1 行（select 点，锁 sfl_rc↔"Start QEMU" 对应，防写反）。
- Run: `grep -nF 'exit_on_user_cancel "$ca_rc" "QEMU start"' lib/commands.sh`
- Expected: 命中 1 行（confirm 点，锁 ca_rc↔"QEMU start" 对应）。
- Run: `grep -nE 'warn "(Start QEMU|QEMU start) cancelled' lib/commands.sh`
- Expected: 无命中。

### Task 4: 收口 cmd_stop_qemu 的 select rc 映射 + 全局收口确认

- 目标：`cmd_stop_qemu` 内 select rc 块替换为 `exit_on_user_cancel`，verb `Stop QEMU`；并做全局收口确认（5 处全部收敛到 helper）。
- Files: Modify `lib/commands.sh`（`cmd_stop_qemu`）
- 验证范围：`commands.sh` 内硬编码 cancel warn 全部消失（仅剩 helper 定义内一行）；helper 调用共 5 处，verb 字面值精确。

**Step 1: 改动前检查**

- Run: `grep -n 'warn "Stop QEMU cancelled' lib/commands.sh`
- Expected: 命中 1 行（约 825）。

**Step 2: 替换**

将

```bash
        local sfl_rc=0
        select_from_list "Select instance to stop [1-${total}]" "$total" || sfl_rc=$?
        if [[ "$sfl_rc" -eq 2 ]]; then
            warn "Stop QEMU cancelled by user."
            exit 2
        elif [[ "$sfl_rc" -ne 0 ]]; then
            exit 1
        fi
        targets+=("${available[$((SELECT_FROM_LIST_CHOICE - 1))]}")
```

改为

```bash
        local sfl_rc=0
        select_from_list "Select instance to stop [1-${total}]" "$total" || sfl_rc=$?
        exit_on_user_cancel "$sfl_rc" "Stop QEMU"
        targets+=("${available[$((SELECT_FROM_LIST_CHOICE - 1))]}")
```

- Change: select 手写块缩为一行 helper 调用；空列表 `exit 0`、`--all` 与状态列渲染保留不变。

**Step 3: 改动后验证（verb 字面值）**

- Run: `grep -nF 'exit_on_user_cancel "$sfl_rc" "Stop QEMU"' lib/commands.sh`
- Expected: 命中 1 行。

**Step 4: 全局收口确认**

- Run: `grep -nE '^[[:space:]]+warn ".*cancelled by user' lib/commands.sh`
- Expected: 恰好 1 行命中（helper 定义内的 `warn "$verb cancelled by user."`）；收口前为 5 行（Build×2 / Start QEMU / QEMU start / Stop QEMU）。锚定 `^[[:space:]]+warn`（行首缩进的 warn）以排除 helper 注释里的 `warn "<verb> cancelled by user."` 字样——裸 `warn ".*cancelled by user` 会误命中注释，实测命中 2 行（注释 + 实际），与第二轮 `grep -c` 注释干扰同类。
- 说明：不在此跑 per-file `shellcheck lib/commands.sh`——仓库已有 SC2164/SC2153/SC2012 历史告警，per-file 退出 1，不能当 PASS 条件；shellcheck baseline 比较由最终 `ob_check.sh` 完成。也不做 `grep -c exit_on_user_cancel` 总数断言——helper 注释行 `# exit_on_user_cancel <rc> <verb>` 和定义行 `exit_on_user_cancel() {` 也会命中，总数不稳定（实际为 7，非 6）；调用点正确性已由各 Task 的 verb 字面值 grep 锁死。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证。
- 行号仅为辅助定位，以函数名 + 代码块内容为准确契约；若代码已漂移，用对应 `grep` 重新定位。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 当前分支为 `main`：实现阶段只编辑文件，不自行 commit；commit 仅在用户明确要求时执行。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `bash tools/ob_check.sh`
  - Expected: 结构检查 / 函数登记（extract_funcs）/ shellcheck baseline（flat 合成 + 纯文本比较）/ exit-contract / run_all 默认套件全部通过，exit 0。
  - 关注点：`exit_contract` 的 Y 规则（util / bitbake_env / machine_state 为 leaf-pure）不受影响——`exit_on_user_cancel` 在 `commands.sh`，本就不在 leaf-pure 集。shellcheck baseline 关注是否有**新增**告警，而非零告警（历史告警已纳入 baseline）。ob_check 已聚合默认 `run_all.sh`，故下一条单独 run_all 仅作显式确认，可省略。
- Run（可选显式确认，ob_check 已覆盖）: `bash tests/run_all.sh`
  - Expected: protocol / unit / orchestration 默认套件全过，含 `interact.sh` 新增的 `exit_on_user_cancel` case（rc 0/2/1 + rc=2 cancel 文案断言）；FAIL=0。
- 可选（确认 cancel 端到端退出码零变化）: `bash tests/run_all.sh --full`（驱动 `manual_matrix.exp` 的 init/build/start cancel）与 `bash tests/run_all.sh --integration`（stop cancel）。
  - Expected: 各 cancel 场景退出码仍为 2。注意 `.exp` 矩阵只断言退出码、不断言文案，故 cancel 文案正确性不由此路径覆盖——文案由 Task 1 helper unit 的 `assert_contains` + Task 2/3/4 的 verb 字面值 grep 锁定。
- 修改摘要应包含：新增 `exit_on_user_cancel`、5 处收口（cmd_build×2 / cmd_start_qemu×2 / cmd_stop_qemu×1）、`interact.sh` +cancel 文案断言、cancel 文案由 5 处手写收敛为 helper 统一生成。

## 审阅 Checkpoint

- 计划正文到此结束。请先审阅这份计划；如有问题，我修改并重跑自检。审阅通过后，默认执行方是普通编码 agent 或人工，按计划推进。
