#!/usr/bin/env bash
# lib/qemu_commands.sh — QEMU 命令簇 L1 编排(cmd_start_qemu/cmd_stop_qemu/cmd_deploy_to_qemu/cmd_test_qemu). 术语见 CONTEXT.md function semantic layer / exit-code 契约 / ob deploy-to-qemu / ob test-qemu / QEMU instance.
# Exit: exit seam（L1 cmd_* 顶层编排, 使用 exit-code 契约值 0/1/2/3）.
# 形态对照: L1 exit-seam 命令族(顶层命令直接 exit, 无 dispatcher 收口), 区别于 lib/devtool_subcmd.sh 的 L3 leaf-pure handler(return exit-code, 由 cmd_dev 收口 exit)。

_qemu_lifecycle_lock_or_exit() {
    local machine="$1" fd_out="$2" owned_out="$3"
    local _qll_fd="" _qll_owned="" _qll_status=""
    qemu_instance_lifecycle_lock_enter "$machine" _qll_fd _qll_owned _qll_status
    case "$_qll_status" in
        ok)
            printf -v "$fd_out" '%s' "$_qll_fd"
            printf -v "$owned_out" '%s' "$_qll_owned"
            ;;
        busy)
            error "Another QEMU lifecycle operation is active for '$machine'."
            error "Wait for it to finish, then retry."
            exit 3
            ;;
        *)
            error "Cannot acquire QEMU lifecycle lock for '$machine'."
            exit 1
            ;;
    esac
}

_qemu_lifecycle_lock_export_if_owned() {
    local machine="$1" lock_fd="$2" lock_owned="$3"
    [[ "$lock_owned" == "1" ]] || return 0
    export OB_QEMU_LIFECYCLE_LOCK_FD="$lock_fd"
    export OB_QEMU_LIFECYCLE_LOCK_MACHINE="$machine"
}

_qemu_lifecycle_lock_release_if_owned() {
    local lock_fd="$1" lock_owned="$2"
    [[ "$lock_owned" == "1" ]] || return 0
    qemu_instance_lifecycle_lock_release "$lock_fd"
    unset OB_QEMU_LIFECYCLE_LOCK_FD OB_QEMU_LIFECYCLE_LOCK_MACHINE
}

cmd_start_qemu() {
    detect_harness_root

    # ── Resolve machine(经 machine_selection_guard: empty/nontty/ok, 同 cmd_build/cmd_dev) ──
    if [[ -z "$MACHINE" ]]; then
        local _msg=""
        machine_selection_guard machine_state_firmware_image_ready_machines _msg
        case "$_msg" in
            empty)
                # any_initdone 子分类留 cmd(D2): guard 是横切检测原语, 不承载 image-ready 领域逻辑。
                # image-ready 空 → 再查 initialized 区分 remedy("先 build" vs "先 init")。
                # 注: guard 拉 firmware_image_ready 判 empty + 本处拉 initialized 分 remedy, 是两个不同
                # list_fn 各求值一次(非同一函数两次), 同改造前手写代码的两次查询, 非新引入冗余;
                # 且仅在 empty 异常路径, 非 hot path(同 deploy 段 empty 分支的判空前置模式)。
                if [[ -n "$(machine_state_initialized_machines)" ]]; then
                    error "No firmware-image-ready machines found."
                    error "Run '$OB_CMD build <machine>' first."
                else
                    error "No initialized machines found."
                    error "Run '$OB_CMD init <machine>' first."
                fi
                exit 3 ;;
            nontty)
                error "No interactive terminal. Specify machine: $OB_CMD start-qemu <machine>"
                exit 3 ;;
            ok) ;;
        esac
        echo ""
        step_header "Select Machine"
        local pm_rc=0
        pick_machine machine_state_firmware_image_ready_machines "Start QEMU" || pm_rc=$?
        case "$pm_rc" in
            0) ;;
            2) warn "Start QEMU cancelled by user."; exit 2 ;;
            *) exit 1 ;;
        esac
    fi

    # Re-derive paths after machine resolution
    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
    SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"

    # ── Prerequisite 1: machine init-done ──
    if ! machine_state_is_initialized "$MACHINE"; then
        error "Machine '$MACHINE' has not been initialized."
        error "Run '$OB_CMD init $MACHINE' first."
        exit 3
    fi

    # ── Prerequisite 2: image file ──
    local image_file=""
    local deploy_dir=""
    deploy_dir="$(machine_state_deploy_dir "$MACHINE")"
    image_file=$(machine_state_firmware_image_path "$MACHINE" 2>/dev/null || true)
    if [[ -z "$image_file" ]]; then
        error "No firmware image found for machine '$MACHINE' in $deploy_dir"
        error "Run '$OB_CMD build $MACHINE' first."
        exit 3
    fi
    verbose "Image file: $image_file"

    # ── Existing-instance conflict (F1 invariant: must precede qemu_prepare_launch,
    #     whose check_ports_available exits 3 on occupied ports; killing the old
    #     same-machine instance first avoids a spurious port-conflict exit) ──
    derive_qemu_paths
    local _start_lock_fd="" _start_lock_owned=""
    _qemu_lifecycle_lock_or_exit "$MACHINE" _start_lock_fd _start_lock_owned
    _qemu_lifecycle_lock_export_if_owned "$MACHINE" "$_start_lock_fd" "$_start_lock_owned"
    local _liv=""
    qemu_instance_liveness "$MACHINE" _liv   # 恒 return 0 + outvar 状态(ADR-0024), 消灭 set-e footgun
    case "$_liv" in
        running)
            # Instance is running and valid
            if [[ "$QEMU_FORCE" -eq 1 ]]; then
                warn "Killing existing QEMU instance (PID $PIDFILE_PID)..."
                qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
            elif [[ -t 0 ]]; then
                echo ""
                warn "QEMU instance already running for '$MACHINE':"
                qemu_instance_summarize_full
                echo ""
                print_confirm_banner "kill and restart QEMU for" "$MACHINE"
                local answer
                if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Kill and restart? [y/N]: ")" answer; then
                    exit 1
                fi
                if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
                    info "Aborted."
                    exit 2
                fi
                qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
                # ── Port reuse (restart 语义): 沿用旧实例端口, 经 leaf-pure module 统一 cli_first
                # (ADR-0022; X-α -z guard 保 CLI flag 优先。deploy 同款, 不再不对称)。
                resolve_qemu_port_reuse "$PIDFILE_SSH_PORT" "$PIDFILE_REDFISH_PORT" "$PIDFILE_IPMI_PORT" "$PIDFILE_HTTP_PORT"
            else
                error "QEMU instance already running for '$MACHINE' (PID $PIDFILE_PID)."
                error "Use --force to kill and restart, or '$OB_CMD stop-qemu $MACHINE' first."
                exit 1
            fi
            ;;
        exited|recycled)
            # Stale PID file — clean up via module
            qemu_instance_clean_stale "$MACHINE"
            ;;
        nopid)
            ;;
    esac

    # ── Prepare launch (Shape 2 half 1: profile/binary/firmware/ports/build) ──
    qemu_prepare_launch "$MACHINE" "$image_file"

    step_header "Starting QEMU for '$MACHINE' ($QEMU_LAUNCH_SOC_TYPE)"
    echo "  Machine   : $QEMU_LAUNCH_MACHINE_NAME"
    echo "  SoC       : $QEMU_LAUNCH_SOC_TYPE"
    echo "  Binary    : $QEMU_BIN_FILE"
    echo "  Image     : $image_file"
    echo "  Serial log: $QEMU_LAUNCH_SERIAL_LOG"
    echo ""

    # ── Safety confirmation（仅交互 TTY）──
    # 非 TTY(CI/agent) 跳过确认直接起, 对齐 CONTEXT confirmation banner「正常起 QEMU
    # 一律跳过、无需 --force」—— 起新 QEMU 非路径风险; banner 只留给 kill 既有实例
    # (上方 conflict 块, 非 TTY 需 --force)。使 `start-qemu → test-qemu → stop-qemu` 在 CI 非交互跑通。
    if [[ -t 0 ]]; then
        local ca_rc=0
        confirm_action "start QEMU for" "$MACHINE" || ca_rc=$?
        case "$ca_rc" in
            0) ;;
            2) warn "QEMU start cancelled by user."; exit 2 ;;
            *) exit 1 ;;
        esac
        echo ""
        info "QEMU start confirmed for machine '$MACHINE'."

        # ── Emergency escape window（仅交互） ──
        warn "Launching QEMU in 3 seconds..."
        echo ""
        for _i in 3 2 1; do
            echo -e "  ${_i}..."
            sleep 1
        done
    else
        info "Non-interactive start: launching QEMU for '$MACHINE' (no confirmation)."
    fi

    verbose "Command: setsid ${QEMU_CMD[*]}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would run: setsid ${QEMU_CMD[*]}"
        exit 0
    fi

    # ── Execute launch (Shape 2 half 2: setsid + PID write + BMC wait + summary) ──
    qemu_execute_launch
    _qemu_lifecycle_lock_release_if_owned "$_start_lock_fd" "$_start_lock_owned"
}

cmd_stop_qemu() {
    detect_harness_root

    # ── Collect target machines ──
    local -a targets=()

    if [[ "$QEMU_STOP_ALL" -eq 1 ]]; then
        # --all: stop every instance
        mapfile -t targets < <(qemu_instance_list)
    elif [[ -n "$MACHINE" ]]; then
        targets+=("$MACHINE")
    else
        # No machine specified: list running instances and let user choose
        local -a available=()
        mapfile -t available < <(qemu_instance_list)

        if [[ ${#available[@]} -eq 0 ]]; then
            info "No QEMU instances found."
            exit 0
        fi

        if [[ ! -t 0 ]]; then
            error "No interactive terminal. Specify machine: $OB_CMD stop-qemu <machine>"
            error "Or use --all: $OB_CMD stop-qemu --all"
            exit 3
        fi

        echo ""
        step_header "Running QEMU Instances"
        # 渲染实例详情（PID/端口/状态，同 ob status 格式）经 qemu_instance_summarize_brief；
        # pick_machine 只渲染纯序号+名字（Q3），故 cmd_stop_qemu 自渲染带详情列表 + 复用 read_machine_choice
        local total=${#available[@]}
        local idx_width=${#total}
        local i m
        for (( i=0; i<total; i++ )); do
            m="${available[$i]}"
            printf "  %${idx_width}d) %-20s %s\n" "$((i + 1))" "$m" "$(qemu_instance_summarize_brief "$m")"
        done
        local pm_rc=0
        read_machine_choice "$total" "Stop QEMU" available || pm_rc=$?
        case "$pm_rc" in
            0) ;;
            2) warn "Stop QEMU cancelled by user."; exit 2 ;;
            *) exit 1 ;;
        esac
        targets+=("$MACHINE")
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        info "No QEMU instances to stop."
        exit 0
    fi

    # Acquire every target before modifying any instance, so --all cannot stop a
    # partial set before discovering a busy lifecycle writer.
    local -a _stop_lock_fds=() _stop_lock_owned=()
    local _stop_lock_fd _stop_owned
    for target_machine in "${targets[@]}"; do
        _stop_lock_fd=""; _stop_owned=""
        _qemu_lifecycle_lock_or_exit "$target_machine" _stop_lock_fd _stop_owned
        _stop_lock_fds+=("$_stop_lock_fd")
        _stop_lock_owned+=("$_stop_owned")
    done

    # ── Stop each target ──
    for target_machine in "${targets[@]}"; do
        MACHINE="$target_machine"

        echo ""
        local _liv=""
        qemu_instance_liveness "$MACHINE" _liv   # 恒 return 0 + outvar 状态(ADR-0024), 消灭 set-e footgun
        case "$_liv" in
            nopid)
                info "No PID file for '$MACHINE' — not running."
                continue
                ;;
            exited)
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    info "[DRY-RUN] Would clean stale PID file for '$MACHINE' (process exited)"
                    continue
                fi
                info "QEMU process for '$MACHINE' (PID $PIDFILE_PID) has already exited."
                qemu_instance_clean_stale "$MACHINE"
                continue
                ;;
            recycled)
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    info "[DRY-RUN] Would clean stale PID file for '$MACHINE' (PID recycled)"
                    continue
                fi
                warn "PID $PIDFILE_PID no longer belongs to QEMU (recycled). Cleaning stale PID file."
                qemu_instance_clean_stale "$MACHINE"
                continue
                ;;
            running)
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    info "[DRY-RUN] Would stop QEMU for '$MACHINE' (PID $PIDFILE_PID)"
                    continue
                fi
                # Process is running — show info and confirm
                echo -e "Running QEMU instance for '${BOLD}$MACHINE${NC}':"
                qemu_instance_summarize_full
                echo ""
                print_confirm_banner "stop QEMU for" "$MACHINE"

                if [[ "$QEMU_FORCE" -ne 1 ]]; then
                    if [[ -t 0 ]]; then
                        while true; do
                            local answer
                            if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Stop this instance? [y/N]: ")" answer; then
                                exit 1
                            fi
                            case "$answer" in
                                [yY])
                                    break
                                    ;;
                                [nN])
                                    info "Skipped '$MACHINE'."
                                    continue 2
                                    ;;
                                *)
                                    warn "Invalid input. Please type Y or N."
                                    ;;
                            esac
                        done
                    else
                        error "Non-interactive mode. Use --force to stop without confirmation."
                        exit 1
                    fi
                fi

                # Kill and wait
                qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
                info "QEMU instance for '$MACHINE' stopped."
                ;;
        esac
    done

    local _stop_lock_i
    for (( _stop_lock_i=0; _stop_lock_i<${#_stop_lock_fds[@]}; _stop_lock_i++ )); do
        _qemu_lifecycle_lock_release_if_owned \
            "${_stop_lock_fds[$_stop_lock_i]}" "${_stop_lock_owned[$_stop_lock_i]}"
    done
}

cmd_deploy_to_qemu() {
    detect_harness_root

    # ── Resolve machine(经 resolve_command_machine: given verify / empty·nontty·ok, ADR-0019) ──
    local _rc=0
    resolve_command_machine machine_state_initialized_machines "Deploy to QEMU" stdout "No interactive terminal. Specify machine: $OB_CMD deploy-to-qemu <machine>" || _rc=$?
    # 字面 case 收口（同 cmd_build/cmd_dev; 1) error 作 3) exit 3 的 Z(b) 锚点）。
    case "$_rc" in
        0) ;;
        1) error "ob deploy-to-qemu: failed to read machine selection input."; exit 1 ;;
        2) exit 2 ;;
        3) exit 3 ;;
        *) exit 1 ;;
    esac

    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
    SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"

    # ── DRY-RUN 短路(评审 Y2: 前移到探测 QEMU 前, 避免 DRY-RUN + QEMU 在跑时弹 confirm 交互;
    #   v3/G-new2: 前移后 DRY-RUN 也不探测 QEMU / 不读旧端口 / 不弹 banner, 输出仅 notice 一行) ──
    if [[ "$DRY_RUN" -eq 1 ]]; then
        notice "[DRY-RUN] would bitbake obmc-phosphor-image + restart QEMU for '$MACHINE'" >&2
        exit 0
    fi

    derive_qemu_paths   # 算 QEMU_PID_FILE 等(qemu.sh:6)
    local _deploy_lock_fd="" _deploy_lock_owned=""
    _qemu_lifecycle_lock_or_exit "$MACHINE" _deploy_lock_fd _deploy_lock_owned
    _qemu_lifecycle_lock_export_if_owned "$MACHINE" "$_deploy_lock_fd" "$_deploy_lock_owned"

    # ── 探测 QEMU 在跑 + 预读旧端口(必须在 stop 前, 约束 2) ──
    local qemu_running=0
    local old_qemu_pid="" old_qemu_started_at="" old_qemu_start_ticks="" old_qemu_serial_sock=""
    local old_ssh_port="" old_redfish_port="" old_ipmi_port="" old_http_port=""
    local _liv=""
    qemu_instance_liveness "$MACHINE" _liv   # 恒 return 0 + outvar 状态(ADR-0024), 消灭 set-e footgun
    case "$_liv" in
        running)
            qemu_running=1
            old_qemu_pid="$PIDFILE_PID"
            old_qemu_started_at="$PIDFILE_STARTED_AT"
            old_qemu_start_ticks="$PIDFILE_PROCESS_START_TICKS"
            old_qemu_serial_sock="$PIDFILE_SERIAL_SOCK"
            old_ssh_port="$PIDFILE_SSH_PORT"
            old_redfish_port="$PIDFILE_REDFISH_PORT"
            old_ipmi_port="$PIDFILE_IPMI_PORT"
            old_http_port="$PIDFILE_HTTP_PORT"
            ;;
        exited|recycled)
            qemu_instance_clean_stale "$MACHINE"
            ;;
        nopid)
            ;;
    esac

    # ── confirm: 仅 QEMU 在跑时 banner(约束 4, 路径风险原则) ──
    if [[ $qemu_running -eq 1 ]]; then
        echo ""
        warn "QEMU instance running for '$MACHINE' — deploy will kill it, rebuild image, and restart."
        qemu_instance_summarize_full
        print_confirm_banner "rebuild image and restart QEMU for" "$MACHINE"
        local answer
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Kill + rebuild + restart? [y/N]: ")" answer; then
            exit 1
        fi
        [[ "$answer" == [yY] ]] || { info "Aborted."; exit 2; }
    fi

    # Image build does not mutate QEMU lifecycle state and may take hours. Do
    # not block other start/stop operations for the whole build; re-acquire and
    # verify the snapshot before touching the instance.
    _qemu_lifecycle_lock_release_if_owned "$_deploy_lock_fd" "$_deploy_lock_owned"
    _deploy_lock_fd=""; _deploy_lock_owned=""

    # ── Step 1: build(build-first, 约束 3 — QEMU 在跑也不停) ──
    echo ""
    step_header "Building $MACHINE (image rebuild)"
    info "Running: bitbake obmc-phosphor-image"
    info "Estimated time: 1-4 hours depending on machine and cache state."

    if ! build_obmc_image "$MACHINE" "$BUILD_DIR"; then
        echo ""
        step_header "Build Failed"
        error "bitbake failed — image not rebuilt, QEMU unchanged (build-first)."
        exit 1                       # 约束 3: build 失败 QEMU 不动
    fi

    # ── build 成功 stage 标记(约束 6; 评审 Y3: 简化版——只 Machine/Image 两行) ──
    #   cmd_build 的 Size/Deploy 行不复制——deploy 语境已隐含 build 成功 + 即将重启,
    #   size/deploy dir 冗余; 若未来要 build 族输出对称再复刻(技术债)。
    local image_file=""
    image_file=$(machine_state_firmware_image_path "$MACHINE" 2>/dev/null || true)
    step_header "Image Rebuilt"
    echo "  Machine: $MACHINE"
    echo "  Image  : ${image_file:-<not found>}"

    _qemu_lifecycle_lock_or_exit "$MACHINE" _deploy_lock_fd _deploy_lock_owned
    _qemu_lifecycle_lock_export_if_owned "$MACHINE" "$_deploy_lock_fd" "$_deploy_lock_owned"
    local _deploy_liv_now=""
    qemu_instance_liveness "$MACHINE" _deploy_liv_now
    if [[ $qemu_running -eq 1 ]]; then
          if [[ "$_deploy_liv_now" != "running" || "$PIDFILE_PID" != "$old_qemu_pid" || \
              "$PIDFILE_STARTED_AT" != "$old_qemu_started_at" || \
              "$PIDFILE_PROCESS_START_TICKS" != "$old_qemu_start_ticks" || \
              "$PIDFILE_SERIAL_SOCK" != "$old_qemu_serial_sock" ]]; then
            error "QEMU instance for '$MACHINE' changed while the image was building."
            error "Review the current instance, then retry '$OB_CMD deploy-to-qemu $MACHINE'."
            exit 3
        fi
    else
        case "$_deploy_liv_now" in
            running)
                error "A QEMU instance for '$MACHINE' appeared while the image was building."
                error "Review the current instance, then retry '$OB_CMD deploy-to-qemu $MACHINE'."
                exit 3
                ;;
            exited|recycled)
                qemu_instance_clean_stale "$MACHINE"
                ;;
        esac
    fi

    # ── Step 2: stop 旧 QEMU(若在跑) + 端口复用注入(约束 2) ──
    if [[ $qemu_running -eq 1 ]]; then
        echo ""
        warn "Stopping old QEMU (PID $PIDFILE_PID)..."
        qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
        info "Old QEMU stopped."
        resolve_qemu_port_reuse "$old_ssh_port" "$old_redfish_port" "$old_ipmi_port" "$old_http_port"
    fi

    # ── Step 3: start 新 QEMU(端口复用) + 恢复引导(约束 5/6) ──
    echo ""
    step_header "Starting new QEMU for '$MACHINE'"
    info "If start fails, image is already rebuilt — recover manually: $OB_CMD start-qemu $MACHINE"

    qemu_prepare_launch "$MACHINE" "$image_file"
    echo "  Machine   : $QEMU_LAUNCH_MACHINE_NAME"
    echo "  SoC       : $QEMU_LAUNCH_SOC_TYPE"
    echo "  Binary    : $QEMU_BIN_FILE"
    echo "  Image     : $image_file"
    echo "  Serial log: $QEMU_LAUNCH_SERIAL_LOG"
    echo ""

    qemu_execute_launch        # setsid + PID 写 + BMC-ready 等待(超时仅 warn 不中止) + hostkey + summary
    _qemu_lifecycle_lock_release_if_owned "$_deploy_lock_fd" "$_deploy_lock_owned"
    # 到此返回 0(QEMU 启动即成功, 约束 5); setsid 失败时 execute_launch 自己退出 1
}

# ════════════════════════════════════════════════════════════════════════════
# ob test-qemu — baseline AR probe runner (probe-only)。术语见 CONTEXT.md baseline / ob test-qemu / exit-code 契约.
# probe-only (不 boot/teardown, 无 EXIT trap), 读 PID 文件真实 Redfish 端口。
#   逐条深测 per-machine baseline 的 QEMU 可仿真 AR 子集, 产 pass/fail/skip/xfail/xpass;
#   内建 smoke suite(ADR-0028 收编, 5 AR 可达性门)守 per-push 绿灯, 其余 suite 守 nightly/PR-to-main。
# per-machine 全栈独立 (ADR-0025): 每 machine baseline 目录自包含 AR 数据 + probe 引擎, 不共享。
#   落点二分 + 谱系路由 (ADR-0026): community 谱系(community source label)→ tests/baseline/<machine>/
#   (随上游); custom 谱系(custom source label)→ contexts/baseline/<machine>/ (不随上游)。各找各的,
#   不做优先级覆盖 — 错配(custom 谱系测社区基线, fail 无法归因)在路由层不可能出现。
# ════════════════════════════════════════════════════════════════════════════

# test_qemu_lineage <source_label> <outvar> — leaf-pure 谱系判定(单维度: source label)。
# source_label: manifest 的 source_label(经 read_source_label, 缺失 fallback community)。
# label 是谱系唯一权威事实源: 一个 harness 绑定唯一 source(repo.sh source conflict 保护),
# binary 目录由 label 派生(derive_qemu_paths: qemu-bin/$label), provisioning 由 label 分派
# (ensure_qemu_binary), launch 无 binary override — (label, binary 路径)在 ob 体系内完全
# 共线, binary 维度是冗余信号(且防不住真威胁: OB_QEMU_BINARY_URL 指向自编 URL 下载替换
# community/ 内容时路径不变, 路径判定照样误判 community, 反成假安全感)。
# 字面 "custom" → custom / "community" → community; 其他值 → "unknown"(manifest 被外力
# 写坏的防御, cmd 层 exit 3, 不静默归类)。恒 return 0 + outvar(对齐 ADR-0024 范式)。
test_qemu_lineage() {
    local src_label="$1" outvar="$2"
    case "$src_label" in
        custom)    printf -v "$outvar" '%s' "custom" ;;
        community) printf -v "$outvar" '%s' "community" ;;
        *)         printf -v "$outvar" '%s' "unknown" ;;
    esac
    return 0
}

# test_qemu_resolve_lineage <outvar> — leaf-pure 谱系解析(manifest strict 读取 → 谱系判定)。
# 自读 manifest 而不经 read_source_label: 后者把 label 缺失(文件缺/字段空)静默 fallback
# community, 调用方无法区分"真 community"与"fallback community" — 信息在该层已丢。
# 谱系判定是 baseline 路由的归因闸门, 缺失态须 fail-closed(ADR-0026 2026-08-18 修订):
# 文件缺失/source_label 字段空 → "unknown"(cmd 层 exit 3 + 按成因 remedy, 与"写坏"同档
# 强防御); 字段非空 → 交 test_qemu_lineage 字面二值判定。恒 return 0 + outvar。
# read_source_label 的 community fallback 本体保留 — binary provisioning 等其他消费方
# 的缺失默认是 fail-safe 方向(下载社区 binary), 无归因问题, 不在本闸门管辖。
test_qemu_resolve_lineage() {
    local outvar="$1" label=""
    if [[ -f "${SOURCE_MANIFEST_FILE:-}" ]]; then
        label=$(read_manifest_field source_label 2>/dev/null || true)
        label=$(trim_whitespace "$label")
    fi
    if [[ -z "$label" ]]; then
        printf -v "$outvar" '%s' "unknown"
    else
        test_qemu_lineage "$label" "$outvar"
    fi
    return 0
}

# test_qemu_resolve_baseline_dir <lineage> <machine> <outvar> — leaf-pure helper: 按谱系路由 baseline 目录。
# community 谱系 → tests/baseline/<machine>(社区基线, 随上游); custom 谱系 →
# contexts/baseline/<machine>(custom 基线, 不随上游)。各找各的, 不做优先级覆盖 —
# 谱系与基线的错配(custom 谱系测社区基线 → fail 无法归因)在路由层不可能出现。
# 锚定 $HARNESS_ROOT (detect_harness_root 设置 = $OB_ENTRY_DIR; 从任意 cwd 调 ob 时相对路径会误报 MISSING)。
# outvar 写命中目录绝对路径或 "MISSING"; 恒 return 0 (对齐 machine_selection_guard outvar+恒0 / ADR-0024)。
# 抽出为独立 helper: 让 protocol 测谱系路由时直测路由分支细节 (cmd 层 baseline remedy
# 无 QEMU 即可测 — 前置重排后先于 liveness, 见 cmd_test_qemu 排序原则注释)。
test_qemu_resolve_baseline_dir() {
    local lineage="$1" machine="$2" outvar="$3"
    local root="${HARNESS_ROOT:-$OB_ENTRY_DIR}"
    local dir=""
    case "$lineage" in
        community) dir="$root/tests/baseline/$machine" ;;
        custom)    dir="$root/contexts/baseline/$machine" ;;
        *)         printf -v "$outvar" '%s' "MISSING"; return 0 ;;
    esac
    if [[ -d "$dir" ]]; then
        printf -v "$outvar" '%s' "$dir"
    else
        printf -v "$outvar" '%s' "MISSING"
    fi
    return 0
}

# test_qemu_usage — cmd_test_qemu 的 -h/--help 输出 (ob test-qemu --help)。自包含 test-qemu 专属说明。
test_qemu_usage() {
    cat <<EOF
Usage: $OB_CMD test-qemu <machine> [options]

Run <machine>'s baseline AR probes on its RUNNING QEMU instance (probe mode;
--dry-run lists ARs + applicability without an instance). Each AR
(需求条目) is probed and verdicted pass/fail/skip/xfail/xpass.

Options:
  --suite <name>   Only run ARs in this suite (built-in per-machine suites
                   include 'smoke' — the 5-AR reachability gate: Redfish
                   root/Manager/firmware, IPMI mc info, SSH TCP; ADR-0028)
  --ar <id>        Only run the named AR
  --report <path>  Dump JSON report to PATH
  -v, --verbose    Per-AR live fail/error lines also carry code= when
                   available (reason is always shown; live status lines
                   always stream to stderr)
  -d, --dry-run    List ARs + applicability, no probe (no running instance needed)
  -h, --help       Show this help

Environment:
  OB_TQ_USER / OB_TQ_PASSWORD   Redfish creds — env wins over argv flags and over
                                ar_probes.yaml auth (keeps secrets out of 'ps';
                                environ is owner-only). Missing ones fall back to
                                ar_probes.yaml auth.redfish / auth.
  OB_TQ_IPMI_USER / OB_TQ_IPMI_PASSWORD
                                IPMI creds (smoke SMOKE-04) — env wins over
                                ar_probes.yaml auth.ipmi (fallback auth);
                                if absent everywhere the ipmi probe errors 3.
  OB_TQ_TIMEOUT                 Per-probe HTTP timeout seconds (default 10)
  (OB_TQ_SSH_PORT / OB_TQ_IPMI_PORT are exported from the instance's PID
  file for the smoke suite's ssh_tcp / ipmi probes — not user-facing knobs.)

Boundary: probe-only — does NOT boot or tear down QEMU; reads the Redfish
          port from the instance's PID file (no port overrides honored).
          With no <machine> on a TTY it offers a numbered pick among
          running instances; non-interactively it lists them and exits 3.
          With no running instance it exits 3 and will NOT boot one — run
          '$OB_CMD start-qemu <machine>' first. With --dry-run no instance is
          needed — baseline asset check only.

baseline dir (lineage-routed, per ADR-0025/0026; lineage is judged on the
          source label alone — the QEMU binary dir is derived from the same
          label, not an independent factor; a missing manifest or empty
          source_label fails closed, it never silently defaults to community):
          community lineage (community source label)
            → tests/baseline/<machine>   (community baseline, ships upstream)
          custom lineage (custom source label — any non-community source)
            → contexts/baseline/<machine> (custom baseline, local only)
          No cross-lineage fallback: a custom build never probes the
          community baseline — fail attribution stays closed.

Verdict (per AR):
  pass   applicable AR, probe matched the assert
  fail   applicable AR, probe did NOT match (BMC misses baseline)
  skip   not applicable / not QEMU-emulatable (no probe run)
  xfail  expected fail: probe failed as expected
  xpass  unexpected pass: an xfail AR surprisingly passed (improvement signal)
  error  probe could not get a clean BMC answer (transport/timeout/schema) —
         infra, NOT a baseline miss
  skip/xfail/xpass do NOT affect the exit-code — only an applicable AR that
  actually fails causes exit-code 1.

Exit codes (test-qemu-specific):
  0   All applicable ARs passed (skip/xfail/xpass do not count).
  1   One or more applicable ARs failed — α truth: the BMC does not meet its
      baseline. This is NOT "test-qemu broken"; read the fail rows + report.
  3   Precondition missing (no running instance, machine not resolved, or no
      baseline dir for <machine> — see remedy line), OR one or more probes hit
      a transient infra error mid-run (VERDICT: ERROR) — the instance may be
      fine; re-run / check connectivity rather than treat it as a baseline fail.
EOF
}

cmd_test_qemu() {
    detect_harness_root

    # 先扫 -h/--help: parse_args 的 test-qemu) set -- 让 --help 进 TEST_QEMU_ARGS 而非全局 parser;
    # 必须在 machine 必填/liveness 之前, 否则 './ob test-qemu --help' 因 MACHINE 空走 exit 3。
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
            -h|--help) test_qemu_usage; return 0 ;;
        esac
    done

    # 解析命令私有 flags (machine 由全局 $MACHINE 提供, parse_args 已设; argv 只含私有 flags)
    local _suite="" _ar="" _report="" _verbose=0 _dry=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --suite) _suite="$2"; shift 2 ;;
            --ar) _ar="$2"; shift 2 ;;
            --report) _report="$2"; shift 2 ;;
            -v|--verbose) _verbose=1; shift ;;
            -d|--dry-run) _dry=1; shift ;;
            -h|--help) test_qemu_usage; return 0 ;;
            *) error "Unknown option: $1"; test_qemu_usage >&2; exit 1 ;;
        esac
    done

    # ── 前置 1: machine 必填 (TTY 时交互选号, 同 cmd_stop_qemu 模式; 非 TTY 列 running
    #    candidates + exit 3, 保 CI/agent 语义; 交互选号不破坏 probe-only — 只选目标, 不 bring-up) ──
    if [[ -z "$MACHINE" ]]; then
        local -a _tq_targets=()
        mapfile -t _tq_targets < <(qemu_instance_list)
        if [[ ${#_tq_targets[@]} -eq 0 ]]; then
            error "No machine specified."
            error "No QEMU instance is running. test-qemu probes a running instance — run '$OB_CMD start-qemu <machine>' first."
            exit 3
        fi
        if [[ ! -t 0 ]]; then
            error "No machine specified."
            error "Running QEMU instances you can test:"
            local _t
            for _t in "${_tq_targets[@]}"; do
                printf '  %-20s %s\n' "$_t" "$(qemu_instance_summarize_brief "$_t")" >&2
            done
            error "Specify a machine: $OB_CMD test-qemu <machine>"
            exit 3
        fi
        # 交互: 渲染实例详情(PID/端口/状态, 同 ob status 格式)+ 复用 read_machine_choice
        # (pick_machine 只渲染纯序号+名字, 同 cmd_stop_qemu 的自渲染理由)
        echo ""
        step_header "Running QEMU Instances"
        local _tq_total=${#_tq_targets[@]}
        local _tq_idx_width=${#_tq_total}
        local _tq_i _tq_m
        for (( _tq_i=0; _tq_i<_tq_total; _tq_i++ )); do
            _tq_m="${_tq_targets[$_tq_i]}"
            printf "  %${_tq_idx_width}d) %-20s %s\n" "$((_tq_i + 1))" "$_tq_m" "$(qemu_instance_summarize_brief "$_tq_m")"
        done
        local _tq_pm_rc=0
        read_machine_choice "$_tq_total" "Test QEMU" _tq_targets || _tq_pm_rc=$?
        case "$_tq_pm_rc" in
            0) ;;
            2) warn "Test QEMU cancelled by user."; exit 2 ;;
            *) exit 1 ;;
        esac
    fi

    # PyYAML 前置(runner/report/auth 解析 YAML; 缺失 → exit 3 + remedy, 计划全局约束 + 评审 🔴2)
    if ! python3 -c "import yaml" 2>/dev/null; then
        error "PyYAML not installed (test-qemu runner needs 'import yaml')."
        error "Install: pip install pyyaml  (or your distro's python3-yaml)"
        exit 3
    fi

    # ── 前置 2: baseline 目录按谱系路由 (ADR-0026; community→tests/, custom→contexts/) ──
    # 排序原则: 前置按"缺失时用户修复成本"排序 — baseline 是结构性缺失(建目录级投入)且
    # 零 QEMU 依赖, 先于 QEMU 运行态检查暴露; liveness 段是 probe-only 标准前置。
    # 谱系 = source label 单维度。label 是唯一权威事实源: 一个 harness 绑定唯一 source,
    # binary 目录由 label 派生(derive_qemu_paths: qemu-bin/$label), 共线非独立信号。
    # 经 test_qemu_resolve_lineage strict 读取(ADR-0026 2026-08-18 修订): manifest 缺失/
    # 字段空不 fallback community 而判 unknown(exit 3, 与写坏同档强防御) — 谱系是 baseline
    # 路由的归因闸门, 缺失态 fail-closed; read_source_label 的 community fallback 保留给
    # binary provisioning 等消费方(那里缺失是 fail-safe 方向)。custom 源 → custom 谱系,
    # 必须测自己的 contexts 基线(fail 归因闭合); 不做跨谱系回退 — 本谱系目录缺失即 exit 3,
    # remedy 按谱系指名应建的目录。
    local _lineage=""
    test_qemu_resolve_lineage _lineage
    if [[ "$_lineage" == "unknown" ]]; then
        # 按成因分档 remedy(unknown = 缺失/字段空 或 写坏): 排查方向不同, 不共用文案
        local _mlabel=""
        if [[ -f "${SOURCE_MANIFEST_FILE:-}" ]]; then
            _mlabel=$(read_manifest_field source_label 2>/dev/null || true)
            _mlabel=$(trim_whitespace "$_mlabel")
        fi
        if [[ -z "$_mlabel" ]]; then
            error "Cannot determine lineage for '$MACHINE': source manifest missing or source_label empty."
            error "Restore ${SOURCE_MANIFEST_FILE:-workspace/configs/openbmc-source.manifest} or re-run '$OB_CMD init' to regenerate it. See ADR-0026."
        else
            error "Cannot determine lineage for '$MACHINE': source label is neither 'community' nor 'custom'."
            error "The manifest is externally corrupted — check via '$OB_CMD status' (Source label) or re-run $OB_CMD init. See ADR-0026."
        fi
        exit 3
    fi
    local _dir=""
    test_qemu_resolve_baseline_dir "$_lineage" "$MACHINE" _dir
    if [[ "$_dir" == "MISSING" ]]; then
        error "No baseline dir for '$MACHINE' (lineage: $_lineage)."
        if [[ "$_lineage" == "custom" ]]; then
            error "Expected contexts/baseline/$MACHINE/ — this harness's source label is 'custom' (source other than github.com/openbmc/openbmc; lineage is judged on the source label alone)."
            error "A community baseline cannot own a custom build's verdict; provide contexts/baseline/$MACHINE/ (see tests/baseline/README.md, ADR-0026)."
        else
            error "Expected tests/baseline/$MACHINE/ (community lineage, ships with ob-harness)."
            error "Create it per tests/baseline/README.md, or verify lineage via '$OB_CMD status'. See ADR-0026."
        fi
        exit 3
    fi

    # ── 前置 3: 凭据解析 — env OB_TQ_USER/OB_TQ_PASSWORD 优先, 缺者从 ar_probes.yaml auth 补 ──
    # 凭据只依赖 baseline dir(读 ar_probes.yaml), 修复成本低但检查零成本 — 与 baseline 同属
    # 本地可判定前置, 先于 QEMU 运行态。仅 probe 需要: dry-run 不 probe, 凭据无用
    # (与 run.sh DRY_RUN 分支的凭据豁免对齐)。
    # (评审 🟡2 + 🟢1: 密码经 env 注入 runner/probe — argv 是 ps 全局可见的, environ owner-only;
    #  双源校验防 env 与 YAML 打架: user/password 各满足 env 或 YAML 至少一源, 缺则 exit 3 指名。)
    # $() 捕获 + || _arc=$? 显式判 rc(评审 🟡1): process substitution 的 read 在 set -e 下 EOF
    # exit 1 会先于显式 exit 3 触发 errexit, 把 malformed YAML 误报成 exit 1(α truth 污染)。
    if [[ $_dry -eq 0 ]]; then
        local _auth_user="${OB_TQ_USER:-}" _auth_pass="${OB_TQ_PASSWORD:-}"
        local _ipmi_user="${OB_TQ_IPMI_USER:-}" _ipmi_pass="${OB_TQ_IPMI_PASSWORD:-}"
        local _auth_out="" _arc=0
        if [[ -z "$_auth_user" || -z "$_auth_pass" || -z "$_ipmi_user" || -z "$_ipmi_pass" ]]; then
            _auth_out=$(OB_TQ_YAML="$_dir/ar_probes.yaml" python3 -c '
import yaml, os, sys
try:
    d = yaml.safe_load(open(os.environ["OB_TQ_YAML"])) or {}
except Exception as e:
    sys.stderr.write("cmd_test_qemu: cannot parse %s: %s\n" % (os.environ["OB_TQ_YAML"], e))
    sys.exit(3)
a = d.get("auth") or {}
def pick(k):
    sub = a.get(k) if isinstance(a.get(k), dict) else None
    return (sub or {}).get("user") or a.get("user") or "", (sub or {}).get("password") or a.get("password") or ""
u, p = pick("redfish")
print(u); print(p)
u, p = pick("ipmi")
print(u); print(p)
') || _arc=$?
            if [[ $_arc -ne 0 ]]; then
                error "Cannot parse $_dir/ar_probes.yaml auth (YAML malformed — see parse error above)."
                exit 3
            fi
            # env 已设者胜, 只从 YAML 补缺(print 四行 redfish user/pass + ipmi user/pass)
            local -a _auth_lines=()
            mapfile -t _auth_lines <<< "$_auth_out"
            [[ -z "$_auth_user" ]] && _auth_user="${_auth_lines[0]:-}"
            [[ -z "$_auth_pass" ]] && _auth_pass="${_auth_lines[1]:-}"
            [[ -z "$_ipmi_user" ]] && _ipmi_user="${_auth_lines[2]:-}"
            [[ -z "$_ipmi_pass" ]] && _ipmi_pass="${_auth_lines[3]:-}"
        fi
        if [[ -z "$_auth_user" ]]; then
            error "No Redfish user for '$MACHINE' baseline probes."
            error "Set OB_TQ_USER env, or auth.redfish.user (fallback auth.user) in $_dir/ar_probes.yaml."
            exit 3
        fi
        if [[ -z "$_auth_pass" ]]; then
            error "No Redfish password for '$MACHINE' baseline probes."
            error "Set OB_TQ_PASSWORD env, or auth.redfish.password (fallback auth.password) in $_dir/ar_probes.yaml."
            exit 3
        fi
        export OB_TQ_USER="$_auth_user" OB_TQ_PASSWORD="$_auth_pass"
        # per-interface 凭据(ADR-0028 smoke 收编): ipmi 凭据 env > auth.ipmi > auth 顶层;
        # 全缺则不 export — 纯 redfish suite 不受影响, ipmi probe 自行 error 3 指名。
        [[ -n "$_ipmi_user" && -n "$_ipmi_pass" ]] && export OB_TQ_IPMI_USER="$_ipmi_user" OB_TQ_IPMI_PASSWORD="$_ipmi_pass"
    fi

    # ── 前置 4: RUNNING QEMU instance (probe-only; 绝不探死端口防假"BMC 坏") ──
    # liveness/lock/port 仅 probe 需要; dry-run 是 baseline 资产检查(planner-only), 不碰
    # BMC —— 与 run.sh DRY_RUN 分支的前置豁免对齐。
    local _test_lock_fd="" _test_lock_owned="" _liv="" _port=""
    if [[ $_dry -eq 0 ]]; then
        derive_qemu_paths
        _qemu_lifecycle_lock_or_exit "$MACHINE" _test_lock_fd _test_lock_owned
        qemu_instance_liveness "$MACHINE" _liv   # 恒 return 0 + outvar 状态(ADR-0024)
        case "$_liv" in
            nopid)
                error "No QEMU instance running for '$MACHINE' (no PID file)."
                error "Run '$OB_CMD start-qemu $MACHINE' first."
                exit 3
                ;;
            exited|recycled)
                qemu_instance_clean_stale "$MACHINE"
                error "QEMU instance for '$MACHINE' is not running (stale PID file cleaned)."
                error "Run '$OB_CMD start-qemu $MACHINE' first."
                exit 3
                ;;
            running)
                ;;
        esac

        # ── 从 PID 文件读真实 Redfish 端口 (qemu_instance_liveness 已填 PIDFILE_*; 不假设默认值) ──
        _port="$PIDFILE_REDFISH_PORT"
        # smoke suite probe-type 端口注入(ADR-0028): ipmi/ssh_tcp probe 从 env 读端口,
        # 与 redfish 的 --port argv 通道并存; 值来自实例 PID 文件(同一事实源)。
        export OB_TQ_SSH_PORT="$PIDFILE_SSH_PORT" OB_TQ_IPMI_PORT="$PIDFILE_IPMI_PORT"
    fi

    # ── 调共享 runner (host/port argv + 数据/凭据 env 注入; runner exit 0/1 透传为 ob exit 0/1) ──
    # runner 单副本在主仓 tests/baseline/runner/ (ADR-0027): 谱系路由($_dir)只定数据目录,
    # 数据路径经 OB_TQ_AR_PROBES/OB_TQ_APPL env 注入(runner 既有钩子, 引擎零参数化)。
    # 凭据走 env 不走 argv(评审 🟡2): ob → bash run.sh → python probe 全链 ps 不可见;
    # run.sh 侧"argv 或 env 至少一源"校验由 env 满足, probe _resolve_auth 的 env fallback 消费。
    if [[ $_dry -eq 1 ]]; then
        info "test-qemu: dry-run '$MACHINE' baseline at $_dir (lineage $_lineage, no probe, no instance needed)."
    else
        info "test-qemu: probing '$MACHINE' baseline at $_dir (lineage $_lineage, Redfish port $_port)."
    fi
    local _tq_root="${HARNESS_ROOT:-$OB_ENTRY_DIR}"
    export OB_TQ_AR_PROBES="$_dir/ar_probes.yaml" OB_TQ_APPL="$_dir/applicability.yaml"
    local -a _run_args=(bash "$_tq_root/tests/baseline/runner/run.sh")
    [[ $_dry -eq 0 ]] && _run_args+=(--host 127.0.0.1 --port "$_port")
    [[ -n "$_ar" ]] && _run_args+=(--ar "$_ar")
    [[ -n "$_suite" ]] && _run_args+=(--suite "$_suite")
    [[ -n "$_report" ]] && _run_args+=(--report "$_report")
    [[ $_verbose -eq 1 ]] && _run_args+=(-v)
    [[ $_dry -eq 1 ]] && _run_args+=(-d)

    local _rrc=0
    "${_run_args[@]}" || _rrc=$?
    [[ $_dry -eq 0 ]] && _qemu_lifecycle_lock_release_if_owned "$_test_lock_fd" "$_test_lock_owned"
    # runner exit taxonomy(评审 🔴2): 0=无 applicable fail / 1=α truth(BMC fail) / 3=infra-config-data 前置缺失。
    # 映射字面 exit(exit-contract X: 须字面 0/1/2/3)。unknown rc → exit 3(runner internal error),
    # 不用 exit 1——test-qemu 的 exit 1 专属 α truth, 不混 broken。
    case "$_rrc" in
        0) exit 0 ;;
        1) exit 1 ;;    # α truth: BMC 不满足 baseline(runner 的 fail 行已说明哪条 AR)
        3) exit 3 ;;    # infra/config/data 前置缺失(runner 已输出 remedy: no-instance/YAML/0-AR 等)
        *)
            error "runner returned unexpected exit-code $_rrc (runner internal error)."
            error "This is NOT a BMC baseline failure — report with the output above."
            exit 3
            ;;
    esac
}
