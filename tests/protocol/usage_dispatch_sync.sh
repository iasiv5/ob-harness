#!/usr/bin/env bash
# tests/protocol/usage_dispatch_sync.sh — 防漂移闸。
# 断言 ob 的 usage() Commands 段子命令集合 == dispatch `case "$COMMAND"` 子命令集合。
# 随 ob 增长(如未来 ob dev)自动拦截"加了子命令却忘了更新 --help"或反向的漂移。
# OB_FILE 可覆盖被测 ob 路径(漂移演示用);默认仓库根 ob。
set -uo pipefail

source "$(dirname "$0")/../lib/assert.sh"
assert_reset

OBF="${OB_FILE:-$(cd "$(dirname "$0")/../.." && pwd)/ob}"

if [[ ! -f "$OBF" ]]; then
    _assert_bad "ob file not found: $OBF"
    assert_summary
    exit
fi

# (a) dispatch 子命令:case "$COMMAND" in ... esac 之间的 <cmd>) 标签(排除 *)
dispatch=$(awk '
    /case "\$COMMAND" in/ { in_block=1; next }
    in_block && /^[[:space:]]*esac/ { exit }
    in_block && /^[[:space:]]*[a-z][a-z-]*\)/ {
        gsub(/[[:space:]]/, ""); sub(/\).*/, ""); print
    }
' "$OBF" | sort -u)

# (b) usage() Commands 段命令名:Commands: 与下一个空行之间每行首 token
usage_cmds=$(awk '
    /^Commands:/ { in_block=1; next }
    in_block && /^[[:space:]]*$/ { exit }
    in_block { print $1 }
' "$OBF" | sort -u)

only_dispatch=$(comm -23 <(printf '%s\n' "$dispatch") <(printf '%s\n' "$usage_cmds"))
only_usage=$(comm -13 <(printf '%s\n' "$dispatch") <(printf '%s\n' "$usage_cmds"))

if [[ -z "$only_dispatch" && -z "$only_usage" ]]; then
    _assert_ok "usage() Commands == dispatch 子命令集合 ($(echo "$dispatch" | tr '\n' ' '))"
else
    [[ -n "$only_dispatch" ]] && _assert_bad "dispatch 有但 --help 缺: $(echo "$only_dispatch" | tr '\n' ' ')"
    [[ -n "$only_usage" ]] && _assert_bad "--help 有但 dispatch 缺: $(echo "$only_usage" | tr '\n' ' ')"
fi

assert_summary
