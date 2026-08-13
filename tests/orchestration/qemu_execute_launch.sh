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
mkfake_bin "$DB" pgrep
mkfake_bin "$DB" ssh-keygen

QEMU_SERIAL_LOG="$TMP/launch-serial.log"
fake_daemon="$TMP/fake-daemon"
cat > "$fake_daemon" <<'SH'
#!/usr/bin/env bash
exec -a "$1" sleep 300
SH
chmod +x "$fake_daemon"
fake_daemon_pid=""

MACHINE=romulus
QEMU_NO_WAIT=1
PATH="$DB:$PATH"
# prepare + execute 同子 shell(共享 QEMU_LAUNCH_*/QEMU_CMD 全局)
(
    qemu_prepare_launch romulus "$image_file"
    "$fake_daemon" "$QEMU_BIN_FILE -machine $QEMU_LAUNCH_MACHINE_NAME $QEMU_LAUNCH_SERIAL_SOCK" &
    fake_pid=$!
    printf '%s\n' "$fake_pid" > "$TMP/fake-daemon.pid"
    for _ in $(seq 1 50); do
        fake_cmdline="$(tr '\0' ' ' < "/proc/$fake_pid/cmdline" 2>/dev/null || true)"
        [[ "$fake_cmdline" == *"$QEMU_LAUNCH_SERIAL_SOCK"* ]] && break
        sleep 0.1
    done
    stub_out "$DB" pgrep "$fake_pid"
    precheck_rc=0
    _qemu_instance_probe_alive "$fake_pid" "$QEMU_BIN_FILE" \
        "$QEMU_LAUNCH_MACHINE_NAME" "" "$QEMU_LAUNCH_SERIAL_SOCK" || precheck_rc=$?
    printf 'rc=%s\nbinary=%s\nmachine=%s\nsock=%s\ncmdline=%s\n' \
        "$precheck_rc" "$QEMU_BIN_FILE" "$QEMU_LAUNCH_MACHINE_NAME" \
        "$QEMU_LAUNCH_SERIAL_SOCK" "$fake_cmdline" > "$TMP/identity-precheck"
    qemu_execute_launch
) > "$TMP/out" 2>&1
rc=$?
fake_daemon_pid="$(cat "$TMP/fake-daemon.pid")"
identity_precheck="$(cat "$TMP/identity-precheck")"
assert_contains "fake daemon identity precheck passes" "$identity_precheck" "rc=0"

assert_eq "execute pipeline succeeds" "$rc" "0"
# setsid 收到装配好的 QEMU_CMD(含 binary 路径)
assert_true "setsid invoked (sentinel written)" test -s "$sentinel"
assert_contains "sentinel has binary path" "$(cat "$sentinel")" "qemu-system-arm"
# PID 文件写入,字段正确
pid_file="$QEMU_PIDS_DIR/romulus.pid"
assert_true "PID file written" test -f "$pid_file"
assert_contains "PID file has fake pid" "$(cat "$pid_file")" "pid=$fake_daemon_pid"
assert_contains "PID file has machine" "$(cat "$pid_file")" "machine=romulus"
assert_true "PID file has process generation" grep -q '^process_start_ticks=[0-9][0-9]*$' "$pid_file"
assert_contains "PID file has serial socket" "$(cat "$pid_file")" "serial_sock=$TMP/launch-serial.sock"
# summary 触发
assert_contains "summary printed" "$(cat "$TMP/out")" "QEMU started for 'romulus'"

# setsid success without a discoverable daemon PID is an ownership failure:
# no harness manifest may be published as a successful instance.
stub_out "$DB" pgrep ""
mkfake_bin "$DB" pkill
kill "$fake_daemon_pid" 2>/dev/null || true
wait "$fake_daemon_pid" 2>/dev/null || true
rm -f "$pid_file"
no_pid_rc=0
(
    qemu_prepare_launch romulus "$image_file"
    qemu_execute_launch
) > "$TMP/no-pid.out" 2>&1 || no_pid_rc=$?
assert_eq "missing daemon PID fails launch" "$no_pid_rc" "1"
assert_false "missing daemon PID publishes no manifest" test -f "$pid_file"
leftover_manifest="$(find "$QEMU_PIDS_DIR" -maxdepth 1 -name '.romulus.pid.*' -print -quit)"
assert_eq "missing daemon PID leaves no temp manifest" "$leftover_manifest" ""
assert_true "missing daemon PID prints ownership diagnostic" \
    grep -q "daemon PID could not be resolved" "$TMP/no-pid.out"

rm -rf "$TMP" "$DB"
assert_summary
