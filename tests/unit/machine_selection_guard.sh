#!/usr/bin/env bash
# tests/unit/machine_selection_guard.sh — machine_selection_guard 单测(unit 层)。
# 覆盖 status_outvar empty/nontty 两态; ok 态需真实 tty(交互终端), unit 环境无法 mock [[ -t 0 ]],
# 靠 protocol/manual_matrix.exp(cmd_dev/cmd_build 交互路径)覆盖。
# outvar 回传: helper 经 printf -v "$status_outvar" 写 caller 作用域, 必须当前 shell 跑;
#              nontty 用 </dev/null 重定向贯穿函数使 [[ -t 0 ]] 退 false(while 读进程替换, 不读 fd0)。
# leaf-pure: helper 恒返回 0(空优先判 empty, 不查 tty); exit_contract Y 静态守卫。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT

# mock list_fn(命令名, module 内部 "$list_fn" 调用; 进程替换继承当前 shell 函数)
_list_empty() { :; }                  # 无输出 = 集合空
_list_two()   { printf 'm1\nm2\n'; }  # 两个 machine

_st=""
# ① empty: list_fn 空 → empty(空优先, 不查 tty)
machine_selection_guard _list_empty _st </dev/null
assert_eq "① empty: status=empty" "$_st" "empty"

# ② nontty: list_fn 非空 + stdin 非tty(</dev/null) → nontty
machine_selection_guard _list_two _st </dev/null
assert_eq "② nontty: status=nontty" "$_st" "nontty"

# ok 态需真实 tty(交互终端), unit 环境无法 mock [[ -t 0 ]]; 靠 protocol/manual_matrix.exp
# (cmd_dev/cmd_build 交互路径)覆盖。ok 是 empty/nontty 之后的 else 分支, 逻辑极简。
assert_summary
