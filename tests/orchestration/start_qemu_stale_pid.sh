#!/usr/bin/env bash
# tests/orchestration/start_qemu_stale_pid.sh — cmd_start_qemu stale .pid set -e 回归锁。
# 锁住: stale .pid(进程不存在) → is_alive return 1 → 必须 if 包裹走 clean_stale, 不能 set -e abort。
# 既有债背景: cmd_start_qemu:491 原裸调 + $? 读, set -euo 下死实例 return 1 会 abort(实测
#   `set -e; f(){return 1;}; f; echo`→exit), clean_stale 走不到, 用户遇 stale .pid(ctrl+c/OOM/重启)
#   只见非零退出无 hint, 须手 rm .pid 恢复。本测试照 cmd_deploy_to_qemu:733 if 包裹模式修复后回归锁。
# 关键设计(评审要点): source ob(OB_NO_MAIN) 保留 ob:4 set -euo——不经 ob_loader 的 set +e,
#   否则 set -e 债被掩盖; () 子 shell 隔离 cmd_start_qemu 的 abort(rc 捕获, 父 shell 断言)。
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
source "$(dirname "$0")/../lib/qemu_stubs.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
DB="$(mktemp -d)"
WS="$TMP/workspace"
MACHINE="romulus"
QEMU_PIDS_DIR="$WS/qemu-bin/.pids"
DEPLOY_DIR="$WS/openbmc/build/$MACHINE/tmp/deploy/images/$MACHINE"

# stage initialized machine + binary + qemuboot.conf(让 stale 清理后的 prepare_launch 能走到 confirm)
mkdir -p "$DEPLOY_DIR" "$WS/configs" "$QEMU_PIDS_DIR" "$WS/qemu-bin/community"
: > "$WS/configs/$MACHINE.init-done"
printf 'source_label=community\n' > "$WS/configs/openbmc-source.manifest"
: > "$DEPLOY_DIR/$MACHINE.static.mtd"
cat > "$DEPLOY_DIR/$MACHINE.qemuboot.conf" <<QB
[config_bsp]
qb_machine = -machine romulus
qb_mem = -m 512
qb_system_name = qemu-system-arm
QB
printf '#!/usr/bin/env bash\necho fake-qemu\n' > "$WS/qemu-bin/community/qemu-system-arm"
chmod +x "$WS/qemu-bin/community/qemu-system-arm"
# stale .pid: pid=99999 进程不存在 → is_alive return 1(exited)
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

# stubs(让 prepare_launch 过到 confirm; stale 清理在 confirm 前, 是本测试断言对象)
make_qemu_curl_fake "$DB"
mkfake_bin "$DB" ss
mkfake_bin "$DB" ssh-keygen

# source ob 保留 set -euo(不经 ob_loader set +e)——暴露 set -e 债的关键
set -euo pipefail
OB_NO_MAIN=1 source "$ROOT/ob"
OB_ENTRY_DIR="$TMP"   # 覆盖 ob:72, 指向假 workspace
MACHINE="romulus"      # 覆盖 ob:10(source ob 会把 MACHINE 重置为空), 否则 cmd 走 resolve machine 非 TTY exit 3
PATH="$DB:$PATH" OB_NPM_REGISTRY= QEMU_NO_WAIT=1

# () 子 shell 跑 cmd_start_qemu; || rc=$? 防 set -e(() return 非0 不 abort 父, rc 捕获); </dev/null 非 TTY
rc=0; ( cmd_start_qemu ) </dev/null >"$TMP/out" 2>&1 || rc=$?

# 回归锁: stale .pid(进程不存在) 必须被 clean_stale 清理(.pid rm)——验证 stale 清理功能。
assert_true "start-qemu stale .pid cleaned (clean_stale ran)" test ! -f "$QEMU_PIDS_DIR/$MACHINE.pid"

rm -rf "$TMP" "$DB"
assert_summary
