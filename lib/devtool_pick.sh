#!/usr/bin/env bash
# lib/devtool_pick.sh — modified recipe selection 交互选择 module(leaf-pure)。
#   devtool_pick_modified_recipe: ob dev 的 reset/finish/build TTY 子命令共享的"先选一个 modified
#   recipe 再动手"前置。取 modified recipe 列表(devtool_status_run) → status 阶段失败复用 dev_relay_result
#   收口为 status-failed → 空 empty → 非空渲染序号 + read_list_choice 选号 → ok:<recipe>/cancel/read-fail。
#   消费 devtool_status_run / dev_relay_result / read_list_choice。术语见 CONTEXT.md modified recipe selection。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程/交互副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断。

# devtool_pick_modified_recipe <machine> <build_dir> <verb> <status_outvar>
# 前提(调用者保证): machine initialized + 交互终端 + status_outvar 名不与本函数 local 同名。
# 结果全经 status_outvar 回传(恒返回 0, 仅 mktemp 等硬失败非零):
#   ok:<recipe>    选中(recipe 嵌入) -> cmd_dev 取出继续
#   empty          status 成功但无 modified recipe -> cmd_dev exit 3 + remedy
#   cancel         read_list_choice rc=2 -> exit 2
#   read-fail      read_list_choice rc=1 -> exit 1
#   status-failed  status 阶段失败(stage 异常 或 rc!=0); 文案由 dev_relay_result 打印 -> exit 1
devtool_pick_modified_recipe() {
    local machine="$1" build_dir="$2" verb="$3" status_outvar="$4"
    local _entries="" _stage="" _stderr="" _rc=0
    devtool_status_run "$machine" "$build_dir" _entries _stage _stderr || _rc=$?
    # status 阶段失败(stage cd/setup/postcondition 或 rc!=0): dev_relay_result cat+rm stderr + 打印文案 + return 1
    dev_relay_result "$verb" "$_stderr" "$_stage" "" "${_rc:-0}" \
        || { printf -v "$status_outvar" '%s' "status-failed"; return 0; }
    # 解析 entries("recipe<TAB>srctree" 换行串) → recipe 列表
    local -a _recipes=()
    local _r
    while IFS=$'\t' read -r _r _; do
        [[ -n "$_r" ]] && _recipes+=("$_r")
    done <<< "$_entries"
    if [[ ${#_recipes[@]} -eq 0 ]]; then
        printf -v "$status_outvar" '%s' "empty"
        return 0
    fi
    # 渲染序号(>&2, 守 ob dev porcelain stdout 契约)
    local _i _w=${#_recipes[@]}
    for (( _i=0; _i<_w; _i++ )); do
        printf '  %d) %s\n' "$((_i + 1))" "${_recipes[$_i]}" >&2
    done
    # 选号(read_list_choice 多态 rc: 0=选中/2=cancel/1=read-fail)
    local _sel="" _plrc=0
    read_list_choice "$_w" "recipe" "$verb" _recipes _sel >&2 || _plrc=$?
    case "$_plrc" in
        0) printf -v "$status_outvar" '%s' "ok:$_sel" ;;
        2) printf -v "$status_outvar" '%s' "cancel" ;;
        *) printf -v "$status_outvar" '%s' "read-fail" ;;
    esac
    return 0
}
