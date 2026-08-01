#!/usr/bin/env bash
# lib/commands.sh — cmd_* 命令编排(status/build/init/dev/menu). 术语见 CONTEXT.md function semantic layer / exit-code 契约.
# Exit: exit seam（L1 cmd_* 顶层编排, 使用 exit-code 契约值 0/1/2/3）.


# ob status 呈现层(原内联在 cmd_status 前的 4 个 section 渲染函数)已抽至 lib/status_render.sh(status_render_*);
# cmd_status 负责 gather(machine_state_*/qemu_instance_*/git/manifest)→ render。术语见 CONTEXT.md status presentation module。

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

    # --- gather main_repo facts(含网络 upstream 比较;原内联在 main_repo section 渲染,现上移编排层) ---
    local mr_origin_url="" mr_source_label="" mr_branch="" mr_commit=""
    local mr_upstream_display="⚠️ unreachable (skipped)" mr_first_init_raw="" mr_local_path="$OPENBMC_DIR"
    if [[ "$repo_exists" -eq 1 ]]; then
        mr_origin_url=$(git -C "$OPENBMC_DIR" remote get-url origin 2>/dev/null || true)
        if [[ -f "$SOURCE_MANIFEST_FILE" ]]; then
            mr_source_label=$(read_manifest_field source_label 2>/dev/null || true)
        fi
        mr_branch=$(git -C "$OPENBMC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        mr_commit=$(git -C "$OPENBMC_DIR" log --oneline -1 2>/dev/null || true)
        if timeout 10 git -C "$OPENBMC_DIR" fetch origin --quiet 2>/dev/null; then
            local ahead behind
            ahead=$(git -C "$OPENBMC_DIR" rev-list --count "origin/${mr_branch}..HEAD" 2>/dev/null || echo "0")
            behind=$(git -C "$OPENBMC_DIR" rev-list --count "HEAD..origin/${mr_branch}" 2>/dev/null || echo "0")
            if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
                mr_upstream_display="✅ up-to-date"
            elif [[ "$behind" -gt 0 ]]; then
                mr_upstream_display="⬇️  behind ${behind}${ahead:+, ⬆️  ahead ${ahead}}"
            else
                mr_upstream_display="⬆️  ahead ${ahead}"
            fi
        fi
        if [[ -f "$SOURCE_MANIFEST_FILE" ]]; then
            mr_first_init_raw=$(read_manifest_field created_at 2>/dev/null || true)
        fi
    fi
    status_render_main_repo "$repo_exists" "$mr_origin_url" "$mr_source_label" "$mr_branch" "$mr_commit" "$mr_upstream_display" "$mr_first_init_raw" "$mr_local_path"

    echo ""

    # --- gather machines records(raw facts;renderer 做 emoji 映射。gather 原样透传,禁兜底——否则破坏 golden) ---
    local -a status_machine_records=()
    local _m
    while IFS= read -r _m; do
        [[ -n "$_m" ]] || continue
        local _init_state _snapshot_state _repo_count _init_time _fw_ready="0" _fw_path="" _fw_mtime=""
        _init_state=$(machine_state_init_state "$_m")
        _snapshot_state=$(machine_state_snapshot_state "$_m")
        _repo_count=$(machine_state_repo_count "$_m")
        _init_time=$(machine_state_init_time "$_m")
        if machine_state_is_firmware_image_ready "$_m"; then
            _fw_ready="1"
            _fw_path=$(machine_state_firmware_image_path "$_m" 2>/dev/null || true)
            _fw_mtime=$(machine_state_firmware_image_mtime "$_m")
        fi
        status_machine_records+=("$_m|$_init_state|$_snapshot_state|$_repo_count|$_init_time|$_fw_ready|$_fw_path|$_fw_mtime")
    done < <(machine_state_display_machines)
    status_render_machines status_machine_records

    # --- gather orphan diagnostics records ---
    local -a status_orphan_records=()
    local _om
    while IFS= read -r _om; do
        [[ -n "$_om" ]] || continue
        local _opath
        _opath=$(machine_state_firmware_image_path "$_om" 2>/dev/null || true)
        status_orphan_records+=("$_om|$_opath")
    done < <(machine_state_orphan_firmware_image_machines)
    status_render_diagnostics status_orphan_records

    # --- gather tips inputs ---
    local has_initialized_machine=0
    local has_initialized_without_firmware_image=0
    local _im
    while IFS= read -r _im; do
        [[ -n "$_im" ]] || continue
        has_initialized_machine=1
        if ! machine_state_is_firmware_image_ready "$_im"; then
            has_initialized_without_firmware_image=1
        fi
    done < <(machine_state_initialized_machines)
    status_render_tips "$repo_exists" "$has_initialized_machine" "$has_initialized_without_firmware_image"

    # --- QEMU instances(编排层内联,out of scope;只读含 stale 显示,不删 PID 文件——清理 owner = start-qemu/stop-qemu) ---
    local _has_qemu=0
    local -a _qemu_lines=()
    local _qm
    while IFS= read -r _qm; do
        [[ -n "$_qm" ]] || continue
        _has_qemu=1
        _qemu_lines+=("  $_qm   $(qemu_instance_summarize_brief "$_qm")")
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
    # resolve_command_machine 据 $MACHINE 判 given/empty（与 caller 同源）。记 had_explicit 保 confirm 门:
    # 仅交互选号（empty 路径 pick）才 confirm; 显式 `ob build <m>`（given 路径）不 confirm。
    local had_explicit=0
    [[ -n "$MACHINE" ]] && had_explicit=1
    local _rc=0
    resolve_command_machine machine_state_initialized_machines "Build" stdout "No machine specified and no interactive terminal. Run 'ob status' to list initialized machines. Specify a machine: ob build <machine>" || _rc=$?
    # 字面 case 收口（exit_contract X 禁 exit $?, || _rc=$? 防 set -e; _rc=0 前置是 set -u 必需）;
    # 1) 的 error 同时作 3) exit 3 的 exit_contract Z(b) 静态锚点（同 cmd_init）。
    case "$_rc" in
        0) ;;
        1) error "ob build: failed to read machine selection input."; exit 1 ;;
        2) exit 2 ;;
        3) exit 3 ;;
        *) exit 1 ;;
    esac
    [[ "$had_explicit" -eq 0 ]] && interactive_selection=1
    BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"

    # === Read main repo info（仓库信息块; seam return 0 后打印, given/empty 两路均展示）===
    local manifest_origin_url manifest_source_label
    manifest_origin_url=$(read_manifest_field origin_url || echo "<unknown>")
    manifest_source_label=$(read_manifest_field source_label || echo "")

    step_header "OpenBMC Repository"
    echo "  Source : $manifest_origin_url${manifest_source_label:+ ($manifest_source_label)}"
    echo "  Path   : $OPENBMC_DIR"
    echo ""

    echo ""
    info "Selected: $MACHINE"
    info "Target  : obmc-phosphor-image"
    info "Estimated time: 1-4 hours depending on machine and cache state."
    echo ""

    if [[ "$interactive_selection" -eq 1 ]]; then
        local ca_rc=0
        confirm_action "build" "$MACHINE" || ca_rc=$?
        # confirm rc 迁 inline case+warn（替 exit_on_user_cancel; 保 cancel warn）。
        case "$ca_rc" in
            0) ;;
            2) warn "Build cancelled by user."; exit 2 ;;
            *) exit 1 ;;
        esac
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would source setup $MACHINE $BUILD_DIR"
        info "[DRY-RUN] Would run: bitbake obmc-phosphor-image (machine=$MACHINE)"
        exit 0
    fi

    # === Build obmc-phosphor-image(经 obmc-phosphor-image build module: enter+npm+bitbake, return rc) ===
    echo ""
    step_header "Building $MACHINE"
    info "Running: bitbake obmc-phosphor-image"
    echo ""

    if build_obmc_image "$MACHINE" "$BUILD_DIR"; then
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

    # 解析+确认 machine(经 ob init command intake module: empty/arg 校验/pick/confirm, return 0/1/2/3)。
    # 原 L266-306 内联决策树(含 exit_on_user_cancel 2 处)已抽进 lib/init_intake.sh; exit 由本 L1 字面 case 收口。
    local _irc=0
    init_intake || _irc=$?
    # intake return 契约: 0=ok / 1=read-fail / 2=cancel / 3=prereq-missing(空列表/非TTY)。
    # 2/3 的 remedy 已在 intake 内打印; exit-code 由本 L1 字面 case 收口。
    # 1)/*) 的 error 同时作 3) exit 3 的 exit_contract Z(b) 静态锚点: intake 抽取后 exit3 的 remedy
    # 已随 leaf-pure 搬进 intake, Z(b) 同函数前文回溯扫不到 → case 内补 error 兜底
    # (行为: exit3 路径只走 3) 不触达 1) error, 字节级不变; cmd_dev 是靠 case 外 guard error 满足, 路径不同)。
    case "$_irc" in
        0) ;;
        1) error "ob init: failed to read machine selection input."; exit 1 ;;
        2) exit 2 ;;
        3) exit 3 ;;
        *) error "ob init: unexpected intake status ($_irc)."; exit 1 ;;
    esac

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
    local dev_machine="" dev_subcmd="" dev_pattern="" dev_recipe=""
    local _iarc=0
    dev_intake_argv dev_machine dev_subcmd dev_pattern dev_recipe "$@" || _iarc=$?
    # cmd_dev 字面 case 收口（exit_contract X 禁 exit $?, || _rc=$? 防 set -e）
    case "$_iarc" in 0) ;; *) exit 1;; esac

    # machine 解析经 resolve_command_machine（ADR-0019）。无条件同步全局 $MACHINE ← 局部 dev_machine:
    # seam 只看全局; 显式给定→同步该值、未给定→清空, 让 seam 正确进 given/empty（无条件而非 [[ -n ]] &&,
    # 条件版留 stale $MACHINE 是 footgun）。pick_stream=stderr 护 ob dev porcelain stdout 契约。
    MACHINE="$dev_machine"
    local _rc=0
    resolve_command_machine machine_state_initialized_machines "Develop" stderr "No --machine specified and no interactive terminal. Specify a machine: ob dev --machine <machine> ${dev_subcmd:-list}" || _rc=$?
    # 字面 case 收口（同 cmd_build; 1) error 作 3) exit 3 的 Z(b) 锚点）。
    case "$_rc" in
        0) ;;
        1) error "ob dev: failed to read machine selection input."; exit 1 ;;
        2) exit 2 ;;
        3) exit 3 ;;
        *) exit 1 ;;
    esac
    dev_machine="$MACHINE"
    local dev_build_dir="$OPENBMC_DIR/build/$dev_machine"

    # 无子命令 + TTY → 交互引导(选 list/modify/refresh, 按需补 pattern/recipe)。
    # 非 TTY 不进此段, 落到下面 case "" 分支维持 agent/CI 契约(exit 3 + remedy)。
    if [[ -z "$dev_subcmd" && -t 0 ]]; then
        local _trc=0
        dev_intake_tty "$dev_machine" "$dev_build_dir" dev_subcmd dev_pattern dev_recipe || _trc=$?
        # cmd_dev 字面 case 收口（exit_contract X 禁 exit $?, || _rc=$? 防 set -e）
        case "$_trc" in 0) ;; 1) exit 1;; 2) exit 2;; 3) exit 3;; *) exit 1;; esac
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
