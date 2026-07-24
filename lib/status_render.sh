#!/usr/bin/env bash
# lib/status_render.sh — status presentation module(leaf-pure)。
#   ob status 仪表盘呈现层:把 cmd_status 已采集的事实格式化为 stdout(表格/diagnostics 段/tips)。
#   纯参数注入——绝不读全局($OPENBMC_DIR/$SOURCE_MANIFEST_FILE)、绝不拉网络(git/timeout)、
#   绝不调数据接口(machine_state_*/qemu_instance_*/read_manifest_field);数据全由 cmd_status 以参数喂入。
#   呈现逻辑(emoji 映射/列宽/分段/timestamp 格式化)归本 module。术语见 CONTEXT.md status presentation module。
#   caller 传 renderer 的数组名不得与本函数内 _sr_* local nameref 同名(否则 bash circular name reference)。
# Exit: leaf-pure module(函数绝不 exit; 只 print stdout); exit-code/remedy/采集归 cmd_status(L1)。

# status_render_main_repo <repo_exists 0/1> <origin_url> <source_label> <branch> <commit> <upstream_display> <first_init_raw> <local_path>
status_render_main_repo() {
    local repo_exists="$1" origin_url="$2" source_label="$3" branch="$4"
    local commit="$5" upstream_display="$6" first_init_raw="$7" local_path="$8"
    step_header "OpenBMC Main Repository"
    if [[ "$repo_exists" -eq 0 ]]; then
        echo "  Status       : missing"
        return 0
    fi
    local source_display="${origin_url:-<no origin>}${source_label:+ ($source_label)}"
    local first_init=""
    [[ -n "$first_init_raw" ]] && first_init=$(format_timestamp "$first_init_raw")
    echo "  Status       : present"
    echo "  Source       : $source_display"
    echo "  Local path   : $local_path"
    echo "  Branch       : ${branch:-<unknown>}"
    echo "  Commit       : ${commit:-<unknown>}"
    echo "  Upstream     : ${upstream_display:-⚠️ unreachable (skipped)}"
    echo "  First init   : ${first_init:-<unknown>}"
}

# status_render_machines <records_nameref>
# records 每元素: name|init_raw|snapshot_state|repo_count|init_time|fw_ready(0/1)|fw_path|fw_mtime
status_render_machines() {
    local -n _sr_machines_records="$1"
    step_header "Machines"
    if [[ ${#_sr_machines_records[@]} -eq 0 ]]; then
        echo "  (none)"
        return 0
    fi
    printf "  %-22s %-15s %s\n" "Machine" "Init" "Firmware Image"
    local _rec _name _init_raw _snap _repos _init_time _fw_ready _fw_path _fw_mtime _init_disp _fw_disp _padded
    for _rec in "${_sr_machines_records[@]}"; do
        IFS='|' read -r _name _init_raw _snap _repos _init_time _fw_ready _fw_path _fw_mtime <<< "$_rec"
        case "$_init_raw" in
            initialized) _init_disp="✅ initialized" ;;
            partial)      _init_disp="⏳ partial" ;;
            *)            _init_disp="— uninitialized" ;;
        esac
        if [[ "$_fw_ready" == "1" ]]; then _fw_disp="📦 ready"; else _fw_disp="— missing"; fi
        printf -v _padded "%-22s" "$_name"
        printf "  %b%-15s %s\n" "${YELLOW}${_padded}${NC}" "$_init_disp" "$_fw_disp"
    done
    for _rec in "${_sr_machines_records[@]}"; do
        IFS='|' read -r _name _init_raw _snap _repos _init_time _fw_ready _fw_path _fw_mtime <<< "$_rec"
        [[ "$_snap" == "present" ]] || continue
        echo ""
        echo "  ── $_name ──────────────────────────────────────"
        local _it=""
        [[ -n "$_init_time" ]] && _it=$(format_timestamp "$_init_time")
        echo "    Init time    : ${_it:--}"
        echo "    Repos        : ${_repos}"
        if [[ "$_fw_ready" == "1" && -n "$_fw_path" ]]; then
            local _ft="-"
            [[ -n "$_fw_mtime" ]] && _ft=$(format_timestamp "$_fw_mtime")
            echo "    Firmware time: $_ft"
            echo "    Firmware name: $(basename "$_fw_path")"
            echo "    Firmware path: $(dirname "$_fw_path")/"
        fi
    done
}

# status_render_diagnostics <orphan_records_nameref>  每元素: name|path
status_render_diagnostics() {
    local -n _sr_diag_records="$1"
    [[ ${#_sr_diag_records[@]} -gt 0 ]] || return 0
    echo ""
    step_header "Diagnostics"
    echo "  Orphan firmware image artifacts"
    local _rec _name _path
    for _rec in "${_sr_diag_records[@]}"; do
        IFS='|' read -r _name _path <<< "$_rec"
        echo ""
        echo "    $_name"
        echo "      Path      : ${_path:-<unknown>}"
        echo "      Reason    : firmware image artifact exists, but machine init is incomplete"
        echo "      Next step : ob init $_name"
    done
}

# status_render_tips <repo_exists 0/1> <has_init 0/1> <has_init_no_fw 0/1>
status_render_tips() {
    local repo_exists="$1" has_init="$2" has_init_no_fw="$3"
    local tip=""
    if   [[ "$repo_exists"  -eq 0 ]]; then tip="💡 Run 'ob init' to get started."
    elif [[ "$has_init"     -eq 0 ]]; then tip="💡 Run 'ob init' to initialize a machine."
    elif [[ "$has_init_no_fw" -eq 1 ]]; then tip="💡 Run 'ob build <machine>' to produce a firmware image."
    fi
    # 用 if 不用 `[[ -n $tip ]] && {...}`:后者 tip 为空时返回非零,作为函数末句会使 renderer
    # 返回 1,在 cmd_status 的 set -e 上下文里触发退出(bestpractice_07 短路 && 陷阱)。
    if [[ -n "$tip" ]]; then
        echo ""
        echo "  $tip"
    fi
}
