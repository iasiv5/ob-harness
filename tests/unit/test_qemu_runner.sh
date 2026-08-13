#!/usr/bin/env bash
# tests/unit/test_qemu_runner.sh — runner 层 no-match / 空集断言(无 QEMU, 毫秒级)。
# 评审 🔴1: --ar/--suite 无命中 / baseline 空 → 0 条 AR 不是"全通过", 是筛选/配置前置错误 → exit 3。
# 锁住 run.sh 的 planner 后 0 条检查, 避免退回"空 PASS false green"。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/baseline/romulus/runner/run.sh"

# no-match --ar (dry-run) → exit 3 + remedy
rc=0; bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --ar NOPE --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "no-match --ar dry-run → exit 3" "$rc" "3"

# no-match --ar (normal path) → exit 3
rc=0; bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --ar NOPE --timeout 2 >/dev/null 2>&1 || rc=$?
assert_eq "no-match --ar normal → exit 3" "$rc" "3"

# no-match --suite → exit 3
rc=0; bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --suite NOPE --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "no-match --suite → exit 3" "$rc" "3"

# remedy 文案含 "No AR matched"(可读诊断, 非静默 exit 3)
out=$(bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --ar NOPE --dry-run 2>&1) || true
assert_true "remedy mentions 'No AR matched'" grep -q "No AR matched" <<<"$out"

# 正向: 全 AR dry-run → exit 0(非 0 条, 正常列 AR)
rc=0; bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "full AR dry-run → exit 0 (not false-green)" "$rc" "0"

assert_summary
