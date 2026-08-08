#!/usr/bin/env bash
# tests/protocol/qemu_port_reuse_surface.sh — port-reuse interface-shrink 回归锁(ADR-0022)。
# 防回潮: cmd_start_qemu / cmd_deploy_to_qemu 的端口复用必须经 resolve_qemu_port_reuse,
# 不再内联 -z guard / 无条件赋值 ritual(bestpractice_10 形态 A)。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QC="$ROOT/lib/qemu_commands.sh"
test -f "$QC" || { echo "MISSING $QC" >&2; exit 1; }

extract_fn() {  # 同 machine_resolve_surface.sh
    local file="$1" fn="$2"
    awk -v fn="$fn" '
        BEGIN { in_fn = 0 }
        $0 ~ "^" fn "[(][)] [{$]" || $0 ~ "^" fn "[(][)]$" { in_fn = 1; print; next }
        in_fn && $0 ~ "^[A-Za-z_][A-Za-z0-9_]*[(][)] [{$]" { in_fn = 0; exit }
        in_fn { print }
    ' "$file"
}

start_seg="$(extract_fn  "$QC" cmd_start_qemu)"
deploy_seg="$(extract_fn "$QC" cmd_deploy_to_qemu)"
assert_true "extracted cmd_start_qemu body"   test -n "$start_seg"
assert_true "extracted cmd_deploy_to_qemu body" test -n "$deploy_seg"

# required: 两段都恰好一次经 module(带参数形避注释干扰, 对照 machine_resolve_surface.sh)
assert_eq "cmd_start_qemu calls resolve_qemu_port_reuse"   "$(grep -Fc 'resolve_qemu_port_reuse "$PIDFILE_SSH_PORT"' <<< "$start_seg")" 1
assert_eq "cmd_deploy_to_qemu calls resolve_qemu_port_reuse" "$(grep -Fc 'resolve_qemu_port_reuse "$old_ssh_port"' <<< "$deploy_seg")" 1

# forbidden: 两段不再内联注入 ritual(赋值到 QEMU_*_PORT 的旧形态)
for pat in 'QEMU_SSH_PORT="$PIDFILE' 'QEMU_SSH_PORT="$old' 'QEMU_HTTP_PORT="$PIDFILE' 'QEMU_HTTP_PORT="$old'; do
    assert_false "cmd_start_qemu drops inline $pat"   grep -Fq "$pat" <<< "$start_seg"
    assert_false "cmd_deploy_to_qemu drops inline $pat" grep -Fq "$pat" <<< "$deploy_seg"
done

assert_summary
