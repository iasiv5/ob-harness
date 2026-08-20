#!/usr/bin/env bash
# tests/unit/machine_resolve.sh — resolve_command_machine 单测(unit 层)。
# 覆盖 command machine resolution 7 态(function-override stub,不依赖 PTY/workspace):
#   ① given+init            → 0  (给定 machine 已 initialized, 快路径直通)
#   ② given+noinit          → 3  (verify remedy, stderr)
#   ③ empty+ok              → 0  (交互 pick 选号, 设全局 $MACHINE)
#   ④ empty+empty           → 3  (empty remedy, stderr)
#   ⑤ empty+ok+pick-read-fail → 1 (无 cancel warn)
#   ⑥ nontty                → 3  (nontty_remedy, stderr)
#   ⑦ cancel                → 2  (warn "<verb> cancelled by user.", stdout)
# mock 策略: source ob_loader 后覆盖 machine_state_is_initialized/machine_selection_guard/pick_machine
#   为同 shell 函数(pick_machine 设全局 $MACHINE + return MOCK rc;guard 经 printf -v 写 outvar)。
#   不可用 PATH executable——子进程回传不了 $MACHINE/outvar(对照 init_intake.sh:22-25)。
# 输出通道: remedy 走 error→stderr、cancel warn 走 warn→stdout(util.sh:12 error 带 >&2 / :10 warn 无);
#   按通道分别捕获——cancel 态断 stdout, remedy 态断 stderr, 勿统一捕 stderr 否则 cancel 态假失败。
# pick_stream=stderr(dev 路径)重定向由 Task 3 cmd_dev porcelain 测试覆盖, 本测统一 stdout。
# leaf-pure: resolve_command_machine return 0/1/2/3(不 exit); exit_contract Y 静态守卫。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
_err="$TMP/err"
_out="$TMP/out"
rc=0

# assert.sh 无 not-contains;镜像 assert_contains 补一个。
assert_not_contains(){ local l="$1" h="$2" n="$3"; [[ "$h" != *"$n"* ]] && _assert_ok "$l" || _assert_bad "$l (unexpectedly contains '$n')"; }

_verb="Build"
_nontty="No machine specified and no interactive terminal. Run './ob status' to list initialized machines. Specify a machine: ./ob build <machine>"

# mock 依赖(resolve_command_machine 消费的原语): 覆盖 ob_loader source 的同名函数。
machine_state_is_initialized(){ return "${MOCK_INIT_RC:-0}"; }
machine_selection_guard(){ local _l="$1"; printf -v "$2" '%s' "${MOCK_GUARD_STAT:-ok}"; return 0; }
pick_machine(){ MACHINE="${MOCK_PICK_RESULT:-}"; return "${MOCK_PICK_RC:-0}"; }

# ① given+init: 给定 machine 已 initialized → 0
MACHINE="romulus"; MOCK_INIT_RC=0; MOCK_GUARD_STAT=ok; MOCK_PICK_RC=99; MOCK_PICK_RESULT=""; rc=0
resolve_command_machine machine_state_initialized_machines "$_verb" stdout "$_nontty" 2>"$_err" >"$_out" || rc=$?
assert_eq "① given+init rc=0" "$rc" "0"
assert_eq "① given+init keep MACHINE" "$MACHINE" "romulus"

# ② given+noinit: 给定 machine 未 initialized → 3 + verify remedy(stderr)
MACHINE="romulus"; MOCK_INIT_RC=1; MOCK_GUARD_STAT=ok; MOCK_PICK_RC=99; MOCK_PICK_RESULT=""; rc=0
resolve_command_machine machine_state_initialized_machines "$_verb" stdout "$_nontty" 2>"$_err" >"$_out" || rc=$?
assert_eq "② given+noinit rc=3" "$rc" "3"
assert_contains "② verify remedy is not initialized" "$(cat "$_err")" "is not initialized"
assert_contains "② verify remedy init hint" "$(cat "$_err")" "Run './ob init romulus' first."

# ③ empty+ok: 交互选号 → 0 + 设 $MACHINE。MOCK_INIT_RC=1 故意置 1 证 empty+ok 路径不查 is_initialized
#    (pick 自 initialized_machines 源可信, 不重复 verify, ADR-0019; 若路径误查 init 会因 MOCK_INIT_RC=1 返 3 而非 0)
MACHINE=""; MOCK_INIT_RC=1; MOCK_GUARD_STAT=ok; MOCK_PICK_RC=0; MOCK_PICK_RESULT="witherspoon"; rc=0
resolve_command_machine machine_state_initialized_machines "$_verb" stdout "$_nontty" 2>"$_err" >"$_out" || rc=$?
assert_eq "③ empty+ok rc=0" "$rc" "0"
assert_eq "③ empty+ok set MACHINE" "$MACHINE" "witherspoon"

# ④ empty+empty: 无 initialized machine → 3 + empty remedy(stderr)
MACHINE=""; MOCK_INIT_RC=1; MOCK_GUARD_STAT=empty; MOCK_PICK_RC=99; MOCK_PICK_RESULT=""; rc=0
resolve_command_machine machine_state_initialized_machines "$_verb" stdout "$_nontty" 2>"$_err" >"$_out" || rc=$?
assert_eq "④ empty+empty rc=3" "$rc" "3"
assert_contains "④ empty remedy" "$(cat "$_err")" "No initialized machines found."
assert_contains "④ empty remedy hint" "$(cat "$_err")" "Run './ob init <machine>' first."

# ⑤ empty+ok+pick-read-fail: pick 读失败 → 1 (无 cancel warn)
MACHINE=""; MOCK_INIT_RC=1; MOCK_GUARD_STAT=ok; MOCK_PICK_RC=1; MOCK_PICK_RESULT=""; rc=0
resolve_command_machine machine_state_initialized_machines "$_verb" stdout "$_nontty" 2>"$_err" >"$_out" || rc=$?
assert_eq "⑤ pick-read-fail rc=1" "$rc" "1"
assert_not_contains "⑤ no cancel warn on read-fail" "$(cat "$_out")" "cancelled"

# ⑥ nontty: 非交互终端 → 3 + nontty_remedy(stderr)
MACHINE=""; MOCK_INIT_RC=1; MOCK_GUARD_STAT=nontty; MOCK_PICK_RC=99; MOCK_PICK_RESULT=""; rc=0
resolve_command_machine machine_state_initialized_machines "$_verb" stdout "$_nontty" 2>"$_err" >"$_out" || rc=$?
assert_eq "⑥ nontty rc=3" "$rc" "3"
assert_contains "⑥ nontty remedy" "$(cat "$_err")" "no interactive terminal"

# ⑦ cancel: 用户取消 → 2 + warn(stdout, 含 <verb> cancelled by user.)
MACHINE=""; MOCK_INIT_RC=1; MOCK_GUARD_STAT=ok; MOCK_PICK_RC=2; MOCK_PICK_RESULT=""; rc=0
resolve_command_machine machine_state_initialized_machines "$_verb" stdout "$_nontty" 2>"$_err" >"$_out" || rc=$?
assert_eq "⑦ cancel rc=2" "$rc" "2"
assert_contains "⑦ cancel warn on stdout" "$(cat "$_out")" "Build cancelled by user."
assert_not_contains "⑦ cancel warn not on stderr" "$(cat "$_err")" "cancelled"

assert_summary
