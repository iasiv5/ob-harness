#!/usr/bin/env bash
# tests/unit/smoke_verdict.sh — _smoke_render_verdict 单测(unit 层)。
# 纯 verdict 渲染(无 curl/ipmitool/tcp),无 stub。锁 return 0/1 + summary 行 + 失败
# breakdown 计数 + 通道契约。ob_loader 已 set +e(关 errexit)。
#
# 通道契约(见 lib/util.sh: log/info/warn→stdout; error→stderr; α-banner 经 >&2 强制 stderr):
#   stdout = echo summary 行 + ✗ breakdown + RAW 块 + info(all-pass 成功行)
#   stderr = error 诊断行(Failed assertions / failed for) + warn α-banner
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ERR="$(mktemp)"

# --- (1) all-pass: total==passed, 空 failed arrays → return 0, 绿 summary, 无 ✗, 无 banner ---
fn=(); fr=()
rc=9; out=$(_smoke_render_verdict 5 5 fn fr romulus 2>"$ERR"); rc=$?
err="$(cat "$ERR")"
assert_eq    "(1) all-pass return 0"            "$rc" 0
assert_contains "(1) 绿 summary 5/5(stdout)"    "$out" "5/5"
assert_contains "(1) info 成功行带 machine(stdout)" "$out" "romulus"
assert_false "(1) 无 ✗ 行(stdout)"             grep -q "✗" <<<"$out"
assert_false "(1) 无 Failed assertions(stdout)" grep -q "Failed assertions" <<<"$out"
assert_false "(1) 无 α-banner(stdout)"         grep -q "truth-reporter" <<<"$out"
assert_false "(1) 无 α-banner(stderr)"         grep -q "truth-reporter" "$ERR"

# --- (2) all-fail: passed=0, 5 failed → return 1; stdout 红 0/5 + 5✗ + 5RAW; stderr Failed(5) + banner ---
fn=("Redfish root" "Redfish Managers" "SoftwareVersion" "IPMI over LAN" "System ready")
fr=("iface: root"$'\n'"RAW: r1" "iface: mgr"$'\n'"RAW: r2" "iface: swv"$'\n'"RAW: r3" \
    "iface: ipmi"$'\n'"RAW: r4" "iface: ssh"$'\n'"RAW: r5")
rc=9; out=$(_smoke_render_verdict 5 0 fn fr romulus 2>"$ERR"); rc=$?
err="$(cat "$ERR")"
assert_eq    "(2) all-fail return 1"            "$rc" 1
assert_contains "(2) 红 summary 0/5(stdout)"    "$out" "0/5"
assert_contains "(2) Failed assertions (5)(stderr)" "$err" "Failed assertions (5)"
assert_false "(2) Failed assertions 不在 stdout" grep -q "Failed assertions" <<<"$out"
# ✗ 行由 echo -e "  ${RED}✗ ..." 渲染: 空格后是 ANSI SGR(ESC[0;31m)再接 ✗, 故计数正则须
# 容许 ✗ 前的 ANSI 转义(否则 ^[[:space:]]*✗ 因 ESC 卡在中间而 0 命中)。
_n=$(grep -cE $'^[[:space:]]*(\033\\[[0-9;]*m)*✗ ' <<<"$out" || true); assert_eq "(2) 恰好 5 ✗ 行(stdout)" "$_n" 5
_n=$(grep -c "RAW response" <<<"$out" || true);    assert_eq "(2) 恰好 5 RAW 块(stdout)" "$_n" 5
assert_true  "(2) α-banner 在 stderr"           grep -q "truth-reporter" "$ERR"
assert_false "(2) α-banner 不在 stdout"         grep -q "truth-reporter" <<<"$out"
assert_contains "(2) failed-for 诊断行(stderr)" "$err" "smoke assertions failed for 'romulus'"
assert_false "(2) failed-for 诊断行不在 stdout" grep -q "smoke assertions failed for" <<<"$out"

# --- (3) mixed: passed=3, 2 failed → return 1; stdout 3/5 + 2✗ + 2RAW; stderr Failed(2) + banner ---
fn=("IPMI over LAN" "System ready")
fr=("iface: ipmi"$'\n'"RAW: ipmi" "iface: ssh"$'\n'"RAW: ssh")
rc=9; out=$(_smoke_render_verdict 5 3 fn fr romulus 2>"$ERR"); rc=$?
err="$(cat "$ERR")"
assert_eq    "(3) mixed return 1"               "$rc" 1
assert_contains "(3) summary 3/5(stdout)"       "$out" "3/5"
assert_contains "(3) Failed assertions (2)(stderr)" "$err" "Failed assertions (2)"
_n=$(grep -cE $'^[[:space:]]*(\033\\[[0-9;]*m)*✗ ' <<<"$out" || true); assert_eq "(3) 恰好 2 ✗ 行(stdout)" "$_n" 2
assert_true  "(3) α-banner 在 stderr"           grep -q "truth-reporter" "$ERR"
assert_contains "(3) failed-for 诊断行(stderr)" "$err" "smoke assertions failed for 'romulus'"

rm -f "$ERR"
assert_summary
