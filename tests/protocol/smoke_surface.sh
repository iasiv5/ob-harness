#!/usr/bin/env bash
# tests/protocol/smoke_surface.sh — ob smoke 表面/契约协议测试(probe-only)。
# 锁定: (1) smoke 在 usage Commands 段登记 + smoke Options 段 + 示例(且 verify 字样已退役);
#       (2) parse_args smoke <machine> 设 COMMAND/MACHINE(smoke 不再吞 port-override flags —
#           --ssh/redfish/ipmi-port 仍是 start-qemu/deploy-to-qemu 的全局 option, smoke 不消费);
#       (3) main smoke 真调 cmd_smoke(MACHINE 透传);
#       (4) cmd_smoke 登记在 lib/qemu_commands.sh;
#       (5) probe-only 不变量: cmd_smoke 函数体不引用 qemu_prepare_launch/qemu_execute_launch,
#           不装 EXIT trap, 调 qemu_instance_liveness(只探活实例, 绝不探死端口);
#       (6) 前置 exit 3 + 恰好一条 remedy: 无 machine arg / 无 PID file / stale PID 三路。
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# === (1) usage 登记 smoke(且 verify 已退役) ===
_usage_out="$(usage 2>/dev/null)"
assert_contains "usage Commands 含 smoke"          "$_usage_out" "smoke"
assert_contains "usage smoke 行说明 probe-only"     "$_usage_out" "Probe a running QEMU-backed BMC"
assert_contains "usage 含 smoke Options 段"         "$_usage_out" "smoke Options:"
assert_contains "usage smoke 含 OB_SMOKE_READY_ATTEMPTS" "$_usage_out" "OB_SMOKE_READY_ATTEMPTS"
assert_contains "usage 含 ob smoke 示例"            "$_usage_out" "ob smoke romulus"
# verify 命令字样退役(probe-only 重命名后不再残留)
assert_false "usage 不再登记 verify 命令行" grep -q '^  verify ' <<<"$_usage_out"
assert_false "usage 不再有 verify Options 段"      grep -q 'verify Options:' <<<"$_usage_out"

# === (2) parse_args: smoke <machine> 设 COMMAND/MACHINE ===
DEV_ARGS=(); MACHINE=""
_pm="$(parse_args smoke romulus 2>/dev/null; printf '|CMD:%s|M:%s' "$COMMAND" "$MACHINE")"
assert_contains "parse_args smoke 设 COMMAND" "$_pm" "|CMD:smoke"
assert_contains "parse_args smoke 设 MACHINE" "$_pm" "|M:romulus"

# smoke 位置参数不吞 flag(--force 不被当 machine)
DEV_ARGS=(); MACHINE=""
parse_args smoke --force >/dev/null 2>&1 || true
assert_eq "smoke 不带 machine → MACHINE 空" "$MACHINE" ""

# === (3) main smoke → cmd_smoke(MACHINE 透传) ===
# 用函数覆盖(stub)cmd_smoke, 跑 main smoke 验证 dispatch 通路。
cmd_smoke() { printf 'SMOKE_CALLED machine=%s\n' "$MACHINE"; return 0; }
_disp="$(main smoke romulus 2>/dev/null)" || true
assert_contains "main smoke 调 cmd_smoke" "$_disp" "SMOKE_CALLED machine=romulus"
# 取消 stub: 重新 source 真 cmd_smoke(覆盖 stub)。ob_loader source ob 已定义 cmd_smoke, 重 source 该 lib。
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/qemu_commands.sh"

# === (4) cmd_smoke 登记在 lib/qemu_commands.sh; verify 函数已退役 ===
QCMDS="$(cd "$(dirname "$0")/../.." && pwd)/lib/qemu_commands.sh"
assert_true  "cmd_smoke defined in qemu_commands.sh" grep -q '^cmd_smoke()' "$QCMDS"
assert_false "cmd_verify 已从 qemu_commands.sh 退役"   grep -q '^cmd_verify()' "$QCMDS"
assert_false "_verify_* 已从 qemu_commands.sh 退役"    grep -q '_verify_' "$QCMDS"
# lib 断言 module 重命名生效
SA="$(cd "$(dirname "$0")/../.." && pwd)/lib/smoke_assertions.sh"
VA="$(cd "$(dirname "$0")/../.." && pwd)/lib/verify_assertions.sh"
assert_true  "lib/smoke_assertions.sh 存在"        test -f "$SA"
assert_false "lib/verify_assertions.sh 已退役"      test -e "$VA"

# === (5) probe-only 不变量: 提取 cmd_smoke 函数体, 断言不 bring-up / 不 teardown / 探活实例 ===
# awk: 从 'cmd_smoke()' 行起打印, 到首个独占一行的 '}' 止 = 函数体。
SMOKE_BODY="$(awk '/^cmd_smoke\(\)/{g=1} g{print; if($0=="}") exit}' "$QCMDS")"
assert_false "cmd_smoke probe-only: 不引用 qemu_prepare_launch" grep -q 'qemu_prepare_launch' <<<"$SMOKE_BODY"
assert_false "cmd_smoke probe-only: 不引用 qemu_execute_launch" grep -q 'qemu_execute_launch' <<<"$SMOKE_BODY"
assert_false "cmd_smoke probe-only: 不装 EXIT trap"             grep -q 'trap ' <<<"$SMOKE_BODY"
assert_true  "cmd_smoke 调 qemu_instance_liveness(只探活实例)"  grep -q 'qemu_instance_liveness' <<<"$SMOKE_BODY"
assert_true  "cmd_smoke 读 PIDFILE_SSH_PORT(端口来自实例)"        grep -q 'PIDFILE_SSH_PORT' <<<"$SMOKE_BODY"

# === (6) 前置 exit 3 + remedy: 三路(无 machine / 无 PID / stale PID) ===
# 子进程 helper: 造 tmp workspace, source ob, 覆盖 detect_harness_root 指向 tmp, 跑 cmd_smoke。
# 用法: _run_smoke_in_tmp <tmp> <machine_or_empty> <pid_file_content_or_empty>
_run_smoke_in_tmp() {
    local tmp="$1" machine="$2" pid_content="$3"
    (
        OB_NO_MAIN=1 source "$OB"; set +e
        detect_harness_root() {
            HARNESS_ROOT="$tmp"; WORKSPACE_DIR="$HARNESS_ROOT/workspace"
            OPENBMC_DIR="$WORKSPACE_DIR/openbmc"; BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
            SRC_DIR="$WORKSPACE_DIR/src/$MACHINE"; CONFIGS_DIR="$WORKSPACE_DIR/configs"
            SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
            QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
            QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
        }
        mkdir -p "$tmp/workspace/qemu-bin/.pids"
        [[ -n "$pid_content" ]] && printf '%s' "$pid_content" > "$tmp/workspace/qemu-bin/.pids/${machine}.pid"
        MACHINE="$machine"
        detect_harness_root
        cmd_smoke
    )
}

# (6a) 无 machine arg → exit 3 + remedy "Specify a machine"
_tmp="$(mktemp -d)"; _rc=0; _out=$(_run_smoke_in_tmp "$_tmp" "" "" 2>&1) || _rc=$?
rm -rf "$_tmp"
assert_eq "no machine arg → exit 3" "$_rc" "3"
assert_contains "no machine remedy 提示 ob smoke" "$_out" "ob smoke <machine>"

# (6b) machine 给定, 无 PID file → exit 3 + remedy "Run 'ob start-qemu'"
_tmp="$(mktemp -d)"; _rc=0; _out=$(_run_smoke_in_tmp "$_tmp" "romulus" "" 2>&1) || _rc=$?
rm -rf "$_tmp"
assert_eq "no PID file → exit 3" "$_rc" "3"
assert_contains "no PID remedy 提示 start-qemu" "$_out" "ob start-qemu"

# (6c) stale PID file(进程已退出)→ clean_stale + exit 3 + 同 remedy
#   PID 999999 几乎必然无 /proc 条目 → qemu_instance_liveness = exited → NOT running → 清理 + exit 3。
_stale_pid_content="pid=999999
user=test
machine=romulus
binary=/fake/qemu
started_at=now
ssh_port=2222
redfish_port=2443
ipmi_port=2623
"
_tmp="$(mktemp -d)"; _rc=0; _out=$(_run_smoke_in_tmp "$_tmp" "romulus" "$_stale_pid_content" 2>&1) || _rc=$?
# stale 路径应删掉 PID 文件(qemu_instance_clean_stale)
_stale_file_gone=0; [[ ! -f "$_tmp/workspace/qemu-bin/.pids/romulus.pid" ]] && _stale_file_gone=1
rm -rf "$_tmp"
assert_eq "stale PID → exit 3" "$_rc" "3"
assert_contains "stale PID remedy 提示 start-qemu" "$_out" "ob start-qemu"
assert_eq  "stale PID file 被 clean_stale 删除" "$_stale_file_gone" "1"

assert_summary
