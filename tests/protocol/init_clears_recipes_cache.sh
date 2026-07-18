#!/usr/bin/env bash
# tests/protocol/init_clears_recipes_cache.sh — cmd_init 清理 recipes cache 断言(静态)。
# cmd_init 函数体(machine_state_clear_init_progress 后)必须调 devtool_recipes_clear_cache,
# 防 init 重跑后旧索引残留。函数本身的删 cache+meta 行为由 unit/devtool_search.sh 覆盖,
# 返回码编排由 init_machine_state_errors.sh 覆盖；真实 init→清理由 T8 integration 验证。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

CMD_SH="$(cd "$(dirname "$0")/../.." && pwd)/lib/commands.sh"

# 提取 cmd_init 函数体(到下一个 cmd_dev), 检查含 devtool_recipes_clear_cache 调用
if awk '/^cmd_init\(\)/,/^cmd_dev\(\)/' "$CMD_SH" \
        | grep -q 'devtool_recipes_clear_cache "\$MACHINE"'; then
    _assert_ok "cmd_init 清理 recipes cache(调 devtool_recipes_clear_cache)"
else
    _assert_bad "cmd_init 未在清理段调 devtool_recipes_clear_cache"
fi

assert_summary
