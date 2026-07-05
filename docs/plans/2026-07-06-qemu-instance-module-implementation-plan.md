# QEMU instance module 实施计划

## 目标

把 "QEMU instance" 抽成 deep module（新文件 `lib/qemu_instance.sh`，leaf-pure），吸收 `lib/commands.sh` 里 4 处 inline 的 PID 文件物理布局知识（`.pids/*.pid` glob、kv 字段读取、`/proc/$pid` 存活判断、stale 清理）。模块立起后，caller 只通过 interface 查询/渲染实例，PID 文件 schema 成为单一真值。

唯一 behavior change：`ob status` 从「隐式 `rm` stale PID 文件且不显示」改为「只读、显示 `⚠️ stale`」。stale 清理 owner 收敛到 `ob start-qemu` 冲突块 / `ob stop-qemu`。

## 架构快照

- 新建 `lib/qemu_instance.sh`（leaf-pure module，与 `machine_state.sh` 同构），承载 7 个函数：`qemu_instance_list / qemu_instance_load / qemu_instance_is_alive / qemu_instance_summarize_brief / qemu_instance_summarize_full / qemu_instance_clean_stale / qemu_instance_stop`。
- 前 4 个（load/is_alive/summarize_full/stop）从 `lib/qemu.sh` 搬迁并改名（原 `read_pid_file / validate_pid / qemu_instance_describe / qemu_stop_instance`，已事实 leaf-pure，无一 `exit`）；后 3 个（list/summarize_brief/clean_stale）新增。
- `lib/qemu.sh` 移除搬走的 4 函数（瘦身 ~80 行），非 instance 函数（`build_qemu_cmd / qemu_prepare_launch / qemu_execute_launch / check_ports_available / hostkey` 等）不动。
- `lib/commands.sh` 4 处 inline 改为调 module：`cmd_status`（240-266）、`cmd_stop_qemu`（591-646）、`cmd_start_qemu` 冲突块（507-542）、`__stop_qemu_running_machines`（583-589，删除）。
- `ob` 用 `for f in lib/*.sh; do source "$f"; done`（[ob:76](ob#L76)）glob 加载，新文件**自动 source，无需改 ob**。
- 测试经 `tests/lib/ob_loader.sh` source ob，所有 lib 函数自动可用。

## 全局约束

- **leaf-pure 纪律**：`lib/qemu_instance.sh` 登记 `tools/exit_contract.py` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（`'qemu_instance.sh': set()`，无例外），函数绝不 `exit`，只 `return`。caller（exit seam）收口 exit-code 契约。
- **behavior-preserving 除一处**：`ob status` 显示 stale 且不删（Task 6），其余 caller 改造行为不变。stale 含两类——`exited`（进程没了，`/proc/$pid` 不在）和 `recycled`（PID 被复用，`/proc/$pid` 在但 cmdline 不匹配 binary/machine）；旧 `cmd_status` 只查 `/proc` 存在，recycled 会误显示 `✅ running`，新行为（经 `qemu_instance_is_alive` 严格校验）两类都显示 `⚠️ stale`。
- **不动**：`machine_picker.sh` / `pick_machine` / `read_machine_choice`（machine discovery 前置序列是「第二刀」）；`qemu.sh` 非 instance 函数。
- **可回滚**：每个 Task 一个 working-tree commit，`main` 分支开始前先与用户确认切分支。
- **配套自检**：改 `ob`/`lib/*.sh` 后必须跑 `tools/ob_check.sh`（AGENTS.md 规定）。

## 输入工件

- 设计共识：grilling 走完的 7 分支决策（本会话确认，未另落 spec）。
- 领域术语：[CONTEXT.md](CONTEXT.md) 的 `QEMU instance` / `QEMU PID file` / `function semantic layer` / `exit-code 契约`。
- 架构报告：`/tmp/architecture-review-20260705-222053.html`（candidate 可视化）。
- 相关 ADR：无直接冲突（ADR-0007 是 `QEMU launch profile` 的 decision seam，与 instance lifecycle 正交）。

## 文件结构与职责

- **Create**: `lib/qemu_instance.sh` — QEMU instance 只读视图 + stale 清理 + stop（7 函数，leaf-pure）。
- **Create**: `tests/unit/qemu_instance.sh` — hermetic 单测（造 `.pids` 目录测 list/load/summarize_brief/summarize_full/clean_stale；`is_alive` 沿用 ports.sh 真实-`/proc` 模式）。
- **Modify**: `lib/qemu.sh` — 移除搬走的 4 函数（`read_pid_file / validate_pid / qemu_instance_describe / qemu_stop_instance`）。
- **Modify**: `lib/commands.sh` — 4 处 caller 改造 + 删 `__stop_qemu_running_machines`。
- **Modify**: `tools/exit_contract.py` — `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加 `'qemu_instance.sh': set()`。
- **Modify**: `tools/coverage_matrix.md` — 函数改名 + 新增 qemu_instance 行。
- **Modify**: `tests/protocol/status_machine_state.sh` — 扩展 stale 显示断言。
- **Delete**: `tests/unit/qemu_instance_describe.sh` — 内容迁入 `tests/unit/qemu_instance.sh`（Task 2/3 时合并）。
- **无需改**: `ob`（glob source 自动覆盖）。

## 任务清单

### Task 0: git preflight

- **目标**：确认分支、处置当前已 staged 的非任务文件（CONTEXT.md 术语 + 本 plan），建立 path-limited commit 纪律。防止后续 task 的 commit 把无关文件卷入。
- **Files**: 无代码改动（仅 git 操作）。
- **验证范围**：`git status --short` 暂存区清空到只含本次处置的文件；分支符合预期。
- **接口契约**: Consumes 无；Produces 干净起点（后续 task 依赖）。

- [ ] **Step 1: 确认分支**
  - Run: `git rev-parse --abbrev-ref HEAD`
  - Expected: 非 `main`/`master`，或在 `main` 且用户已明确同意在此实现（SOUL：不可逆/外发操作前确认）。

- [ ] **Step 2: 处置已 staged 的非任务文件**
  - Run: `git status --short`
  - Expected: 看到 `M  CONTEXT.md`（grilling 加 `QEMU instance` 术语）与 `A  docs/plans/2026-07-06-qemu-instance-module-implementation-plan.md`（本文件）。各自独立 commit，**不混入**后续代码 task：
    - Run: `git commit -m "docs(context): add QEMU instance glossary term" -- CONTEXT.md`
    - Run: `git commit -m "docs(plan): qemu instance module implementation plan" -- docs/plans/2026-07-06-qemu-instance-module-implementation-plan.md`
    - Expected: 两个 commit 成功；`git status --short` 干净。

- [ ] **Step 3: 建立提交纪律（约束后续所有 task）**
  - 后续每个 task 只 `git add <该 task Files 列出的精确路径>`；commit 前先 `git diff --cached --name-only` 核对只含本 task 文件；**禁用 `git add -A`**。

### Task 1: 搬迁 4 个 instance 函数到新 module（保留原名）

- **目标**：把 `read_pid_file / validate_pid / qemu_instance_describe / qemu_stop_instance` 从 `lib/qemu.sh` 物理移动到新建 `lib/qemu_instance.sh`，函数名不变，调用点不动。纯 move，零 behavior change。
- **Files**: Create `lib/qemu_instance.sh`；Modify `lib/qemu.sh`。
- **验证范围**：4 函数只在 `qemu_instance.sh` 出现定义；`tools/ob_check.sh` 通过。
- **接口契约**：
  - Consumes：`lib/qemu.sh` 现有 4 函数（`read_pid_file:361 / validate_pid:395 / qemu_instance_describe:417 / qemu_stop_instance:427`）。
  - Produces：`lib/qemu_instance.sh`（4 函数，原名）；`lib/qemu.sh` 不再含这 4 函数。

- [ ] **Step 1: 改动前检查**（确认 4 函数当前在 qemu.sh）
  - Run: `grep -nE '^(read_pid_file|validate_pid|qemu_instance_describe|qemu_stop_instance)\(\)' lib/qemu.sh`
  - Expected: 4 行命中（定义在 qemu.sh）。

- [ ] **Step 2: 创建 lib/qemu_instance.sh**
  - Change: 新建文件，header 标注 leaf-pure module，从 `lib/qemu.sh` 原样搬入 4 函数（连同其上方的中文注释）。文件头：
    ```bash
    #!/usr/bin/env bash
    # lib/qemu_instance.sh — QEMU instance 只读视图 + stale 清理 + stop. 术语见 CONTEXT.md QEMU instance / QEMU PID file.
    # Exit: leaf-pure module（函数绝不 exit, 只 return; 与 machine_state.sh 同构）.
    ```
    搬入的 4 函数体保持一字不改（含 `read_pid_file` 的 `while IFS='=' read` 自解析、`validate_pid` 的 `/proc/$pid/cmdline` 校验、`qemu_instance_describe` 的四行 echo、`qemu_stop_instance` 的 kill+wait+SIGKILL+rm）。

- [ ] **Step 3: 从 lib/qemu.sh 删除 4 函数**
  - Change: 删除 `lib/qemu.sh` 中这 4 个函数定义及其上方注释（行段约 361-441）。`lib/qemu.sh` 的 header 注释若提及这 4 函数也一并修正。

- [ ] **Step 4: 改动后验证**
  - Run: `grep -nE '^(read_pid_file|validate_pid|qemu_instance_describe|qemu_stop_instance)\(\)' lib/*.sh`
  - Expected: 4 行全部命中 `lib/qemu_instance.sh`，`lib/qemu.sh` 0 命中。
  - Run: `tools/ob_check.sh`
  - Expected: 全绿（`extract_funcs` 认到 4 函数在新文件；`exit_contract` 未登记 qemu_instance.sh 前，4 函数本就不 exit，不触发 Y 规则——见 Task 2 登记）。

- [ ] **Step 5: checkpoint commit**
  - Run: `git add lib/qemu_instance.sh lib/qemu.sh && git commit -m "refactor(qemu_instance): move 4 instance fns to new leaf-pure module (renames follow)"`
  - Expected: commit 成功。

### Task 2: 登记 leaf-pure + 改名 4 函数 + 同步调用点

- **目标**：把 4 函数改为 grilling 确认的新名（`qemu_instance_load / qemu_instance_is_alive / qemu_instance_summarize_full / qemu_instance_stop`），登记 `exit_contract`，同步更新所有调用点。
- **Files**: Modify `lib/qemu_instance.sh`、`tools/exit_contract.py`、`lib/commands.sh`、`tests/unit/ports.sh`、`tests/unit/qemu_instance_describe.sh`、`tests/orchestration/qemu_stop_instance.sh`、`tests/orchestration/start_qemu_force_restart.sh`。
- **验证范围**：旧函数名 0 残留；`ob_check.sh` 通过。
- **接口契约**：
  - Consumes：Task 1 产出的 4 原名函数。
  - Produces：4 函数新名 + load 签名增强 + 内部路径 helper（后续 Task 4/5/7 消费，使 caller 不再拼 `.pids` 路径）：
    - `_qemu_instance_pid_file <machine>` — module 内部 helper（下划线前缀，私有），`echo "$WORKSPACE_DIR/qemu-bin/.pids/$1.pid"`，收口 `.pids` 物理路径。
    - `qemu_instance_load [machine]` — 传 machine 则内部经 helper 设 `QEMU_PID_FILE` 再读；不传则用调用者已设的 `QEMU_PID_FILE`（兼容 `cmd_start_qemu` 经 `derive_qemu_paths` 设的路径）。字段读入 `PIDFILE_*` 全局，`return 0/1`。
    - `qemu_instance_is_alive <pid> <binary> <machine> → 0/1/2`、`qemu_instance_summarize_full`、`qemu_instance_stop <pid> <file>`。

- [ ] **Step 1: 改动前检查**（旧名调用点清单）
  - Run: `grep -rnE '\b(read_pid_file|validate_pid|qemu_instance_describe|qemu_stop_instance)\b' lib/ tests/ | grep -v 'qemu_instance.sh:'`
  - Expected: 命中 `commands.sh`（508/510/517/521/532/659/665/691/722 等）、`tests/unit/ports.sh`、`tests/unit/qemu_instance_describe.sh`、`tests/orchestration/qemu_stop_instance.sh`。

- [ ] **Step 2: 改名 + load 签名增强 + 登记 leaf-pure**
  - Change:
    - `lib/qemu_instance.sh`：
      - 顶部（load 之前）新增 module 内部 helper：`_qemu_instance_pid_file() { echo "$WORKSPACE_DIR/qemu-bin/.pids/$1.pid"; }`
      - `read_pid_file()` → `qemu_instance_load()`，并在原函数体首行（`if [[ ! -f "$QEMU_PID_FILE" ]]` 之前）插入 machine 可选参数处理：`local machine="${1:-}"; [[ -n "$machine" ]] && QEMU_PID_FILE="$(_qemu_instance_pid_file "$machine")";`；其余字段读取体不变。
      - `validate_pid()` → `qemu_instance_is_alive()`；`qemu_instance_describe()` → `qemu_instance_summarize_full()`；`qemu_stop_instance()` → `qemu_instance_stop()`。函数体不变，注释里的旧名一并改。
    - `tools/exit_contract.py`：`LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 加一行 `'qemu_instance.sh': set(),`（Y 规则覆盖 module 内所有函数含 helper，均不 exit）。

- [ ] **Step 3: 同步调用点与测试注释**
  - Change（全部为同名替换，行为不变；**含测试文件注释**，否则 Step 4 grep 会命中注释残留导致验证失败）：
    - `lib/commands.sh`：`read_pid_file` → `qemu_instance_load`、`validate_pid` → `qemu_instance_is_alive`、`qemu_instance_describe` → `qemu_instance_summarize_full`、`qemu_stop_instance` → `qemu_instance_stop`（cmd_start_qemu 508-532、cmd_stop_qemu 659-722 范围内的调用）。
    - `tests/unit/ports.sh`：`validate_pid` 断言（行 29-30）+ 注释（行 3、28）→ `qemu_instance_is_alive`。
    - `tests/unit/qemu_instance_describe.sh`：`qemu_instance_describe`（行 15）+ 注释（行 2）→ `qemu_instance_summarize_full`。该文件后续在 Task 3 合并进 `tests/unit/qemu_instance.sh`，此处只改函数名让它先绿。
    - `tests/orchestration/qemu_stop_instance.sh`：`qemu_stop_instance` 调用（行 11、24）+ 注释（行 2、20）→ `qemu_instance_stop`。
    - `tests/orchestration/start_qemu_force_restart.sh`：注释（行 42）`validate_pid` → `qemu_instance_is_alive`（该测试无直接调用，仅注释引用旧名）。

- [ ] **Step 4: 改动后验证**
  - Run: `grep -rnE '\b(read_pid_file|validate_pid|qemu_instance_describe|qemu_stop_instance)\b' lib/ tests/`
  - Expected: 0 命中（旧名彻底消失）。
  - Run: `tools/ob_check.sh`
  - Expected: 全绿。`exit_contract` Y 规则覆盖 `qemu_instance.sh`，4 函数本就不 exit，合规。

- [ ] **Step 5: checkpoint commit**
  - Run: `git add lib/qemu_instance.sh tools/exit_contract.py lib/commands.sh tests/unit/ports.sh tests/unit/qemu_instance_describe.sh tests/orchestration/qemu_stop_instance.sh tests/orchestration/start_qemu_force_restart.sh && git commit -m "refactor(qemu_instance): rename 4 fns + register leaf-pure + load signature"`
  - Expected: commit 成功。

### Task 3: 新增 qemu_instance_list + 合并 describe 单测

- **目标**：新增 `qemu_instance_list`（枚举 `.pids/*.pid` 对应的 machine 全集，作 list-source）；把 `tests/unit/qemu_instance_describe.sh` 合并进新建的 `tests/unit/qemu_instance.sh`。
- **Files**: Modify `lib/qemu_instance.sh`；Create `tests/unit/qemu_instance.sh`；Delete `tests/unit/qemu_instance_describe.sh`。
- **验证范围**：`tests/unit/qemu_instance.sh` 通过；`run_all.sh` 绿。
- **接口契约**：
  - Consumes：`$WORKSPACE_DIR`（caller 保证已设）。
  - Produces：`qemu_instance_list`（stdout 每行一个 machine 名，无实例时输出空）。

- [ ] **Step 1: 写失败测试**
  - Change: 新建 `tests/unit/qemu_instance.sh`，合并原 describe 测 + 新 list 测：
    ```bash
    #!/usr/bin/env bash
    # tests/unit/qemu_instance.sh — QEMU instance module 单测（hermetic）。
    source "$(dirname "$0")/../lib/ob_loader.sh"
    source "$(dirname "$0")/../lib/assert.sh"
    assert_reset

    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    WORKSPACE_DIR="$TMP/workspace"
    PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
    mkdir -p "$PIDS_DIR"
    # 造两个实例 PID 文件
    printf 'pid=111\nbinary=qemu-system-arm\nmachine=romulus\nssh_port=2222\nredfish_port=2443\nipmi_port=2623\n' > "$PIDS_DIR/romulus.pid"
    printf 'pid=222\nmachine=witherspoon\n' > "$PIDS_DIR/witherspoon.pid"

    # --- qemu_instance_list ---
    out="$(qemu_instance_list | sort)"
    assert_eq "list returns all machines" "$out" "romulus
witherspoon"

    # --- qemu_instance_load（Task 7 关键接口：接 machine 设路径 + 读字段；无参兼容 caller 的 QEMU_PID_FILE）---
    qemu_instance_load romulus
    assert_eq "load sets pid" "$PIDFILE_PID" "111"
    assert_eq "load sets machine" "$PIDFILE_MACHINE" "romulus"
    assert_eq "load sets pid file path" "$QEMU_PID_FILE" "$PIDS_DIR/romulus.pid"
    QEMU_PID_FILE="$PIDS_DIR/witherspoon.pid"
    qemu_instance_load
    assert_eq "load no-arg keeps compatibility" "$PIDFILE_MACHINE" "witherspoon"

    # 空目录
    rm -f "$PIDS_DIR"/*.pid
    out="$(qemu_instance_list)"
    assert_eq "list empty when no pids" "$out" ""

    # --- qemu_instance_summarize_full（合并自 qemu_instance_describe.sh）---
    PIDFILE_PID="12345"; PIDFILE_STARTED_AT="2026-07-04T01:02:03Z"
    PIDFILE_SSH_PORT="2222"; PIDFILE_REDFISH_PORT="2443"; PIDFILE_IPMI_PORT="2623"
    PIDFILE_SERIAL_LOG="/tmp/serial.log"
    out="$(qemu_instance_summarize_full)"
    assert_contains "full has PID line"     "$out" "PID       : 12345"
    assert_contains "full has Ports line"   "$out" "SSH(2222) Redfish(2443) IPMI(2623/UDP)"
    assert_contains "full has Serial line"  "$out" "Serial log: /tmp/serial.log"

    assert_summary
    ```

- [ ] **Step 2: 运行并确认失败**
  - Run: `bash tests/unit/qemu_instance.sh`
  - Expected: 失败——`qemu_instance_list: command not found`（函数还没定义）。

- [ ] **Step 3: 写最小实现**
  - Change: 在 `lib/qemu_instance.sh` 加：
    ```bash
    # qemu_instance_list — 枚举当前 workspace 所有 QEMU PID 文件对应的 machine 名（全集，
    # 每行一个）。作 list-source；存活判断不在此（caller 调 qemu_instance_is_alive）。
    # 与 lib/qemu.sh derive_qemu_paths 的 QEMU_PIDS_DIR 同源（$WORKSPACE_DIR/qemu-bin/.pids）。
    qemu_instance_list() {
        local pid_file
        for pid_file in "$WORKSPACE_DIR/qemu-bin/.pids/"*.pid; do
            [[ -f "$pid_file" ]] || continue
            basename "$pid_file" .pid
        done
    }
    ```
  - Delete `tests/unit/qemu_instance_describe.sh`（内容已合并）。

- [ ] **Step 4: 运行并确认通过**
  - Run: `bash tests/unit/qemu_instance.sh`
  - Expected: `assert_summary` 全绿。
  - Run: `tools/ob_check.sh`
  - Expected: 全绿（describe 测文件删除后 `run_all` 不再引用它）。

- [ ] **Step 5: checkpoint commit**
  - Run: `git add lib/qemu_instance.sh tests/unit/qemu_instance.sh tests/unit/qemu_instance_describe.sh && git commit -m "feat(qemu_instance): add qemu_instance_list + merge describe unit"`
  - Expected: commit 成功。

### Task 4: 新增 qemu_instance_summarize_brief（单行 + stale 标注）

- **目标**：新增 `qemu_instance_summarize_brief <machine>`，输出详情行（`PID <pid>   SSH(...) Redfish(...) IPMI(...)   ✅ running / ⚠️ stale`），machine 名留给 caller 布局。内部 `load → is_alive`，统一存活判断。
- **Files**: Modify `lib/qemu_instance.sh`、`tests/unit/qemu_instance.sh`。
- **验证范围**：`tests/unit/qemu_instance.sh` 通过。
- **接口契约**：
  - Consumes：`qemu_instance_load`、`qemu_instance_is_alive`（Task 2 产出）；`$WORKSPACE_DIR`。
  - Produces：`qemu_instance_summarize_brief <machine>` → stdout 一行详情（不含 machine 名），stale 时标 `⚠️ stale`。

- [ ] **Step 1: 写失败测试**
  - Change: 在 `tests/unit/qemu_instance.sh` 追加（重新造一个 running 用 `$$` 难控 cmdline，故用 stub 拦截 is_alive 的 /proc；这里用「PID 不存在 → stale」+「stub load 后直接设字段」两条路径）：
    ```bash
    # --- qemu_instance_summarize_brief ---
    # 路径 A: stale（pid 不在 /proc）
    printf 'pid=99999999\nbinary=qemu-system-arm\nmachine=romulus\nssh_port=2222\nredfish_port=2443\nipmi_port=2623\n' > "$PIDS_DIR/romulus.pid"
    out="$(qemu_instance_summarize_brief romulus)"
    assert_contains "brief stale marks stale" "$out" "⚠️ stale"
    assert_contains "brief stale has ports"   "$out" "SSH(2222) Redfish(2443) IPMI(2623/UDP)"
    assert_false "brief excludes machine name (caller lays out)" grep -q "romulus" <<< "$out"

    # 路径 B: running（stub 放子 shell,不污染父 shell 的真实 is_alive——unset -f 是删除不是恢复,
    # 父 shell 若被污染会让路径 C 的 recycled 判断假绿:command not found 走 false 也输出 stale）
    out="$(qemu_instance_is_alive() { return 0; }; qemu_instance_summarize_brief romulus)"
    assert_contains "brief running marks running" "$out" "✅ running"

    # 路径 C: recycled（pid=$$ 测试进程存在,但 cmdline 不匹配 qemu binary/machine → is_alive 返 2 → stale）
    printf 'pid=%s\nbinary=qemu-system-arm\nmachine=recyc\nssh_port=2222\nredfish_port=2443\nipmi_port=2623\n' "$$" > "$PIDS_DIR/recyc.pid"
    out="$(qemu_instance_summarize_brief recyc)"
    assert_contains "brief recycled marks stale" "$out" "⚠️ stale"
    ```

- [ ] **Step 2: 运行并确认失败**
  - Run: `bash tests/unit/qemu_instance.sh`
  - Expected: 失败——`qemu_instance_summarize_brief: command not found`。

- [ ] **Step 3: 写最小实现**
  - Change: 在 `lib/qemu_instance.sh` 加：
    ```bash
    # qemu_instance_summarize_brief <machine> — echo 单行实例详情（PID + 三端口 + 状态）。
    # machine 名不含（caller 决定布局）；running 标 ✅，stale（exited/recycled）标 ⚠️。
    # 内部 load → is_alive，统一存活判断（消灭 cmd_status/cmd_stop_qemu 的简化版双轨）。
    qemu_instance_summarize_brief() {
        local machine="$1"
        qemu_instance_load "$machine" || return 1   # Task 2: load 接 machine, 内部经 _qemu_instance_pid_file 设路径
        local status_mark
        if qemu_instance_is_alive "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE"; then
            status_mark="✅ running"
        else
            status_mark="⚠️ stale"
        fi
        echo "PID ${PIDFILE_PID}   SSH(${PIDFILE_SSH_PORT}) Redfish(${PIDFILE_REDFISH_PORT}) IPMI(${PIDFILE_IPMI_PORT}/UDP)   ${status_mark}"
    }
    ```

- [ ] **Step 4: 运行并确认通过**
  - Run: `bash tests/unit/qemu_instance.sh`
  - Expected: `assert_summary` 全绿。
  - Run: `tools/ob_check.sh`
  - Expected: 全绿（改 `lib/qemu_instance.sh` 后配套自检，与 Task 1/2/3 纪律一致）。

- [ ] **Step 5: checkpoint commit**
  - Run: `git add lib/qemu_instance.sh tests/unit/qemu_instance.sh && git commit -m "feat(qemu_instance): add summarize_brief (one-line + stale + recycled)"`
  - Expected: commit 成功。

### Task 5: 新增 qemu_instance_clean_stale

- **目标**：新增 `qemu_instance_clean_stale <machine>`，rm 对应 PID 文件（封装 stale 清理，供 start-qemu 冲突块 / stop-qemu 用）。
- **Files**: Modify `lib/qemu_instance.sh`、`tests/unit/qemu_instance.sh`。
- **验证范围**：`tests/unit/qemu_instance.sh` 通过。
- **接口契约**：
  - Consumes：`$WORKSPACE_DIR`。
  - Produces：`qemu_instance_clean_stale <machine>`（rm PID 文件，best-effort）。

- [ ] **Step 1: 写失败测试**
  - Change: 在 `tests/unit/qemu_instance.sh` 追加：
    ```bash
    # --- qemu_instance_clean_stale ---
    printf 'pid=99999999\nmachine=romulus\n' > "$PIDS_DIR/romulus.pid"
    [[ -f "$PIDS_DIR/romulus.pid" ]] || { echo "fixture missing"; exit 1; }
    qemu_instance_clean_stale romulus
    assert_false "clean_stale removes pid file" test -f "$PIDS_DIR/romulus.pid"
    # 不存在时也恒返回 0（best-effort；不能用 cmd && assert，set +e 下 cmd 失败不记 failure）
    qemu_instance_clean_stale nonexistent
    assert_eq "clean_stale idempotent rc" "$?" "0"
    ```

- [ ] **Step 2: 运行并确认失败**
  - Run: `bash tests/unit/qemu_instance.sh`
  - Expected: 失败——`qemu_instance_clean_stale: command not found`。

- [ ] **Step 3: 写最小实现**
  - Change: 在 `lib/qemu_instance.sh` 加：
    ```bash
    # qemu_instance_clean_stale <machine> — rm stale PID 文件（best-effort，恒返回 0）。
    # owner = start-qemu 冲突块 / stop-qemu；cmd_status（只读）不调用。
    qemu_instance_clean_stale() {
        local machine="$1"
        rm -f "$(_qemu_instance_pid_file "$machine")" 2>/dev/null || true
        return 0
    }
    ```

- [ ] **Step 4: 运行并确认通过**
  - Run: `bash tests/unit/qemu_instance.sh`
  - Expected: 全绿。
  - Run: `tools/ob_check.sh`
  - Expected: 全绿（改 `lib/qemu_instance.sh` 后配套自检）。

- [ ] **Step 5: checkpoint commit**
  - Run: `git add lib/qemu_instance.sh tests/unit/qemu_instance.sh && git commit -m "feat(qemu_instance): add clean_stale (best-effort, always rc 0)"`
  - Expected: commit 成功。

### Task 6: 改造 cmd_status 用 module（显示 stale，不删）⚠️ behavior change

- **目标**：`cmd_status` 的 QEMU 实例块（240-266）改为调 `qemu_instance_list` + `qemu_instance_summarize_brief`，**显示 stale 且不删**。这是本次唯一 behavior change。
- **Files**: Modify `lib/commands.sh`（`cmd_status` 239-276 段）、`tests/protocol/status_machine_state.sh`。
- **验证范围**：`status_machine_state.sh` 通过（含新 stale 断言）；`ob_check.sh` 通过。
- **接口契约**：
  - Consumes：`qemu_instance_list`（Task 3）、`qemu_instance_summarize_brief`（Task 4）。
  - Produces：无（caller 终点）。

- [ ] **Step 1: 写失败测试**
  - Change: 在 `tests/protocol/status_machine_state.sh` 的 fixture 段（第一个 `output="$(cmd_status ...)"` 之前）造 exited + recycled 两类 stale 实例，并在断言段加：
    ```bash
    # 造两类 stale QEMU 实例：exited（pid 不存在）+ recycled（pid=$$ 测试进程,cmdline 不匹配 qemu）
    QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
    mkdir -p "$QEMU_PIDS_DIR"
    printf 'pid=99999999\nbinary=qemu-system-arm\nmachine=stalebox\nssh_port=2222\nredfish_port=2443\nipmi_port=2623\n' > "$QEMU_PIDS_DIR/stalebox.pid"
    printf 'pid=%s\nbinary=qemu-system-arm\nmachine=recycbox\nssh_port=2225\nredfish_port=2445\nipmi_port=2625\n' "$$" > "$QEMU_PIDS_DIR/recycbox.pid"
    ```
    在第一个 `cmd_status` 调用后加断言：
    ```bash
    stalebox_line="$(grep -F "stalebox" <<< "$output" || true)"
    recycbox_line="$(grep -F "recycbox" <<< "$output" || true)"
    assert_contains "status shows exited instance stale" "$stalebox_line" "⚠️ stale"
    assert_contains "status shows recycled instance stale" "$recycbox_line" "⚠️ stale"
    assert_true "status keeps exited stale pid file" test -f "$QEMU_PIDS_DIR/stalebox.pid"
    assert_true "status keeps recycled stale pid file" test -f "$QEMU_PIDS_DIR/recycbox.pid"
    ```

- [ ] **Step 2: 运行并确认失败**
  - Run: `bash tests/protocol/status_machine_state.sh`
  - Expected: 失败——`⚠️ stale` 不出现（现状是 rm 掉了且不显示），且文件被删。

- [ ] **Step 3: 改 cmd_status**
  - Change: 把 `lib/commands.sh` `cmd_status` 内的 Section 5 QEMU 块（约 240-276，从 `local _pids_dir=...` 到该 section 结束）替换为：
    ```bash
    # Section 5: QEMU instances（只读，含 stale 显示；不删 PID 文件——清理 owner = start-qemu/stop-qemu）
    local _has_qemu=0
    local -a _qemu_lines=()
    local _m
    while IFS= read -r _m; do
        [[ -n "$_m" ]] || continue
        _has_qemu=1
        _qemu_lines+=("  $_m   $(qemu_instance_summarize_brief "$_m")")
    done < <(qemu_instance_list)

    if [[ "$_has_qemu" -eq 1 ]]; then
        echo ""
        step_header "QEMU Instances"
        local _ql
        for _ql in "${_qemu_lines[@]}"; do
            echo "$_ql"
        done
    fi
    ```
    注意：原 `_qemu_lines` 组装含 `✅ running` 字面量与 `/proc` 判断、`rm -f "$_pf"` 全部移除（由 `summarize_brief` 接管状态、由 start/stop 接管清理）。

- [ ] **Step 4: 运行并确认通过**
  - Run: `bash tests/protocol/status_machine_state.sh`
  - Expected: 全绿（含 `⚠️ stale` 显示 + 文件保留断言）。
  - Run: `tools/ob_check.sh`
  - Expected: 全绿。

- [ ] **Step 5: checkpoint commit**
  - Run: `git add lib/commands.sh tests/protocol/status_machine_state.sh && git commit -m "refactor(status): show stale QEMU instances via module (read-only; was rm)"`
  - Expected: commit 成功。

### Task 7: 改造 cmd_stop_qemu 用 module + 删 __stop_qemu_running_machines

- **目标**：`cmd_stop_qemu` 的 `--all` glob（599-602）和选择列表 inline 渲染（628-641）改用 `qemu_instance_list` + `qemu_instance_summarize_brief`；删除被取代的 `__stop_qemu_running_machines`（583-589）。
- **Files**: Modify `lib/commands.sh`。
- **验证范围**：`ob_check.sh` 通过（含 `tests/protocol/exit_codes.sh` 的 stop-qemu 无实例 exit 0、`tests/orchestration/qemu_stop_instance.sh`）。
- **接口契约**：
  - Consumes：`qemu_instance_list`、`qemu_instance_summarize_brief`、`qemu_instance_load`、`qemu_instance_is_alive`、`qemu_instance_stop`、`qemu_instance_clean_stale`。
  - Produces：无。

- [ ] **Step 1: 改动前检查**
  - Run: `grep -nE '__stop_qemu_running_machines|qemu-bin/\.pids' lib/commands.sh`
  - Expected: 命中 `__stop_qemu_running_machines` 定义（583）与调用（608）、`--all` glob（599）、选择列表 `_pf` 拼接（630）。

- [ ] **Step 2: 改造 --all 与选择列表**
  - Change:
    - `--all` 分支（597-602）：`for pid_file ... targets+=("$(basename ...)")` 整段替换为 `mapfile -t targets < <(qemu_instance_list)`。
    - 选择列表分支（606-646）：`mapfile -t available < <(__stop_qemu_running_machines)` 改为 `mapfile -t available < <(qemu_instance_list)`；选择列表渲染循环（628-641）的 inline `_pid/_sport/...` + `/proc` 判断 + `_detail` 拼接，替换为 `printf "  %${idx_width}d) %-20s %s\n" "$((i+1))" "$m" "$(qemu_instance_summarize_brief "$m")"`（`summarize_brief` 已含状态标注；`read_machine_choice` 调用保留不变）。
    - 删除 `__stop_qemu_running_machines` 函数定义（583-589）。

- [ ] **Step 3: 同步停单个实例段 + 下沉 .pids 路径拼接**
  - Change（`cmd_stop_qemu` for 循环段 654-724）：
    - 删除 `QEMU_PID_FILE="$WORKSPACE_DIR/qemu-bin/.pids/$MACHINE.pid"`（656）——路径拼接下沉到 module。
    - 其后 `if ! qemu_instance_load; then`（Task 2 已改名）改为 `if ! qemu_instance_load "$MACHINE"; then`（load 接 machine，内部经 `_qemu_instance_pid_file` 设路径）。
    - `rm -f "$QEMU_PID_FILE"`（679、685，stale 清理）替换为 `qemu_instance_clean_stale "$MACHINE"`。
    - `qemu_instance_stop` 调用（722）保留。

- [ ] **Step 4: 改动后验证**
  - Run: `grep -nE '__stop_qemu_running_machines|/proc/|read_kv_field.*\.pid|qemu-bin/\.pids' lib/commands.sh`
  - Expected: 0 命中（commands.sh 不再裸写 `.pids` 路径 / `/proc` / PID kv，也不含 `__stop_qemu_running_machines`）。
  - Run: `tools/ob_check.sh`
  - Expected: 全绿。

- [ ] **Step 5: checkpoint commit**
  - Run: `git add lib/commands.sh && git commit -m "refactor(stop-qemu): use qemu_instance module; drop __stop_qemu_running_machines"`
  - Expected: commit 成功。

### Task 8: 改造 cmd_start_qemu 冲突块用 clean_stale

- **目标**：`cmd_start_qemu` 冲突块（507-542）的 inline `rm -f "$QEMU_PID_FILE"`（540，stale 清理）替换为 `qemu_instance_clean_stale "$MACHINE"`；其余（`qemu_instance_is_alive`/`qemu_instance_stop`/`qemu_instance_summarize_full` Task 2 已改名）保留。
- **Files**: Modify `lib/commands.sh`。
- **验证范围**：`ob_check.sh` 通过（含 `tests/orchestration/start_qemu_force_restart.sh` F1 不变量）。
- **接口契约**：
  - Consumes：`qemu_instance_clean_stale`（Task 5）、`qemu_instance_load/is_alive/stop/summarize_full`（Task 2）。
  - Produces：无。

- [ ] **Step 1: 改动前检查**
  - Run: `grep -nE 'rm -f .*QEMU_PID_FILE|/proc/' lib/commands.sh`
  - Expected: 命中 `cmd_start_qemu` 540 的 `rm -f "$QEMU_PID_FILE"`（stale 分支）。

- [ ] **Step 2: 替换 inline rm**
  - Change: `cmd_start_qemu` 冲突块里 `# Stale PID file — clean up` 分支（约 538-541）的 `rm -f "$QEMU_PID_FILE"` 替换为 `qemu_instance_clean_stale "$MACHINE"`。

- [ ] **Step 3: 改动后验证**
  - Run: `grep -nE '/proc/|rm -f .*\.pid|qemu-bin/\.pids' lib/commands.sh`
  - Expected: 0 命中（commands.sh 完全脱离 PID 文件物理布局）。
  - Run: `tools/ob_check.sh`
  - Expected: 全绿（含 `tests/orchestration/start_qemu_force_restart.sh` 的 F1 不变量：kill 先于 check_ports）。

- [ ] **Step 4: checkpoint commit**
  - Run: `git add lib/commands.sh && git commit -m "refactor(start-qemu): use qemu_instance_clean_stale in conflict block"`
  - Expected: commit 成功。

### Task 9: 更新 coverage_matrix.md + 最终验证

- **目标**：同步 `tools/coverage_matrix.md` 的函数改名 + 新增 qemu_instance 行；跑全量自检 + drift 信号验证。
- **Files**: Modify `tools/coverage_matrix.md`。
- **验证范围**：`ob_check.sh` 全绿 + drift grep 信号。

- [ ] **Step 1: 更新 coverage_matrix**
  - Change: `tools/coverage_matrix.md` 中 `validate_pid` → `qemu_instance_is_alive`、`qemu_instance_describe` → `qemu_instance_summarize_full`、`qemu_stop_instance` → `qemu_instance_stop`（涉及 start-qemu / stop-qemu / 横切行）；新增 qemu_instance module 行（`qemu_instance_list / load / summarize_brief / clean_stale` 覆盖 `tests/unit/qemu_instance.sh`）；移除已删的 `__stop_qemu_running_machines`。

- [ ] **Step 2: 最终 drift 验证**
  - Run: `grep -rnE '/proc/|qemu-bin/\.pids|read_kv_field.*\.pid' lib/commands.sh`
  - Expected: 0 命中（commands.sh 完全脱离 PID 物理布局：不碰 `.pids` 路径、`/proc/$pid` 存活判断、PID kv 字段）。
  - Run: `grep -rnE '/proc/\$[A-Za-z_]' lib/ | grep -v 'lib/util.sh'`
  - Expected: 只命中 `lib/qemu_instance.sh`（`is_alive` 的 `/proc/$pid/cmdline` + `stop` 的 `/proc/$pid` wait）。`lib/util.sh` 的 `/proc/version`、`/proc/meminfo` 是 WSL/内存探测，与 PID lifecycle 无关，显式排除，不在本门禁范围。

- [ ] **Step 3: 全量自检**
  - Run: `tools/ob_check.sh`
  - Expected: 全绿（extract_funcs / shellcheck baseline / exit_contract / run_all 全过）。

- [ ] **Step 4: checkpoint commit**
  - Run: `git add tools/coverage_matrix.md && git diff --cached --name-only && git commit -m "docs(coverage): update qemu_instance coverage matrix"`
  - Expected: commit 成功；`git status --short` 干净（无 dirty 残留）。

- [ ] **Step 5: 输出修改摘要**
  - Expected: 列出 11 个 commit（Task 0 两个 docs commit + Task 1-9 九个 task commit）、`qemu.sh` 减少行数、`commands.sh` 4 处 inline 消除、唯一 behavior change（status 显示 stale 不删）。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证（每个 Task 的 Step 4 + `ob_check.sh`）。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 若在 `main`/`master` 且用户未明确同意，开始实现前先确认切分支。
- 全部任务完成后，运行最终验证（Task 9 Step 2-3）并输出修改摘要。

## 最终验证

- `tools/ob_check.sh` 全绿（结构 / 函数登记 / shellcheck baseline / exit_contract / run_all）。
- drift 信号：`grep -rnE '/proc/|qemu-bin/\.pids|read_kv_field.*\.pid' lib/commands.sh` 0 命中；`grep -rnE '/proc/\$[A-Za-z_]' lib/ | grep -v lib/util.sh` 只命中 `lib/qemu_instance.sh`（util.sh 的 `/proc/version`、`/proc/meminfo` 合法，排除）。
- 行为验证：`tests/protocol/status_machine_state.sh` 含 `⚠️ stale` 显示 + stale PID 文件保留断言通过（唯一 behavior change 被测覆盖）。
- 环境前提：bash + `tools/ob_check.sh` 依赖（python3 / shellcheck / expect 可选）；当前为 WSL2 bash，命令沿用 Unix 工具。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-06-qemu-instance-module-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
