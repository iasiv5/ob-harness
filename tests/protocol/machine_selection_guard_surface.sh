#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$ROOT/lib/machine_selection_guard.sh"
test -f "$RENDER" || { echo "MISSING $RENDER" >&2; exit 1; }

# guard forbidden-token 回归锁: guard 是 machine selection 前提检测层(leaf-pure), 不该选号 /
# exit / execute / 写 state / 列宽自适应——选号归调用方调 pick_machine, execute 归 handler,
# state 写归 init/build 动作, tput 是 pick_machine 的列宽职责。guard 合法调用("$list_fn" 枚举 /
# printf -v / [[ -t 0 ]] / return)不禁。只 grep 非注释行: 头注释列了 module 职责(提及 pick_machine),
# 裸 grep 会误伤。
forbidden=( 'pick_machine' 'read_machine_choice' 'read_list_choice' \
            'devtool_modify_run' 'devtool_build_run' 'devtool_reset_run' \
            'devtool_finish_run' 'devtool_search_refresh' 'dev_dispatch_subcmd' \
            'machine_state_write' 'machine_state_mark' 'machine_state_clear' \
            'tput ' )
body="$(grep -v '^[[:space:]]*#' "$RENDER")"
for tok in "${forbidden[@]}"; do
    assert_false "guard forbids $tok" grep -Fq "$tok" <<< "$body"
done
assert_summary
