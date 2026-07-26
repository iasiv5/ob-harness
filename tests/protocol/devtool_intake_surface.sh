#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$ROOT/lib/devtool_intake.sh"
test -f "$RENDER" || { echo "MISSING $RENDER" >&2; exit 1; }

# intake forbidden-token 回归锁: intake 是命令入口解析+引导层(leaf-pure), 不该直接 execute /
# dispatch / 查 machine 生命周期——那些归 handler 层 / cmd_dev。合法调用(devtool_pick_modified_recipe /
# read / printf -v / error / warn)不禁。
# 实测: 对 intake.sh body(= 抽取后的 argv parser + TTY 引导)上述 8 token 全 0 命中(machine_state_
# 在 cmd_dev 全段命中 3 次但全属"留 cmd_dev"的 machine/init-done 前置段, 不进 intake body)。
forbidden=( 'devtool_modify_run' 'devtool_reset_run' 'devtool_finish_run' \
            'devtool_build_run' 'devtool_search_refresh' 'devtool_search_read' \
            'dev_dispatch_subcmd' 'machine_state_' )
# 只 grep 非注释行: 头注释列了 module 职责(提及"不调"的 token), 裸 grep 会误伤。
body="$(grep -v '^[[:space:]]*#' "$RENDER")"
for tok in "${forbidden[@]}"; do
    assert_false "intake forbids $tok" grep -Fq "$tok" <<< "$body"
done
assert_summary
