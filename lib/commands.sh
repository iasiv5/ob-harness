#!/usr/bin/env bash
# lib/commands.sh — cmd_* 命令编排(status/init/build/start-qemu/stop-qemu/menu). 术语见 CONTEXT.md function semantic layer / exit-code 契约.
# Exit: exit seam（L1 cmd_* 顶层编排, 使用 exit-code 契约值 0/1/2/3）.


status_section_main_repo() {
    step_header "OpenBMC Main Repository"

    if [[ ! -d "$OPENBMC_DIR/.git" ]]; then
        echo "  Status       : missing"
        return 0
    fi

    # Source (origin URL + label)
    local origin_url=""
    local source_label=""
    origin_url=$(git -C "$OPENBMC_DIR" remote get-url origin 2>/dev/null || true)
    if [[ -f "$SOURCE_MANIFEST_FILE" ]]; then
        source_label=$(read_manifest_field source_label 2>/dev/null || true)
    fi
    local source_display="${origin_url:-<no origin>}${source_label:+ ($source_label)}"

    # Branch & commit
    local branch=""
    local commit_line=""
    branch=$(git -C "$OPENBMC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    commit_line=$(git -C "$OPENBMC_DIR" log --oneline -1 2>/dev/null || true)

    # Upstream comparison (network, best-effort)
    local upstream_display="⚠️ unreachable (skipped)"
    if timeout 10 git -C "$OPENBMC_DIR" fetch origin --quiet 2>/dev/null; then
        local ahead behind
        ahead=$(git -C "$OPENBMC_DIR" rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo "0")
        behind=$(git -C "$OPENBMC_DIR" rev-list --count "HEAD..origin/${branch}" 2>/dev/null || echo "0")
        if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
            upstream_display="✅ up-to-date"
        elif [[ "$behind" -gt 0 ]]; then
            upstream_display="⬇️  behind ${behind}${ahead:+, ⬆️  ahead ${ahead}}"
        else
            upstream_display="⬆️  ahead ${ahead}"
        fi
    fi

    # First init time
    local first_init=""
    if [[ -f "$SOURCE_MANIFEST_FILE" ]]; then
        local raw_time
        raw_time=$(read_manifest_field created_at 2>/dev/null || true)
        if [[ -n "$raw_time" ]]; then
            # Format ISO to readable: 2026-06-06T17:13:41Z → 2026-06-06 17:13 UTC
            first_init=$(format_timestamp "$raw_time")
        fi
    fi

    echo "  Status       : present"
    echo "  Source       : $source_display"
    echo "  Local path   : $OPENBMC_DIR"
    echo "  Branch       : ${branch:-<unknown>}"
    echo "  Commit       : ${commit_line:-<unknown>}"
    echo "  Upstream     : $upstream_display"
    echo "  First init   : ${first_init:-<unknown>}"
}

status_section_machines() {
    step_header "Machines"

    # --- Summary table ---
    # Collect per-machine data
    local -a machines=()
    local -A m_init=() m_repos=() m_firmware=() m_firmware_path=() m_firmware_mtime=() m_snapshot=() m_init_time=()
    local m

    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        local init_state snapshot_state repo_count firmware_image_path firmware_image_mtime raw_init_time
        init_state=$(machine_state_init_state "$m")
        snapshot_state=$(machine_state_snapshot_state "$m")
        repo_count=$(machine_state_repo_count "$m")
        raw_init_time=$(machine_state_init_time "$m")
        machines+=("$m")

        case "$init_state" in
            initialized) m_init["$m"]="✅ initialized" ;;
            partial) m_init["$m"]="⏳ partial" ;;
            *) m_init["$m"]="— uninitialized" ;;
        esac

        m_snapshot["$m"]="$snapshot_state"
        m_repos["$m"]="$repo_count"
        m_init_time["$m"]="$raw_init_time"

        if machine_state_is_firmware_image_ready "$m"; then
            firmware_image_path=$(machine_state_firmware_image_path "$m" 2>/dev/null || true)
            firmware_image_mtime=$(machine_state_firmware_image_mtime "$m")
            m_firmware["$m"]="📦 ready"
            m_firmware_path["$m"]="$firmware_image_path"
            m_firmware_mtime["$m"]="$firmware_image_mtime"
        else
            m_firmware["$m"]="— missing"
        fi
    done < <(machine_state_display_machines)

    if [[ ${#machines[@]} -eq 0 ]]; then
        echo "  (none)"
        return 0
    fi

    # Print summary table header
    printf "  %-22s %-15s %s\n" "Machine" "Init" "Firmware Image"
    for m in "${machines[@]}"; do
        local m_padded
        printf -v m_padded "%-22s" "$m"
        printf "  %b%-15s %s\n" "${YELLOW}${m_padded}${NC}" "${m_init[$m]}" "${m_firmware[$m]}"
    done

    # --- Per-machine expansion ---
    for m in "${machines[@]}"; do
        # Only expand machines that have a snapshot file (meaningful repo data)
        [[ "${m_snapshot[$m]}" == "present" ]] || continue

        echo ""
        echo "  ── $m ──────────────────────────────────────"

        # Init time
        local init_time=""
        if [[ -n "${m_init_time[$m]}" ]]; then
            init_time=$(format_timestamp "${m_init_time[$m]}")
        fi
        echo "    Init time    : ${init_time:--}"

        # Repos
        echo "    Repos        : ${m_repos[$m]}"

        # Firmware image details (only when ready)
        if [[ -n "${m_firmware_path[$m]:-}" ]]; then
            local firmware_time="-"
            if [[ -n "${m_firmware_mtime[$m]}" ]]; then
                firmware_time=$(format_timestamp "${m_firmware_mtime[$m]}")
            fi
            echo "    Firmware time: $firmware_time"
            echo "    Firmware name: $(basename "${m_firmware_path[$m]}")"
            echo "    Firmware path: $(dirname "${m_firmware_path[$m]}")/"
        fi
    done
}

status_section_diagnostics() {
    local -a orphan_machines=()
    local machine

    while IFS= read -r machine; do
        [[ -n "$machine" ]] && orphan_machines+=("$machine")
    done < <(machine_state_orphan_firmware_image_machines)

    if [[ ${#orphan_machines[@]} -eq 0 ]]; then
        return 0
    fi

    echo ""
    step_header "Diagnostics"
    echo "  Orphan firmware image artifacts"

    for machine in "${orphan_machines[@]}"; do
        local firmware_path
        firmware_path=$(machine_state_firmware_image_path "$machine" 2>/dev/null || true)
        echo ""
        echo "    $machine"
        echo "      Path      : ${firmware_path:-<unknown>}"
        echo "      Reason    : firmware image artifact exists, but machine init is incomplete"
        echo "      Next step : ob init $machine"
    done
}

status_section_tips() {
    local repo_exists="$1"
    local has_initialized_machine="$2"
    local has_initialized_without_firmware_image="$3"

    local tip=""

    if [[ "$repo_exists" -eq 0 ]]; then
        tip="💡 Run 'ob init' to get started."
    elif [[ "$has_initialized_machine" -eq 0 ]]; then
        tip="💡 Run 'ob init' to initialize a machine."
    elif [[ "$has_initialized_without_firmware_image" -eq 1 ]]; then
        tip="💡 Run 'ob build <machine>' to produce a firmware image."
    fi

    if [[ -n "$tip" ]]; then
        echo ""
        echo "  $tip"
    fi
}

# exit_on_user_cancel <rc> <verb>
# 消费 pick_machine / confirm_action 的 rc (0=ok / 2=cancel / 1=read-fail)。
# rc 0 → return 0 继续下行;rc 2 → warn "<verb> cancelled by user." + exit 2;
# 否则 exit 1(read-fail 的 error 已由 L3 调用方 pick_machine/confirm_action 打印)。
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

cmd_status() {
    local repo_exists=0
    [[ -d "$OPENBMC_DIR/.git" ]] && repo_exists=1

    # Section 1: Main repo info (always shown)
    status_section_main_repo

    echo ""

    # Section 2: Machine list + expansion (always shown, even if repo missing — may have residual data)
    status_section_machines

    # Section 3: Diagnostics for residual artifacts
    status_section_diagnostics

    # Section 4: Dynamic tips
    local has_initialized_machine=0
    local has_initialized_without_firmware_image=0
    local _ms_machine
    while IFS= read -r _ms_machine; do
        [[ -n "$_ms_machine" ]] || continue
        has_initialized_machine=1
        if ! machine_state_is_firmware_image_ready "$_ms_machine"; then
            has_initialized_without_firmware_image=1
        fi
    done < <(machine_state_initialized_machines)

    status_section_tips "$repo_exists" "$has_initialized_machine" "$has_initialized_without_firmware_image"

    # Section 5: QEMU instances (only shown when instances exist)
    local _pids_dir="$WORKSPACE_DIR/qemu-bin/.pids"
    local _has_qemu=0
    local -a _qemu_lines=()

    for _pf in "$_pids_dir"/*.pid; do
        [[ -f "$_pf" ]] || continue

        local _qm="" _qp="" _qbin="" _qstart="" _qsport="" _qrport="" _qiport=""
        _qm=$(basename "$_pf" .pid)

        # Read PID file fields
        _qp=$(read_kv_field "$_pf" pid) || _qp=""
        _qbin=$(read_kv_field "$_pf" binary) || _qbin=""
        _qstart=$(read_kv_field "$_pf" started_at) || _qstart=""
        _qsport=$(read_kv_field "$_pf" ssh_port) || _qsport=""
        _qrport=$(read_kv_field "$_pf" redfish_port) || _qrport=""
        _qiport=$(read_kv_field "$_pf" ipmi_port) || _qiport=""

        # Validate process is alive
        if [[ -n "$_qp" ]] && [[ -d "/proc/$_qp" ]]; then
            _has_qemu=1
            _qemu_lines+=("  $_qm   PID $_qp   SSH($_qsport) Redfish($_qrport) IPMI($_qiport/UDP)   ✅ running")
        else
            # Stale PID file — clean up silently
            rm -f "$_pf"
        fi
    done

    if [[ "$_has_qemu" -eq 1 ]]; then
        echo ""
        step_header "QEMU Instances"
        local _ql
        for _ql in "${_qemu_lines[@]}"; do
            echo "$_ql"
        done
    fi
}

cmd_build() {
    # === Prerequisites ===
    require_path "$OPENBMC_DIR/.git" "OpenBMC main repository" "Run 'ob init' first." 3

    require_path "$SOURCE_MANIFEST_FILE" "Source manifest" "Run 'ob init' first." 3

    local interactive_selection=0
    if [[ -n "$MACHINE" ]]; then
        if ! machine_state_is_initialized "$MACHINE"; then
            error "Machine '$MACHINE' is not initialized (no completed init-done marker - a previous init may have been interrupted)."
            error "Run 'ob init $MACHINE' first."
            exit 3
        fi

        BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
    else
        # === Discover initialized machines ===
        local -a machines=()
        local initialized_machine
        while IFS= read -r initialized_machine; do
            [[ -n "$initialized_machine" ]] || continue
            machines+=("$initialized_machine")
        done < <(machine_state_initialized_machines)

        if [[ ${#machines[@]} -eq 0 ]]; then
            step_header "Initialized Machines"
            echo ""
            echo "  (none)"
            echo ""
            error "No initialized machines found."
            error "Run 'ob init <machine>' first."
            exit 3
        fi

        # === Read main repo info（仓库信息块；machine 元数据看 ob status，选择表只列名字）===
        local manifest_origin_url manifest_source_label
        manifest_origin_url=$(read_manifest_field origin_url || echo "<unknown>")
        manifest_source_label=$(read_manifest_field source_label || echo "")

        step_header "OpenBMC Repository"
        echo "  Source : $manifest_origin_url${manifest_source_label:+ ($manifest_source_label)}"
        echo "  Path   : $OPENBMC_DIR"
        echo ""

        step_header "Initialized Machines"

        # === Interactive selection ===
        if [[ ! -t 0 ]]; then
            error "No machine specified and no interactive terminal. Run 'ob status' to list initialized machines."
            error "Specify a machine: ob build <machine>"
            exit 3
        fi

        local pm_rc=0
        pick_machine machine_state_initialized_machines "Build" || pm_rc=$?
        exit_on_user_cancel "$pm_rc" "Build"

        BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
        interactive_selection=1
    fi

    echo ""
    info "Selected: $MACHINE"
    info "Target  : obmc-phosphor-image"
    info "Estimated time: 1-4 hours depending on machine and cache state."
    echo ""

    if [[ "$interactive_selection" -eq 1 ]]; then
        local ca_rc=0
        confirm_action "build" "$MACHINE" || ca_rc=$?
        exit_on_user_cancel "$ca_rc" "Build"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would source setup $MACHINE $BUILD_DIR"
        info "[DRY-RUN] Would run: bitbake obmc-phosphor-image (machine=$MACHINE)"
        exit 0
    fi

    # === Re-enter bitbake environment ===
    build_env_enter "$MACHINE" "$BUILD_DIR" 2>/dev/null

    # === npm registry auto-detection ===
    resolve_npm_registry
    if [[ "$NPM_REGISTRY_RESOLVED" != "skip" ]]; then
        export npm_config_registry="$NPM_REGISTRY_RESOLVED"
        export npm_config_fetch_timeout=600000
        export npm_config_fetch_retry_maxtimeout=120000
        export npm_config_fetch_retry_mintimeout=30000
        export npm_config_fetch_retry_factor=2
        local _npm_vars="npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor"
        local _existing="${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
        BB_ENV_PASSTHROUGH_ADDITIONS="$_npm_vars"
        if [[ -n "$_existing" ]]; then
            BB_ENV_PASSTHROUGH_ADDITIONS="$_existing $BB_ENV_PASSTHROUGH_ADDITIONS"
        fi
        export BB_ENV_PASSTHROUGH_ADDITIONS
        verbose "Exported npm config for bitbake passthrough"
        verbose "  npm_config_registry=$npm_config_registry"
    fi

    # === Run bitbake ===
    echo ""
    step_header "Building $MACHINE"
    info "Running: bitbake obmc-phosphor-image"
    echo ""

    if bitbake obmc-phosphor-image; then
        echo ""
        step_header "Build Succeeded"

        local deploy_dir="$BUILD_DIR/tmp/deploy/images/$MACHINE"
        local image_file=""
        image_file=$(machine_state_firmware_image_path "$MACHINE" 2>/dev/null || true)

        echo "  Machine : $MACHINE"
        echo "  Image   : ${image_file:-<not found>}"
        if [[ -n "$image_file" && -f "$image_file" ]]; then
            local image_size
            image_size=$(python3 - "$image_file" <<'PY'
import os
import sys

size = os.path.getsize(sys.argv[1])
units = ["B", "KiB", "MiB", "GiB", "TiB"]
value = float(size)

for unit in units:
    if value < 1024.0 or unit == units[-1]:
        if unit == "B":
            print(f"{int(value)} {unit}")
        elif value >= 10:
            print(f"{value:.0f} {unit}")
        else:
            print(f"{value:.1f} {unit}")
        break
    value /= 1024.0
PY
)
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
        echo "    1. Re-run:         ob build  -- select same machine -- retry"
        echo "    2. Clean & retry:  cd $OPENBMC_DIR && source setup $MACHINE"
        echo "                       bitbake -c cleansstate <failed-recipe>"
        echo "    3. Full log:       $BUILD_DIR/tmp/log/cooker/$MACHINE/"
        echo ""
        exit 1
    fi
}

cmd_start_qemu() {
    detect_harness_root

    # ── Resolve machine ──
    if [[ -z "$MACHINE" ]]; then
        # Discover firmware-image-ready machines (init-done + firmware image artifact)
        local -a machines=()
        local _machine
        while IFS= read -r _machine; do
            [[ -n "$_machine" ]] && machines+=("$_machine")
        done < <(machine_state_firmware_image_ready_machines)

        if [[ ${#machines[@]} -eq 0 ]]; then
            local any_initdone=0
            if [[ -n "$(machine_state_initialized_machines)" ]]; then
                any_initdone=1
            fi

            if [[ "$any_initdone" -eq 1 ]]; then
                error "No firmware-image-ready machines found."
                error "Run 'ob build <machine>' first."
            else
                error "No initialized machines found."
                error "Run 'ob init <machine>' first."
            fi
            exit 3
        fi

        if [[ ! -t 0 ]]; then
            error "No interactive terminal. Specify machine: ob start-qemu <machine>"
            exit 3
        fi

        echo ""
        step_header "Select Machine"
        local pm_rc=0
        pick_machine machine_state_firmware_image_ready_machines "Start QEMU" || pm_rc=$?
        exit_on_user_cancel "$pm_rc" "Start QEMU"
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
    if read_pid_file; then
        local pid_status
        validate_pid "$PIDFILE_PID" "$PIDFILE_BINARY" "$MACHINE"
        pid_status=$?

        if [[ $pid_status -eq 0 ]]; then
            # Instance is running and valid
            if [[ "$QEMU_FORCE" -eq 1 ]]; then
                warn "Killing existing QEMU instance (PID $PIDFILE_PID)..."
                qemu_stop_instance "$PIDFILE_PID" "$QEMU_PID_FILE"
            elif [[ -t 0 ]]; then
                echo ""
                warn "QEMU instance already running for '$MACHINE':"
                qemu_instance_describe
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
                qemu_stop_instance "$PIDFILE_PID" "$QEMU_PID_FILE"
            else
                error "QEMU instance already running for '$MACHINE' (PID $PIDFILE_PID)."
                error "Use --force to kill and restart, or 'ob stop-qemu $MACHINE' first."
                exit 1
            fi
        else
            # Stale PID file — clean up
            rm -f "$QEMU_PID_FILE"
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
    exit_on_user_cancel "$ca_rc" "QEMU start"
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

# __stop_qemu_running_machines — 印当前 workspace 所有 QEMU 实例的 machine 名
# （源自 qemu-bin/.pids/*.pid，每行一个）。作 pick_machine 的 list-source（module 级可见）。
__stop_qemu_running_machines() {
    local pid_file
    for pid_file in "$WORKSPACE_DIR/qemu-bin/.pids/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        basename "$pid_file" .pid
    done
}

cmd_stop_qemu() {
    detect_harness_root

    # ── Collect target machines ──
    local -a targets=()

    if [[ "$QEMU_STOP_ALL" -eq 1 ]]; then
        # --all: stop every instance
        for pid_file in "$WORKSPACE_DIR/qemu-bin/.pids/"*.pid; do
            [[ -f "$pid_file" ]] || continue
            targets+=("$(basename "$pid_file" .pid)")
        done
    elif [[ -n "$MACHINE" ]]; then
        targets+=("$MACHINE")
    else
        # No machine specified: list running instances and let user choose
        local -a available=()
        mapfile -t available < <(__stop_qemu_running_machines)

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
        local pm_rc=0
        pick_machine __stop_qemu_running_machines "Stop QEMU" || pm_rc=$?
        exit_on_user_cancel "$pm_rc" "Stop QEMU"
        targets+=("$MACHINE")
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        info "No QEMU instances to stop."
        exit 0
    fi

    # ── Stop each target ──
    for target_machine in "${targets[@]}"; do
        MACHINE="$target_machine"
        QEMU_PID_FILE="$WORKSPACE_DIR/qemu-bin/.pids/$MACHINE.pid"

        echo ""
        if ! read_pid_file; then
            info "No PID file for '$MACHINE' — not running."
            continue
        fi

        local pid_status
        validate_pid "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE"
        pid_status=$?

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
            rm -f "$QEMU_PID_FILE"
            continue
        fi

        if [[ $pid_status -eq 2 ]]; then
            warn "PID $PIDFILE_PID no longer belongs to QEMU (recycled). Cleaning stale PID file."
            rm -f "$QEMU_PID_FILE"
            continue
        fi

        # Process is running — show info and confirm
        echo -e "Running QEMU instance for '${BOLD}$MACHINE${NC}':"
        qemu_instance_describe
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
        qemu_stop_instance "$PIDFILE_PID" "$QEMU_PID_FILE"
        info "QEMU instance for '$MACHINE' stopped."
    done
}

cmd_init() {
    # Step 1/8: 前置检查。
    prerequisites_check

    # Step 2/8: 准备主仓库并解析 machine。
    # 首次运行时 clone 主仓；重跑时做 source 校验并复用已有仓库。
    require_openbmc_repo || clone_openbmc

    # [OEM] Step 2 扩展动作：如当前主仓需要 vendor bootstrap，继续补齐其子目录。
    run_repo_init_script

    # 解析 machine（Step 2 的一部分，交互选择或确认命令行参数）。
    # 显式编排（空 guard + arg 快路径 + 非TTY + 展示 + pick_machine + confirm）。
    local -a _init_machines=()
    local _im
    while IFS= read -r _im; do
        [[ -n "$_im" ]] && _init_machines+=("$_im")
    done < <(list_available_machines)

    if [[ ${#_init_machines[@]} -eq 0 ]]; then
        error "No machines found in $OPENBMC_DIR."
        error "Check the OpenBMC main repository, or re-clone: cd $OPENBMC_DIR && git pull"
        exit 3
    fi

    if [[ -n "$MACHINE" ]] && printf '%s\n' "${_init_machines[@]}" | grep -qx -- "$MACHINE"; then
        print_available_machines
        print_previously_initialized _init_machines
        info "Machine '$MACHINE' confirmed."
    else
        if [[ -n "$MACHINE" ]]; then
            warn "Machine '$MACHINE' is not in the available list."
        else
            warn "No machine specified."
        fi

        if [[ ! -t 0 ]]; then
            error "No valid machine and no interactive terminal. Pass a valid machine: ob init <machine>"
            exit 3
        fi

        print_available_machines
        print_previously_initialized _init_machines

        local pm_rc=0
        pick_machine list_available_machines "init" || pm_rc=$?
        exit_on_user_cancel "$pm_rc" "init"

        local ca_rc=0
        confirm_action "init" "$MACHINE" || ca_rc=$?
        exit_on_user_cancel "$ca_rc" "init"
        echo ""
        info "Init confirmed for machine '$MACHINE'."
    fi

    # Re-derive paths (machine may have changed via interactive pick_machine)
    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
    SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"

    # Clear previous completion state before starting work (re-entering init flow).
    # This ensures ob build never sees stale state if init is interrupted.
    if ! machine_state_clear_init_progress "$MACHINE"; then
        error "Failed to clear machine state for '$MACHINE'."
        exit 1
    fi

    # --- Detect fresh run vs incremental re-run ---
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

    # Step 3/8: 初始化 bitbake。
    init_bitbake_env

    # Step 4/8: 生成依赖图。
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

    # Step 5/8: 拉取子仓库。
    clone_sub_repos

    # Step 6/8: 生成 machine snapshot。
    generate_machine_snapshot

    # Step 7/8: 生成构建缓存配置。
    generate_build_config

    # Step 8/8: 收尾，打印并落盘最终状态报告。
    print_report

    # Write init-done marker (all 8 steps completed successfully).
    # ob build uses this to discover buildable machines.
    if ! machine_state_mark_init_done "$MACHINE"; then
        error "Failed to write init-done marker: $(machine_state_init_done_path "$MACHINE")"
        exit 1
    fi
}

cmd_menu() {
    # Non-interactive terminal guard
    if [[ ! -t 0 ]]; then
        error "Non-interactive terminal detected. Use CLI mode: ./ob <command> [args]"
        exit 3
    fi

    local first_run=1

    # First entry: show logo (no clear — preserve user's terminal history)
    show_logo

    while true; do
        # Print menu header
        echo ""
        if [[ "$first_run" -eq 0 ]]; then
            show_brand_line
        fi

        echo "Please select a task:"
        echo "    1 - init        - Initialize OpenBMC development environment"
        echo "    2 - build       - Build OpenBMC firmware image"
        echo "    3 - status      - Show current OpenBMC workspace status"
        echo "    4 - start-qemu  - Launch QEMU with built BMC image"
        echo "    5 - stop-qemu   - Stop a running QEMU instance"
        echo "    C - Clear terminal screen  (c/C)"
        echo "    Q - Quit this 'ob' session (q/Q)"
        echo ""
        echo "Tip: CLI mode — ./ob init <machine> | ./ob build | ./ob start-qemu <machine> | ./ob --help"
        echo ""

        local choice
        read -r -p "$(echo -e "${PROMPT_PREFIX} Choose [1/2/3/4/5/C/Q]: ")" choice

        case "$choice" in
            1)
                local init_rc=0
                (cmd_init) || init_rc=$?
                echo ""
                if [[ "$init_rc" -ne 0 && "$init_rc" -ne 2 && "$init_rc" -ne 3 ]]; then
                    error "Initialization failed (exit code: $init_rc)."
                fi
                read -r -p "$(echo -e "${PROMPT_PREFIX} Press Enter to continue...") " _dummy
                ;;
            2)
                local build_rc=0
                (cmd_build) || build_rc=$?
                echo ""
                if [[ "$build_rc" -ne 0 && "$build_rc" -ne 2 && "$build_rc" -ne 3 ]]; then
                    error "Build failed (exit code: $build_rc)."
                fi
                read -r -p "$(echo -e "${PROMPT_PREFIX} Press Enter to continue...") " _dummy
                ;;
            3)
                (cmd_status) # Status always succeeds — report already printed above
                read -r -p "$(echo -e "${PROMPT_PREFIX} Press Enter to continue...") " _dummy
                ;;
            4)
                local qemu_rc=0
                (cmd_start_qemu) || qemu_rc=$?
                echo ""
                if [[ "$qemu_rc" -ne 0 && "$qemu_rc" -ne 2 && "$qemu_rc" -ne 3 ]]; then
                    error "start-qemu failed (exit code: $qemu_rc)."
                fi
                read -r -p "$(echo -e "${PROMPT_PREFIX} Press Enter to continue...") " _dummy
                ;;
            5)
                local stop_rc=0
                (cmd_stop_qemu) || stop_rc=$?
                echo ""
                if [[ "$stop_rc" -ne 0 && "$stop_rc" -ne 2 && "$stop_rc" -ne 3 ]]; then
                    error "stop-qemu failed (exit code: $stop_rc)."
                fi
                read -r -p "$(echo -e "${PROMPT_PREFIX} Press Enter to continue...") " _dummy
                ;;
            [cC])
                clear
                show_logo
                first_run=1
                continue
                ;;
            [qQ])
                fn_quit
                ;;
            *)
                echo -e "${YELLOW}ob-harness> Invalid input. Please choose 1/2/3/4/5/C/Q${NC}"
                continue
                ;;
        esac

        first_run=0
    done
}

