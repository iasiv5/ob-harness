#!/usr/bin/env bash
# tests/unit/test_qemu_runner.sh — runner 层 no-match / 空集断言(无 QEMU, 毫秒级)。
# 评审 🔴1: --ar/--suite 无命中 / baseline 空 → 0 条 AR 不是"全通过", 是筛选/配置前置错误 → exit 3。
# 锁住 run.sh 的 planner 后 0 条检查, 避免退回"空 PASS false green"。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# 锚定 romulus runner(ADR-0025 per-machine: 每 machine baseline 自带 runner, 测试跟着 baseline 走)。
# OB_TQ_RUNNER env 可指向其它 machine 的 runner(未来 custom 机 runner 复用本测试时用);
# PROBE_BIN 从 RUNNER 目录派生, 切 runner 时跟着切。
RUNNER="${OB_TQ_RUNNER:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/baseline/romulus/runner/run.sh}"

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

# unknown assert type → exit 3(planner 白名单, 评审二轮 🟡: baseline 数据错, 非 BMC fail)
PROBE_BIN="$(dirname "$RUNNER")/probe_redfish.py"
_tmp=$(mktemp -d)
cat > "$_tmp/bad.yaml" <<'YAML'
auth: {user: r, password: x}
ars:
  - ar: BAD-TYPO
    name: typo assert type
    probe: redfish
    suite: x
    request: {method: GET, path: /redfish/v1}
    assert:
      - type: json_path_exist
    depends_on: []
    rationale: typo
YAML
cat > "$_tmp/appl.yaml" <<'YAML'
default: applicable
YAML
rc=0; OB_TQ_AR_PROBES="$_tmp/bad.yaml" OB_TQ_APPL="$_tmp/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/out" 2>&1 || rc=$?
assert_eq "unknown assert type → runner exit 3" "$rc" "3"
assert_true "runner remedy mentions 'unknown assert type'" grep -q "unknown assert type" "$_tmp/out"

# probe 兜底(方案 B, 评审二轮 🟡): 直接调 probe 绕过 runner, unknown type → error JSON + exit 3
rc=0; out=$(python3 "$PROBE_BIN" --host 127.0.0.1 --port 1 --user r --password x \
    --method GET --path /p --asserts '[{"type":"typo_assert"}]' --timeout 2 2>/dev/null) || rc=$?
assert_eq "probe unknown type → exit 3" "$rc" "3"
assert_true "probe unknown type → error JSON" grep -q '"error": true' <<<"$out"
rm -rf "$_tmp"

assert_summary
