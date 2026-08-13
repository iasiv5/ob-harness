#!/usr/bin/env bash
# tests/orchestration/qemu_restart_port_reuse.sh — ADR-0021 restart 端口复用行为锁。
# 场景 B (--force 路径, 唯一可端到端测): stage running QEMU(IPMI 2624 痛点场景) + QEMU_FORCE=1 →
#   断言新 .pid ipmi_port == 2623(默认, 未注入旧 2624); 证明 --force 不触发 restart 注入(D6)。
#   单 ipmi_port==2623 断言精确捕获语义: --force 不注入 → 2623; 若误注入旧端口 → 2624 FAIL;
#   若 execute_launch 未跑 → 读到 staged 旧 .pid 的 2624 → FAIL。三态皆可区分。
# 场景 A (交互确认路径): F1 降级, 非 E2E 可测(cmd_start_qemu 交互分支带 `elif [[ -t 0 ]]` 守卫,
#   pipe/非 TTY 下恒假走 else exit 1, 到不了注入点)。覆盖转交:
#   (1) Task 2 protocol 结构锁(注入位置在 stop 后、prepare_launch 前);
#   (2) deploy_to_qemu.sh 场景②已行为级证明「注入旧端口 → 新 .pid ssh_port=旧值」链成立。
# scaffold: 复用 start_qemu_force_restart.sh 的假 harness root(OB_ENTRY_DIR=$TMP) + dynamic ss 模式。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
source "$(dirname "$0")/../lib/qemu_stubs.sh"
assert_reset

TMP="$(mktemp -d)"
DB="$(mktemp -d)"
WS="$TMP/workspace"
MACHINE="romulus"
QEMU_PIDS_DIR="$WS/qemu-bin/.pids"
DEPLOY_DIR="$WS/openbmc/build/$MACHINE/tmp/deploy/images/$MACHINE"
fake_pid=""
launch_fake_pid=""
sentinel="$TMP/setsid.sentinel"

# ── stage helper: initialized machine(复制自 deploy_to_qemu.sh L27, 不共用 lib — YAGNI) ──
stage_initialized_machine() {
    local openbmc_dir="$WS/openbmc"
    local build_dir="$openbmc_dir/build/$MACHINE"
    local configs_dir="$WS/configs"
    mkdir -p "$openbmc_dir/.git" "$build_dir" "$DEPLOY_DIR" "$configs_dir" \
             "$QEMU_PIDS_DIR" "$WS/qemu-bin/community"
    # build_env_enter(cd OPENBMC_DIR 后 source setup): setup 收 $1=machine $2=build_dir
    cat > "$openbmc_dir/setup" <<'SETUP'
#!/usr/bin/env bash
mkdir -p "$2"
cd "$2"
SETUP
    : > "$configs_dir/$MACHINE.init-done"                                     # init-done marker
    printf 'source_label=community\n' > "$configs_dir/openbmc-source.manifest" # detect_harness_root/derive_qemu_paths 读
    : > "$DEPLOY_DIR/$MACHINE.static.mtd"                                     # firmware image(machine_state_firmware_image_path find *.static.mtd)
    cat > "$DEPLOY_DIR/$MACHINE.qemuboot.conf" <<QB                           # resolve_qemu_launch_profile 从它解析(不走 bitbake -e)
[config_bsp]
qb_machine = -machine romulus
qb_mem = -m 512
qb_system_name = qemu-system-arm
QB
    printf '#!/usr/bin/env bash\necho fake-qemu\n' > "$WS/qemu-bin/community/qemu-system-arm"  # binary fast path
    chmod +x "$WS/qemu-bin/community/qemu-system-arm"
}

# ── stage helper: running QEMU 实例(ipmi_port=2624 模拟痛点场景; 复制自 deploy_to_qemu.sh L53, 改 ipmi) ──
stage_running_qemu() {
    local fake_qemu="$TMP/fake-qemu"
    printf '#!/usr/bin/env bash\nsleep 300\n' > "$fake_qemu"; chmod +x "$fake_qemu"
    "$fake_qemu" "$MACHINE" qemu-system-arm >/dev/null 2>&1 &   # cmdline 含 romulus + qemu-system-arm, 过 is_alive
    fake_pid=$!
    for _ in 1 2 3 4 5; do [[ -d "/proc/$fake_pid" ]] && break; sleep 0.1; done
    cat > "$QEMU_PIDS_DIR/$MACHINE.pid" <<PF
pid=$fake_pid
user=$(whoami)
machine=$MACHINE
binary=qemu-system-arm
started_at=2026-07-04T00:00:00Z
ssh_port=29222
redfish_port=2443
ipmi_port=2624
serial_log=$TMP/serial.log
PF
}

# ── 场景 A: 交互确认路径 — F1 降级(非 E2E 可测, -t 0 守卫), 覆盖转交 Task 2 结构锁 + deploy 场景② ──
# 不跑无效的 `printf 'y\n' | cmd_start_qemu`(交互分支 -t 0 恒假 → else exit 1, 到不了注入点)。
echo "scenario A: interactive-confirm path covered by Task 2 structure lock + deploy_to_qemu.sh scenario② (F1: -t 0 guard, not E2E testable)"

# ── 场景 B: --force 不注入(端口回默认 2623) ──
stage_initialized_machine
stage_running_qemu                # ipmi_port=2624 模拟痛点场景

# stubs: curl/bitbake 兜底(qemuboot.conf staged 后不触发); pgrep 新 .pid pid=12345;
#        ssh-keygen(F6: check_ssh_hostkey_conflict 真调 ssh-keygen, -F 无输出早退);
#        setsid 写 sentinel(不真启); dynamic ss(按 staged 存活报占用/空闲)。
make_qemu_curl_fake "$DB"
make_bitbake_env_fake "$DB"
mkfake_bin "$DB" ssh-keygen
make_setsid_sentinel "$DB" "$sentinel"
QEMU_SERIAL_LOG="$TMP/launch-serial.log"
launch_serial_sock="${QEMU_SERIAL_LOG%.log}.sock"
launch_fake="$TMP/launch-fake"
cat > "$launch_fake" <<'SH'
#!/usr/bin/env bash
exec -a "$1" sleep 300
SH
chmod +x "$launch_fake"
"$launch_fake" "$WS/qemu-bin/community/qemu-system-arm -machine romulus -machine romulus-bmc $launch_serial_sock" &
launch_fake_pid=$!
for _ in $(seq 1 50); do
    launch_cmdline="$(tr '\0' ' ' < "/proc/$launch_fake_pid/cmdline" 2>/dev/null || true)"
    [[ "$launch_cmdline" == *"$launch_serial_sock"* ]] && break
    sleep 0.1
done
make_pgrep_fake "$DB" "$launch_fake_pid"
mkfake_bin "$DB" ss
cat > "$DB/.ss.sh" <<SS
[[ -d "/proc/$fake_pid" ]] && echo "occupied by staged instance"
SS

OB_ENTRY_DIR="$TMP"               # 让 detect_harness_root 算出 $TMP/workspace/...
MACHINE=romulus
QEMU_FORCE=1
QEMU_NO_WAIT=1
PATH="$DB:$PATH"
( cmd_start_qemu romulus ) </dev/null >"$TMP/outB" 2>&1
rcB=$?

# 评审强化: 锁 --force 路径成功完成(非只靠 .pid 字段误绿)。
# rcB==0 证明路径走通到末尾; sentinel 非空证明 qemu_execute_launch 的 setsid 真被调(写了新 .pid)。
assert_eq "scenario B: --force restart exits 0 (path completed)" "$rcB" "0"
assert_true "scenario B: qemu_execute_launch invoked (setsid sentinel written)" test -s "$sentinel"

new_ipmiB="$(grep '^ipmi_port=' "$QEMU_PIDS_DIR/$MACHINE.pid" 2>/dev/null | cut -d= -f2)"
# 核心: --force 不注入旧 2624, prepare 走默认 2623(QEMU_IPMI_PORT 空 → ${QEMU_IPMI_PORT:-${OB_QEMU_IPMI_PORT:-2623}})。
assert_eq "scenario B: --force does NOT reuse old 2624 (uses default 2623)" "$new_ipmiB" "2623"

# ── 清理 ──
[[ -n "$fake_pid" ]] && kill "$fake_pid" 2>/dev/null
[[ -n "$launch_fake_pid" ]] && kill "$launch_fake_pid" 2>/dev/null
rm -rf "$TMP" "$DB"
assert_summary
