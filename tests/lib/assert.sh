#!/usr/bin/env bash
# tests/lib/assert.sh — 断言库。source 后用 assert_*;末尾 assert_summary 决定退出码。
ASSERT_PASS=0; ASSERT_FAIL=0
assert_reset()  { ASSERT_PASS=0; ASSERT_FAIL=0; }
_assert_ok()    { ASSERT_PASS=$((ASSERT_PASS+1)); echo "ok   $1"; }
_assert_bad()   { ASSERT_FAIL=$((ASSERT_FAIL+1)); echo "FAIL $1"; }
assert_eq()      { local l="$1" a="$2" e="$3"; [[ "$a" == "$e" ]] && _assert_ok "$l" || _assert_bad "$l (got '$a' want '$e')"; }
assert_match()   { local l="$1" a="$2" r="$3"; [[ "$a" =~ $r ]] && _assert_ok "$l" || _assert_bad "$l (got '$a' want /$r/)"; }
assert_contains(){ local l="$1" h="$2" n="$3"; [[ "$h" == *"$n"* ]] && _assert_ok "$l" || _assert_bad "$l (missing '$n')"; }
assert_true()    { local l="$1"; shift; if "$@"; then _assert_ok "$l"; else _assert_bad "$l"; fi; }
assert_false()   { local l="$1"; shift; if "$@"; then _assert_bad "$l"; else _assert_ok "$l"; fi; }
assert_rc() { # <exp_rc> <label> <cmd...>  子进程跑,断言退出码
    local exp="$1" l="$2"; shift 2; local rc=0; "$@" >/dev/null 2>&1 || rc=$?
    [[ "$rc" == "$exp" ]] && _assert_ok "$l (rc=$rc)" || _assert_bad "$l (rc=$rc want $exp)"
}
assert_summary() { echo ""; echo "PASS=$ASSERT_PASS FAIL=$ASSERT_FAIL"; [[ "$ASSERT_FAIL" -eq 0 ]]; }
