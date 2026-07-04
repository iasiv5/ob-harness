#!/usr/bin/env bash
# tests/orchestration/start_qemu_force_restart.sh — F1 不变量回归锁。
# 锁住: cmd_start_qemu 的冲突 kill 必须先于 qemu_prepare_launch 的 check_ports_available。
# 顺序敏感: dynamic fake ss(按 staged 进程存活报占用/空闲)+ 真实 kill。
#  - F1 正确(冲突块在 prepare 前): kill staged → ss 见死 → 端口空闲 → 到 confirm(EOF)→ exit 1。
#  - F1 破坏(check_ports 在 kill 前): ss 见 staged 活 → exit 3。
# 故断言 rc != 3 即锁住顺序。
#
# 关键: 假 harness root = $TMP(OB_ENTRY_DIR=$TMP),让 cmd_start_qemu 首行的 detect_harness_root
# 自己算出 $TMP/workspace/... 各路径(而非覆盖成真实仓库路径),所有 staged 文件放 $TMP 下。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
source "$(dirname "$0")/../lib/qemu_stubs.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OB="$ROOT/ob"
TMP="$(mktemp -d)"
DB="$(mktemp -d)"
WS="$TMP/workspace"

# ── 在假 harness root($TMP)下 stage 全部状态(detect_harness_root 会算出这些路径)──
OPENBMC_DIR="$WS/openbmc"
BUILD_DIR="$OPENBMC_DIR/build/romulus"
CONFIGS_DIR="$WS/configs"
QEMU_PIDS_DIR="$WS/qemu-bin/.pids"
mkdir -p "$BUILD_DIR/tmp/deploy/images/romulus" "$CONFIGS_DIR" "$QEMU_PIDS_DIR" "$WS/qemu-bin/community"
: > "$OPENBMC_DIR/setup"
: > "$CONFIGS_DIR/romulus.init-done"                                   # init-done marker
printf 'source_label=community\n' > "$CONFIGS_DIR/openbmc-source.manifest"
: > "$BUILD_DIR/tmp/deploy/images/romulus/romulus.static.mtd"          # firmware image
cat > "$BUILD_DIR/tmp/deploy/images/romulus/romulus.qemuboot.conf" <<QB
[config_bsp]
qb_machine = -machine romulus
qb_mem = -m 512
qb_system_name = qemu-system-arm
QB
printf '#!/usr/bin/env bash\necho fake-qemu\n' > "$WS/qemu-bin/community/qemu-system-arm"  # binary fast path
chmod +x "$WS/qemu-bin/community/qemu-system-arm"

# ── 造"运行中"旧实例:活进程(cmdline 含 romulus + qemu-system-arm,过 validate_pid)+ PID 文件 ──
fake_qemu="$TMP/fake-qemu"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$fake_qemu"; chmod +x "$fake_qemu"
"$fake_qemu" romulus qemu-system-arm >/dev/null 2>&1 &
fake_pid=$!
for _ in 1 2 3 4 5; do [[ -d "/proc/$fake_pid" ]] && break; sleep 0.1; done
cat > "$QEMU_PIDS_DIR/romulus.pid" <<PF
pid=$fake_pid
user=$(whoami)
machine=romulus
binary=qemu-system-arm
started_at=2026-07-04T00:00:00Z
ssh_port=2222
redfish_port=2443
ipmi_port=2623
serial_log=$TMP/serial.log
PF

# ── stubs:curl/bitbake(兜底);dynamic ss(按 staged 存活报占用);kill 用真的 ──
make_qemu_curl_fake "$DB"
make_bitbake_env_fake "$DB"
mkfake_bin "$DB" ss
cat > "$DB/.ss.sh" <<SS
[[ -d "/proc/$fake_pid" ]] && echo "occupied by staged instance"
SS

OB_ENTRY_DIR="$TMP"        # 让 detect_harness_root 算出 $TMP/workspace/...
MACHINE=romulus
QEMU_FORCE=1
QEMU_NO_WAIT=1
PATH="$DB:$PATH"
( cmd_start_qemu romulus ) </dev/null >"$TMP/out" 2>&1
rc=$?

# F1 锁:不能 exit 3(那意味着 check_ports 在 kill 前跑、撞上占用端口)
assert_true "F1: --force restart did NOT exit 3 (got rc=$rc)" test "$rc" -ne 3
# staged 旧实例确被 kill(冲突块执行了 kill)
if kill -0 "$fake_pid" 2>/dev/null; then
    assert_true "staged old instance killed" false
    kill "$fake_pid" 2>/dev/null
else
    assert_true "staged old instance killed" true
fi

rm -rf "$TMP" "$DB"
assert_summary
