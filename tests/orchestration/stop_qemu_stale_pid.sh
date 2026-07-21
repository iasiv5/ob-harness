#!/usr/bin/env bash
# tests/orchestration/stop_qemu_stale_pid.sh — cmd_stop_qemu stale .pid set -e 回归锁。
# 锁住: stale .pid(进程不存在) → is_alive return 1 → || pid_status=$? 保留 0/1/2 + clean_stale, 不能 set -e abort。
# 既有债背景: cmd_stop_qemu:622 原裸调 + $? 读, set -euo 下死实例 return 1 abort, clean_stale(:636)走不到。
#   cmd_stop_qemu 需区分 0/1/2(DRY_RUN case + exited/recycled 分支), 故用 `|| pid_status=$?`(非 if 包裹)。
# 关键设计(评审要点): source ob(OB_NO_MAIN) 保留 ob:4 set -euo——不经 ob_loader 的 set +e;
#   () 子 shell 隔离 cmd_stop_qemu 的 abort(rc 捕获, 父 shell 断言)。
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
source "$(dirname "$0")/../lib/qemu_stubs.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
WS="$TMP/workspace"
MACHINE="romulus"
QEMU_PIDS_DIR="$WS/qemu-bin/.pids"

# stage stale .pid(pid=99999 进程不存在 → is_alive return 1); cmd_stop_qemu 不 prepare_launch, 无需 binary/qemuboot.conf
mkdir -p "$WS/configs" "$QEMU_PIDS_DIR"
: > "$WS/configs/$MACHINE.init-done"
cat > "$QEMU_PIDS_DIR/$MACHINE.pid" <<PF
pid=99999
user=$(whoami)
machine=$MACHINE
binary=qemu-system-arm
started_at=2026-07-04T00:00:00Z
ssh_port=2222
redfish_port=2443
ipmi_port=2623
serial_log=$TMP/serial.log
PF

# source ob 保留 set -euo(不经 ob_loader set +e)——暴露 set -e 债的关键
set -euo pipefail
OB_NO_MAIN=1 source "$ROOT/ob"
OB_ENTRY_DIR="$TMP"   # 覆盖 ob:72, 指向假 workspace
MACHINE="romulus"      # 覆盖 ob:10(source ob 会把 MACHINE 重置为空), 否则 cmd 走 resolve machine 非 TTY exit 3

# () 子 shell 跑 cmd_stop_qemu(stale pid_status=1 → :636 clean_stale + continue); || rc=$? 防 set -e
rc=0; ( cmd_stop_qemu ) </dev/null >"$TMP/out" 2>&1 || rc=$?

# 回归锁: stale .pid(进程不存在) 必须被 clean_stale 清理(.pid rm)——验证 stale 清理功能。
assert_true "stop-qemu stale .pid cleaned (clean_stale ran)" test ! -f "$QEMU_PIDS_DIR/$MACHINE.pid"

rm -rf "$TMP"
assert_summary
