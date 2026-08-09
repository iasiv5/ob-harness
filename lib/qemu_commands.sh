#!/usr/bin/env bash
# lib/qemu_commands.sh — QEMU 命令簇 L1 编排(cmd_start_qemu/cmd_stop_qemu/cmd_deploy_to_qemu/cmd_smoke). 术语见 CONTEXT.md function semantic layer / exit-code 契约 / ob deploy-to-qemu / QEMU instance.
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
                # ── Port reuse (restart 语义): 沿用旧实例端口, 经 leaf-pure module 统一 cli_first
                # (ADR-0022; X-α -z guard 保 CLI flag 优先。deploy 同款, 不再不对称)。
                resolve_qemu_port_reuse "$PIDFILE_SSH_PORT" "$PIDFILE_REDFISH_PORT" "$PIDFILE_IPMI_PORT" "$PIDFILE_HTTP_PORT"
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

    # ── Safety confirmation（仅交互 TTY）──
    # 非 TTY(CI/agent) 跳过确认直接起, 对齐 CONTEXT confirmation banner「正常起 QEMU
    # 一律跳过、无需 --force」—— 起新 QEMU 非路径风险; banner 只留给 kill 既有实例
    # (上方 conflict 块, 非 TTY 需 --force)。使 `start-qemu → smoke → stop-qemu` 在 CI 非交互跑通。
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
        resolve_qemu_port_reuse "$old_ssh_port" "$old_redfish_port" "$old_ipmi_port" "$old_http_port"
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
# ob smoke — probe-only smoke prober (OOB smoke)。术语见 CONTEXT.md QEMU instance / exit-code 契约.
# 形态对照 cmd_start_qemu/cmd_deploy_to_qemu: smoke 不拥有 QEMU 生命周期——不 bring-up
#   (不调 qemu_prepare_launch/qemu_execute_launch)、不 teardown、无 EXIT trap。它探针一个 RUNNING
#   instance(由 ob start-qemu 起好), 读 PID 文件的真实转发端口(更深接口, 反映实际跑的实例),
#   跑 Redfish(root/Managers/SoftwareVersion)/IPMI/system-ready 五条断言(α: 纯 truth-reporter, 零 per-machine 期望画像/baseline)。
# 断言判函数 leaf-pure(lib/smoke_assertions.sh); probe 采集经 nameref outvars(非 module 全局,
#   对照 resolve_command_machine 的 nameref 范式, 使 probe 可被 protocol 层直接单测)。
# ════════════════════════════════════════════════════════════════════════════

# _smoke_tcp_probe <port> — bash /dev/tcp 探 TCP 端口可连(sshpass-independent, timeout 3s)。
# return 0=可连 / 非0=拒绝或超时。cmd_smoke 私有(exit-seam 内, 有 I/O 副作用, 不 exit)。
_smoke_tcp_probe() {
    local port="$1"
    timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null
}

# _smoke_wait_ssh_tcp <port> — BMC 就绪门(sshpass-independent, smoke 自有)。有界轮询 TCP 端口可连。
# 不中止 smoke: 超时只 warn, 让断言自己判 deterministic pass/fail(端口未就绪 → system-ready 断言 fail)。
# 理由: start-qemu 的 BMC-ready 等待是 sshpass-dependent 且 warn-only, smoke 必须自己 gate 探针时机。
_smoke_wait_ssh_tcp() {
    local port="$1"
    local attempts=0
    local max_attempts="${OB_SMOKE_READY_ATTEMPTS:-30}"
    info "Waiting for BMC SSH port $port to accept connections (up to $((max_attempts*5))s)..."
    while [[ $attempts -lt $max_attempts ]]; do
        attempts=$((attempts + 1))
        if _smoke_tcp_probe "$port"; then
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

# _smoke_probe_redfish <port> <code_ref> <body_ref> — curl 取 Redfish 根, 经 nameref 回填 code/body。
# nameref 回填(非 _VF_* 全局), protocol 可测(对照 resolve_command_machine nameref 范式)。
# curl 整体失败(连接拒绝)→ code 留 "000", body 空。不 exit; set -e-safe(|| rc=$?)。
_smoke_probe_redfish() {
    local port="$1"
    local -n _spr_code="$2"
    local -n _spr_body="$3"
    _spr_code="000"; _spr_body=""
    local out="" rc=0
    out=$(curl -sk -u root:0penBmc -w $'\n__OB_HTTP__%{http_code}' \
          "https://localhost:$port/redfish/v1" 2>/dev/null) || rc=$?
    if [[ -n "$out" ]]; then
        _spr_code="${out##*$'\n'}"        # 末行 = __OB_HTTP__<code>
        _spr_code="${_spr_code#__OB_HTTP__}"
        _spr_body="${out%$'\n'*}"          # 去末行 = body
    fi
    # curl 整体失败 → 维持 "000"(judge 据此判 fail)
    return 0
}

# _smoke_probe_redfish_managers <port> <code_ref> <body_ref> — curl 取 Redfish Managers/bmc
# (OpenBMC 标准 manager id, 全 image 通用, 非 per-machine 知识), 经 nameref 回填 code/body。
# 形态对照 _smoke_probe_redfish; 一次 probe 喂 managers + swversion 两个 judge(深一层接口)。
# curl 整体失败(连接拒绝)→ code "000", body 空。不 exit; set -e-safe(|| rc=$?)。
_smoke_probe_redfish_managers() {
    local port="$1"
    local -n _sprm_code="$2"
    local -n _sprm_body="$3"
    _sprm_code="000"; _sprm_body=""
    local out="" rc=0
    out=$(curl -sk -u root:0penBmc -w $'\n__OB_HTTP__%{http_code}' \
          "https://localhost:$port/redfish/v1/Managers/bmc" 2>/dev/null) || rc=$?
    if [[ -n "$out" ]]; then
        _sprm_code="${out##*$'\n'}"        # 末行 = __OB_HTTP__<code>
        _sprm_code="${_sprm_code#__OB_HTTP__}"
        _sprm_body="${out%$'\n'*}"          # 去末行 = body
    fi
    # curl 整体失败 → 维持 "000"(judge 据此判 fail)
    return 0
}

# _smoke_probe_ipmi <port> <rc_ref> <out_ref> — 一条 ipmitool mc info, 经 nameref 回填 rc/out。
_smoke_probe_ipmi() {
    local port="$1"
    local -n _spi_rc="$2"
    local -n _spi_out="$3"
    _spi_rc=0; _spi_out=""
    _spi_out=$(ipmitool -I lanplus -H localhost -p "$port" -U root -P 0penBmc mc info 2>&1) || _spi_rc=$?
    return 0
}

# _smoke_probe_ssh_tcp <port> <rc_ref> — TCP 探 SSH 转发端口, 经 nameref 回填 rc。
_smoke_probe_ssh_tcp() {
    local port="$1"
    local -n _sps_rc="$2"
    _sps_rc=0
    _smoke_tcp_probe "$port" || _sps_rc=$?
    return 0
}

# _smoke_render_verdict <total> <passed> <failed_names_ref> <failed_raws_ref> <machine>
#   cmd_smoke 私有 verdict 渲染(leaf-pure 风格: 不 exit, return 0=all-pass / 1=any-fail;
#   exit 收口留 cmd_smoke)。消费 total/passed + failed_names[]/failed_raws[](nameref 只读),
#   打 summary 行 + 失败 breakdown(✗ + RAW) + α-banner(>&2)。
#   前置(lockstep): total/passed/failed_names 由 cmd_smoke 维护——每次 fail 同时 total++ 与
#   failed_names+=, 故 ${#failed_names[@]} == total-passed(本函数不另做 mismatch 校验)。
_smoke_render_verdict() {
    local total="$1" passed="$2"
    local -n _srv_fn="$3"     # failed_names (只读消费)
    local -n _srv_fr="$4"     # failed_raws (只读消费)
    local machine="$5"
    echo ""
    if [[ "$passed" -eq "$total" ]]; then
        echo -e "${GREEN}Smoke summary: $passed/$total assertions passed${NC}"
        info "ob smoke: all smoke assertions passed for '$machine'."
        return 0
    fi
    echo -e "${RED}Smoke summary: $passed/$total assertions passed${NC}"
    echo ""
    error "Failed assertions (${#_srv_fn[@]}):"
    local i
    for (( i=0; i<${#_srv_fn[@]}; i++ )); do
        echo -e "  ${RED}✗ ${_srv_fn[$i]}${NC}"
        echo    "----- RAW response (for localization) -----"
        echo    "${_srv_fr[$i]}"
        echo    "-------------------------------------------"
    done
    echo ""
    error "ob smoke: smoke assertions failed for '$machine' (see ✗ rows + RAW responses above)."
    # α 重申: exit 1 当下向 stderr 喂一行 α 语义, 防 caller 据全局 "1 = broken" 误判 smoke 坏。
    # warn 默认走 stdout, 显式 >&2 落 stderr(不污染 stdout 真相报告)。
    warn "exit 1 here is the α truth-reporter contract: the ✗ rows above report the BMC interface's ACTUAL state, NOT a smoke command failure — read the ✗ rows to see which interface and why (debug the BMC interface, not smoke)." >&2
    return 1
}

cmd_smoke() {
    detect_harness_root

    # ── 前置 1: machine arg 必填(probe-only 命令不做交互选号——scope 裁剪; 但列出可 smoke 的对象) ──
    # smoke 的合法对象 = running QEMU 实例(非 initialized machines, 见前置 2), 故列 qemu_instance_list,
    # 不引向 ob status(那是 build 的 initialized-machine 语义, 会把用户引向未启动的 machine)。
    # 缺参数仍 exit 3(precondition missing, exit 契约不变)。
    if [[ -z "$MACHINE" ]]; then
        error "No machine specified."
        local -a _smoke_targets=()
        mapfile -t _smoke_targets < <(qemu_instance_list)
        if [[ ${#_smoke_targets[@]} -eq 0 ]]; then
            error "No QEMU instance is running. smoke probes a running instance — run 'ob start-qemu <machine>' first."
        else
            error "Running QEMU instances you can smoke:"
            local _t
            for _t in "${_smoke_targets[@]}"; do
                printf '  %-20s %s\n' "$_t" "$(qemu_instance_summarize_brief "$_t")" >&2
            done
        fi
        error "Specify a machine: ob smoke <machine>"
        exit 3
    fi

    # ── 前置 2: RUNNING QEMU instance(smoke 不 bring-up, 只探活实例——绝不探死端口, 防假"BMC 坏") ──
    derive_qemu_paths
    if ! qemu_instance_load "$MACHINE"; then
        error "No QEMU instance running for '$MACHINE' (no PID file)."
        error "Run 'ob start-qemu $MACHINE' first."
        exit 3
    fi
    # if 包裹 is_alive: 0=running/1=exited/2=recycled 多态返回在 set -euo 下裸调会 abort(同 cmd_start_qemu 注)。
    # NOT alive → clean stale PID + exit 3 + 同 remedy(stale 也是"没在跑", 让 caller 先 start-qemu)。
    if ! qemu_instance_is_alive "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE"; then
        qemu_instance_clean_stale "$MACHINE"
        error "QEMU instance for '$MACHINE' is not running (stale PID file cleaned)."
        error "Run 'ob start-qemu $MACHINE' first."
        exit 3
    fi

    # ── 从实例 PID 文件读真实转发端口(不假设默认值, 命中真端口; smoke 不接受 port override) ──
    local s_ssh="$PIDFILE_SSH_PORT"
    local s_redfish="$PIDFILE_REDFISH_PORT"
    local s_ipmi="$PIDFILE_IPMI_PORT"
    echo ""
    info "Smoke-probing forwarded ports: SSH $s_ssh / Redfish $s_redfish / IPMI $s_ipmi (UDP)"

    # ── BMC 就绪门(sshpass-independent TCP 轮询 SSH 端口; smoke own, 不依赖 start-qemu 的 sshpass 门) ──
    _smoke_wait_ssh_tcp "$s_ssh" || true

    # ── 跑 5 条断言(probe → judge; judge 向 stdout 打 ✓/✗ 行 + return 0/1) ──
    # Redfish(root + Managers + SoftwareVersion)/ IPMI / system-ready; Managers probe 喂后两条 Redfish judge。
    echo ""
    step_header "Smoke assertions for '$MACHINE'"
    local -i total=0 passed=0
    local -a failed_names=() failed_raws=()
    # probe outvars(经 nameref 回填; 名字与 probe 内 nameref local 不撞, 防 bash 循环引用告警)
    local p_redfish_code="" p_redfish_body=""
    local p_mgr_code="" p_mgr_body=""
    local p_ipmi_rc="" p_ipmi_out=""
    local p_ssh_rc=""

    # Redfish 根可达
    total=$((total+1))
    _smoke_probe_redfish "$s_redfish" p_redfish_code p_redfish_body
    local r1=0; smoke_judge_redfish_root "$p_redfish_code" "$p_redfish_body" || r1=$?
    if [[ $r1 -eq 0 ]]; then passed=$((passed+1)); else
        failed_names+=("Redfish root reachable")
        failed_raws+=("interface: Redfish @ https://localhost:$s_redfish/redfish/v1"$'\n'"HTTP code: $p_redfish_code"$'\n'"RAW body:"$'\n'"$p_redfish_body")
    fi

    # Redfish Managers 可达(深一层接口: Managers/bmc 资源; 一次 probe 喂 managers + swversion 两 judge)
    total=$((total+1))
    _smoke_probe_redfish_managers "$s_redfish" p_mgr_code p_mgr_body
    local r4=0; smoke_judge_redfish_managers "$p_mgr_code" "$p_mgr_body" || r4=$?
    if [[ $r4 -eq 0 ]]; then passed=$((passed+1)); else
        failed_names+=("Redfish Managers reachable")
        failed_raws+=("interface: Redfish @ https://localhost:$s_redfish/redfish/v1/Managers/bmc"$'\n'"HTTP code: $p_mgr_code"$'\n'"RAW body:"$'\n'"$p_mgr_body")
    fi

    # Redfish SoftwareVersion(BMC 上报固件版本 — 功能态断言; 复用 managers probe body)
    total=$((total+1))
    local r5=0; smoke_judge_redfish_swversion "$p_mgr_body" || r5=$?
    if [[ $r5 -eq 0 ]]; then passed=$((passed+1)); else
        failed_names+=("Redfish SoftwareVersion reported")
        failed_raws+=("interface: Redfish Managers body @ https://localhost:$s_redfish/redfish/v1/Managers/bmc"$'\n'"RAW body:"$'\n'"$p_mgr_body")
    fi

    # IPMI over LAN
    total=$((total+1))
    _smoke_probe_ipmi "$s_ipmi" p_ipmi_rc p_ipmi_out
    local r2=0; smoke_judge_ipmi_lan "$p_ipmi_rc" "$p_ipmi_out" || r2=$?
    if [[ $r2 -eq 0 ]]; then
        passed=$((passed+1))
    else
        failed_names+=("IPMI over LAN works")
        local _ipmi_raw="interface: IPMI @ localhost:$s_ipmi/UDP (ipmitool mc info)"$'\n'"ipmitool return code: $p_ipmi_rc"$'\n'"RAW output:"$'\n'"$p_ipmi_out"
        # Generic (non per-machine) diagnostic: a non-zero ipmitool rc on a reachable
        # Redfish BMC most often means the image itself lacks an RMCP+/LAN responder.
        # Phrased as generic Redfish/IPMI protocol knowledge (not naming any machine).
        if [[ "$p_ipmi_rc" != "0" ]]; then
            _ipmi_raw+=$'\n'"possible cause: image may lack an RMCP+/LAN responder (phosphor-ipmi-netbridged not installed/enabled) — image-side, not a smoke defect; Redfish remains the canonical probe."
        fi
        failed_raws+=("$_ipmi_raw")
    fi

    # System ready signal(SSH 端口 TCP 可连)
    total=$((total+1))
    _smoke_probe_ssh_tcp "$s_ssh" p_ssh_rc
    local r3=0; smoke_judge_system_ready "$p_ssh_rc" || r3=$?
    if [[ $r3 -eq 0 ]]; then passed=$((passed+1)); else
        failed_names+=("System ready signal (SSH port TCP-connectable)")
        failed_raws+=("interface: SSH TCP @ localhost:$s_ssh"$'\n'"tcp connect rc: $p_ssh_rc"$'\n'"(port not accepting connections — BMC sshd may still be booting)")
    fi

    # ── α verdict: 渲染经 _smoke_render_verdict(leaf-pure 风格, return 0/1); exit 收口留本 cmd_smoke ──
    # 无 --allow-fail / 无 per-machine expected-profile / 无 baseline: 回归检测是 caller 的事(零 per-machine 知识)。
    local _vrc=0
    _smoke_render_verdict "$total" "$passed" failed_names failed_raws "$MACHINE" || _vrc=$?
    case "$_vrc" in
        0) return 0 ;;            # smoke 不拥有 QEMU → 不 teardown, 直接 return
        *) exit 1 ;;              # smoke 不拥有 QEMU → 无 EXIT trap, 直接 exit 1
    esac
}
