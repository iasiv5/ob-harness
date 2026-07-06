#!/usr/bin/env bash
# tests/orchestration/qemu_instance_stop.sh — qemu_instance_stop orchestration。
# 锁住: kill → 等 /proc 退出 → 删 PID 文件。spawn sleep 作 fake 进程,验证真被杀 + PID 文件清除。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# Case 1: 活进程 → kill + 清 PID 文件
sleep 60 & pid1=$!
pf1="$(mktemp)"
qemu_instance_stop "$pid1" "$pf1"
assert_true "PID file removed (live process)" test ! -f "$pf1"
assert_true "process killed" test -d "/proc/$pid1" -o true   # placeholder, real check below
if kill -0 "$pid1" 2>/dev/null; then
    assert_true "process actually dead" false; kill -9 "$pid1" 2>/dev/null
else
    assert_true "process actually dead" true
fi

# Case 2: 已退出进程(无 /proc)→ 不卡、清 PID 文件(qemu_instance_stop 仍 rm)
: &
pid2=$!; wait "$pid2" 2>/dev/null   # 让它退出
pf2="$(mktemp)"
qemu_instance_stop "$pid2" "$pf2"
assert_true "PID file removed (exited process)" test ! -f "$pf2"

rm -f "$pf1" "$pf2"
assert_summary
