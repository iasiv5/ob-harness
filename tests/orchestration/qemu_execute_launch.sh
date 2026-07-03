#!/usr/bin/env bash
# tests/orchestration/qemu_execute_launch.sh — qemu_execute_launch smoke。
# 锁住 execute 半段(Shape 2 half 2): 先 prepare 填好 QEMU_LAUNCH_*/QEMU_CMD,再 execute
# → setsid 启动(fake sentinel 不真启)+ PID 文件写入 + hostkey 检测(无 known_hosts→早退)。
# QEMU_NO_WAIT=1 跳 BMC-ready 轮询。prepare+execute 同 (...) 子 shell 共享全局。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
source "$(dirname "$0")/../lib/qemu_stubs.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OB="$ROOT/ob"
TMP="$(mktemp -d)"
DB="$(mktemp -d)"

# ── fake openbmc 环境(同 prepare 测试)──
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$OPENBMC_DIR/build/romulus"
WORKSPACE_DIR="$TMP/workspace"
CONFIGS_DIR="$WORKSPACE_DIR/configs"
QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
mkdir -p "$BUILD_DIR" "$CONFIGS_DIR" "$QEMU_PIDS_DIR" "$WORKSPACE_DIR/qemu-bin/community"
: > "$OPENBMC_DIR/setup"
cat > "$CONFIGS_DIR/openbmc-source.manifest" <<MS
source_label=community
MS
deploy_dir="$BUILD_DIR/tmp/deploy/images/romulus"
mkdir -p "$deploy_dir"
cat > "$deploy_dir/romulus.qemuboot.conf" <<QB
[config_bsp]
qb_machine = -machine romulus
qb_mem = -m 512
qb_system_name = qemu-system-arm
QB
image_file="$deploy_dir/obmc-phosphor-image-romulus.static.mtd"
: > "$image_file"
printf '#!/usr/bin/env bash\necho fake-qemu\n' > "$WORKSPACE_DIR/qemu-bin/community/qemu-system-arm"
chmod +x "$WORKSPACE_DIR/qemu-bin/community/qemu-system-arm"

# ── stubs:ss/curl/bitbake(prepare 用)+ setsid(sentinel)+ pgrep(假 PID)+ ssh-keygen(空→hostkey 早退)──
mkfake_bin "$DB" ss
make_qemu_curl_fake "$DB"
make_bitbake_env_fake "$DB"
sentinel="$TMP/setsid.sentinel"
make_setsid_sentinel "$DB" "$sentinel"
make_pgrep_fake "$DB" 12345
mkfake_bin "$DB" ssh-keygen

MACHINE=romulus
QEMU_NO_WAIT=1
PATH="$DB:$PATH"
# prepare + execute 同子 shell(共享 QEMU_LAUNCH_*/QEMU_CMD 全局)
(
    qemu_prepare_launch romulus "$image_file"
    qemu_execute_launch
) > "$TMP/out" 2>&1
rc=$?

assert_eq "execute pipeline succeeds" "$rc" "0"
# setsid 收到装配好的 QEMU_CMD(含 binary 路径)
assert_true "setsid invoked (sentinel written)" test -s "$sentinel"
assert_contains "sentinel has binary path" "$(cat "$sentinel")" "qemu-system-arm"
# PID 文件写入,字段正确
pid_file="$QEMU_PIDS_DIR/romulus.pid"
assert_true "PID file written" test -f "$pid_file"
assert_contains "PID file has fake pid" "$(cat "$pid_file")" "pid=12345"
assert_contains "PID file has machine" "$(cat "$pid_file")" "machine=romulus"
# summary 触发
assert_contains "summary printed" "$(cat "$TMP/out")" "QEMU started for 'romulus'"

rm -rf "$TMP" "$DB"
assert_summary
