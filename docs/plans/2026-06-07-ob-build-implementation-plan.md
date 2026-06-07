# ob build 实施计划

## 目标

在 `ob` 脚本中新增 `ob build` 命令：交互选择已通过 `ob init` 成功初始化的 machine，执行 `bitbake obmc-phosphor-image` 编译。同时在 `ob init` 流程中增加 `.init-done` 完成标记，作为两个命令之间的契约。

## 架构快照

`cmd_build()` 遵循现有 `cmd_status()` 的模式——在 `main()` 中根据 `$COMMAND` 分发，共享 `detect_harness_root()` 设置的全局变量。`ob build` 不接受命令行 machine 参数，只能从 `.init-done` 文件列表中交互选择，避免绕过校验的口子。

新增 `.init-done` 文件作为 `ob init` 和 `ob build` 之间的契约：`ob init` 在 `main()` 末尾原子写入，重跑时先删除；`ob build` 用文件存在性判定可编译 machine。

## 输入工件

- 设计决策：grilling session Q1-Q7 全部确认
- ADR：`docs/adr/0001-init-done-marker.md`
- CONTEXT.md 已更新：新增 `init-done marker` 术语

## 文件结构与职责

- Modify：`ob` — 唯一改动的源码文件
  - `usage()` — 新增 build 命令描述
  - `parse_args()` — 新增 build case（无参数）
  - `main()` — 新增 build 分发 + init-done 删除/写入
  - `cmd_build()` — 新函数：探测 → 展示 → 选择 → 确认 → 编译 → 输出

## 任务清单

### Task 1: Wire up build command dispatch

- 目标：`ob build` 能被 parse_args 解析、usage 展示、main 分发到 cmd_build（初始为 stub）
- 涉及文件：`ob`
- 验证范围：`ob build -h` 显示帮助；`ob build` 调用 cmd_build stub

- [ ] Step 1: 确认当前 dispatch 不识别 build 命令
- Run: `./ob build 2>&1 || true`
- Expected: `Unknown command: build`

- [ ] Step 2: 在 `usage()` 的 Commands 段落（`init` 和 `status` 之间）添加 build 描述
- Change: 添加一行 `  build                 Select an initialized machine and build its image`

- [ ] Step 3: 在 `parse_args()` 的 case 语句中（`status)` 之后）添加 build case
- Change:
```bash
        build)
            # No arguments accepted for build
            ;;
```

- [ ] Step 4: 在 `main()` 中 `detect_harness_root` 之后、`if [[ "$COMMAND" == "status" ]]` 代码块之后，添加 build 分发
- Change:
```bash
    if [[ "$COMMAND" == "build" ]]; then
        cmd_build
        return 0
    fi
```

- [ ] Step 5: 在 `cmd_status()` 函数附近添加 cmd_build stub
- Change:
```bash
cmd_build() {
    info "ob build not yet implemented"
}
```

- [ ] Step 6: 验证 dispatch
- Run: `./ob build`
- Expected: `ob build not yet implemented`
- Run: `./ob -h`
- Expected: usage 中包含 `build` 命令描述

### Task 2: Add init-done marker to ob init

- 目标：`ob init` 全部 8 步完成后在 `workspace/configs/<machine>.init-done` 写入 UTC 时间戳；重跑时先删除
- 涉及文件：`ob` — `main()` 函数
- 验证范围：`ob init` 完成后 `.init-done` 存在且包含时间戳；重跑后时间戳更新

- [ ] Step 1: 确认当前 workspace/configs 下无 .init-done 文件
- Run: `ls workspace/configs/*.init-done 2>&1 || true`
- Expected: `No match found` 或空输出

- [ ] Step 2: 在 `main()` 中 `resolve_machine()` 和路径重算（`BUILD_DIR=` / `SRC_DIR=`）之后、`is_rerun` 检测之前，添加 init-done 删除逻辑
- Change: 在 `SRC_DIR=...` 之后添加：
```bash
    # Remove init-done marker before starting work (re-entering init flow).
    # This ensures ob build never sees a stale marker if init is interrupted.
    rm -f "$CONFIGS_DIR/$MACHINE.init-done"
```

- [ ] Step 3: 在 `main()` 中 `print_report` 调用之后、函数结尾之前，添加 init-done 写入逻辑
- Change: 在 `print_report` 之后添加：
```bash
    # Write init-done marker (all 8 steps completed successfully).
    # ob build uses this to discover buildable machines.
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$CONFIGS_DIR/$MACHINE.init-done"
```

- [ ] Step 4: 验证 — 增量重跑已有 machine
- Run: `./ob init romulus -s`
- Expected: 命令成功完成
- Run: `cat workspace/configs/romulus.init-done`
- Expected: 包含 UTC 时间戳，如 `2026-06-07T15:30:00Z`

- [ ] Step 5: 验证 — 重跑时 marker 被删除再重建（时间戳更新）
- Run: 记录 `cat workspace/configs/romulus.init-done` 的时间戳
- Run: `./ob init romulus -s`
- Run: `cat workspace/configs/romulus.init-done`
- Expected: 新时间戳晚于之前的

- [ ] Step 6: checkpoint commit
- Run: `git add ob && git commit -m "feat(ob init): add .init-done marker for ob build discovery"`

### Task 3: Implement cmd_build — machine discovery + selection table

- 目标：`ob build` 展示主仓信息和已初始化 machine 列表，支持交互选择和 Enter 确认
- 涉及文件：`ob` — `cmd_build()` 函数
- 验证范围：`ob build` 正确展示表单，选择 machine 后进入确认提示

- [ ] Step 1: 将 cmd_build() stub 替换为完整实现
- Change: 替换 `cmd_build()` 函数体为：

```bash
cmd_build() {
    # === Prerequisites ===
    if [[ ! -d "$OPENBMC_DIR/.git" ]]; then
        error "OpenBMC main repository not found at $OPENBMC_DIR"
        error "Run 'ob init' first."
        exit 1
    fi

    if [[ ! -f "$SOURCE_LOCK_FILE" ]]; then
        error "Source lock not found at $SOURCE_LOCK_FILE"
        error "Run 'ob init' first."
        exit 1
    fi

    # === Discover init-done machines ===
    local -a machines=()
    local -a init_times=()
    local -a repo_counts=()

    for init_done_file in "$CONFIGS_DIR"/*.init-done; do
        [[ -f "$init_done_file" ]] || continue
        local mname
        mname=$(basename "$init_done_file" .init-done)
        machines+=("$mname")

        local init_time
        init_time=$(cat "$init_done_file" 2>/dev/null || echo "<unknown>")
        init_times+=("$init_time")

        local lockfile="$CONFIGS_DIR/$mname.lock"
        local repo_count=0
        if [[ -f "$lockfile" ]]; then
            repo_count=$(python3 -c "import json; print(len(json.load(open('$lockfile'))['sub_repos']))" 2>/dev/null || echo "?")
        else
            repo_count="?"
        fi
        repo_counts+=("$repo_count")
    done

    if [[ ${#machines[@]} -eq 0 ]]; then
        step_header "Initialized Machines"
        echo ""
        echo "  (none)"
        echo ""
        error "No machines are ready to build."
        error "Run 'ob init' first to initialize a machine, then come back."
        exit 1
    fi

    # === Read main repo info ===
    local lock_origin_url lock_source_label
    lock_origin_url=$(read_lock_field origin_url || echo "<unknown>")
    lock_source_label=$(read_lock_field source_label || echo "")

    # === Display ===
    step_header "OpenBMC Repository"
    echo "  Source : $lock_origin_url${lock_source_label:+ ($lock_source_label)}"
    echo "  Path   : $OPENBMC_DIR"
    echo ""

    step_header "Initialized Machines"

    local total=${#machines[@]}
    local idx_width=${#total}
    local i
    for (( i=0; i<total; i++ )); do
        printf "  %${idx_width}d) %-20s %s    %s repos\n" \
            "$((i + 1))" "${machines[$i]}" "${init_times[$i]}" "${repo_counts[$i]}"
    done

    echo ""
    info "If the machine you want is not listed, run 'ob init' first."
    echo ""

    # === Interactive selection ===
    if [[ ! -t 0 ]]; then
        error "No interactive terminal. ob build requires interactive mode."
        exit 1
    fi

    local selected chosen=""
    while true; do
        if ! read -r -p "Choose [1-${total}]: " selected; then
            error "Unable to read selection from stdin."
            exit 1
        fi
        if [[ "$selected" =~ ^[0-9]+$ ]]; then
            if [[ "$selected" -ge 1 && "$selected" -le "$total" ]]; then
                chosen="${machines[$((selected - 1))]}"
                break
            fi
            warn "Number out of range (1-${total}): $selected"
            continue
        fi
        warn "Please enter a number (1-${total})"
    done

    MACHINE="$chosen"
    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"

    echo ""
    info "Selected: $MACHINE"
    info "Target  : obmc-phosphor-image"
    info "Estimated time: 1-4 hours depending on machine and cache state."
    echo ""
    if ! read -r -p "Press Enter to start build, Ctrl+C to cancel... "; then
        error "Unable to read confirmation from stdin."
        exit 1
    fi

    # === Build execution placeholder (Task 4) ===
    info "Build execution coming soon..."
}
```

- [ ] Step 2: 验证表单展示
- Run: `./ob build`
- Expected: 显示主仓信息（Source、Path）+ machine 列表（romulus + gb200nvl-obmc 含时间和 repo 数）+ 引导文字 + 选择提示
- 输入 `1` → 看到 Selected + Target + Estimated time + Enter 确认提示 → Ctrl+C 退出

- [ ] Step 3: 验证空列表场景
- Run: `rm workspace/configs/*.init-done && ./ob build 2>&1; git checkout -- workspace/configs/` (临时删除 init-done 文件测试空列表)
- Expected: 显示 "(none)" + "No machines are ready to build" + "Run 'ob init' first"
- 恢复: `./ob init romulus -s` 重新生成 init-done

- [ ] Step 4: checkpoint commit
- Run: `git add ob && git commit -m "feat(ob build): machine discovery and interactive selection table"`

### Task 4: Implement cmd_build — build execution + post-build output

- 目标：cmd_build 在用户确认后进入 bitbake 环境并执行编译，成功显示 image 路径，失败显示修复提示
- 涉及文件：`ob` — `cmd_build()` 函数后半段
- 验证范围：bitbake 正常启动并开始解析 recipes

- [ ] Step 1: 替换 cmd_build() 末尾的 `info "Build execution coming soon..."` 为真实实现
- Change: 替换占位行为：

```bash
    # === Re-enter bitbake environment ===
    cd "$OPENBMC_DIR"

    local prev_opts
    prev_opts=$(set +o | grep nounset)
    set +u
    # shellcheck disable=SC1091
    source setup "$MACHINE" "$BUILD_DIR" 2>/dev/null
    eval "$prev_opts"

    # === Run bitbake ===
    echo ""
    step_header "Building $MACHINE"
    info "Running: bitbake obmc-phosphor-image"
    echo ""

    if bitbake obmc-phosphor-image; then
        echo ""
        step_header "Build Succeeded"

        local deploy_dir="$BUILD_DIR/tmp/deploy/images/$MACHINE"
        local image_file="$deploy_dir/obmc-phosphor-image-$MACHINE.static.mtd"

        echo "  Machine : $MACHINE"
        echo "  Image   : $image_file"
        if [[ -f "$image_file" ]]; then
            local image_size
            image_size=$(du -h "$image_file" | cut -f1)
            echo "  Size    : $image_size"
        fi
        echo "  Deploy  : $deploy_dir"
        echo ""
        info "Build completed successfully."
    else
        local bb_exit=$?
        echo ""
        step_header "Build Failed"
        echo ""
        error "bitbake exited with code $bb_exit"
        echo ""
        echo "  BitBake error details are shown above."
        echo ""
        echo "  Common fixes:"
        echo "    1. Re-run:         ob build  → select same machine → retry"
        echo "    2. Clean & retry:  cd $OPENBMC_DIR && source setup $MACHINE"
        echo "                       bitbake -c cleansstate <failed-recipe>"
        echo "    3. Full log:       $BUILD_DIR/tmp/log/cooker/$MACHINE/"
        echo ""
        exit "$bb_exit"
    fi
```

- [ ] Step 2: 验证 bitbake 启动
- Run: `./ob build` → 选择一个 machine → Enter 确认
- Expected: 看到 bitbake 输出 "Parsing recipes..." 或类似内容，表明环境进入成功
- Ctrl+C 中断即可，不需要等待完整编译完成

- [ ] Step 3: 验证脚本语法
- Run: `bash -n ob`
- Expected: 无输出（无语法错误）

- [ ] Step 4: checkpoint commit
- Run: `git add ob && git commit -m "feat(ob build): bitbake execution with success/failure output"`

## 执行纪律

- 开始实现前，先批判性复查整份计划；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划
- 按任务顺序执行，不要无声跳步、合并步或改变任务目标
- 每完成一个任务，都运行该任务定义的验证
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜
- 当前在 main 分支上直接进行
- 全部任务完成后，运行最终验证并输出修改摘要

## 最终验证

1. 语法检查
- Run: `bash -n ob`
- Expected: 无输出

2. 帮助信息
- Run: `./ob -h`
- Expected: usage 包含 `build` 命令描述

3. init-done 标记
- Run: `./ob init romulus -s && cat workspace/configs/romulus.init-done`
- Expected: 成功完成，`.init-done` 存在且包含 UTC 时间戳

4. ob build 端到端
- Run: `./ob build`
- Expected: 显示主仓信息 + machine 列表 + 交互选择 + Enter 确认 + bitbake 启动

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-06-07-ob-build-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
