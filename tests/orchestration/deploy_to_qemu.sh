#!/usr/bin/env bash
# tests/orchestration/deploy_to_qemu.sh — cmd_deploy_to_qemu 编排 stub 测试(7 场景)。
# 锁三个不变量:
#   1. 编排顺序: build → (QEMU 在跑则 stop + 端口复用注入) → start
#   2. 端口复用: 新 .pid ssh_port == 旧 .pid ssh_port(场景② 2222==2222)
#   3. build-first: build 失败不 stop QEMU(场景③ fake_qemu 存活)
# 假 harness root = $TMP(OB_ENTRY_DIR=$TMP), detect_harness_root 算 $TMP/workspace/... 各路径。
# scaffold 组合: start_qemu_force_restart.sh(stage + 运行实例 + dynamic ss)
#   + cmd_build_bitbake_handoff.sh(build_env_enter setup + bitbake stub)
#   + qemu_execute_launch.sh(setsid/pgrep/ssh-keygen stub)。
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
sentinel="$TMP/setsid.sentinel"

# ── stage helper: initialized machine(build + qemu 环境;场景①②③④⑤⑦ 必备, ⑥ 不调) ──
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

# ── stage helper: running QEMU 实例(活进程 + .pid 含端口;场景②③④⑤ 必备) ──
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
ipmi_port=2623
serial_log=$TMP/serial.log
PF
}

# ── common stubs(7 场景共享; .calls/.rc 由 reset_between 清) ──
make_qemu_curl_fake "$DB"                 # ensure_qemu_binary 下载兜底(binary 已 staged 不触发)
mkfake_bin "$DB" ss                       # check_ports_available: 默认 exit 0 无 stdout = 端口空闲
make_pgrep_fake "$DB" 12345               # qemu_execute_launch PID 发现 → 新 .pid pid=12345
mkfake_bin "$DB" ssh-keygen               # check_ssh_hostkey_conflict: -F 无输出 → 早退 return 0
make_setsid_sentinel "$DB" "$sentinel"    # fake setsid 写 sentinel(不真启); 场景⑤ stub_exit 改 rc
# bitbake: 按参数分支(-e 兜底吐 QB_*; obmc-phosphor-image build 记录调用 + rc 控制)
mkfake_bin "$DB" bitbake
cat > "$DB/.bitbake.sh" <<'BB_SH'
case "$1" in
    -e)  # resolve_qemu_launch_profile fallback(qemuboot.conf 已 staged 不触发; 兜底)
        printf 'QB_MACHINE="-machine romulus"\nQB_MEM="-m 512"\nQB_SYSTEM_NAME="qemu-system-arm"\n'
        ;;
esac
BB_SH

# ── run_deploy: () 子 shell 跑 cmd_deploy_to_qemu, 返回 rc; 输出到 $TMP/out ──
# 继承父 shell 已 source 的 cmd_deploy_to_qemu + lib 函数; () 隔离 cd/exit 副作用。
# $1 = confirm stdin 文件(可选; 不传则 </dev/null)。
run_deploy() {
    local _in="${1:-/dev/null}"
    (
        PATH="$WS:$DB:$PATH"
        OB_ENTRY_DIR="$TMP"          # detect_harness_root 算 $TMP/workspace/...(覆盖 ob:72 的 ob 目录)
        OB_NPM_REGISTRY=             # 禁用 npm registry 解析(照 cmd_build_bitbake_handoff)
        DRY_RUN="${DRY_RUN:-0}"      # MACHINE 继承父 shell(romulus); DRY_RUN 按场景
        QEMU_NO_WAIT=1               # 跳 BMC-ready 轮询(qemu_execute_launch :169)
        cmd_deploy_to_qemu
    ) <"$_in" >"$TMP/out" 2>&1
}

# ── reset_between: 清上场景残留(进程 + .pid + 调用记录 + 失败 rc) ──
reset_between() {
    [[ -n "$fake_pid" ]] && kill "$fake_pid" 2>/dev/null
    fake_pid=""
    rm -f "$QEMU_PIDS_DIR/$MACHINE.pid" "$sentinel" \
          "$DB/.bitbake.calls" "$DB/.bitbake.rc" "$DB/.setsid.calls" "$DB/.setsid.rc"
}

# ============================================================================
# 场景 ① QEMU 没跑 + build 成功 → exit 0 + setsid sentinel + 新 .pid + 无 confirm banner
# ============================================================================
reset_between
stage_initialized_machine
DRY_RUN=0
run_deploy </dev/null; rc=$?
assert_eq "① rc=0 (no qemu + build ok)" "$rc" "0"
assert_true "① setsid sentinel written (start invoked)" test -s "$sentinel"
assert_true "① new .pid written" test -f "$QEMU_PIDS_DIR/$MACHINE.pid"
assert_false "① no confirm banner (qemu not running)" grep -q "Kill + rebuild" "$TMP/out"

# ============================================================================
# 场景 ② QEMU 在跑 + build 成功 → confirm 'y' → exit 0 + fake_qemu killed + 新 .pid ssh_port=2222(端口复用)
# ============================================================================
reset_between
stage_initialized_machine
stage_running_qemu
DRY_RUN=0
printf 'y\n' > "$TMP/yes"
run_deploy "$TMP/yes"; rc=$?
assert_eq "② rc=0 (qemu running + confirm y + build ok)" "$rc" "0"
if kill -0 "$fake_pid" 2>/dev/null; then
    assert_true "② old fake_qemu killed (stop invoked)" false
    kill "$fake_pid" 2>/dev/null
else
    assert_true "② old fake_qemu killed (stop invoked)" true
fi
# 新 .pid 由 qemu_execute_launch 写: pid=pgrep fake(12345) + ssh_port=注入的旧端口(29222)。
# 空壳不 start → .pid 还是 stage 旧 .pid(pid=$fake_pid) → pid=12345 断言 FAIL(红灯);
# ssh_port=29222 非默认(默认 2222), 锁"端口复用注入"(T3 忘注入会落默认 2222 → FAIL)。
assert_true "② new .pid by start (pid=12345, not stale fake_pid)" grep -q '^pid=12345$' "$QEMU_PIDS_DIR/$MACHINE.pid"
assert_true "② port reuse: new .pid ssh_port=29222 (injected from old)" grep -q '^ssh_port=29222$' "$QEMU_PIDS_DIR/$MACHINE.pid"

# ============================================================================
# 场景 ③ build 失败 + QEMU 在跑 → exit 1 + fake_qemu 存活(build-first) + bitbake calls=1 + setsid 未调
# ============================================================================
reset_between
stage_initialized_machine
stage_running_qemu
DRY_RUN=0
stub_exit "$DB" bitbake 1                 # build 失败
printf 'y\n' > "$TMP/yes"
run_deploy "$TMP/yes"; rc=$?              # confirm 'y'(过 confirm) → build 失败
assert_eq "③ rc=1 (build fail)" "$rc" "1"
if kill -0 "$fake_pid" 2>/dev/null; then
    assert_true "③ fake_qemu alive (build-first: build fail no stop)" true
else
    assert_true "③ fake_qemu alive (build-first: build fail no stop)" false
fi
assert_eq "③ bitbake called once" "$(wc -l < "$DB/.bitbake.calls" 2>/dev/null || echo 0)" "1"
assert_contains "③ bitbake target obmc-phosphor-image" "$(cat "$DB/.bitbake.calls" 2>/dev/null)" "obmc-phosphor-image"
assert_false "③ setsid not invoked (build-first)" test -s "$sentinel"

# ============================================================================
# 场景 ④ confirm 拒绝 'n' + QEMU 在跑 → exit 2 + fake_qemu 存活 + bitbake 未调 + setsid 未调
# ============================================================================
reset_between
stage_initialized_machine
stage_running_qemu
DRY_RUN=0
printf 'n\n' > "$TMP/no"
run_deploy "$TMP/no"; rc=$?
assert_eq "④ rc=2 (confirm rejected)" "$rc" "2"
if kill -0 "$fake_pid" 2>/dev/null; then
    assert_true "④ fake_qemu alive (confirm reject no stop)" true
else
    assert_true "④ fake_qemu alive (confirm reject no stop)" false
fi
assert_false "④ bitbake not called" test -f "$DB/.bitbake.calls"
assert_false "④ setsid not invoked" test -s "$sentinel"

# ============================================================================
# 场景 ⑤ build 成功 + setsid 失败 → exit 1 + 输出含 Image Rebuilt + 含恢复引导 ob start-qemu
# ============================================================================
reset_between
stage_initialized_machine
stage_running_qemu
DRY_RUN=0
stub_exit "$DB" setsid 1                  # qemu_execute_launch setsid 失败 → exit 1
printf 'y\n' > "$TMP/yes"
run_deploy "$TMP/yes"; rc=$?
assert_eq "⑤ rc=1 (setsid fail)" "$rc" "1"
assert_contains "⑤ Image Rebuilt stage marker" "$(cat "$TMP/out")" "Image Rebuilt"
assert_contains "⑤ recovery hint ob start-qemu" "$(cat "$TMP/out")" "ob start-qemu"

# ============================================================================
# 场景 ⑥ init-done 缺失 → exit 3 + 输出含 ob init remedy
# ============================================================================
reset_between
stage_initialized_machine
rm -f "$WS/configs/$MACHINE.init-done"    # 缺前置 init-done
DRY_RUN=0
run_deploy </dev/null; rc=$?
assert_eq "⑥ rc=3 (init-done missing)" "$rc" "3"
assert_contains "⑥ stderr hints ob init" "$(cat "$TMP/out")" "ob init"

# ============================================================================
# 场景 ⑦ DRY_RUN=1 → exit 0 + 输出含 [DRY-RUN] + bitbake/setsid 均未调
# ============================================================================
reset_between
stage_initialized_machine
DRY_RUN=1
run_deploy </dev/null; rc=$?
assert_eq "⑦ rc=0 (dry-run)" "$rc" "0"
assert_contains "⑦ [DRY-RUN] output" "$(cat "$TMP/out")" "[DRY-RUN]"
assert_false "⑦ bitbake not called" test -f "$DB/.bitbake.calls"
assert_false "⑦ setsid not invoked" test -s "$sentinel"

# ── 清理 ──
[[ -n "$fake_pid" ]] && kill "$fake_pid" 2>/dev/null
rm -rf "$TMP" "$DB"
assert_summary
