#!/usr/bin/env bash
# lib/qemu_commands.sh — QEMU 命令簇 L1 编排(cmd_start_qemu/cmd_stop_qemu/cmd_deploy_to_qemu). 术语见 CONTEXT.md function semantic layer / exit-code 契约 / ob deploy-to-qemu.
# Exit: exit seam（L1 cmd_* 顶层编排, 使用 exit-code 契约值 0/1/2/3）.
# 形态对照: L1 exit-seam 命令族(顶层命令直接 exit, 无 dispatcher 收口), 区别于 lib/devtool_subcmd.sh 的 L3 leaf-pure handler(return exit-code, 由 cmd_dev 收口 exit)。

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
                    error "Run 'ob build <machine>' first."
                else
                    error "No initialized machines found."
                    error "Run 'ob init <machine>' first."
                fi
                exit 3 ;;
            nontty)
                error "No interactive terminal. Specify machine: ob start-qemu <machine>"
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
        error "Run 'ob init $MACHINE' first."
        exit 3
    fi

    # ── Prerequisite 2: image file ──
    local image_file=""
    local deploy_dir=""
    deploy_dir="$(machine_state_deploy_dir "$MACHINE")"
    image_file=$(machine_state_firmware_image_path "$MACHINE" 2>/dev/null || true)
    if [[ -z "$image_file" ]]; then
        error "No firmware image found for machine '$MACHINE' in $deploy_dir"
        error "Run 'ob build $MACHINE' first."
        exit 3
    fi
    verbose "Image file: $image_file"

    # ── Existing-instance conflict (F1 invariant: must precede qemu_prepare_launch,
    #     whose check_ports_available exits 3 on occupied ports; killing the old
    #     same-machine instance first avoids a spurious port-conflict exit) ──
    derive_qemu_paths
    if qemu_instance_load "$MACHINE"; then
        # if 包裹 is_alive: 明确意图(alive vs stale) + 必须 set -e 安全, 与 cmd_deploy_to_qemu 同款。
        # 注: is_alive 是多态返回函数(0=running/1=exited/2=recycled), 裸调 + $? 读在 ob set -euo 下
        # 死实例(return 1)与 PID recycled(return 2)都会 abort、clean_stale 走不到(bash 5.2.15 实测
        # 顶层/嵌套/sourced/子shell 四上下文裸调 return 1 全部 abort, 见 start_qemu_stale_pid.sh);
        # if 包裹消费 rc 才能落到 clean_stale, 是必需而非"无害防御"。
        if qemu_instance_is_alive "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE"; then
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
            else
                error "QEMU instance already running for '$MACHINE' (PID $PIDFILE_PID)."
                error "Use --force to kill and restart, or 'ob stop-qemu $MACHINE' first."
                exit 1
            fi
        else
            # Stale PID file — clean up via module
            qemu_instance_clean_stale "$MACHINE"
        fi
    fi

    # ── Prepare launch (Shape 2 half 1: profile/binary/firmware/ports/build) ──
    qemu_prepare_launch "$MACHINE" "$image_file"

    step_header "Starting QEMU for '$MACHINE' ($QEMU_LAUNCH_SOC_TYPE)"
    echo "  Machine   : $QEMU_LAUNCH_MACHINE_NAME"
    echo "  SoC       : $QEMU_LAUNCH_SOC_TYPE"
    echo "  Binary    : $QEMU_BIN_FILE"
    echo "  Image     : $image_file"
    echo "  Serial log: $QEMU_LAUNCH_SERIAL_LOG"
    echo ""

    # ── Safety confirmation (same pattern as ob init / ob build) ──
    local ca_rc=0
    confirm_action "start QEMU for" "$MACHINE" || ca_rc=$?
    case "$ca_rc" in
        0) ;;
        2) warn "QEMU start cancelled by user."; exit 2 ;;
        *) exit 1 ;;
    esac
    echo ""
    info "QEMU start confirmed for machine '$MACHINE'."

    # ── Emergency escape window ──
    warn "Launching QEMU in 3 seconds..."
    echo ""
    for _i in 3 2 1; do
        echo -e "  ${_i}..."
        sleep 1
    done

    verbose "Command: setsid ${QEMU_CMD[*]}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would run: setsid ${QEMU_CMD[*]}"
        exit 0
    fi

    # ── Execute launch (Shape 2 half 2: setsid + PID write + BMC wait + summary) ──
    qemu_execute_launch
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
            error "No interactive terminal. Specify machine: ob stop-qemu <machine>"
            error "Or use --all: ob stop-qemu --all"
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

    # ── Stop each target ──
    for target_machine in "${targets[@]}"; do
        MACHINE="$target_machine"

        echo ""
        if ! qemu_instance_load "$MACHINE"; then
            info "No PID file for '$MACHINE' — not running."
            continue
        fi

        # || pid_status=$? 保留 0/1/2 区分(DRY_RUN case + exited/recycled 分支)且 set -e 安全
        # (裸调 + $? 读在 set -euo 下死实例 return 1/2 会 abort — 既有债, 此处照 cmd_deploy_to_qemu:733 修)
        local pid_status=0
        qemu_instance_is_alive "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE" || pid_status=$?

        if [[ "$DRY_RUN" -eq 1 ]]; then
            case "$pid_status" in
                0) info "[DRY-RUN] Would stop QEMU for '$MACHINE' (PID $PIDFILE_PID)" ;;
                1) info "[DRY-RUN] Would clean stale PID file for '$MACHINE' (process exited)" ;;
                2) info "[DRY-RUN] Would clean stale PID file for '$MACHINE' (PID recycled)" ;;
            esac
            continue
        fi

        if [[ $pid_status -eq 1 ]]; then
            info "QEMU process for '$MACHINE' (PID $PIDFILE_PID) has already exited."
            qemu_instance_clean_stale "$MACHINE"
            continue
        fi

        if [[ $pid_status -eq 2 ]]; then
            warn "PID $PIDFILE_PID no longer belongs to QEMU (recycled). Cleaning stale PID file."
            qemu_instance_clean_stale "$MACHINE"
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
    done
}

cmd_deploy_to_qemu() {
    detect_harness_root

    # ── Resolve machine(经 resolve_command_machine: given verify / empty·nontty·ok, ADR-0019) ──
    local _rc=0
    resolve_command_machine machine_state_initialized_machines "Deploy to QEMU" stdout "No interactive terminal. Specify machine: ob deploy-to-qemu <machine>" || _rc=$?
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

    # ── 探测 QEMU 在跑 + 预读旧端口(必须在 stop 前, 约束 2) ──
    local qemu_running=0
    local old_ssh_port="" old_redfish_port="" old_ipmi_port="" old_http_port=""
    if qemu_instance_load "$MACHINE"; then
        # if 包裹 is_alive 防御 set -e(计划伪代码裸调 + $? 在 ob 直接 set -e 下 return 1 会中止)
        if qemu_instance_is_alive "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE"; then
            qemu_running=1
            old_ssh_port="$PIDFILE_SSH_PORT"
            old_redfish_port="$PIDFILE_REDFISH_PORT"
            old_ipmi_port="$PIDFILE_IPMI_PORT"
            old_http_port="$PIDFILE_HTTP_PORT"
        else
            qemu_instance_clean_stale "$MACHINE"
        fi
    fi

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

    # ── Step 2: stop 旧 QEMU(若在跑) + 端口复用注入(约束 2) ──
    if [[ $qemu_running -eq 1 ]]; then
        echo ""
        warn "Stopping old QEMU (PID $PIDFILE_PID)..."
        qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
        info "Old QEMU stopped."
        QEMU_SSH_PORT="$old_ssh_port"
        QEMU_REDFISH_PORT="$old_redfish_port"
        QEMU_IPMI_PORT="$old_ipmi_port"
        [[ -n "$old_http_port" && "$old_http_port" != "none" ]] && QEMU_HTTP_PORT="$old_http_port"
    fi

    # ── Step 3: start 新 QEMU(端口复用) + 恢复引导(约束 5/6) ──
    echo ""
    step_header "Starting new QEMU for '$MACHINE'"
    info "If start fails, image is already rebuilt — recover manually: ob start-qemu $MACHINE"

    qemu_prepare_launch "$MACHINE" "$image_file"
    echo "  Machine   : $QEMU_LAUNCH_MACHINE_NAME"
    echo "  SoC       : $QEMU_LAUNCH_SOC_TYPE"
    echo "  Binary    : $QEMU_BIN_FILE"
    echo "  Image     : $image_file"
    echo "  Serial log: $QEMU_LAUNCH_SERIAL_LOG"
    echo ""

    qemu_execute_launch        # setsid + PID 写 + BMC-ready 等待(超时仅 warn 不中止) + hostkey + summary
    # 到此返回 0(QEMU 启动即成功, 约束 5); setsid 失败时 execute_launch 自己退出 1
}
