#!/usr/bin/env bash
# tests/protocol/qemu_restart_port_reuse.sh — ADR-0021 restart 端口沿用结构锁。
# 锁三个维度(评审强化: 全端口 + HTTP none + 精确落点 + 全端口反例, 非 SSH-only):
#   1. 交互确认分支(confirm_seg)四端口 -z guard 注入(SSH/Redfish/IPMI/HTTP 同构; HTTP 排除 none)
#   2. --force 分支不注入任何端口(全端口反例)
#   3. stale 清理分支不注入任何端口
# 注入仅服务交互确认 restart 分支(D4/D6); -z guard 保 CLI flag 优先(X-α)。
# 交互路径不可 E2E(-t 0 守卫), protocol 是主防线 → 逐端口断言, 防删 IPMI 痛点行测试仍绿。
# 形态对照 qemu_commands_guard_surface.sh: sed 切函数段 + assert_true/false grep 模式。
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

# 1. 交互确认分支四端口 -z guard 注入(全端口, 非 SSH-only; HTTP 额外判 PIDFILE_HTTP_PORT != none)
assert_true "interactive injects SSH (-z guard)" \
    grep -Fq '[[ -z "$QEMU_SSH_PORT" ]]    && QEMU_SSH_PORT="$PIDFILE_SSH_PORT"' <<< "$confirm_seg"
assert_true "interactive injects Redfish (-z guard)" \
    grep -Fq '[[ -z "$QEMU_REDFISH_PORT" ]] && QEMU_REDFISH_PORT="$PIDFILE_REDFISH_PORT"' <<< "$confirm_seg"
assert_true "interactive injects IPMI (-z guard, 痛点端口 2624 复用)" \
    grep -Fq '[[ -z "$QEMU_IPMI_PORT" ]]   && QEMU_IPMI_PORT="$PIDFILE_IPMI_PORT"' <<< "$confirm_seg"
assert_true "interactive injects HTTP with none guard (PIDFILE_HTTP_PORT != none)" \
    grep -Fq '[[ -n "$PIDFILE_HTTP_PORT" && "$PIDFILE_HTTP_PORT" != "none" && -z "$QEMU_HTTP_PORT" ]]' <<< "$confirm_seg"

# 2. 注入块在 cmd_start_qemu 恰好一处(SSH guard 计数锁, 防止在别处重复注入)
guard_count=$(grep -Fc '[[ -z "$QEMU_SSH_PORT" ]]' <<< "$start_seg")
assert_eq "guard block appears exactly once in cmd_start_qemu (no duplicate injection)" "$guard_count" "1"

# 3. --force 分支不注入任何端口(全端口反例; F2: BRE .* 容真实双引号代码 `[[ "$QEMU_FORCE" -eq 1 ]]`)
force_seg="$(sed -n '/QEMU_FORCE.*-eq 1/,/^            elif/p' <<< "$start_seg")"
assert_true "force_seg non-empty (F2 final: BRE .* matches real double-quote code)" test -n "$force_seg"
assert_false "--force branch injects NO port (SSH/Redfish/IPMI/HTTP all absent)" \
    grep -Eq 'QEMU_(SSH|REDFISH|IPMI|HTTP)_PORT="\$PIDFILE' <<< "$force_seg"

# 4. stale 清理分支不注入任何端口
stale_seg="$(awk '/qemu_instance_clean_stale/{g=1} g{print; if(/fi[[:space:]]*$/) exit}' <<< "$start_seg")"
assert_false "stale-cleanup branch injects NO port" \
    grep -Eq 'QEMU_(SSH|REDFISH|IPMI|HTTP)_PORT="\$PIDFILE' <<< "$stale_seg"

assert_summary
