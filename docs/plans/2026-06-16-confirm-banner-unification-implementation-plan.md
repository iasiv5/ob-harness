# ob confirmation banner 统一 实施计划

## 目标

把 `ob` 脚本里 4 处手写的"边框 + 3 行重复 `warn`"确认块抽成一个纯视觉函数 `print_confirm_banner "<verb>" "$object"` 复用；并给 2 个破坏性确认缺口（`stop-qemu` 的 `Stop this instance?`、`start-qemu` 内的 `Kill and restart?`）补上同款 banner。banner 只负责视觉强调，**不改动任何确认逻辑**——Y/N 循环、3 秒倒计时、批量循环、`--force` 分支各点自管。术语定义见 `CONTEXT.md` 的 **confirmation banner** 条目。

非目标：
- 不动 stale SSH host key 确认点（`ob:3495`，太 minor）。
- 不动 `start-qemu` 的 3 秒倒计时（`ob:3730`，长驻进程逃生窗，不属于 banner）。
- 不改任何确认点的 Y/N 提示语、退出码、批量行为。

## 架构快照

- 新增一个纯展示函数 `print_confirm_banner()`，定义在辅助函数群 `verbose()`（`ob:61`）之后、`step_header()`（`ob:271`）之前，紧邻 `warn()`（`ob:59`）。函数体只含 `echo` + `warn`，无外部命令，无失败风险；参数用 `local verb="${1:-}"` / `local object="${2:-}"` 防 `set -u`（`ob:4` 为 `set -euo pipefail`）。
- 函数内部固定输出 7 行：上边框、空行、3 行 `warn`、空行、下边框、空行——与现有 4 处手写逐字一致，保证替换后输出零变化。
- 4 处现有手写块整体替换为单行调用，删除各自的 6 行边框/空行 `echo`；banner 前若原有独立 `echo ""` 间隔，保留该间隔行。
- 2 处缺口在现有 `read -r -p` 确认循环之前插入单行调用，后续 Y/N 逻辑一字不动。
- 行号会随编辑漂移，定位以 `warn` 文本 / 注释锚点为准，行号仅作初始参考。

## 输入工件

- 设计来源：本会话 `/grill-with-docs` 访谈收敛的决策（无独立 design 文档）。
- 术语：`CONTEXT.md` → **confirmation banner**（已在访谈中落盘）。
- 改动前基线（已实测）：
  - `grep -c "You are about to" ob` == **12**（4 处 × 3 行）
  - `grep -c "print_confirm_banner" ob` == **0**

## 文件结构与职责

- Modify: `ob`（仓库根，单文件 bash 脚本）
  - 新增 `print_confirm_banner()` —— 锚点：`verbose() { ... }`（`ob:61`）之后
  - 替换 4 处手写块：
    - update community QEMU binary —— 锚点：`warn "  You are about to update community QEMU binary`（`ob:742`）
    - `cmd_build` —— 锚点：`warn "  You are about to build:`（`ob:2313`）
    - `cmd_init` —— 锚点：`warn "  You are about to init:`（`ob:2835`）
    - `cmd_start_qemu` —— 锚点：`warn "  You are about to start QEMU for:`（`ob:3701`）
  - 新增 2 处调用：
    - `stop-qemu` —— 锚点：`echo "  Serial log: $PIDFILE_SERIAL_LOG"`（`ob:3967`）之后的 `echo ""` 之后
    - `start-qemu` Kill-and-restart —— 锚点：`warn "QEMU instance already running for '$MACHINE':"`（`ob:3639`）所在 `elif` 块内、`read -r -p "... Kill and restart?"`（`ob:3646`）之前
- Test: 无独立测试文件。`ob` 是交互式编排脚本，验证用 grep count 结构门禁 + `bash -n` + 抽取函数渲染 harness（离线，无需 BMC 环境）。

## 任务清单

### Task 1: 新增 `print_confirm_banner` 函数

- 目标：加一个纯展示函数，输出"边框 + 3 行重复 warn + 边框"的 7 行 banner，供 6 个确认点复用。
- 涉及文件：Modify `ob` —— 在 `verbose() { ... }`（`ob:61`）之后插入。
- 验证范围：函数定义存在；`bash -n` 通过。

- [ ] Step 1: 写当前状态检查
  - 该函数尚不存在。
  - Run: `grep -c '^print_confirm_banner()' ob`
  - Expected: `0`

- [ ] Step 2: 运行并确认失败
  - Run: 同上
  - Expected: `0`（确认尚未实现）

- [ ] Step 3: 写最小实现
  - Change: 在 `verbose() { ... }`（`ob:61`）这一行之后、下一个空行处插入：
  ```bash

  # Print the 3-line confirmation banner (visual only — no confirmation logic).
  # See CONTEXT.md "confirmation banner". Usage: print_confirm_banner "<verb>" "$object"
  print_confirm_banner() {
      local verb="${1:-}"
      local object="${2:-}"
      echo "============================================================"
      echo ""
      warn "  You are about to ${verb}:  >>> ${object} <<<"
      warn "  You are about to ${verb}:  >>> ${object} <<<"
      warn "  You are about to ${verb}:  >>> ${object} <<<"
      echo ""
      echo "============================================================"
      echo ""
  }
  ```

- [ ] Step 4: 运行并确认通过
  - Run: `grep -c '^print_confirm_banner()' ob && bash -n ob && echo OK`
  - Expected: `1` 换行 `OK`（函数已定义且语法通过）

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob && git commit -m "refactor(ob): 抽 print_confirm_banner 视觉函数"`
  - Expected: commit 成功

### Task 2: 用函数替换 4 处现有手写 banner

- 目标：把 update-qemu-binary / build / init / start-qemu 四处手写的"边框+3 行 warn+边框"整体替换为单行 `print_confirm_banner` 调用，输出零变化。
- 涉及文件：Modify `ob` —— 4 个锚点（见文件结构）。
- 验证范围：`grep -c "You are about to" ob` 由 12 降为 1（只剩函数模板那 1 行）；缩进调用点计数为 4；`bash -n` 通过。

- [ ] Step 1: 写当前状态检查
  - 4 处仍是手写三行。
  - Run: `grep -c "You are about to" ob`
  - Expected: `12`

- [ ] Step 2: 运行并确认失败
  - Run: 同上
  - Expected: `12`

- [ ] Step 3: 写最小实现（4 处替换）
  - Change A — update community QEMU binary（`ob:739-747`，保留前置 `echo ""`）：
    - old:
    ```bash
        echo ""
        echo "============================================================"
        echo ""
        warn "  You are about to update community QEMU binary:  >>> build #${local_build} → #${remote_build} <<<"
        warn "  You are about to update community QEMU binary:  >>> build #${local_build} → #${remote_build} <<<"
        warn "  You are about to update community QEMU binary:  >>> build #${local_build} → #${remote_build} <<<"
        echo ""
        echo "============================================================"
        echo ""
    ```
    - new:
    ```bash
        echo ""
        print_confirm_banner "update community QEMU binary" "build #${local_build} → #${remote_build}"
    ```
  - Change B — `cmd_build`（`ob:2311-2318`）：
    - old:
    ```bash
        echo "============================================================"
        echo ""
        warn "  You are about to build:  >>> $MACHINE <<<"
        warn "  You are about to build:  >>> $MACHINE <<<"
        warn "  You are about to build:  >>> $MACHINE <<<"
        echo ""
        echo "============================================================"
        echo ""
    ```
    - new:
    ```bash
        print_confirm_banner "build" "$MACHINE"
    ```
  - Change C — `cmd_init`（`ob:2833-2840`）：
    - old:
    ```bash
        echo "============================================================"
        echo ""
        warn "  You are about to init:  >>> $MACHINE <<<"
        warn "  You are about to init:  >>> $MACHINE <<<"
        warn "  You are about to init:  >>> $MACHINE <<<"
        echo ""
        echo "============================================================"
        echo ""
    ```
    - new:
    ```bash
        print_confirm_banner "init" "$MACHINE"
    ```
  - Change D — `cmd_start_qemu`（`ob:3699-3706`，保留上方注释行 `# ── Safety confirmation ... ──`）：
    - old:
    ```bash
        echo "============================================================"
        echo ""
        warn "  You are about to start QEMU for:  >>> $MACHINE <<<"
        warn "  You are about to start QEMU for:  >>> $MACHINE <<<"
        warn "  You are about to start QEMU for:  >>> $MACHINE <<<"
        echo ""
        echo "============================================================"
        echo ""
    ```
    - new:
    ```bash
        print_confirm_banner "start QEMU for" "$MACHINE"
    ```

- [ ] Step 4: 运行并确认通过
  - Run: `echo "warn-template:"; grep -c "You are about to" ob; echo "calls:"; grep -cE '^[[:space:]]+print_confirm_banner "' ob; bash -n ob && echo SYNTAX-OK`
  - Expected: `warn-template:` → `1`；`calls:` → `4`；`SYNTAX-OK`

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob && git commit -m "refactor(ob): 4 处确认块改用 print_confirm_banner"`
  - Expected: commit 成功

### Task 3: 给 `stop-qemu` 的 "Stop this instance?" 补 banner

- 目标：在 `stop-qemu` 的确认循环之前插入 banner 调用，让"杀进程"这类破坏性确认与其它重操作视觉一致；后续 `[y/N]` 逻辑不动。
- 涉及文件：Modify `ob` —— `cmd_stop_qemu` 内，`echo "  Serial log: $PIDFILE_SERIAL_LOG"`（`ob:3967`）之后的 `echo ""`（`ob:3968`）之后、`if [[ "$QEMU_FORCE" -ne 1 ]]; then`（`ob:3970`）之前。
- 验证范围：`stop QEMU for` 调用出现 1 次；缩进调用点计数升到 5；`bash -n` 通过。
- 设计注记：banner 插在 `QEMU_FORCE` 判断之前，因此 `--force` 批量停机时每个实例也会先印 banner（作为"正在停止此实例"的提示）。如希望 `--force` 时静默，可改为插在 `if [[ "$QEMU_FORCE" -ne 1 ]]` 的交互分支内；本计划默认放在 if 之前以保持简单。

- [ ] Step 1: 写当前状态检查
  - 该调用尚不存在。
  - Run: `grep -c "stop QEMU for" ob`
  - Expected: `0`

- [ ] Step 2: 运行并确认失败
  - Run: 同上
  - Expected: `0`

- [ ] Step 3: 写最小实现
  - Change: 定位 `cmd_stop_qemu` 内 instance 详情展示块（`echo "  Serial log: $PIDFILE_SERIAL_LOG"` 后跟一个 `echo ""`），在该 `echo ""` 之后、空行 / `if [[ "$QEMU_FORCE" -ne 1 ]]; then` 之前插入一行（8 空格缩进）：
  ```bash
          echo ""
          print_confirm_banner "stop QEMU for" "$MACHINE"
  ```
  - 定位锚点：`echo "  Serial log: $PIDFILE_SERIAL_LOG"`（`ob:3967`），其下两行即是插入点。

- [ ] Step 4: 运行并确认通过
  - Run: `grep -c "stop QEMU for" ob; grep -cE '^[[:space:]]+print_confirm_banner "' ob; bash -n ob && echo SYNTAX-OK`
  - Expected: `1`；`5`；`SYNTAX-OK`

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob && git commit -m "feat(ob): stop-qemu 确认点补 confirmation banner"`
  - Expected: commit 成功

### Task 4: 给 `start-qemu` 内的 "Kill and restart?" 补 banner

- 目标：在"杀已有实例并重启"的交互确认之前插入 banner 调用；后续 `[y/N]` 逻辑不动。
- 涉及文件：Modify `ob` —— `cmd_start_qemu` 内、`elif [[ -t 0 ]]; then`（`ob:3637`）块中，`echo ""`（`ob:3644`）之后、`local answer`（`ob:3645`）之前。
- 验证范围：`kill and restart QEMU for` 调用出现 1 次；缩进调用点计数升到 6；`bash -n` 通过。
- 设计注记：该分支只在交互式（`-t 0`）命中；`--force` 分支（`ob:3632`）直接 kill 不进此块，故 `--force` 不会多印 banner。

- [ ] Step 1: 写当前状态检查
  - 该调用尚不存在。
  - Run: `grep -c "kill and restart QEMU for" ob`
  - Expected: `0`

- [ ] Step 2: 运行并确认失败
  - Run: 同上
  - Expected: `0`

- [ ] Step 3: 写最小实现
  - Change: 定位 `warn "QEMU instance already running for '$MACHINE':"`（`ob:3639`）所在的 `elif [[ -t 0 ]]` 块，在 instance 详情展示后的那个 `echo ""`（`ob:3644`）之后、`local answer`（`ob:3645`）之前插入一行（16 空格缩进）：
  ```bash
                  echo ""
                  print_confirm_banner "kill and restart QEMU for" "$MACHINE"
                  local answer
  ```
  - 定位锚点：`warn "QEMU instance already running for '$MACHINE':"`，向下数行找到其后的 `echo ""` 与 `local answer`，在两者之间插入。

- [ ] Step 4: 运行并确认通过
  - Run: `grep -c "kill and restart QEMU for" ob; grep -cE '^[[:space:]]+print_confirm_banner "' ob; bash -n ob && echo SYNTAX-OK`
  - Expected: `1`；`6`；`SYNTAX-OK`

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add ob && git commit -m "feat(ob): start-qemu Kill-and-restart 确认点补 banner"`
  - Expected: commit 成功

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动手。
- 当前在 `main` 分支且 working tree 干净；若未获明确同意在 `main` 直接改，先开分支（如 `git switch -c refactor/confirm-banner`）再实现。working tree 内的 commit 是安全迭代手段。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务 Step 4 的验证；不通过立即停下说明，不猜。
- 行号会漂移，定位一律以 `warn` 文本 / 注释锚点为准。

## 最终验证

全部任务完成后运行：

1. 语法：
   - Run: `bash -n ob && echo SYNTAX-OK`
   - Expected: `SYNTAX-OK`

2. 结构门禁（手写三行已全部收敛进函数模板）：
   - Run: `grep -c "You are about to" ob`
   - Expected: `1`（仅函数定义内那 1 行模板）

3. 调用点计数（1 定义 + 6 调用 = 6 个缩进调用行）：
   - Run: `grep -cE '^[[:space:]]+print_confirm_banner "' ob`
   - Expected: `6`

4. 定义存在：
   - Run: `grep -c '^print_confirm_banner()' ob`
   - Expected: `1`

5. 渲染 harness（从 ob 真实抽取颜色变量 + `warn` + 新函数，离线渲染两组样例，无需 BMC 环境）：
   - Run:
   ```bash
   {
     grep -E '^(RED|GREEN|YELLOW|BOLD|NC)=' ob
     grep '^warn()' ob
     sed -n '/^print_confirm_banner()/,/^}/p' ob
     printf 'print_confirm_banner "build" "fake-machine"\n'
     printf 'print_confirm_banner "stop QEMU for" "b865g8-bytedance"\n'
   } | bash
   ```
   - Expected: 打印两组 banner，每组形如（`[WARN]` 带黄色 ANSI）：
   ```
   ============================================================

   [WARN]   You are about to build:  >>> fake-machine <<<
   [WARN]   You are about to build:  >>> fake-machine <<<
   [WARN]   You are about to build:  >>> fake-machine <<<

   ============================================================

   ```

6. 交互确认（可选，需已有构建产物 + 在跑 QEMU 实例）：在真实 machine 上各跑一次 `ob start-qemu <machine>`、`ob stop-qemu <machine>`，肉眼确认 banner 在 Y/N 之前正确渲染、Y/N 逻辑与改动前一致。

## 审阅 Checkpoint

- 计划正文到此结束。
- 请先审阅这份计划；通过前不进入实现。
- 通过后默认执行方为普通编码 agent 或人工，按 Task 1 → 4 顺序执行并逐任务验证。
