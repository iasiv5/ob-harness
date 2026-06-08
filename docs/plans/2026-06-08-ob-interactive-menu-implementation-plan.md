# ob 脚本交互菜单模式实施计划

## 目标

基于已批准的设计文档，为 `ob` 脚本新增交互菜单模式：`./ob` 无参数进入菜单循环，`./ob <command>` 保持现有 CLI 行为。

## 架构快照

本次改造的核心思路是**子 shell 隔离**：在 `cmd_menu()` 的 while 循环中，每个命令调用包裹在 `(cmd_xxx)` 子 shell 内。子 shell 内的 `exit` 只退出子 shell，主脚本的菜单循环不受影响。

需要的前置重构：将 `main()` 中 init 的 8 个步骤（第 1571-1668 行）抽出为独立的 `cmd_init()` 函数，使 init/build/status 都有平级的 cmd 函数可被菜单调用。

`main()` 入口改为：无参数 → `cmd_menu()`；有参数 → CLI 分发。`show_logo` 调用从 `main()` 首行挪到 CLI 分支内。

## 输入工件

- 设计文档：`docs/specs/2026-06-08-ob-interactive-menu-design.md`

## 文件结构与职责

- Modify: `ob`（根目录脚本，本次唯一改动文件）
  - 新增 `cmd_init()`：从 `main()` 抽出 init 的 8 个步骤
  - 新增 `cmd_menu()`：菜单循环主控函数
  - 新增 `fn_quit()` / `fn_err_quit()`：退出函数
  - 新增 `show_brand_line()`：单行品牌行
  - 修改 `main()`：重构入口分发逻辑
  - 修改 `parse_args()`：无参数时不再报错退出
  - 修改 `usage()`：补充菜单模式说明
  - 修改所有 `read -p` / `read -r -p`：添加 `ob-harness>` 黄色前缀

## 任务清单

### Task 1: ob · 抽出 `cmd_init()` 函数

**目标**：将 `main()` 中 init 的 8 个步骤（第 1571-1668 行）抽出为独立函数 `cmd_init()`，使 init 可被 CLI 和菜单模式共同调用。

**Files**

- Modify: `ob` — `main()` 函数（第 1555-1669 行）

**验证范围**

- `./ob --help` 正常输出 usage，不报错。
- `source ob` 不报语法错误（利用 `OB_NO_MAIN` 机制）。

- [ ] Step 1: 确认当前 init 逻辑的位置
- Run: `grep -n "prerequisites_check\|require_openbmc_repo\|run_repo_init_script\|resolve_machine\|init_bitbake_env\|generate_dep_graph\|clone_sub_repos\|generate_lockfile\|generate_build_config\|print_report\|init-done" /home/iasi/ob-harness/ob | grep -v "^#"`
- Expected: 输出包含 `prerequisites_check` 到 `print_report` 和 `init-done` 的调用，全部在 `main()` 函数体内（第 1571-1668 行区间）

- [ ] Step 2: 创建 `cmd_init()` 函数
- Change: 在 `main()` 函数之前（例如 `cmd_build()` 结束后、`select_openbmc_repo_url()` 之前的位置，约第 802 行附近），新增函数：

```bash
cmd_init() {
    # Step 1/8: 前置检查。
    prerequisites_check

    # Step 2/8: 准备主仓库并解析 machine。
    require_openbmc_repo

    # [OEM] Step 2 扩展动作。
    run_repo_init_script

    resolve_machine

    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
    SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"

    rm -f "$CONFIGS_DIR/$MACHINE.init-done"

    if [[ -f "$SOURCE_LOCK_FILE" && -n "$MACHINE" ]]; then
        local current_first_init
        current_first_init=$(read_lock_field machine_first_init 2>/dev/null || true)
        if [[ -z "$current_first_init" ]]; then
            sed -i "s/^machine_first_init=.*/machine_first_init=$MACHINE/" "$SOURCE_LOCK_FILE"
            verbose "Updated machine_first_init=$MACHINE in $SOURCE_LOCK_FILE"
        fi
    fi

    local is_rerun=0
    if [[ -d "$SRC_DIR" ]] && [[ $(ls -d "$SRC_DIR"/*/ 2>/dev/null | wc -l) -gt 0 ]]; then
        is_rerun=1
    fi
    if [[ -d "$BUILD_DIR/conf" ]] && [[ -f "$BUILD_DIR/conf/local.conf" ]]; then
        is_rerun=1
    fi

    if [[ "$is_rerun" -eq 1 ]]; then
        local existing_repos=0
        existing_repos=$(find "$SRC_DIR" -maxdepth 2 -name ".git" -type d 2>/dev/null | wc -l || true)
        echo ""
        info "INCREMENTAL RUN DETECTED for machine=$MACHINE"
        if [[ "$existing_repos" -gt 0 ]]; then
            info "  Existing repos: $existing_repos under $SRC_DIR"
        fi
        if [[ -f "$BUILD_DIR/conf/local.conf" ]]; then
            info "  Build config: $BUILD_DIR/conf/ already exists"
        fi
        info "  Actions: fetch updates for existing repos, clone missing ones, regenerate config"
        echo ""
    else
        echo ""
        info "FRESH RUN — initializing OpenBMC environment for machine=$MACHINE"
        echo ""
        warn "============================================================"
        warn " Machine '$MACHINE' confirmed — about to fetch its sub-repos."
        warn " Download size : ~20-30 GB"
        warn " Estimated time: 20-60 minutes"
        warn " Resumable     : safe to Ctrl+C; re-run resumes incrementally."
        warn "============================================================"
        echo ""
    fi

    init_bitbake_env

    if [[ "$SKIP_DEPS" -eq 1 ]]; then
        local deps_json="$BUILD_DIR/deps.json"
        if [[ ! -f "$deps_json" ]]; then
            error "--skip-deps requires an existing $deps_json. Run full init first."
            exit 1
        fi
        local dep_count
        dep_count=$(python3 -c "import json; print(len(json.load(open('$deps_json'))))")
        warn "--skip-deps: reusing existing deps.json ($dep_count repos)"
    else
        generate_dep_graph
    fi

    clone_sub_repos

    generate_lockfile

    generate_build_config

    print_report

    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$CONFIGS_DIR/$MACHINE.init-done"
}
```

- [ ] Step 3: 精简 `main()` 函数，调用 `cmd_init`
- Change: 将 `main()` 中第 1571-1668 行的 init 代码替换为 `cmd_init; return 0`。`main()` 变为：

```bash
main() {
    SECONDS=0
    parse_args "$@"
    detect_harness_root

    if [[ "$COMMAND" == "status" ]]; then
        show_logo
        cmd_status
        return 0
    fi

    if [[ "$COMMAND" == "build" ]]; then
        show_logo
        cmd_build
        return 0
    fi

    # Default: init
    show_logo
    cmd_init
}
```

注意：此时 `show_logo` 仍在 `main()` 中各分支内，尚未移到 CLI-only 位置。这会在后续 Task 中调整。当前先保持 CLI 功能不变。

- [ ] Step 4: 验证语法和 CLI 行为
- Run: `bash -n /home/iasi/ob-harness/ob`
- Expected: 无语法错误输出
- Run: `bash -c 'OB_NO_MAIN=1 source /home/iasi/ob-harness/ob && type cmd_init'`
- Expected: 输出 `cmd_init is a function`

---

### Task 2: ob · 新增退出函数和单行品牌行

**目标**：新增 `fn_quit()`、`fn_err_quit()` 退出函数和 `show_brand_line()` 单行品牌行，供后续 `cmd_menu()` 使用。

**Files**

- Modify: `ob` — 在 `show_logo()` 函数之后（约第 236 行）插入新函数

**验证范围**

- 函数定义存在且语法正确。

- [ ] Step 1: 确认插入位置
- Run: `grep -n "^show_logo\|^# === Functions" /home/iasi/ob-harness/ob | head -5`
- Expected: `show_logo()` 在第 218 行，`# === Functions ===` 在第 237 行

- [ ] Step 2: 在 `show_logo()` 和 `# === Functions ===` 之间插入三个新函数
- Change: 在第 236 行之后插入：

```bash
show_brand_line() {
    echo -e "\n\033[38;2;255;210;80m━━━ ob-harness ━━━\033[0m\n"
}

fn_quit() {
    echo ""
    echo -e "${PROMPT_PREFIX} ...... 退出 [ ob-harness · OpenBMC Development Environment ]"
    echo ""
    exit 0
}

fn_err_quit() {
    echo ""
    echo -e "${PROMPT_PREFIX} ...... \033[0;31m异常退出 [ ob-harness · OpenBMC Development Environment ]\033[0m"
    echo ""
    exit 1
}
```

注意：`PROMPT_PREFIX` 变量在 Task 4 Step 2 中定义。如果 Task 2 在 Task 4 之前执行，需确保变量已存在。建议在 Task 2 插入函数的同时，在颜色定义区域（第 27-33 行附近）同步添加 `PROMPT_PREFIX` 变量定义。

- [ ] Step 3: 验证语法
- Run: `bash -n /home/iasi/ob-harness/ob`
- Expected: 无语法错误输出
- Run: `bash -c 'OB_NO_MAIN=1 source /home/iasi/ob-harness/ob && type show_brand_line && type fn_quit && type fn_err_quit'`
- Expected: 三个函数均输出 `xxx is a function`

---

### Task 3: ob · 修改 `parse_args()` 支持无参数进入菜单

**目标**：当前 `parse_args()` 在 `$# < 1` 时调用 `usage` 并 `exit 1`。需要改为：无参数时设置 `COMMAND=""` 并正常返回，由 `main()` 决定进入菜单模式。

**Files**

- Modify: `ob` — `parse_args()` 函数（第 262-318 行）

**验证范围**

- `./ob --help` 正常输出。
- 无参数时 `COMMAND` 为空，不报错退出。

- [ ] Step 1: 确认当前无参数行为
- Run: `bash -c 'OB_NO_MAIN=1 source /home/iasi/ob-harness/ob && parse_args; echo "COMMAND=$COMMAND"' 2>&1`
- Expected: 输出 usage 文本并报错（因为当前会 `exit 1`，source 模式下会退出子 shell）

- [ ] Step 2: 修改 `parse_args()` 的无参数分支
- Change: 将第 263-266 行：

```bash
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi
```

改为：

```bash
    if [[ $# -lt 1 ]]; then
        COMMAND=""
        return 0
    fi
```

- [ ] Step 3: 验证无参数行为
- Run: `bash -c 'OB_NO_MAIN=1 source /home/iasi/ob-harness/ob && parse_args; echo "COMMAND=$COMMAND"'`
- Expected: 输出 `COMMAND=`（空值），无报错
- Run: `bash -c 'OB_NO_MAIN=1 source /home/iasi/ob-harness/ob && parse_args --help' 2>&1 | head -3`
- Expected: 输出 usage 文本前几行（`Usage: ob ...`）

---

### Task 4: ob · 统一所有 `read` 提示符为 `ob-harness>` 黄色前缀

**目标**：将脚本中所有 `read` 调用的提示符统一添加 `ob-harness>` 黄色前缀。

**Files**

- Modify: `ob` — 所有包含 `read` 的位置

**验证范围**

- 所有 `read` 调用都包含 `ob-harness>` 前缀。

- [ ] Step 1: 找出所有 `read` 调用位置
- Run: `grep -n 'read.*-p' /home/iasi/ob-harness/ob`
- Expected: 列出所有 read 调用行及其行号

- [ ] Step 2: 逐一替换每个 `read` 的 prompt 文本
- Change: 对每个 `read -r -p "xxx"` 或 `read -p "xxx"` 调用，在 prompt 字符串前添加 `ob-harness>` 黄色前缀。格式为：

```
read -r -p "$(echo -e '\033[38;2;255;210;80mob-harness>\033[0m 原提示文本') " var
```

`PROMPT_PREFIX` 变量已在 Task 2 中添加到颜色定义区域。将每个 `read` 的 prompt 改为使用 `${PROMPT_PREFIX}` 的形式。具体涉及的 read 调用包括（按行号位置）：

- `cmd_build` 中的 machine 选择 prompt（`Choose [1-N]:`）
- `cmd_build` 中的 Y/N 确认 prompt（`Type Y to confirm...`）
- `select_openbmc_repo_url` 中的 URL 选择 prompt（`Choose [1-2]:`）
- `select_openbmc_repo_url` 中的自定义 URL 输入 prompt（`Enter the full repository URL:`）
- `resolve_machine` 中的 machine 选择 prompt（`Enter number or machine name:`）

- [ ] Step 3: 验证所有 read 调用已更新
- Run: `grep -n 'read.*-p' /home/iasi/ob-harness/ob | grep -v 'ob-harness'`
- Expected: 无输出（所有 read 提示都包含 ob-harness 前缀）
- Run: `bash -n /home/iasi/ob-harness/ob`
- Expected: 无语法错误

---

### Task 5: ob · 新增 `cmd_menu()` 函数

**目标**：实现菜单循环主控函数，包含菜单渲染、用户选择、子 shell 隔离的命令分发、成功/失败处理。

**Files**

- Modify: `ob` — 在 `cmd_init()` 之后插入

**验证范围**

- `./ob`（无参数）进入菜单循环。
- 选 Q 正常退出。
- 选无效输入有提示。

- [ ] Step 1: 确认插入位置
- Run: `grep -n "^cmd_init\|^select_openbmc_repo_url" /home/iasi/ob-harness/ob`
- Expected: `cmd_init` 在某个位置，`select_openbmc_repo_url` 在其后

- [ ] Step 2: 实现 `cmd_menu()` 函数
- Change: 在 `cmd_init()` 之后插入完整的 `cmd_menu()` 函数。核心结构：

```bash
cmd_menu() {
    # Non-interactive terminal guard
    if [[ ! -t 0 ]]; then
        echo -e "${PROMPT_PREFIX} 检测到非交互式终端，请使用 CLI 模式: ./ob <command> [args]"
        exit 1
    fi

    local first_run=1

    # First entry: clear + full logo
    clear
    show_logo

    while true; do
        # Print menu
        echo ""
        if [[ "$first_run" -eq 0 ]]; then
            show_brand_line
        fi

        echo "             1 - init - Initialize OpenBMC development environment"
        echo "             2 - build - Build OpenBMC firmware image"
        echo "             3 - status - Show current OpenBMC workspace status"
        echo "             C - Clear terminal screen (c/C)"
        echo "             Q - Quit this script (q/Q)"
        echo ""
        echo "提示: CLI 模式 → ./ob init <machine> | ./ob build | ./ob --help"
        echo ""

        local choice
        read -r -p "$(echo -e "${PROMPT_PREFIX} ")" choice

        case "$choice" in
            1)
                if (cmd_init); then
                    echo ""
                    info "初始化完成。"
                else
                    echo ""
                    error "初始化过程中出现错误。"
                fi
                read -r -p "$(echo -e "${PROMPT_PREFIX} 按回车键继续...") " _dummy
                ;;
            2)
                if (cmd_build); then
                    echo ""
                    info "构建完成。"
                else
                    echo ""
                    error "构建过程中出现错误。"
                fi
                read -r -p "$(echo -e "${PROMPT_PREFIX} 按回车键继续...") " _dummy
                ;;
            3)
                if (cmd_status); then
                    echo ""
                    info "状态查询完成。"
                else
                    echo ""
                    error "状态查询过程中出现错误。"
                fi
                read -r -p "$(echo -e "${PROMPT_PREFIX} 按回车键继续...") " _dummy
                ;;
            c|C)
                clear
                show_brand_line
                continue
                ;;
            q|Q)
                fn_quit
                ;;
            *)
                echo -e "${YELLOW}ob-harness> 无效输入，请选择 1/2/3/C/Q${NC}"
                continue
                ;;
        esac

        first_run=0
    done
}
```

- [ ] Step 3: 验证函数定义
- Run: `bash -n /home/iasi/ob-harness/ob`
- Expected: 无语法错误
- Run: `bash -c 'OB_NO_MAIN=1 source /home/iasi/ob-harness/ob && type cmd_menu'`
- Expected: `cmd_menu is a function`

---

### Task 6: ob · 重构 `main()` 入口逻辑

**目标**：修改 `main()` 入口，使无参数进入菜单模式，有参数走 CLI 模式。将 `show_logo` 调用从所有路径移到 CLI 分支内。

**Files**

- Modify: `ob` — `main()` 函数

**验证范围**

- `./ob` 无参数进入菜单（输出 logo + 菜单选项）。
- `./ob --help` 输出 usage。
- `./ob status` 正常执行 CLI status（带 logo）。

- [ ] Step 1: 确认当前 main 结构
- Run: `sed -n '/^main()/,/^}/p' /home/iasi/ob-harness/ob`
- Expected: main 函数体包含 parse_args、detect_harness_root、command 分发、cmd_init 调用

- [ ] Step 2: 重写 `main()` 入口
- Change: 将 `main()` 改为：

```bash
main() {
    SECONDS=0
    parse_args "$@"
    detect_harness_root

    if [[ -z "$COMMAND" ]]; then
        cmd_menu
        return $?
    fi

    # CLI mode
    show_logo

    if [[ "$COMMAND" == "status" ]]; then
        cmd_status
        return 0
    fi

    if [[ "$COMMAND" == "build" ]]; then
        cmd_build
        return 0
    fi

    cmd_init
}
```

- [ ] Step 3: 验证 CLI --help
- Run: `./ob --help 2>&1 | head -5`
- Expected: 输出 `Usage: ob <command> ...`

- [ ] Step 4: 验证语法
- Run: `bash -n /home/iasi/ob-harness/ob`
- Expected: 无语法错误

---

### Task 7: ob · 更新 `usage()` 文档

**目标**：在 usage 文本中补充菜单模式的说明。

**Files**

- Modify: `ob` — `usage()` 函数（第 239-260 行）

**验证范围**

- `./ob --help` 输出包含菜单模式说明。

- [ ] Step 1: 修改 usage 文本
- Change: 在 `usage()` 的 heredoc 中，`Commands:` 之前添加一行说明：

```
Usage: ob [command] [options] [arguments]

Run without arguments to enter interactive menu mode.

Commands:
```

将原 `Usage: ob <command>` 改为 `Usage: ob [command]`（command 变为可选），并在 Commands 列表上方加一行 `Run without arguments to enter interactive menu mode.`

- [ ] Step 2: 验证 usage 输出
- Run: `./ob --help 2>&1 | head -6`
- Expected: 输出包含 `interactive menu mode` 字样

---

## 执行纪律

- 开始实现前，先批判性复查整份计划；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1 → Task 7），不要无声跳步、合并步或改变任务目标。
- 每完成一个任务，都运行该任务定义的验证命令。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜。
- 当前在 `main` 分支，实现前先确认是否需要创建 feature branch。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

按顺序执行以下验证，确认改造不退化且菜单模式工作正常：

1. **语法检查**
   - Run: `bash -n ob`
   - Expected: 无输出

2. **CLI --help 不退化**
   - Run: `./ob --help`
   - Expected: 输出包含 `interactive menu mode` 和原有 commands 列表

3. **CLI status 不退化**
   - Run: `./ob status`
   - Expected: 正常输出状态信息（带 logo 前缀）

4. **所有 cmd 函数存在**
   - Run: `bash -c 'OB_NO_MAIN=1 source ob && type cmd_menu cmd_init cmd_build cmd_status fn_quit fn_err_quit show_brand_line'`
   - Expected: 7 个函数均输出 `xxx is a function`

5. **所有 read 提示符已统一**
   - Run: `grep 'read.*-p' ob | grep -v 'ob-harness'`
   - Expected: 无输出

6. **手动菜单体验**（需人工验证）
   - Run: `./ob`（无参数）
   - Expected: 显示全量 logo → 菜单选项 → `ob-harness>` 提示符等待输入
   - 输入 Q → 输出退出信息 → 回到 shell
   - 再次 `./ob` → 输入 3 → status 输出 → 按回车 → 回到菜单 → 输入 Q 退出
