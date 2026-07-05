#!/usr/bin/env bash
# lib/machine_picker.sh — machine selection 交互选择 module。术语见 CONTEXT.md machine selection.
# Exit: leaf-no-exit（leaf-pure module）; return 0(设 $MACHINE)/2(cancel)/1(read 失败), 绝不 exit.


# read_machine_choice <total> <verb> <machines-nameref>
# 前提(调用者保证): 调用者已渲染选择列表 + machine 集合非空 + 交互终端。
# read 输入(数字或名字) → 设 $MACHINE / return 2(cancel) / return 1(read 失败)。绝不 exit。
# pick_machine 的读入循环被提取出来, 供 caller 自渲染列表(如 cmd_stop_qemu 带实例详情)后复用。
read_machine_choice() {
    local total="$1" verb="$2"
    local -n _rmc_machines="$3"
    local selected m
    while true; do
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Select a machine for ${verb} [1-${total}] (number or name, 0 to cancel): ")" selected; then
            error "Unable to read machine selection from stdin."
            return 1
        fi
        [[ "$selected" == "0" ]] && return 2
        if [[ "$selected" =~ ^[0-9]+$ ]] && [[ "$selected" -ge 1 && "$selected" -le "$total" ]]; then
            MACHINE="${_rmc_machines[$((selected - 1))]}"
            return 0
        fi
        for m in "${_rmc_machines[@]}"; do
            if [[ "$m" == "$selected" ]]; then
                MACHINE="$m"
                return 0
            fi
        done
        warn "Invalid selection '$selected'. Enter a number (1-${total}) or a machine name."
    done
}


# pick_machine <list-source-cmd> <verb> [post-list-msg]
# 前提(调用者保证): <list-source-cmd> 产出非空 machine 列表(每行一名) + 交互终端。
# 渲染纯序号+名字选择表(列宽自适应) → [打印 post-list-msg] → read_machine_choice。
# post-list-msg(可选): 列表后、提示词前打印的 caller 上下文(如 init 的 Previously initialized
#                     高亮),让用户在选择时紧邻看到、不必往上翻; 不传则跳过。
# 不判空/不判 TTY/不做 arg 校验/不 exit — 这些是调用者命令前置。
pick_machine() {
    local list_source="$1" verb="$2" post_list_msg="${3:-}"
    local -a machines=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && machines+=("$line")
    done < <("$list_source")

    local total=${#machines[@]}
    local idx_width=${#total}
    local term_cols i _list _row
    term_cols=$(tput cols 2>/dev/null) || term_cols=80
    _list=""
    for (( i=0; i<total; i++ )); do
        printf -v _row "  %${idx_width}d) %s\n" "$((i + 1))" "${machines[$i]}"
        _list+="$_row"
    done
    # column 按终端宽度紧凑分列；无 column 则单列兜底
    printf '%s' "$_list" | column -c "$term_cols" 2>/dev/null || printf '%s' "$_list"

    [[ -n "$post_list_msg" ]] && printf '%s\n' "$post_list_msg"

    read_machine_choice "$total" "$verb" machines
}
