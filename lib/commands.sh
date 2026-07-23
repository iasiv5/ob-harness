#!/usr/bin/env bash
# lib/commands.sh — cmd_* 命令编排(status/build/init/dev/menu). 术语见 CONTEXT.md function semantic layer / exit-code 契约.
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

    # Section 5: QEMU instances（只读,含 stale 显示;不删 PID 文件——清理 owner = start-qemu/stop-qemu）
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
    apply_npm_registry

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

        local pm_rc=0
        # Previously 段作 pick_machine 的 post-list-msg: 列表后、提示词前打印,
        # 用户选择时紧邻看到已 init 的 machine(不必往上翻序号列表对序号)
        pick_machine list_available_machines "init" "$(print_previously_initialized _init_machines)" || pm_rc=$?
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
    # 清理 recipes cache/meta(init 重跑后旧索引必然过期)
    if ! devtool_recipes_clear_cache "$MACHINE"; then
        error "Failed to clear recipe cache for '$MACHINE'."
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

cmd_dev() {
    # 解析 --machine + 二级子命令(来自 main 的 DEV_ARGS)。porcelain: 诊断走 stderr, stdout 只输出 list JSONL / modify srctree。
    local dev_machine="" dev_subcmd="" dev_pattern="" dev_recipe="" _positional_count=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --machine)
                [[ $# -ge 2 ]] || { error "Missing value for --machine" >&2; exit 1; }
                dev_machine="$2"; shift 2
                [[ -z "$dev_machine" || "$dev_machine" == -* ]] && { error "ob dev: invalid --machine value '$dev_machine'" >&2; exit 1; } ;;
            --machine=*)
                dev_machine="${1#--machine=}"; shift
                [[ -z "$dev_machine" || "$dev_machine" == -* ]] && { error "ob dev: invalid --machine value '$dev_machine'" >&2; exit 1; } ;;
            -d|-D|--dry-run) DRY_RUN=1; shift ;;
            list|modify|refresh|build|finish|reset|status)
                if [[ -z "$dev_subcmd" ]]; then
                    dev_subcmd="$1"
                else
                    _positional_count=$((_positional_count + 1))
                    case "$dev_subcmd" in
                        list)   [[ -z "$dev_pattern" ]] || { error "ob dev list: too many patterns" >&2; exit 1; }; dev_pattern="$1" ;;
                        modify|reset|finish|build) [[ -z "$dev_recipe" ]] || { error "ob dev $dev_subcmd: too many recipes" >&2; exit 1; }; dev_recipe="$1" ;;
                        *)      error "ob dev $dev_subcmd: unexpected argument '$1'" >&2; exit 1 ;;
                    esac
                fi
                shift ;;
            -*) error "ob dev: unknown option '$1'" >&2; exit 1 ;;
            *)
                _positional_count=$((_positional_count + 1))
                case "$dev_subcmd" in
                    list)   [[ -z "$dev_pattern" ]] || { error "ob dev list: too many patterns" >&2; exit 1; }; dev_pattern="$1" ;;
                    modify|reset|finish|build) [[ -z "$dev_recipe" ]] || { error "ob dev $dev_subcmd: too many recipes" >&2; exit 1; }; dev_recipe="$1" ;;
                    *)      error "ob dev: unexpected positional '$1' (need subcommand first)" >&2; exit 1 ;;
                esac
                shift ;;
        esac
    done

    # machine 前置: --machine 给定则用它; 否则枚举 initialized + 判 TTY + pick
    if [[ -z "$dev_machine" ]]; then
        local -a _machines=()
        local _line
        while IFS= read -r _line; do
            [[ -n "$_line" ]] && _machines+=("$_line")
        done < <(machine_state_initialized_machines)
        if [[ ${#_machines[@]} -eq 0 ]]; then
            error "No initialized machines found." >&2
            error "Run 'ob init <machine>' first." >&2
            exit 3
        fi
        if [[ ! -t 0 ]]; then
            error "No --machine specified and no interactive terminal." >&2
            error "Specify a machine: ob dev --machine <machine> ${dev_subcmd:-list}" >&2
            exit 3
        fi
        local _pm_rc=0
        pick_machine machine_state_initialized_machines "Develop" >&2 || _pm_rc=$?
        if [[ "$_pm_rc" -eq 2 ]]; then exit 2; fi       # cancel
        if [[ "$_pm_rc" -ne 0 ]]; then exit 1; fi       # read failure(1) 或其他错误(原所有非零当 cancel)
        dev_machine="$MACHINE"
    fi

    # init-done 前置(所有子命令)
    if ! machine_state_is_initialized "$dev_machine"; then
        error "Machine '$dev_machine' is not initialized." >&2
        error "Run 'ob init $dev_machine' first." >&2
        exit 3
    fi
    local dev_build_dir="$OPENBMC_DIR/build/$dev_machine"

    # 无子命令 + TTY → 交互引导(选 list/modify/refresh, 按需补 pattern/recipe)。
    # 非 TTY 不进此段, 落到下面 case "" 分支维持 agent/CI 契约(exit 3 + remedy)。
    if [[ -z "$dev_subcmd" && -t 0 ]]; then
        # 1) 子命令菜单(列已实现 7 个: list/modify/refresh/reset/status/finish/build; deploy 已退役, 迁至 ob deploy-to-qemu)
        echo "  ob dev subcommands:"
        echo "    1) list     Search/list recipes (read-only, reads cache)"
        echo "    2) modify   devtool modify a recipe (outputs srctree path)"
        echo "    3) refresh  Regenerate recipe metadata cache"
        echo "    4) reset    devtool reset a recipe (outputs disposition JSON)"
        echo "    5) status   List modified recipes (read-only, outputs JSONL)"
        echo "    6) finish   devtool finish a recipe (land patches back to layer, outputs JSON)"
        echo "    7) build   devtool build a recipe (outputs nothing on stdout, exit code carries result)"
        local _sub_choice=""
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Select subcommand [1-7] (0 to cancel): ")" _sub_choice; then
            error "Unable to read subcommand selection from stdin." >&2
            exit 1
        fi
        case "$_sub_choice" in
            0) warn "ob dev cancelled by user."; exit 2 ;;
            1) dev_subcmd="list" ;;
            2) dev_subcmd="modify" ;;
            3) dev_subcmd="refresh" ;;
            4) dev_subcmd="reset" ;;
            5) dev_subcmd="status" ;;
            6) dev_subcmd="finish" ;;
            7) dev_subcmd="build" ;;
            *) error "ob dev: invalid subcommand selection '$_sub_choice'." >&2; exit 1 ;;
        esac
        # 2) 按子命令补必填/可选位置参数
        case "$dev_subcmd" in
            list)
                if ! read -r -p "$(echo -e "${PROMPT_PREFIX} pattern (Enter = all recipes): ")" dev_pattern; then
                    error "Unable to read pattern." >&2
                    exit 1
                fi
                ;;
            modify)
                if ! read -r -p "$(echo -e "${PROMPT_PREFIX} recipe name: ")" dev_recipe; then
                    error "Unable to read recipe name." >&2
                    exit 1
                fi
                if [[ -z "$dev_recipe" ]]; then
                    error "ob dev modify: no recipe specified." >&2
                    error "Run 'ob dev --machine $dev_machine list [pattern]' to discover recipes first." >&2
                    exit 3
                fi
                ;;
            reset|finish|build)
                # TTY 选 modified recipe → helper(leaf-pure, 5 态 status_outvar) + exit-code 映射留 cmd_dev
                local _pick_st=""
                devtool_pick_modified_recipe "$dev_machine" "$dev_build_dir" "$dev_subcmd" _pick_st
                case "$_pick_st" in
                    ok:*)
                        dev_recipe="${_pick_st#ok:}" ;;
                    empty)
                        warn "No modified recipes for $dev_machine." >&2
                        error "Run 'ob dev --machine $dev_machine modify <recipe>' first." >&2
                        exit 3 ;;
                    cancel)
                        exit 2 ;;
                    read-fail|status-failed)
                        # read-fail: read_list_choice 读失败; status-failed: 文案已由 dev_relay_result 打印
                        exit 1 ;;
                esac
                # ok 选号成功: dev_recipe 已填, fall through 出 TTY 引导段(fi);
                # 下游 dispatch case(reset/finish/build 各自跑 devtool_*_run + DRY_RUN/recipe 再校验)继续执行,
                # dev_recipe 非空 → 下游 [[ -z "$dev_recipe" ]] exit 3 check 不误触发。
                ;;
            refresh|status) ;;
        esac
    fi

    local _rc=0
    dev_dispatch_subcmd "$dev_subcmd" "$dev_machine" "$dev_build_dir" "$dev_recipe" "$dev_pattern" "${DRY_RUN:-0}" || _rc=$?
    # cmd_dev 字面 case 收口（全局约束；exit_contract X 禁 exit $?, || _rc=$? 防 set -e）
    case "$_rc" in 0) exit 0;; 1) exit 1;; 2) exit 2;; 3) exit 3;; *) exit 1;; esac
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
