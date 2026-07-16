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

# === ob dev 专属: DEV_ARGS 交接/重置 + OB_NO_MAIN 真实 dispatch + porcelain(show_logo 跳过) ===
OB_NO_MAIN=1 source "$OBF" >/dev/null 2>&1
set +e
detect_harness_root() { return 0; }   # 避免测试环境副作用

# DEV_ARGS 交接 + 重置
parse_args build romulus
assert_eq "DEV_ARGS build 后为空(build 不设)" "${#DEV_ARGS[@]}" "0"
parse_args dev --machine m list
assert_eq "DEV_ARGS[0]=--machine" "${DEV_ARGS[0]}" "--machine"
assert_eq "DEV_ARGS[1]=m" "${DEV_ARGS[1]}" "m"
assert_eq "DEV_ARGS[2]=list" "${DEV_ARGS[2]}" "list"
assert_eq "DEV_ARGS 恰好 3 元素(不含 dev)" "${#DEV_ARGS[@]}" "3"

# OB_NO_MAIN 真实 dispatch + 参数: main dev --machine m list → cmd_dev 收到恰好 --machine m list
cmd_dev() { printf 'GOT:%s\n' "$@"; return 0; }
main_out=$(main dev --machine m list 2>/dev/null)
assert_contains "main dev 调 cmd_dev(含 --machine)" "$main_out" "GOT:--machine"
assert_contains "main dev 调 cmd_dev(含 list)" "$main_out" "GOT:list"
assert_false "main dev 不把 dev 字面传给 cmd_dev" grep -q "GOT:dev" <<<"$main_out"

# porcelain: ob dev dispatch 在 show_logo 前 → 不调 show_logo
_logo_called=0
show_logo() { _logo_called=1; }
cmd_dev() { return 0; }
main dev --machine m list >/dev/null 2>&1
assert_eq "ob dev 跳过 show_logo(porcelain)" "$_logo_called" "0"

# === ob dev reset 登记: usage 含 reset(不含 --remove-work) + DEV_ARGS 交接 + 真实 dispatch ===
_usage_out="$(usage 2>/dev/null)"
assert_contains "usage dev 行含 reset" "$_usage_out" "reset"
assert_false "usage 不含 --remove-work(本轮未实现)" grep -q -- "--remove-work" <<<"$_usage_out"

parse_args dev --machine m reset myrecipe
assert_eq "DEV_ARGS reset [2]=reset" "${DEV_ARGS[2]}" "reset"
assert_eq "DEV_ARGS reset [3]=myrecipe" "${DEV_ARGS[3]}" "myrecipe"

# main dev reset → cmd_dev 收到恰好 --machine m reset myrecipe(重设 cmd_dev 捕获)
cmd_dev() { printf 'GOT:%s\n' "$@"; return 0; }
_dispatch_out="$(main dev --machine m reset myrecipe 2>/dev/null)"
assert_contains "main dev reset 调 cmd_dev(reset)" "$_dispatch_out" "GOT:reset"
assert_contains "main dev reset 调 cmd_dev(recipe)" "$_dispatch_out" "GOT:myrecipe"

# === ob dev status 登记: usage dev 行含 status(锚定 dev 行枚举, 避开顶层 status 命令) + DEV_ARGS 交接 + 真实 dispatch ===
_usage_out2="$(usage 2>/dev/null)"
assert_contains "usage dev 行枚举含 status" "$_usage_out2" "refresh|reset|status"

parse_args dev --machine m status
assert_eq "DEV_ARGS status [2]=status" "${DEV_ARGS[2]}" "status"
assert_eq "DEV_ARGS status 恰好 3 元素" "${#DEV_ARGS[@]}" "3"

cmd_dev() { printf 'GOT:%s\n' "$@"; return 0; }
_dispatch_out2="$(main dev --machine m status 2>/dev/null)"
assert_contains "main dev status 调 cmd_dev(status)" "$_dispatch_out2" "GOT:status"
assert_false "main dev status 不把 dev 字面传给 cmd_dev" grep -q "GOT:dev" <<<"$_dispatch_out2"

assert_summary
