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

# probe protocol matrix: infra rc3 must stay error for applicable/xfail; malformed
# output and unexpected rc must never become PASS or alpha FAIL.
cat > "$_tmp/probe-stub.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

mode = os.environ["OB_TQ_STUB_MODE"]
cases = {
  "transport": ({"pass": False, "error": True, "code": None, "body": "",
           "actual": None, "reason": "connection refused"}, 3),
  "empty": ({}, 0),
  "unexpected-rc": ({"pass": False, "code": None, "body": "",
             "actual": None, "reason": "internal"}, 2),
  "bad-types": ({"pass": True, "error": 0, "code": [], "body": {},
           "actual": None, "reason": 7}, 0),
  "good-pass": ({"pass": True, "code": 200, "body": "{}",
           "actual": None, "reason": "ok"}, 0),
  "good-fail": ({"pass": False, "code": 500, "body": "{}",
           "actual": 500, "reason": "bad"}, 1),
  "good-fail-multiline": ({"pass": False, "code": 500, "body": "{}",
           "actual": 500, "reason": "line1\nline2 bad"}, 1),
  "big-body-pass": ({"pass": True, "code": 200, "body": "{}" * 131072,
           "actual": None, "reason": "ok"}, 0),
}
payload, rc = cases[mode]
print(json.dumps(payload))
sys.exit(rc)
PY
chmod +x "$_tmp/probe-stub.py"
cat > "$_tmp/one.yaml" <<'YAML'
auth: {user: r, password: x}
ars:
  - ar: TEST-A
    name: protocol fixture
    probe: redfish
    suite: fixture
    request: {method: GET, path: /redfish/v1}
    assert: [{type: status_in, value: [200]}]
    depends_on: []
    rationale: fixture
YAML
cat > "$_tmp/applicable.yaml" <<'YAML'
default: applicable
overrides: {}
YAML
cat > "$_tmp/xfail.yaml" <<'YAML'
default: applicable
overrides:
  TEST-A: {status: xfail, reason: expected, source: unit}
YAML

_run_protocol_case() {
  local mode="$1" appl="$2"
  OB_TQ_STUB_MODE="$mode" OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$appl" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x \
    >/dev/null 2>&1
}
assert_rc 3 "transport rc3 stays error for applicable AR" \
  _run_protocol_case transport "$_tmp/applicable.yaml"
assert_rc 3 "transport rc3 stays error for xfail AR" \
  _run_protocol_case transport "$_tmp/xfail.yaml"
assert_rc 3 "empty object + rc0 is infra error" \
  _run_protocol_case empty "$_tmp/applicable.yaml"
assert_rc 3 "unexpected probe rc is infra error" \
  _run_protocol_case unexpected-rc "$_tmp/applicable.yaml"
assert_rc 3 "malformed probe field types are infra error" \
  _run_protocol_case bad-types "$_tmp/applicable.yaml"
assert_rc 0 "valid probe pass remains pass" \
  _run_protocol_case good-pass "$_tmp/applicable.yaml"
assert_rc 1 "valid probe fail remains alpha fail" \
  _run_protocol_case good-fail "$_tmp/applicable.yaml"

# 流式 UX 回归: live 行默认开(run.sh 恒打 '  <AR> <status>' 到 stderr), VERDICT 恒为
# stdout 最后一行, -v 时 fail/error 行尾追加 reason 摘要(一行化: 转字符串 + 换行替空格
# + 截断 120 — 与 report.py 逐条行同规则)。
_run_protocol_capture() {
  # 同 _run_protocol_case 的 fixture 注入, 但保留输出供断言: 函数 stdout 即 captured
  # output(2>&1 合并), 调用侧用 command substitution 捕获, rc 由调用侧 || rc=$? 保存。
  local mode="$1"; shift
  OB_TQ_STUB_MODE="$mode" OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/applicable.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x "$@" 2>&1
}

# 1+2: 流式默认 + VERDICT 末行(不加 -v; live 行格式 printf '  %-14s %s\n', 行尾锚定)
out=""; rc=0; out=$(_run_protocol_capture good-pass) || rc=$?
assert_eq "live pass streams by default, runner still rc=0" "$rc" "0"
assert_true "live AR line streams by default (no -v)" grep -Eq '^  TEST-A[[:space:]]+pass$' <<<"$out"
assert_true "VERDICT is the last line" grep -q '^VERDICT: PASS' <<<"$(tail -1 <<<"$out")"

# 3: -v 追加 reason(一行化: 换行替空格, 锁 '每条 AR 一行' 契约)
out=""; rc=0; out=$(_run_protocol_capture good-fail-multiline -v) || rc=$?
assert_eq "verbose fail run keeps alpha rc=1" "$rc" "1"
assert_true "verbose live line carries flattened reason" \
  grep -Eq '^  TEST-A[[:space:]]+fail line1 line2 bad$' <<<"$out"

# 4: 不带 -v 无行内 reason
out=""; rc=0; out=$(_run_protocol_capture good-fail-multiline) || rc=$?
assert_eq "non-verbose fail run keeps alpha rc=1" "$rc" "1"
assert_true "non-verbose live line has no inline reason" \
  grep -Eq '^  TEST-A[[:space:]]+fail$' <<<"$out"

# 5: 通道分工(live→stderr / report→stdout), 分离捕获锁全局约束
_sstdout="$_tmp/split.out"; _sstderr="$_tmp/split.err"
rc=0; OB_TQ_STUB_MODE=good-pass OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/applicable.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x \
    >"$_sstdout" 2>"$_sstderr" || rc=$?
assert_eq "split-stream pass run rc=0" "$rc" "0"
assert_true "live pass line is on stderr" grep -Eq '^  TEST-A[[:space:]]+pass$' "$_sstderr"
assert_true "stdout (compact-rows) carries no pass AR row" bash -c "! grep -q 'TEST-A' '$_sstdout'"
assert_true "stdout last line is VERDICT" grep -q '^VERDICT: PASS' <<<"$(tail -1 "$_sstdout")"
rc=0; OB_TQ_STUB_MODE=good-fail-multiline OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/applicable.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x \
    >"$_sstdout" 2>"$_sstderr" || rc=$?
assert_eq "split-stream fail run rc=1" "$rc" "1"
assert_true "live fail line is on stderr" grep -Eq '^  TEST-A[[:space:]]+fail$' "$_sstderr"
assert_true "stdout keeps fail detail row" grep -Eq 'TEST-A[[:space:]]+fail \| code=' "$_sstdout"
assert_true "stdout last line is VERDICT: FAIL" grep -q '^VERDICT: FAIL' <<<"$(tail -1 "$_sstdout")"

# 6: 大 body record(>128KB 单参数上限)走 stdin 不走 argv — live 行不 E2BIG(回归:
#     曾以 argv 传整 record, python3 "参数列表过长" 致 live 行丢失)
out=""; rc=0; out=$(_run_protocol_capture big-body-pass) || rc=$?
assert_eq "big-body pass run rc=0" "$rc" "0"
assert_true "live line survives >128KB body (record via stdin, not argv)" \
  grep -Eq '^  TEST-A[[:space:]]+pass$' <<<"$out"

# 7: skip live 行带 reason 且解码为可读中文(回归: planner \x1f 字段是 json.dumps 的
#    ASCII 转义形态, 曾直接拼进行里打出 \uXXXX 转义串; 解码走 assemble record)
cat > "$_tmp/skip-appl.yaml" <<'YAML'
default: applicable
overrides:
  TEST-A: {status: skip, reason: "纯硬件/规格条目, QEMU 不可仿真", source: unit}
YAML
out=""; rc=0
out=$(OB_TQ_STUB_MODE=good-pass OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/skip-appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x 2>&1) || rc=$?
assert_eq "skip run rc=0" "$rc" "0"
assert_true "skip live line carries decoded Chinese reason" \
  grep -Eq '^  TEST-A[[:space:]]+skip \| 纯硬件/规格条目, QEMU 不可仿真$' <<<"$out"
assert_true "skip live line has no \\\\uXXXX escapes" \
  bash -c "! grep -E 'skip \\\\\\\\u[0-9a-f]{4}' <<<'$out'"

# 编码回归(评审 🟢4 + 🟡1, 四轮对撞定稿): 敌意 stdio 预设(PYTHONIOENCODING=ascii, UTF-8 mode
# 仍开) + 树内同构中文 reason → run.sh 头部双 export 免疫: xpass 中文正常渲染, rc=0。
# 期望钉在最终修复组合上 — PYTHONIOENCODING=utf-8 覆盖 stdio 面(变体 B), PYTHONUTF8=1 覆盖
# UTF-8 mode 被关(变体 A), 二者互不可替(PYTHONIOENCODING 优先级更高); 移除任一 export 本用例翻红。
# pass-stub 同锁 xpass 判定路径(意外 pass 不污染 exit)。装配层兜底(🟡1)的编码触发器已被
# 双 export 消灭, 不可经本用例到达 — 该分支为防御性, 勿再造测(四轮对撞结论)。
cat > "$_tmp/xfail-zh.yaml" <<'YAML'
default: applicable
overrides:
  TEST-A: {status: xfail, reason: "romulus 预期不填 Description, 跟踪中", source: unit}
YAML
_zh_out=$(mktemp)
rc=0; LC_ALL=C PYTHONIOENCODING=ascii OB_TQ_STUB_MODE=good-pass \
    OB_TQ_PROBE="$_tmp/probe-stub.py" OB_TQ_AR_PROBES="$_tmp/one.yaml" \
    OB_TQ_APPL="$_tmp/xfail-zh.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x >"$_zh_out" 2>&1 || rc=$?
assert_eq "hostile ascii stdio + Chinese xfail reason → immune (run.sh double export)" "$rc" "0"
assert_contains "Chinese xpass reason renders" "$(cat "$_zh_out")" "跟踪中"
assert_contains "xpass recorded (unexpected pass, exit unaffected)" "$(cat "$_zh_out")" "xpass"
rm -f "$_zh_out"

# 凭据 env 通道(评审 🟡2): 不传 --user/--password argv → env 满足"argv 或 env 至少一源"校验,
# probe argv 不含凭据(密码不落 ps)。probe 侧 env fallback 消费由 probe --selftest 锁, 此处锁 run.sh。
rc=0; OB_TQ_USER=r OB_TQ_PASSWORD=x OB_TQ_STUB_MODE=good-pass \
    OB_TQ_PROBE="$_tmp/probe-stub.py" OB_TQ_AR_PROBES="$_tmp/one.yaml" \
    OB_TQ_APPL="$_tmp/applicable.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 >/dev/null 2>&1 || rc=$?
assert_eq "creds via env only (no argv) accepted" "$rc" "0"

# 凭据全缺 → exit 2 usage + 指名 remedy(env -u 防测试 shell 自带 OB_TQ_* 干扰)
rc=0; env -u OB_TQ_USER -u OB_TQ_PASSWORD \
    bash "$RUNNER" --host 127.0.0.1 --port 1 >/dev/null 2>&1 || rc=$?
assert_eq "no creds at all → exit 2 usage" "$rc" "2"

# Planner framing inputs: method is canonical uppercase; AR/path reject every
# ASCII control character, including the unit-separator used by the planner.
python3 - "$_tmp/lower-method.yaml" "$_tmp/control-path.yaml" <<'PY'
import sys
import yaml

base = {
  "auth": {"user": "r", "password": "x"},
  "ars": [{
    "ar": "TEST-A", "name": "fixture", "probe": "redfish", "suite": "fixture",
    "request": {"method": "get", "path": "/redfish/v1"},
    "assert": [{"type": "status_in", "value": [200]}],
    "depends_on": [], "rationale": "fixture",
  }],
}
with open(sys.argv[1], "w") as stream:
  yaml.safe_dump(base, stream)
base["ars"][0]["request"] = {"method": "GET", "path": "/redfish/v1\x1fManagers"}
with open(sys.argv[2], "w") as stream:
  yaml.safe_dump(base, stream)
PY
_planner_fixture() {
  local ar_file="$1"
  OB_TQ_AR_PROBES="$ar_file" OB_TQ_APPL="$_tmp/applicable.yaml" \
    bash "$RUNNER" --dry-run >/dev/null 2>&1
}
assert_rc 3 "lowercase HTTP method rejected as config error" \
  _planner_fixture "$_tmp/lower-method.yaml"
assert_rc 3 "planner unit-separator path rejected as config error" \
  _planner_fixture "$_tmp/control-path.yaml"

# skip AR 可省略 request(评审配套⑤): 无占位假请求; applicable AR 缺 request → exit 3
cat > "$_tmp/skip-noreq.yaml" <<'YAML'
auth: {user: r, password: x}
ars:
  - ar: TEST-SKIP
    name: skip without request
    probe: redfish
    suite: x
    assert: [{type: status_in, value: [200]}]
    depends_on: []
    rationale: skip AR may omit request
YAML
cat > "$_tmp/skip-noreq-appl.yaml" <<'YAML'
default: applicable
overrides:
  TEST-SKIP: {status: skip, reason: not emulatable in QEMU, source: unit}
YAML
rc=0; OB_TQ_AR_PROBES="$_tmp/skip-noreq.yaml" OB_TQ_APPL="$_tmp/skip-noreq-appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/skip-noreq.out" 2>&1 || rc=$?
assert_eq "skip AR without request → dry-run ok" "$rc" "0"
assert_contains "skip AR listed as skip" "$(cat "$_tmp/skip-noreq.out")" "TEST-SKIP"
rc=0; OB_TQ_AR_PROBES="$_tmp/skip-noreq.yaml" OB_TQ_APPL="$_tmp/applicable.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "applicable AR missing request → exit 3" "$rc" "3"

REPORT_BIN="$(dirname "$RUNNER")/report.py"
_report_stdin_case() {
  local payload="$1"
  printf '%s' "$payload" | python3 "$REPORT_BIN" --results - >/dev/null 2>&1
}
assert_rc 3 "report empty results are infra error" _report_stdin_case ""
assert_rc 3 "report duplicate AR results are infra error" _report_stdin_case \
  $'{"ar":"A","status":"pass"}\n{"ar":"A","status":"pass"}\n'
rm -rf "$_tmp"

assert_summary
