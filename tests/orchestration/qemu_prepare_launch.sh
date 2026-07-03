#!/usr/bin/env bash
# tests/orchestration/qemu_prepare_launch.sh — qemu_prepare_launch 端到端 characterization。
# 锁住 prepare 半段(Shape 2 half 1): resolve_profile→ensure_qemu_binary→ensure_qemu_firmware→
# 端口协商→check_ports_available→build_qemu_cmd,产出 QEMU_LAUNCH_*_PORT/SERIAL_* + QEMU_CMD。
# PATH-injection(stub ss/curl/bitbake),非函数 override,保 radar 诚实。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
source "$(dirname "$0")/../lib/qemu_stubs.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OB="$ROOT/ob"

TMP="$(mktemp -d)"
DB="$(mktemp -d)"

# ── fake openbmc 环境(profile qemuboot fast path)──
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$OPENBMC_DIR/build/romulus"
WORKSPACE_DIR="$TMP/workspace"
CONFIGS_DIR="$WORKSPACE_DIR/configs"
mkdir -p "$BUILD_DIR" "$CONFIGS_DIR/qemu-bin" "$WORKSPACE_DIR/qemu-bin/community"
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

# fake QEMU binary 已存在 → ensure_qemu_binary 走 fast path(不下载);无 binary manifest →
# check_jenkins_update 早退(不触 curl)。
printf '#!/usr/bin/env bash\necho fake-qemu\n' > "$WORKSPACE_DIR/qemu-bin/community/qemu-system-arm"
chmod +x "$WORKSPACE_DIR/qemu-bin/community/qemu-system-arm"

# stubs:ss 空(端口空闲)、curl(兜底)、bitbake(不应被调)
mkfake_bin "$DB" ss
make_qemu_curl_fake "$DB"
make_bitbake_env_fake "$DB"

# 跑 prepare(用 (...) 子 shell 而非 bash -c:子 shell 继承父 shell 的 xtrace → radar 可见,
# 且 prepare 的 exit 不杀父进程;非 TTY → resolve_qemu_ports_interactive 早退)
MACHINE=romulus
PATH="$DB:$PATH"
(
    qemu_prepare_launch romulus "$image_file"
    echo "RC=$?"
    echo "SOC=[$QEMU_LAUNCH_SOC_TYPE]"
    echo "MACHINE_NAME=[$QEMU_LAUNCH_MACHINE_NAME]"
    echo "SYSTEM_NAME=[$QEMU_LAUNCH_SYSTEM_NAME]"
    echo "SSH_PORT=[$QEMU_LAUNCH_SSH_PORT]"
    echo "REDFISH_PORT=[$QEMU_LAUNCH_REDFISH_PORT]"
    echo "SERIAL_LOG=[$QEMU_LAUNCH_SERIAL_LOG]"
    echo "QEMU_CMD_LEN=${#QEMU_CMD[@]}"
    echo "QEMU_CMD_0=[${QEMU_CMD[0]}]"
) > "$TMP/out" 2>&1
rc=$?
out=$(cat "$TMP/out")

assert_eq "prepare succeeds" "$rc" "0"
assert_match "profile resolved (SoC set)" "$out" 'SOC=\[[^]]'
assert_match "machine name set" "$out" 'MACHINE_NAME=\[[^]]'
assert_match "ssh port resolved" "$out" 'SSH_PORT=\[[^]]'
assert_match "serial log resolved" "$out" 'SERIAL_LOG=\[[^]]'
assert_match "QEMU_CMD assembled (len > 0)" "$out" 'QEMU_CMD_LEN=[1-9]'
assert_match "QEMU_CMD[0] is the binary" "$out" 'QEMU_CMD_0=\[[^]]'
# bitbake fast-path:不应被调(qemuboot.conf 命中)
bitbake_calls=0; [[ -f "$DB/.bitbake.calls" ]] && bitbake_calls=$(wc -l < "$DB/.bitbake.calls")
assert_eq "qemuboot fast path skips bitbake" "$bitbake_calls" "0"

rm -rf "$TMP" "$DB"
assert_summary
