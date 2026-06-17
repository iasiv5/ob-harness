#!/usr/bin/env bash
# ob 冒烟测试 —— 只测非交互路径的退出码。零依赖、不触发 main、不跑 QEMU、不需 workspace。
#
# 【什么时候用】
#   - 日常回归：改了 ob 之后随手跑一下（秒级），确认参数解析/前提检查没退化
#   - CI 或提交前的快速 sanity check（不依赖 workspace / QEMU / expect）
#   - 快速验证 ob 能否被 OB_NO_MAIN=1 source 加载、函数齐全
#
# 【怎么用】
#   $ bash tests/smoke_ob.sh
#   输出：每个 case 一行 ok/FAIL，末尾 PASS=N FAIL=M。
#   退出：FAIL=0 → exit 0；FAIL>0 → exit 非0（末尾 [[ "$FAIL" -eq 0 ]] 决定）。
#
# 【覆盖项】（非交互退出码）
#   parse_args --help       → 0      parse_args unknown opt    → 1
#   parse_args missing val  → 1      ob build（空 workspace）  → 3
#
# 【原理/局限】
#   - 加载方式：OB_NO_MAIN=1 source ob（只定义函数，不跑 main）。
#   - 故意不 set -e：ob 自带的 set -euo pipefail 会经 source 泄漏进本测试，第一个
#     非零 assert 会整批中止；故保留 nounset/pipefail、关掉 errexit。
#   - --dry-run 等需要 machine 的路径这里测不了（resolve_machine 先于 dry-run 跑，
#     空 workspace 直接 exit 3）——交给 manual_matrix.exp 覆盖。
#
# 【由来】ob 日常零依赖回归基线；交互/取消分支由两个 expect 手动矩阵补充。
set -uo pipefail
# NOTE: 不 set -e —— ob 的 set -euo pipefail 会经 source 泄漏进来，首个非零 assert 会整批中止

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OB="$SCRIPT_DIR/../ob"
PASS=0; FAIL=0

assert_exit() {
    # assert_exit <expected_rc> <label> <cmd...>
    local exp="$1"; local label="$2"; shift 2
    local rc=0
    ( "$@" ) >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq "$exp" ]]; then PASS=$((PASS+1)); echo "ok   $label (rc=$rc)";
    else FAIL=$((FAIL+1)); echo "FAIL $label (expected rc=$exp got $rc)"; fi
}

# Load ob without triggering main. ob's own `set -euo pipefail` leaks into
# this harness via source; re-disable errexit so a non-zero assert doesn't
# abort the whole run. Keep nounset/pipefail.
OB_NO_MAIN=1 source "$OB" || { echo "source failed"; exit 1; }
set +e
echo "OB_NO_MAIN source OK"

# --- parse_args exit codes (each case runs in its own subshell via assert_exit) ---
assert_exit 0 "parse_args --help"      bash -c 'OB_NO_MAIN=1 source "$0"; parse_args --help' "$OB"
assert_exit 1 "parse_args unknown opt" bash -c 'OB_NO_MAIN=1 source "$0"; parse_args start-qemu --bogus-opt' "$OB"
assert_exit 1 "parse_args missing val" bash -c 'OB_NO_MAIN=1 source "$0"; parse_args start-qemu --ssh-port' "$OB"
# --- dispatch + prerequisites (baseline: ob build in empty workspace -> exit 3) ---
TMPWS="$(mktemp -d)"
assert_exit 3 "ob build in empty workspace" \
    bash -c 'cd "$1"; OB_NO_MAIN=1 source /bmc/iasi/ob-harness/ob; set +e; parse_args build; cmd_build' _ "$TMPWS"
rm -rf "$TMPWS"
# NOTE: --dry-run has no machineless path (resolve_machine runs first, exits 3 in empty
# workspace) — covered by the manual matrix, not automated here.

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
