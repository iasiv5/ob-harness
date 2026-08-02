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

# ════════════════════════════════════════════════════════════════════════════
# ob verify — QEMU-backed BMC smoke 自动化(bring-up + 确定性断言 + 总清)。术语见 CONTEXT.md ob verify.
# 形态对照 cmd_start_qemu: 同样做 image-ready machine 解析(guard + 选号, image-ready 集合)+
#   init-done/image 前置; 区别在 bring-up 走子进程 `ob start-qemu --force --no-wait`(完整复用既有机器,
#   不重发明 QEMU bring-up), 断言走 leaf-pure 判函数(lib/verify_assertions.sh), 总清走 EXIT trap。
# ════════════════════════════════════════════════════════════════════════════

# _verify_tcp_probe <port> — bash /dev/tcp 探 TCP 端口可连(sshpass-independent, timeout 3s)。
# return 0=可连 / 非0=拒绝或超时。cmd_verify 私有(exit-seam 内, 有 I/O 副作用, 不 exit)。
_verify_tcp_probe() {
    local port="$1"
    timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null
}

# _verify_probe_redfish <port> — set _VF_REDFISH_CODE/_VF_REDFISH_BODY。curl 取 Redfish 根。
# curl 整体失败(连接拒绝)→ code 留 "000", body 空。不 exit; set -e-safe(|| rc=$?)。
_verify_probe_redfish() {
    local port="$1"
    _VF_REDFISH_CODE="000"; _VF_REDFISH_BODY=""
    local out="" rc=0
    out=$(curl -sk -u root:0penBmc -w $'\n__OB_HTTP__%{http_code}' \
          "https://localhost:$port/redfish/v1" 2>/dev/null) || rc=$?
    if [[ -n "$out" ]]; then
        _VF_REDFISH_CODE="${out##*$'\n'}"        # 末行 = __OB_HTTP__<code>
        _VF_REDFISH_CODE="${_VF_REDFISH_CODE#__OB_HTTP__}"
        _VF_REDFISH_BODY="${out%$'\n'*}"          # 去末行 = body
    fi
    # curl 整体失败 → 维持 "000"(judge 据此判 fail)
    return 0
}

# _verify_probe_ipmi <port> — set _VF_IPMI_RC/_VF_IPMI_OUT。一条 ipmitool mc info。
_verify_probe_ipmi() {
    local port="$1"
    _VF_IPMI_RC=0; _VF_IPMI_OUT=""
    _VF_IPMI_OUT=$(ipmitool -I lanplus -H localhost -p "$port" -U root -P 0penBmc mc info 2>&1) || _VF_IPMI_RC=$?
    return 0
}

# _verify_probe_ssh_tcp <port> — set _VF_SSH_RC。TCP 探 SSH 转发端口。
_verify_probe_ssh_tcp() {
    local port="$1"
    _VF_SSH_RC=0
    _verify_tcp_probe "$port" || _VF_SSH_RC=$?
    return 0
}

# _verify_wait_ssh_tcp <port> — BMC 启动就绪门(sshpass-independent)。有界轮询 TCP 端口可连。
# 不中止 verify: 超时只 warn, 让断言自己判 deterministic pass/fail(端口未就绪 → system-ready 断言 fail)。
_verify_wait_ssh_tcp() {
    local port="$1"
    local attempts=0
    local max_attempts="${OB_VERIFY_READY_ATTEMPTS:-30}"
    info "Waiting for BMC SSH port $port to accept connections (up to $((max_attempts*5))s)..."
    while [[ $attempts -lt $max_attempts ]]; do
        attempts=$((attempts + 1))
        if _verify_tcp_probe "$port"; then
            info "BMC SSH port $port connectable after attempt $attempts (~$((attempts*5))s)"
            return 0
        fi
        printf "\r  Waiting... attempt %d/%d" "$attempts" "$max_attempts"
        sleep 5
    done
    echo ""
    warn "BMC SSH port $port not connectable within $((max_attempts*5))s; running assertions anyway."
    return 1
}

# _verify_cleanup <machine> — EXIT trap 总清: best-effort stop-qemu --force, 恒不失败(掩码 exit code)。
# 设计为 trap 回调: 即使 verify 中途 exit 1(断言失败/setsid 失败)也触发, 不留 QEMU。
_verify_cleanup() {
    local m="${1:-}"
    [[ -n "$m" ]] || return 0
    "$OB_ENTRY_DIR/ob" stop-qemu "$m" --force >/dev/null 2>&1 || true
}

cmd_verify() {
    detect_harness_root

    # ── Resolve machine(经 machine_selection_guard: image-ready 集合, 同 cmd_start_qemu) ──
    if [[ -z "$MACHINE" ]]; then
        local _msg=""
        machine_selection_guard machine_state_firmware_image_ready_machines _msg
        case "$_msg" in
            empty)
                # image-ready 空 → 再查 initialized 区分 remedy(同 cmd_start_qemu empty 分支)。
                if [[ -n "$(machine_state_initialized_machines)" ]]; then
                    error "No firmware-image-ready machines found."
                    error "Run 'ob build <machine>' first."
                else
                    error "No initialized machines found."
                    error "Run 'ob init <machine>' first."
                fi
                exit 3 ;;
            nontty)
                error "No interactive terminal. Specify machine: ob verify <machine>"
                exit 3 ;;
            ok) ;;
        esac
        echo ""
        step_header "Select Machine"
        local pm_rc=0
        pick_machine machine_state_firmware_image_ready_machines "Verify" || pm_rc=$?
        case "$pm_rc" in
            0) ;;
            2) warn "Verify cancelled by user."; exit 2 ;;
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

    # ── Prerequisite 2: image file(同 cmd_start_qemu) ──
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

    # ── 总清 trap: 在启动 QEMU 之前装, 成功/失败两条路径都总清 verify 自己起的实例 ──
    # 注: trap 在前置检查之后装 → 前置缺失(exit 3, 未起 QEMU)不触发无谓的 stop-qemu 子进程。
    local _verify_machine="$MACHINE"
    # shellcheck disable=SC2064  # 单引号延迟展开到 trap 触发时(_verify_machine 此时已定格)
    trap '_verify_cleanup "$_verify_machine"' EXIT

    # ── Step 1: bring up QEMU via 既有 bring-up 原语(qemu_prepare_launch + qemu_execute_launch) ──
    # 形态对照 cmd_deploy_to_qemu: 直接调底层 module 复用既有 QEMU bring-up 机器, 不 shell out、不经
    # cmd_start_qemu 的交互 confirm(verify 是显式 smoke 命令, 自身拥有 QEMU 生命周期, 不需二次 confirm)。
    info "Bringing up QEMU for verify (will be torn down on exit)"
    derive_qemu_paths

    # 既有实例冲突(F1 invariant: 须在 qemu_prepare_launch 的 check_ports 之前)—— verify 拥有自身 QEMU
    # 生命周期, 同 machine 既有实例须先让路。--force 静默杀; TTY 弹 banner; 非 TTY 非 --force → exit 1。
    if qemu_instance_load "$MACHINE"; then
        if qemu_instance_is_alive "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE"; then
            if [[ "$QEMU_FORCE" -eq 1 ]]; then
                warn "Killing existing QEMU instance for '$MACHINE' (PID $PIDFILE_PID) — verify manages its own lifecycle."
                qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
            elif [[ -t 0 ]]; then
                echo ""
                warn "QEMU instance already running for '$MACHINE':"
                qemu_instance_summarize_full
                echo ""
                print_confirm_banner "kill and restart QEMU for verify on" "$MACHINE"
                local answer
                if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Kill and restart? [y/N]: ")" answer; then
                    exit 1
                fi
                [[ "$answer" == [yY] ]] || { info "Aborted."; exit 2; }
                qemu_instance_stop "$PIDFILE_PID" "$QEMU_PID_FILE"
            else
                error "QEMU instance already running for '$MACHINE' (PID $PIDFILE_PID)."
                error "Use --force to let verify kill and restart it, or 'ob stop-qemu $MACHINE' first."
                exit 1
            fi
        else
            qemu_instance_clean_stale "$MACHINE"
        fi
    fi

    # verify 自己做 sshpass-independent 就绪门(TCP 轮询 SSH 端口); 故 QEMU_NO_WAIT=1 跳过 execute_launch
    # 的 BMC-ready 轮询(该轮询依赖 sshpass; 缺 sshpass 时只 warn, 非确定性)。端口 override 经
    # QEMU_SSH_PORT/REDFISH_PORT/IPMI_PORT 全局 → qemu_prepare_launch 的 CLI>env>default 协商生效。
    QEMU_NO_WAIT=1
    qemu_prepare_launch "$MACHINE" "$image_file"

    echo ""
    step_header "Starting QEMU for verify ('$MACHINE')"
    echo "  Machine   : $QEMU_LAUNCH_MACHINE_NAME"
    echo "  SoC       : $QEMU_LAUNCH_SOC_TYPE"
    echo "  Binary    : $QEMU_BIN_FILE"
    echo "  Image     : $image_file"
    echo "  Serial log: $QEMU_LAUNCH_SERIAL_LOG"
    echo ""

    qemu_execute_launch        # setsid + PID 写 + hostkey + summary(BMC-wait 因 QEMU_NO_WAIT=1 跳过)

    # ── Step 2: 从实例 PID 文件读真实转发端口(不假设默认值, 命中真端口) ──
    if ! qemu_instance_load "$MACHINE"; then
        error "ob verify: no QEMU PID file for '$MACHINE' after bring-up (start incomplete)."
        exit 1
    fi
    local v_ssh="$PIDFILE_SSH_PORT"
    local v_redfish="$PIDFILE_REDFISH_PORT"
    local v_ipmi="$PIDFILE_IPMI_PORT"
    echo ""
    info "Verifying against forwarded ports: SSH $v_ssh / Redfish $v_redfish / IPMI $v_ipmi (UDP)"

    # ── Step 3: BMC 启动就绪门(sshpass-independent TCP 轮询 SSH 端口) ──
    _verify_wait_ssh_tcp "$v_ssh" || true

    # ── Step 4: 跑 3 类断言(probe → judge; judge 向 stdout 打 ✓/✗ 行 + return 0/1) ──
    echo ""
    step_header "Verify assertions for '$MACHINE'"
    local -i total=0 passed=0
    local -a failed_names=() failed_raws=()

    # 4a — Redfish 根可达
    total=$((total+1))
    _verify_probe_redfish "$v_redfish"
    local r1=0; verify_judge_redfish_root "$_VF_REDFISH_CODE" "$_VF_REDFISH_BODY" || r1=$?
    if [[ $r1 -eq 0 ]]; then passed=$((passed+1)); else
        failed_names+=("Redfish root reachable")
        failed_raws+=("interface: Redfish @ https://localhost:$v_redfish/redfish/v1"$'\n'"HTTP code: $_VF_REDFISH_CODE"$'\n'"RAW body:"$'\n'"$_VF_REDFISH_BODY")
    fi

    # 4b — IPMI over LAN
    total=$((total+1))
    _verify_probe_ipmi "$v_ipmi"
    local r2=0; verify_judge_ipmi_lan "$_VF_IPMI_RC" "$_VF_IPMI_OUT" || r2=$?
    if [[ $r2 -eq 0 ]]; then passed=$((passed+1)); else
        failed_names+=("IPMI over LAN works")
        failed_raws+=("interface: IPMI @ localhost:$v_ipmi/UDP (ipmitool mc info)"$'\n'"ipmitool return code: $_VF_IPMI_RC"$'\n'"RAW output:"$'\n'"$_VF_IPMI_OUT")
    fi

    # 4c — System ready signal(SSH 端口 TCP 可连)
    total=$((total+1))
    _verify_probe_ssh_tcp "$v_ssh"
    local r3=0; verify_judge_system_ready "$_VF_SSH_RC" || r3=$?
    if [[ $r3 -eq 0 ]]; then passed=$((passed+1)); else
        failed_names+=("System ready signal (SSH port TCP-connectable)")
        failed_raws+=("interface: SSH TCP @ localhost:$v_ssh"$'\n'"tcp connect rc: $_VF_SSH_RC"$'\n'"(port not accepting connections — BMC sshd may still be booting)")
    fi

    # ── Step 5: 汇总 + 失败定位输出 ──
    echo ""
    if [[ $passed -eq $total ]]; then
        echo -e "${GREEN}Verify summary: $passed/$total assertions passed${NC}"
    else
        echo -e "${RED}Verify summary: $passed/$total assertions passed${NC}"
        echo ""
        error "Failed assertions (${#failed_names[@]}):"
        local i
        for (( i=0; i<${#failed_names[@]}; i++ )); do
            echo -e "  ${RED}✗ ${failed_names[$i]}${NC}"
            echo    "----- RAW response (for localization) -----"
            echo    "${failed_raws[$i]}"
            echo    "-------------------------------------------"
        done
        echo ""
        error "ob verify: smoke assertions failed for '$MACHINE' (see RAW responses above)."
        exit 1                       # 触发 EXIT trap 总清
    fi

    info "ob verify: all smoke assertions passed for '$MACHINE'."
    # 正常 return 0 → main return → 脚本 exit 0 → EXIT trap 总清
}
