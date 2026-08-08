#!/usr/bin/env bash
# tests/protocol/qemu_restart_port_reuse.sh — restart 端口沿用结构锁(ADR-0021 机制 / 0022 module 化)。
# 锁四个维度(评审强化: 经 module 注入 + 精确落点 + 分支独占):
#   1. 交互确认分支(confirm_seg)经 resolve_qemu_port_reuse 注入(全端口, module 内部 cli_first + HTTP none)
#   2. start 段恰好一处 module 调用(防别处重复注入)
#   3. --force 分支不注入(不调 module)
#   4. stale 清理分支不注入(不调 module)
# 注入仅服务交互确认 restart 分支(D4/D6); module 内部 cli_first 保 CLI flag 优先(X-α, ADR-0022)。
# 交互路径不可 E2E(-t 0 守卫), protocol 是主防线 → 经 module 调用落点断言, 防删 module 调用测试仍绿。
# 形态对照 machine_resolve_surface.sh: sed 切函数段 + assert_true/false grep + 带参数形避注释干扰。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

QC="$(cd "$(dirname "$0")/../.." && pwd)/lib/qemu_commands.sh"
test -f "$QC" || { echo "MISSING $QC" >&2; exit 1; }
start_seg="$(sed -n '/^cmd_start_qemu()/,/^cmd_stop_qemu()/p' "$QC")"

# 交互确认分支(kill-and-restart): 从 `elif [[ -t 0 ]]` 到 `else`(非TTY 分支)。
# 限定 elif 排除 safety-confirmation 块的 `if [[ -t 0 ]]`(同类守卫, 非注入点)。
# 注入须落此段内(stop 后、prepare_launch 前, F1 顺序不变量)。
confirm_seg="$(sed -n '/elif \[\[ -t 0 \]\]/,/^            else$/p' <<< "$start_seg")"
assert_true "confirm_seg non-empty (interactive kill-and-restart branch located)" test -n "$confirm_seg"

# 1. 交互确认分支经 module 注入(全端口, module 内部 cli_first + HTTP none)
assert_true "confirm branch calls resolve_qemu_port_reuse" \
    grep -Fq 'resolve_qemu_port_reuse "$PIDFILE_SSH_PORT"' <<< "$confirm_seg"
# 2. start 段恰好一处 module 调用(防别处重复; 带参数形避注释干扰, 对照 machine_resolve_surface.sh)
assert_eq "resolve_qemu_port_reuse called once in cmd_start_qemu" \
    "$(grep -Fc 'resolve_qemu_port_reuse "$PIDFILE_SSH_PORT"' <<< "$start_seg")" 1

# 3. --force 分支不注入(不调 module)
force_seg="$(sed -n '/QEMU_FORCE.*-eq 1/,/^            elif/p' <<< "$start_seg")"
assert_true "force_seg non-empty (F2 final: BRE .* matches real double-quote code)" test -n "$force_seg"
assert_false "--force branch calls NO resolve_qemu_port_reuse" \
    grep -Fq 'resolve_qemu_port_reuse' <<< "$force_seg"

# 4. stale 清理分支不注入(不调 module)
stale_seg="$(awk '/qemu_instance_clean_stale/{g=1} g{print; if(/fi[[:space:]]*$/) exit}' <<< "$start_seg")"
assert_false "stale-cleanup branch calls NO resolve_qemu_port_reuse" \
    grep -Fq 'resolve_qemu_port_reuse' <<< "$stale_seg"

assert_summary
