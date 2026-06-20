#!/usr/bin/env bash
# tests/unit/require_path.sh — require_path 前置检查单测(unit 层,exit 函数)。
# require_path <path> <label> <hint> <code>: 不存在 → exit <code>(+ hint 到 stderr);存在 → return 0。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

assert_rc 3 "missing path exit 3"    bash -c 'OB_NO_MAIN=1 source "$1"; require_path /nonexistent/path label hint 3' _ "$OB"
assert_rc 5 "custom exit code 5"     bash -c 'OB_NO_MAIN=1 source "$1"; require_path /nonexistent/path label "" 5' _ "$OB"
# 存在的路径(/)→ 不 exit,函数 return 0
assert_rc 0 "existing path returns 0" bash -c 'OB_NO_MAIN=1 source "$1"; require_path / label "" 3' _ "$OB"
# hint 非空 → 输出到 stderr
err="$(bash -c 'OB_NO_MAIN=1 source "$1"; require_path /nonexistent/path label "custom hint text" 3' _ "$OB" 2>&1 >/dev/null)"
assert_contains "hint in stderr" "$err" "custom hint text"

assert_summary
