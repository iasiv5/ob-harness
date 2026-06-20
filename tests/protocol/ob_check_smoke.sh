#!/usr/bin/env bash
# ob_check.sh 冒烟测试 — 对当前 ob 跑 ob_check(只读) 断言 exit 0,防脚本腐烂。
# 必设 OB_CHECK_SKIP_TESTS=1(避 run_all 递归) + OB_CHECK_READONLY=1(只报告不改 baseline,
# 否则 run_all→smoke→ob_check 自动 cp 覆写 .shellcheck-baseline,架空 CI baseline 门禁)。
# 覆盖边界: smoke 走 skip,ob_check 里"调用 run_all.sh 那段"不执行——该路径写错靠 CI 直接
#           bash tests/run_all.sh 兜底;smoke 实际只覆盖 extract_funcs/reorder/baseline 三段。
set -uo pipefail
OB_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

assert_rc 0 "ob_check clean ob (read-only)" \
    env OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash "$OB_DIR/tools/ob_check.sh"

assert_summary
