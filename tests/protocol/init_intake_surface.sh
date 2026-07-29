#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$ROOT/lib/init_intake.sh"
test -f "$RENDER" || { echo "MISSING $RENDER" >&2; exit 1; }

# intake forbidden-token 回归锁: intake 是命令入口解析+确认层(leaf-pure), 不该 execute init step /
# clear state / 写 marker / 调 guard(Phase 2 暂缓 ADR-0016)/调 exit_on_user_cancel(本抽取退役点,
# 从 cmd_init 直接搬出、build/qemu 仍在用——最易回潮成"能 exit 的伪 leaf")——那些归 cmd_init L1。
# 合法调用(list_available_machines/print_previously_initialized/pick_machine/confirm_action/error/warn/info)不禁。
forbidden=( 'exit_on_user_cancel' \
            'generate_dep_graph' 'clone_sub_repos' 'generate_machine_snapshot' \
            'generate_build_config' 'print_report' 'machine_state_clear_init_progress' \
            'devtool_recipes_clear_cache' 'machine_state_mark_init_done' 'machine_selection_guard' )
body="$(grep -v '^[[:space:]]*#' "$RENDER")"
for tok in "${forbidden[@]}"; do
    assert_false "intake forbids $tok" grep -Fq "$tok" <<< "$body"
done
assert_summary
