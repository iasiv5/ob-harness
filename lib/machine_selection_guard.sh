#!/usr/bin/env bash
# lib/machine_selection_guard.sh — machine selection 前提检测 module(leaf-pure)。
#   machine_selection_guard: cmd_build/cmd_dev 在交互选 machine 前对 pick_machine 两条前提
#   (list_fn 产出 machine 集合非空 + 当前为交互终端)的检测。消费 list_fn; 结果经 outvar 回传
#   empty/nontty/ok, 恒返回 0。选号/exit/remedy/展示留调用方(cmd_* 据 status 做 display + exit 映射)。
#   术语见 CONTEXT.md machine selection guard。
# Exit: leaf-pure module（横切惯例，同 machine_picker.sh/image_build.sh）；函数绝不 exit，恒 return 0；exit 归 cmd_build/cmd_dev（exit_contract Y 规则守）。


# machine_selection_guard <list_fn> <status_outvar>
# 检测 pick_machine 的两条前提: list_fn 产出的 machine 集合非空 + 当前为交互终端。
# 结果经 status_outvar 回传(恒返回 0):
#   empty   集合空(无 initialized machine)
#   nontty  集合非空但非交互终端
#   ok      集合非空 + 交互终端 → 调用方可 pick_machine
# leaf-pure: 绝不 exit, 不打印 remedy/展示, 不选号(pick 留调用方)。术语见 CONTEXT.md machine selection guard。
# 前提(调用者保证): status_outvar 名不与本函数 local 同名(本函数无 nameref, 用 printf -v, 无此风险; 沿用 devtool_pick 范式)。
machine_selection_guard() {
    local list_fn="$1" status_outvar="$2"
    local -a _machines=()
    local _line
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && _machines+=("$_line")
    done < <("$list_fn")
    if [[ ${#_machines[@]} -eq 0 ]]; then
        printf -v "$status_outvar" '%s' "empty"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        printf -v "$status_outvar" '%s' "nontty"
        return 0
    fi
    printf -v "$status_outvar" '%s' "ok"
    return 0
}
