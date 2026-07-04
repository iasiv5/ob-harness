#!/usr/bin/env bash
# lib/machine_picker.sh — machine selection 交互选择 module。术语见 CONTEXT.md machine selection.
# Exit: leaf-no-exit（leaf-pure module）; return 0(设 $MACHINE)/2(cancel)/1(read 失败), 绝不 exit.


# pick_machine <list-source-cmd> <verb>
# 前提(调用者保证): <list-source-cmd> 产出非空 machine 列表(每行一名) + 交互终端。
# 渲染纯序号+名字选择表 → 读输入(数字或名字) → 设 $MACHINE / return 2(cancel)。
# 不判空/不判 TTY/不做 arg 校验/不 exit — 这些是调用者命令前置。
pick_machine() {
    local list_source="$1" verb="$2"
    local -a machines=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && machines+=("$line")
    done < <("$list_source")

    local total=${#machines[@]}
    local idx_width=${#total}
    local i
    for (( i=0; i<total; i++ )); do
        printf "  %${idx_width}d) %s\n" "$((i + 1))" "${machines[$i]}"
    done

    local selected m
    while true; do
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Select a machine for ${verb} [1-${total}] (number or name, 0 to cancel): ")" selected; then
            error "Unable to read machine selection from stdin."
            return 1
        fi
        [[ "$selected" == "0" ]] && return 2
        if [[ "$selected" =~ ^[0-9]+$ ]] && [[ "$selected" -ge 1 && "$selected" -le "$total" ]]; then
            MACHINE="${machines[$((selected - 1))]}"
            return 0
        fi
        for m in "${machines[@]}"; do
            if [[ "$m" == "$selected" ]]; then
                MACHINE="$m"
                return 0
            fi
        done
        warn "Invalid selection '$selected'. Enter a number (1-${total}) or a machine name."
    done
}
