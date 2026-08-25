#!/usr/bin/env bash
# tests/unit/test_qemu_runner.sh — runner 层 no-match / 空集断言(无 QEMU, 毫秒级)。
# 评审 🔴1: --ar/--suite 无命中 / baseline 空 → 0 条 AR 不是"全通过", 是筛选/配置前置错误 → exit 3。
# 锁住 run.sh 的 planner 后 0 条检查, 避免退回"空 PASS false green"。
set -uo pipefail
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# 锚定共享 runner(ADR-0027 单副本: tests/baseline/runner/, machine 差异只在数据 YAML)。
# OB_TQ_RUNNER env 可换指其它 runner 副本; PROBE_BIN 从 RUNNER 目录派生, 切 runner 时跟着切。
# 共享 runner 无 script_dir/../ 数据缺省, 默认数据 env 注入 romulus(直调形态对齐
# cmd_test_qemu 的 OB_TQ_AR_PROBES/OB_TQ_APPL 注入); 各 fixture 用例以调用前缀 env 覆盖。
RUNNER="${OB_TQ_RUNNER:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/baseline/runner/run.sh}"
_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export OB_TQ_AR_PROBES="$_repo/tests/baseline/romulus/ar_probes.yaml"
export OB_TQ_APPL="$_repo/tests/baseline/romulus/applicability.yaml"

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
# v2 布局(ADR-0025/0027 增补): 薄顶层(schema_version: 2 + auth + include) + ar_probes.d/ 分片
PROBE_BIN="$(dirname "$RUNNER")/probe_redfish.py"
_tmp=$(mktemp -d)
cat > "$_tmp/bad.yaml" <<'YAML'
schema_version: 2
auth: {user: r, password: x}
include: [ar_probes.d/bad.yaml]
YAML
mkdir -p "$_tmp/ar_probes.d"
cat > "$_tmp/ar_probes.d/bad.yaml" <<'YAML'
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
schema_version: 1
default: applicable
YAML
rc=0; OB_TQ_AR_PROBES="$_tmp/bad.yaml" OB_TQ_APPL="$_tmp/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/out" 2>&1 || rc=$?
assert_eq "unknown assert type → runner exit 3" "$rc" "3"
assert_true "runner remedy mentions 'unknown assert type'" grep -q "unknown assert type" "$_tmp/out"

# ── probe-type 分派与兼容矩阵(ADR-0028) ──
_mk_pt() {  # $1=ar_yaml_body  $2=out-name → 生成 baseline + 跑 dry-run, rc 经全局 $? 断言
  cat > "$_tmp/ar_probes.d/$2.yaml" <<<"$1"
  cat > "$_tmp/ar_probes.yaml" <<YAML
schema_version: 2
auth: {user: r, password: x}
include: [ar_probes.d/$2.yaml]
YAML
}

# ipmi AR 配 status_in(矩阵违例)→ exit 3 数据错, 不进 α truth
_mk_pt 'ars:
  - ar: PT-MATRIX
    name: matrix violation
    probe: ipmi
    suite: s
    request: {command: mc_info}
    assert:
      - type: status_in
        value: [200]
    depends_on: []
' pt_matrix.yaml
rc=0; OB_TQ_AR_PROBES="$_tmp/ar_probes.yaml" OB_TQ_APPL="$_tmp/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/out_pt" 2>&1 || rc=$?
assert_eq "ipmi AR + status_in 矩阵违例 → exit 3" "$rc" "3"
assert_true "矩阵违例 remedy 指名 assert/probe" grep -q "not allowed for probe 'ipmi'" "$_tmp/out_pt"

# probe none + applicable(无可执行探测定义却要跑)→ exit 3
_mk_pt 'ars:
  - ar: PT-NONE
    name: none sentinel on applicable
    probe: none
    suite: s
    assert: []
    depends_on: []
' pt_none.yaml
rc=0; OB_TQ_AR_PROBES="$_tmp/ar_probes.yaml" OB_TQ_APPL="$_tmp/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/out_pt" 2>&1 || rc=$?
assert_eq "probe none + applicable → exit 3" "$rc" "3"
assert_true "probe none remedy 指名 sentinel 规则" grep -q "probe 'none' only allowed" "$_tmp/out_pt"

# executable AR 空 assert(评审 🔴: 假绿防御)→ exit 3
_mk_pt 'ars:
  - ar: PT-EMPTY
    name: empty assert
    probe: redfish
    suite: s
    request: {method: GET, path: /redfish/v1}
    assert: []
' pt_empty.yaml
rc=0; OB_TQ_AR_PROBES="$_tmp/ar_probes.yaml" OB_TQ_APPL="$_tmp/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/out_pt" 2>&1 || rc=$?
assert_eq "applicable AR 空 assert → exit 3" "$rc" "3"
assert_true "空 assert remedy 指名" grep -q "no assert" "$_tmp/out_pt"

# 畸形类型(评审 🟡: planner 类型防御, 不 traceback 冒充 exit 1)
_mk_pt 'ars:
  - ar: PT-STRASSERT
    name: assert item is str
    probe: redfish
    suite: s
    request: {method: GET, path: /redfish/v1}
    assert: [status_in]
' pt_strassert.yaml
rc=0; OB_TQ_AR_PROBES="$_tmp/ar_probes.yaml" OB_TQ_APPL="$_tmp/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/out_pt" 2>&1 || rc=$?
assert_eq "assert 项为 str → exit 3(非 traceback exit 1)" "$rc" "3"
assert_false "无 Python traceback" grep -q "Traceback" "$_tmp/out_pt"

_mk_pt 'ars:
  - ar: PT-STRREQ
    name: request is str
    probe: redfish
    suite: s
    request: not-a-dict
    assert: [{type: status_in, value: [200]}]
' pt_strreq.yaml
rc=0; OB_TQ_AR_PROBES="$_tmp/ar_probes.yaml" OB_TQ_APPL="$_tmp/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/out_pt" 2>&1 || rc=$?
assert_eq "request 为 str → exit 3(非 traceback exit 1)" "$rc" "3"
assert_false "无 Python traceback(2)" grep -q "Traceback" "$_tmp/out_pt"

_mk_pt 'ars:
  - ar: PT-BADDEPS
    name: depends_on is scalar
    probe: redfish
    suite: s
    request: {method: GET, path: /redfish/v1}
    assert: [{type: status_in, value: [200]}]
    depends_on: 123
' pt_baddeps.yaml
rc=0; OB_TQ_AR_PROBES="$_tmp/ar_probes.yaml" OB_TQ_APPL="$_tmp/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/out_pt" 2>&1 || rc=$?
assert_eq "depends_on 为 scalar → exit 3(非 traceback exit 1)" "$rc" "3"
assert_false "无 Python traceback(3)" grep -q "Traceback" "$_tmp/out_pt"

_mk_pt 'ars:
  - ar: PT-BADOVERRIDES
    name: overrides is list
    probe: redfish
    suite: s
    request: {method: GET, path: /redfish/v1}
    assert: [{type: status_in, value: [200]}]
    depends_on: []
' pt_badoverrides.yaml
cat > "$_tmp/appl_bad_overrides.yaml" <<'YAML'
schema_version: 1
default: applicable
overrides: []
YAML
rc=0; OB_TQ_AR_PROBES="$_tmp/ar_probes.yaml" OB_TQ_APPL="$_tmp/appl_bad_overrides.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp/out_pt" 2>&1 || rc=$?
assert_eq "overrides 为 list → exit 3(非 traceback exit 1)" "$rc" "3"
assert_false "无 Python traceback(4)" grep -q "Traceback" "$_tmp/out_pt"

# 合法 smoke 形态数据(5 AR: redfish×3 + ipmi + ssh_tcp)→ dry-run exit 0(分派层零异常)
cp "$_repo/tests/baseline/romulus/ar_probes.d/smoke.yaml" "$_tmp/ar_probes.d/smoke.yaml"
cat > "$_tmp/ar_probes.yaml" <<'YAML'
schema_version: 2
auth: {user: r, password: x}
include: [ar_probes.d/smoke.yaml]
YAML
rc=0; OB_TQ_AR_PROBES="$_tmp/ar_probes.yaml" OB_TQ_APPL="$_tmp/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --suite smoke --dry-run >"$_tmp/out_pt" 2>&1 || rc=$?
assert_eq "混合 probe-type smoke suite dry-run → exit 0" "$rc" "0"
assert_true "smoke dry-run 列出 SMOKE-01..05" grep -q "SMOKE-05" "$_tmp/out_pt"

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
schema_version: 2
auth: {user: r, password: x}
include: [ar_probes.d/one.yaml]
YAML
cat > "$_tmp/ar_probes.d/one.yaml" <<'YAML'
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
schema_version: 1
default: applicable
overrides: {}
YAML
cat > "$_tmp/xfail.yaml" <<'YAML'
schema_version: 1
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

# 流式 UX 回归: live 行默认开(run.sh 恒打到 stderr), VERDICT 恒为 stdout 最后一行,
# fail/error live 行恒带 reason 摘要(一行化: 转字符串 + 换行替空格 + 截断 120 — 与
# report.py 逐条行同规则); -v 额外带 code=(code 非 None 时)。
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

# 3: -v 额外带 code=(fixture code=500), reason 一行化(换行替空格, 锁 '每条 AR 一行' 契约)
out=""; rc=0; out=$(_run_protocol_capture good-fail-multiline -v) || rc=$?
assert_eq "verbose fail run keeps alpha rc=1" "$rc" "1"
assert_true "verbose live line carries code + flattened reason" \
  grep -Eq '^  TEST-A[[:space:]]+fail code=500 line1 line2 bad$' <<<"$out"

# 4: 不带 -v 恒带行内 reason(无 code= 段)
out=""; rc=0; out=$(_run_protocol_capture good-fail-multiline) || rc=$?
assert_eq "non-verbose fail run keeps alpha rc=1" "$rc" "1"
assert_true "non-verbose live line carries inline reason" \
  grep -Eq '^  TEST-A[[:space:]]+fail line1 line2 bad$' <<<"$out"

# 5: 通道分工(live→stderr / report→stdout), 分离捕获锁全局约束
_sstdout="$_tmp/split.out"; _sstderr="$_tmp/split.err"
rc=0; OB_TQ_STUB_MODE=good-pass OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/applicable.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x \
    >"$_sstdout" 2>"$_sstderr" || rc=$?
assert_eq "split-stream pass run rc=0" "$rc" "0"
assert_true "live pass line is on stderr" grep -Eq '^  TEST-A[[:space:]]+pass$' "$_sstderr"
assert_true "stdout (compact-rows) carries no pass AR row" bash -c "! grep -q 'TEST-A' '$_sstdout'"
assert_true "all-pass run emits no DETAIL ROWS block (no dangling frame)" \
  bash -c "! grep -q '^DETAIL ROWS:' '$_sstdout'"
assert_true "stdout last line is VERDICT" grep -q '^VERDICT: PASS' <<<"$(tail -1 "$_sstdout")"
rc=0; OB_TQ_STUB_MODE=good-fail-multiline OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/applicable.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x \
    >"$_sstdout" 2>"$_sstderr" || rc=$?
assert_eq "split-stream fail run rc=1" "$rc" "1"
assert_true "live fail line is on stderr with inline reason" \
  grep -Eq '^  TEST-A[[:space:]]+fail line1 line2 bad$' "$_sstderr"
assert_true "stdout keeps fail detail row" grep -Eq 'TEST-A[[:space:]]+fail \| code=' "$_sstdout"
assert_true "fail run frames detail rows with DETAIL ROWS header" \
  grep -q '^DETAIL ROWS: 1 non-pass/non-skip AR(s)' "$_sstdout"
assert_true "DETAIL ROWS header is preceded by a separator line" \
  bash -c "grep -B1 '^DETAIL ROWS:' '$_sstdout' | head -1 | grep -qE '^─+$'"
assert_true "stdout last line is VERDICT: FAIL" grep -q '^VERDICT: FAIL' <<<"$(tail -1 "$_sstdout")"

# 6: 大 body record(>128KB 单参数上限)走 stdin 不走 argv — live 行不 E2BIG(回归:
#     曾以 argv 传整 record, python3 "参数列表过长" 致 live 行丢失)
out=""; rc=0; out=$(_run_protocol_capture big-body-pass) || rc=$?
assert_eq "big-body pass run rc=0" "$rc" "0"
assert_true "live line survives >128KB body (record via stdin, not argv)" \
  grep -Eq '^  TEST-A[[:space:]]+pass$' <<<"$out"

# 7: skip live 行恒打 '  <AR> skip | reason [source]'(每条 AR 只出现一次: reason/source
#    在 live 行给全, report --compact-rows 相应跳过 skip 行)。planner \x1f 字段是
#    json.dumps 的 ASCII 转义形态(中文 → \uXXXX), 直接拼会打出转义串(回归);
#    解码走 assemble record。skip 行不区分 -v/-v-default(此前 -v 才带 reason)。
cat > "$_tmp/skip-appl.yaml" <<'YAML'
schema_version: 1
default: applicable
overrides:
  TEST-A: {status: skip, reason: "纯硬件/规格条目, QEMU 不可仿真", source: unit}
YAML
out=""; rc=0
out=$(OB_TQ_STUB_MODE=good-pass OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/skip-appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x 2>&1) || rc=$?
assert_eq "skip run rc=0" "$rc" "0"
assert_true "default skip live line carries decoded Chinese reason [source]" \
  grep -Eq '^  TEST-A[[:space:]]+skip \| 纯硬件/规格条目, QEMU 不可仿真 \[unit\]$' <<<"$out"
assert_eq "skip line appears exactly once (live only, no report duplicate)" \
  "$(grep -Ec 'TEST-A[[:space:]]+skip \|' <<<"$out")" "1"
out=""; rc=0
out=$(OB_TQ_STUB_MODE=good-pass OB_TQ_PROBE="$_tmp/probe-stub.py" \
    OB_TQ_AR_PROBES="$_tmp/one.yaml" OB_TQ_APPL="$_tmp/skip-appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x -v 2>&1) || rc=$?
assert_eq "verbose skip run rc=0" "$rc" "0"
assert_true "verbose skip live line carries decoded Chinese reason [source]" \
  grep -Eq '^  TEST-A[[:space:]]+skip \| 纯硬件/规格条目, QEMU 不可仿真 \[unit\]$' <<<"$out"
assert_true "skip live line has no \\\\uXXXX escapes" \
  bash -c "! grep -E 'skip \\\\\\\\u[0-9a-f]{4}' <<<'$out'"

# 编码回归(评审 🟢4 + 🟡1, 四轮对撞定稿): 敌意 stdio 预设(PYTHONIOENCODING=ascii, UTF-8 mode
# 仍开) + 树内同构中文 reason → run.sh 头部双 export 免疫: xpass 中文正常渲染, rc=0。
# 期望钉在最终修复组合上 — PYTHONIOENCODING=utf-8 覆盖 stdio 面(变体 B), PYTHONUTF8=1 覆盖
# UTF-8 mode 被关(变体 A), 二者互不可替(PYTHONIOENCODING 优先级更高); 移除任一 export 本用例翻红。
# pass-stub 同锁 xpass 判定路径(意外 pass 不污染 exit)。装配层兜底(🟡1)的编码触发器已被
# 双 export 消灭, 不可经本用例到达 — 该分支为防御性, 勿再造测(四轮对撞结论)。
cat > "$_tmp/xfail-zh.yaml" <<'YAML'
schema_version: 1
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
import os
import sys
import yaml

base_ars = [{
    "ar": "TEST-A", "name": "fixture", "probe": "redfish", "suite": "fixture",
    "request": {"method": "get", "path": "/redfish/v1"},
    "assert": [{"type": "status_in", "value": [200]}],
    "depends_on": [], "rationale": "fixture",
  }]

def write_v2(top):
    top = os.path.abspath(top)
    frag_dir = os.path.join(os.path.dirname(top), "ar_probes.d")
    os.makedirs(frag_dir, exist_ok=True)
    frag = os.path.join(frag_dir, os.path.basename(top))
    with open(top, "w") as stream:
        yaml.safe_dump({"schema_version": 2, "auth": {"user": "r", "password": "x"},
                        "include": ["ar_probes.d/" + os.path.basename(top)]}, stream)
    return frag

frag = write_v2(sys.argv[1])
with open(frag, "w") as stream:
    yaml.safe_dump({"ars": base_ars}, stream)
frag = write_v2(sys.argv[2])
base_ars[0]["request"] = {"method": "GET", "path": "/redfish/v1\x1fManagers"}
with open(frag, "w") as stream:
    yaml.safe_dump({"ars": base_ars}, stream)
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
schema_version: 2
auth: {user: r, password: x}
include: [ar_probes.d/skip-noreq.yaml]
YAML
cat > "$_tmp/ar_probes.d/skip-noreq.yaml" <<'YAML'
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
schema_version: 1
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

# ── runner.py 函数级直调段(下沉后 live 行格式成为可 import 的测试面) ──
RUNNER_DIR="$(dirname "$RUNNER")"
_py() { python3 - "$RUNNER_DIR" "$@"; }

# oneline: 截断 120 / 换行替空格 / 非 str coerce
_py "$RUNNER_DIR" <<'PY' && _fn_ok=1 || _fn_ok=0
import sys
sys.path.insert(0, sys.argv[1])
import report
assert report.oneline("多行\nreason") == "多行 reason"
assert report.oneline("x" * 200) == "x" * 120
assert report.oneline(None) == ""
assert report.oneline(7) == "7"
print("fn-ok")
PY
assert_eq "report.oneline 直调(截断/换行/coerce)" "$_fn_ok" "1"

# live_line: skip 裸行带 [source] / fail 恒带 reason / -v=1 额外带 code=
_py "$RUNNER_DIR" <<'PY' && _live_ok=1 || _live_ok=0
import sys
sys.path.insert(0, sys.argv[1])
import report
ll = report.live_line({"ar": "A", "status": "skip", "reason": "r", "source": "unit"}, 0)
assert ll == "  A              skip | r [unit]", ll
ll = report.live_line({"ar": "A", "status": "skip", "reason": "r", "source": ""}, 1)
assert ll.endswith("skip | r"), ll
ll = report.live_line({"ar": "A", "status": "fail", "reason": "boom"}, 0)
assert ll.endswith("fail boom"), ll
ll = report.live_line({"ar": "A", "status": "fail", "reason": "boom", "code": 401}, 1)
assert ll == "  A              fail code=401 boom", ll
ll = report.live_line({"ar": "A", "status": "error", "reason": "x", "code": None}, 1)
assert ll.endswith("error x"), ll
ll = report.live_line({"ar": "A", "status": "fail", "reason": "boom\nx" * 100}, 1)
exp = "  {:<14} {}".format("A", "fail " + "boom x" * 20)  # 合并后每单元 6 字符 ×20 = 120
assert ll == exp, (ll, exp)
print("live-ok")
PY
assert_eq "report.live_line 直调(skip/-v 语义/截断)" "$_live_ok" "1"

# 共用不变量: 同一 skip record 过 live_line(stderr 流)与 run_report 逐条行(stdout),
# reason 片段一致(同源 oneline, 防未来分叉)
_tmp2=$(mktemp -d)
_py "$RUNNER_DIR" "$_tmp2" <<'PY' && _inv_ok=1 || _inv_ok=0
import io, sys, contextlib
sys.path.insert(0, sys.argv[1])
import report
rec = {"ar": "INV", "status": "skip", "reason": "共享\nreason", "source": "unit"}
live = report.live_line(rec, 0)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    report.run_report([rec], None, False)  # 非 compact, skip 逐条行也打
# 块首分隔 + DETAIL ROWS 标头(2026-08-20)占前 2 行, 逐条行按 AR 前缀定位, 不取 [0]
rows = [l for l in buf.getvalue().splitlines() if l.startswith("  INV")]
assert len(rows) == 1, buf.getvalue()
row = rows[0]
assert "共享 reason" in live and "共享 reason" in row, (live, row)
print("inv-ok")
PY
assert_eq "live 行与逐条行共用 oneline 不变量" "$_inv_ok" "1"
rm -rf "$_tmp2"

# probe stderr 透传: stub probe 向 stderr 打诊断标记, runner stderr 须可见
# (防 subprocess 形态只捕 stdout 后把诊断吞掉)。stub 是 python 形态 —
# runner 沿旧惯例以 python3 调 probe。
_tmp3=$(mktemp -d)
cat > "$_tmp3/probe.py" <<'EOF'
import sys
sys.stderr.write("PROBE-STDERR-DIAG\n")
sys.stdout.write('{"pass": true, "code": 200, "body": "b", "actual": null, "reason": "", "error": false}')
sys.exit(0)
EOF
cat > "$_tmp3/ars.yaml" <<'YAML'
schema_version: 2
include: [ar_probes.d/ars.yaml]
YAML
mkdir -p "$_tmp3/ar_probes.d"
cat > "$_tmp3/ar_probes.d/ars.yaml" <<'YAML'
ars:
  - ar: T-STDERR
    suite: t
    request: {method: GET, path: /redfish/v1}
    assert:
      - {type: status_in, value: [200]}
YAML
cat > "$_tmp3/appl.yaml" <<'YAML'
schema_version: 1
default: applicable
YAML
OB_TQ_AR_PROBES="$_tmp3/ars.yaml" OB_TQ_APPL="$_tmp3/appl.yaml" OB_TQ_PROBE="$_tmp3/probe.py" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --timeout 2 \
    >"$_tmp3/out" 2>"$_tmp3/err" || true
assert_true "probe stderr 诊断透传到 runner stderr" grep -q "PROBE-STDERR-DIAG" "$_tmp3/err"

# body 空 JSON 透传: POST body {} 的 AR, stub probe 回显 --body argv 进 record
# reason, 经 --report JSON 断言(pass record 会被 --compact-rows 隐藏, 不走 stderr)
cat > "$_tmp3/probe2.py" <<'EOF'
import json, sys
body = ""
prev = ""
for a in sys.argv[1:]:
    if prev == "--body":
        body = a
    prev = a
sys.stdout.write(json.dumps({"pass": True, "code": 200, "body": "got --body " + body,
                             "actual": None, "reason": "BODY-ARG=[" + body + "]",
                             "error": False}))
sys.exit(0)
EOF
cat > "$_tmp3/ars2.yaml" <<'YAML'
schema_version: 2
include: [ar_probes.d/ars2.yaml]
YAML
cat > "$_tmp3/ar_probes.d/ars2.yaml" <<'YAML'
ars:
  - ar: T-BODY
    suite: t
    request: {method: POST, path: /redfish/v1/Actions, body: {}}
    assert:
      - {type: status_in, value: [200]}
YAML
rc=0
OB_TQ_AR_PROBES="$_tmp3/ars2.yaml" OB_TQ_APPL="$_tmp3/appl.yaml" OB_TQ_PROBE="$_tmp3/probe2.py" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --timeout 2 \
    --report "$_tmp3/report.json" >/dev/null 2>&1 || rc=$?
assert_eq "body {} 用例 runner exit 0" "$rc" "0"
assert_true "body {} 经 --body {} 透传(present iff not None)" \
    python3 -c '
import json, sys
recs = json.load(open(sys.argv[1]))["records"]
r = [x for x in recs if x["ar"] == "T-BODY"][0]
assert "BODY-ARG=[{}]" in r.get("reason", ""), r.get("reason")
' "$_tmp3/report.json"
rm -rf "$_tmp3"

# status_in.value schema 校验: 写坏(values typo / 空 / 非 list)→ planner exit 3,
# 不进 α truth(probe 读 a.get("value", []) 会静默拿 [] → 全 fail 冒充 BMC 缺陷)
_tmp4=$(mktemp -d)
cat > "$_tmp4/appl.yaml" <<'YAML'
schema_version: 1
default: applicable
YAML
for badval in 'values: [200]' 'value: []' 'value: 200'; do
  cat > "$_tmp4/ars.yaml" <<YAML
schema_version: 2
include: [ar_probes.d/ars.yaml]
YAML
  mkdir -p "$_tmp4/ar_probes.d"
  cat > "$_tmp4/ar_probes.d/ars.yaml" <<YAML
ars:
  - ar: T-BADASSERT
    suite: t
    request: {method: GET, path: /redfish/v1}
    assert:
      - {type: status_in, $badval}
YAML
  rc=0; OB_TQ_AR_PROBES="$_tmp4/ars.yaml" OB_TQ_APPL="$_tmp4/appl.yaml" \
      bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run \
      >/dev/null 2>"$_tmp4/err" || rc=$?
  assert_eq "status_in 写坏($badval) → exit 3" "$rc" "3"
  assert_true "remedy 指名 status_in.value($badval)" grep -q "status_in.value" "$_tmp4/err"
done
rm -rf "$_tmp4"

# include 契约负例(布局 v2, ADR-0025/0027 增补): 缺失分片/越界/sibling 前缀/绝对路径/
# 顶层 ars/跨分片重复 AR/分片缺 ars/v1 旧形态, 全部 exit 3; v1 形态必须报 bad schema_version
# (校验顺序: schema 门禁先于结构契约)。sibling 案用 relpath 生成真相对路径, 只考验
# commonpath 判界(绝对路径行为由独立负例覆盖)。
_tmp6=$(mktemp -d)
mkdir -p "$_tmp6/ar_probes.d"
cat > "$_tmp6/appl.yaml" <<'YAML'
schema_version: 1
default: applicable
YAML
_mk_top() {  # $1 = include 列表 YAML 文本(单行), 写到 $_tmp6/ar_probes.yaml
  printf 'schema_version: 2\nauth: {user: r, password: x}\ninclude: [%s]\n' "$1" \
    > "$_tmp6/ar_probes.yaml"
}
_inc_neg() {  # $1 = 用例名, $2 = 可选 stderr grep 模式
  rc=0; OB_TQ_AR_PROBES="$_tmp6/ar_probes.yaml" OB_TQ_APPL="$_tmp6/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run \
    >"$_tmp6/out" 2>&1 || rc=$?
  assert_eq "include contract [$1] → exit 3" "$rc" "3"
  if [ "$#" -ge 2 ]; then
    assert_true "include contract [$1] stderr 指名 $2" grep -q "$2" "$_tmp6/out"
  fi
}
cat > "$_tmp6/ar_probes.d/ok.yaml" <<'YAML'
ars:
  - ar: TEST-A
    suite: fixture
    request: {method: GET, path: /redfish/v1}
    assert: [{type: status_in, value: [200]}]
    depends_on: []
YAML

# 缺失分片 → include + 路径指名
_mk_top 'ar_probes.d/nope.yaml'
_inc_neg "missing fragment" 'include.*nope'

# 逃出 baseline 目录(../..)
_mk_top '../../etc/passwd'
_inc_neg "escape via ../../"

# sibling 前缀逃逸: <tmpdir>-evil 与 base 共享字符串前缀, startswith 会误放行
_evil="${_tmp6}-evil"; mkdir -p "$_evil"
printf 'ars: []\n' > "$_evil/x.yaml"
_rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
  "$_evil/x.yaml" "$_tmp6")"
_mk_top "$_rel"
_inc_neg "sibling-prefix escape"

# 绝对路径 include: 路径合法且在 base 内, 仍拒(relocatable 契约)
_mk_top "$_tmp6/ar_probes.d/ok.yaml"
_inc_neg "absolute include path"

# 顶层 ars 不允许(v2 ars 只能住在分片)
_mk_top 'ar_probes.d/ok.yaml'
printf 'schema_version: 2\nauth: {user: r, password: x}\nars: []\ninclude: [ar_probes.d/ok.yaml]\n' \
  > "$_tmp6/ar_probes.yaml"
_inc_neg "top-level ars rejected" "top-level 'ars'"

# 跨分片重复 AR id
cat > "$_tmp6/ar_probes.d/dup.yaml" <<'YAML'
ars:
  - ar: TEST-A
    suite: fixture
    request: {method: GET, path: /redfish/v1}
    assert: [{type: status_in, value: [200]}]
    depends_on: []
YAML
_mk_top 'ar_probes.d/ok.yaml, ar_probes.d/dup.yaml'
_inc_neg "duplicate AR across fragments" 'duplicate AR ID'

# 分片缺 ars 键
printf '# no ars here\n' > "$_tmp6/ar_probes.d/noars.yaml"
_mk_top 'ar_probes.d/noars.yaml'
_inc_neg "fragment missing ars key"

# v1 旧单文件形态(schema_version: 1 + 顶层 ars) → bad schema_version, 非结构错
printf 'schema_version: 1\nauth: {user: r, password: x}\nars: []\n' > "$_tmp6/ar_probes.yaml"
_inc_neg "v1 single-file form" 'bad schema_version'

rm -rf "$_tmp6" "$_evil"

# schema_version 门禁回归矩阵(ADR-0027 两仓耦合): bool/string/越界版本/旧版本/missing
# × 两份 YAML(ar_probes 基准 v2 / applicability 基准 v1), 全部 exit 3 + "bad schema_version"。
# bool 案尤其关键——type(v) is not int 防 True == 1 穿透(评审三轮真 bug), 不得退化成
# isinstance/not in 单检查。ar_probes 侧须拷整个 ar_probes.d/(v2 include 契约),
# 否则 gate 未测先死在 include missing。
_tmp5=$(mktemp -d)
_repo_data="$_repo/tests/baseline/romulus"
_gate_case() {  # $1 = tamper, $2 = which; 表达式含空格, 调用侧双引号传参
  local tamper="$1" which="$2"
  cp "$_repo_data"/*.yaml "$_tmp5/" && cp -r "$_repo_data/ar_probes.d" "$_tmp5/"
  sed -i "$tamper" "$_tmp5/$which"
  rc=0; OB_TQ_AR_PROBES="$_tmp5/ar_probes.yaml" OB_TQ_APPL="$_tmp5/applicability.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run \
    >"$_tmp5/out" 2>&1 || rc=$?
  assert_eq "schema gate [$tamper @ $which] → exit 3" "$rc" "3"
  assert_true "schema gate [$tamper @ $which] remedy 指名 schema_version" \
    grep -q "bad schema_version" "$_tmp5/out"
}
for tamper in 's/^schema_version: 2/schema_version: true/' \
              's/^schema_version: 2/schema_version: "2"/' \
              's/^schema_version: 2/schema_version: 99/' \
              's/^schema_version: 2/schema_version: 1/' \
              '/^schema_version: 2/d'; do
  _gate_case "$tamper" ar_probes.yaml
done
for tamper in 's/^schema_version: 1/schema_version: true/' \
              's/^schema_version: 1/schema_version: "1"/' \
              's/^schema_version: 1/schema_version: 99/' \
              's/^schema_version: 1/schema_version: 2/' \
              '/^schema_version: 1/d'; do
  _gate_case "$tamper" applicability.yaml
done
rm -rf "$_tmp5"

# ── SMOKE-08 login 块 schema 与分派(2026-08-21 计划: web login 两段式) ──
_tmp6=$(mktemp -d)
# fixture: 单 web AR + login 块(合法/非法变体), 复用 smoke 的 appl 形态
_web_case() {  # $1 = login 行内容(YAML 片段), $2 = 描述
  local login_yaml="$1"
  cat > "$_tmp6/ar_probes.yaml" <<'YAML'
schema_version: 2
auth: {user: r, password: x}
include: [ar_probes.d/web.yaml]
YAML
  mkdir -p "$_tmp6/ar_probes.d"
  {
    echo "ars:"
    echo "  - ar: WEB-01"
    echo "    name: web login probe"
    echo "    probe: web"
    echo "    suite: web"
    echo "    request:"
    echo "      path: /"
    echo "      login:"
    printf '%s\n' "$login_yaml"
    echo "    assert:"
    echo "      - type: status_in"
    echo "        value: [200]"
    echo "    depends_on: []"
    echo "    rationale: test"
  } > "$_tmp6/ar_probes.d/web.yaml"
  rc=0; OB_TQ_AR_PROBES="$_tmp6/ar_probes.yaml" OB_TQ_APPL="$_tmp6/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --suite web --dry-run \
    >"$_tmp6/out" 2>&1 || rc=$?
  echo "$rc"
}

cat > "$_tmp6/appl.yaml" <<'YAML'
schema_version: 1
default: applicable
overrides: {}
YAML

# ① 非法键 → exit 3 指名
rc=$(_web_case "        bad_key: 1" "")
assert_eq "login 非法键 → exit 3" "$rc" "3"
grep -q "login allows only" "$_tmp6/out"
assert_true "login 非法键 remedy 指名 allows only" grep -q "login allows only" "$_tmp6/out"

# ①' logout_method 非法值 → exit 3
rc=$(_web_case "        path: /login
        body: '{user}:{password}'
        logout_method: GET" "")
assert_eq "login logout_method=GET → exit 3" "$rc" "3"
assert_true "logout_method remedy 指名 POST/DELETE" grep -q "logout_method must be" "$_tmp6/out"

# ①'' body 缺占位符 → exit 3(fail-closed: 凭据硬编码/漏写占位符 schema gate 拦截)
rc=$(_web_case "        path: /login
        body: 'static-body-without-placeholders'" "")
assert_eq "login body 缺占位符 → exit 3" "$rc" "3"
assert_true "缺占位符 remedy 指名 placeholders" grep -q "placeholders" "$_tmp6/out"
rc=$(_web_case "        path: /login
        body: 'only-{user}-here'" "")
assert_eq "login body 缺 {password} → exit 3" "$rc" "3"

# ② 合法 login 块 → dry-run exit 0
rc=$(_web_case "        path: /login
        content_type: application/json
        body: '{\"username\":\"{user}\",\"password\":\"{password}\"}'
        csrf: false
        ok_statuses: [200, 201]
        logout_path: /logout
        logout_method: POST" "")
assert_eq "合法 login 块 dry-run → exit 0" "$rc" "0"

# ③ stub 分派测试: 整目录复制 runner, probe_web.py 换 argv/env 记录 stub, 非 dry-run
#    跑 web suite, 断言 --login 透传 / 密码不进 argv / probe 侧 OB_TQ_WEB_* 优先。
_tmp_runner=$(mktemp -d)
cp -r "$_repo/tests/baseline/runner/." "$_tmp_runner/"
rm -rf "$_tmp_runner/__pycache__"
cat > "$_tmp_runner/probe_web.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["OB_TQ_STUB_RECORD"], "w") as f:
    json.dump({"argv": sys.argv[1:],
               "web_user": os.environ.get("OB_TQ_WEB_USER"),
               "web_password": os.environ.get("OB_TQ_WEB_PASSWORD")}, f)
print(json.dumps({"pass": True, "code": 200, "body": "", "actual": None, "reason": "stub ok"}))
sys.exit(0)
PY
cat > "$_tmp6/ar_probes.d/web.yaml" <<'YAML'
ars:
  - ar: WEB-01
    name: web login probe
    probe: web
    suite: web
    request:
      path: /
      login:
        path: /login
        body: "{user}:{password}"
        csrf: false
    assert:
      - type: status_in
        value: [200]
    depends_on: []
    rationale: test
YAML
rc=0
OB_TQ_AR_PROBES="$_tmp6/ar_probes.yaml" OB_TQ_APPL="$_tmp6/appl.yaml" \
OB_TQ_STUB_RECORD="$_tmp6/stub_record.json" \
OB_TQ_USER=dummy OB_TQ_PASSWORD=dummy \
OB_TQ_WEB_USER=dummyweb OB_TQ_WEB_PASSWORD=dummyweb \
bash "$_tmp_runner/run.sh" --host 127.0.0.1 --port 1 --suite web >"$_tmp6/out3" 2>&1 || rc=$?
assert_eq "stub 分派: web suite 非 dry-run → exit 0" "$rc" "0"
assert_true "stub 记录存在(分派真的跑到 probe_web)" test -s "$_tmp6/stub_record.json"
if [[ -s "$_tmp6/stub_record.json" ]]; then
  python3 - "$_tmp6/stub_record.json" <<'PY'
import json
import sys

rec = json.load(open(sys.argv[1]))
argv = rec["argv"]
assert "--login" in argv, "argv missing --login: %r" % argv
i = argv.index("--login")
assert '"path": "/login"' in argv[i + 1].replace("\'", '"'), "login JSON not passed"
assert "--password" not in argv and "dummyweb" not in argv and "dummy" not in argv, \
    "password leaked into argv: %r" % argv
assert rec["web_user"] == "dummyweb", "OB_TQ_WEB_USER not preferred: %r" % rec
assert rec["web_password"] == "dummyweb", "OB_TQ_WEB_PASSWORD not preferred: %r" % rec
PY
  assert_eq "stub 记录内容(--login 透传/密码不进 argv/OB_TQ_WEB_* 优先)" "$?" "0"
fi
rm -rf "$_tmp6" "$_tmp_runner"

# ── ipmi command 只读白名单 + --command 通道(2026-08-25 V2.1 第一批导入) ──
# 测试矩阵: a/b/c/d 改动前红(要打通的能力); b2/e 改动前绿且回归锁(不能破坏的现状)。
_tmp7=$(mktemp -d)
mkdir -p "$_tmp7/ar_probes.d" "$_tmp7/fakebin"
cat > "$_tmp7/appl.yaml" <<'YAML'
schema_version: 1
default: applicable
YAML
_mk_ipmi_top() {  # $1 = request YAML 行
  cat > "$_tmp7/ar_probes.d/cmd.yaml" <<YAML
ars:
  - ar: CMD-A
    name: ipmi command fixture
    probe: ipmi
    suite: s
    request: {command: $1}
    assert:
      - type: exitcode_zero
    depends_on: []
YAML
  cat > "$_tmp7/ar_probes.yaml" <<'YAML'
schema_version: 2
auth: {user: r, password: x}
include: [ar_probes.d/cmd.yaml]
YAML
}

# a) 白名单命令 chassis status → dry-run exit 0(改动前红: 现仅 mc_info 通过)
_mk_ipmi_top 'chassis status'
rc=0; OB_TQ_AR_PROBES="$_tmp7/ar_probes.yaml" OB_TQ_APPL="$_tmp7/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp7/out_a" 2>&1 || rc=$?
assert_eq "ipmi whitelist command dry-run → exit 0" "$rc" "0"

# b) 非白名单写命令 sel clear → exit 3 + read-only 文案(改动前红: 现文案 must be 'mc_info')
_mk_ipmi_top 'sel clear'
rc=0; OB_TQ_AR_PROBES="$_tmp7/ar_probes.yaml" OB_TQ_APPL="$_tmp7/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp7/out_b" 2>&1 || rc=$?
assert_eq "ipmi non-whitelist command → exit 3" "$rc" "3"
assert_true "non-whitelist remedy mentions read-only" grep -q "read-only" "$_tmp7/out_b"

# b2) YAML list command → exit 3 且无 traceback(回归锁: 现状 != 比较即干净 exit 3;
#     防 frozenset in 匹配对 unhashable list 抛 TypeError 污染成 exit 1)
_mk_ipmi_top '[chassis, status]'
rc=0; OB_TQ_AR_PROBES="$_tmp7/ar_probes.yaml" OB_TQ_APPL="$_tmp7/appl.yaml" \
    bash "$RUNNER" --host 127.0.0.1 --port 1 --user r --password x --dry-run >"$_tmp7/out_b2" 2>&1 || rc=$?
assert_eq "ipmi list-type command → exit 3" "$rc" "3"
if grep -q "Traceback" "$_tmp7/out_b2"; then
  assert_eq "list-type command no traceback" "traceback-found" "clean"
else
  assert_eq "list-type command no traceback" "clean" "clean"
fi

# c) probe 直测 --command 透传到 ipmitool argv(改动前红: probe 无 --command 参数)
cat > "$_tmp7/fakebin/ipmitool" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >> "$IPMI_ARGV_FILE"
exit 0
SH
chmod +x "$_tmp7/fakebin/ipmitool"
rc=0
IPMI_ARGV_FILE="$_tmp7/argv_c" PATH="$_tmp7/fakebin:$PATH" OB_TQ_IPMI_PORT=2623 \
OB_TQ_IPMI_USER=u OB_TQ_IPMI_PASSWORD=p \
    python3 "$(dirname "$RUNNER")/probe_ipmi.py" \
    --command "chassis status" --asserts '[{"type":"exitcode_zero"}]' >/dev/null 2>&1 || rc=$?
assert_eq "probe --command 直测 → exit 0" "$rc" "0"
if [[ -s "$_tmp7/argv_c" ]]; then
  assert_eq "probe argv 尾部 = chassis status" \
    "$(tail -2 "$_tmp7/argv_c" | paste -sd' ')" "chassis status"
else
  assert_eq "probe argv 落盘(fake ipmitool 被调)" "missing" "present"
fi

# _live_ipmi_case: 全链 fixture 经 run.sh 跑真 probe + fake ipmitool, 断言 argv 尾部
_live_ipmi_case() {  # $1 = command 值, $2 = 期望 argv 尾部, $3 = argv 落盘后缀
  _mk_ipmi_top "$1"
  rc=0
  OB_TQ_AR_PROBES="$_tmp7/ar_probes.yaml" OB_TQ_APPL="$_tmp7/appl.yaml" \
  OB_TQ_USER=r OB_TQ_PASSWORD=x OB_TQ_IPMI_PORT=2623 \
  IPMI_ARGV_FILE="$_tmp7/argv_$3" PATH="$_tmp7/fakebin:$PATH" \
      bash "$RUNNER" --host 127.0.0.1 --port 1 --suite s >"$_tmp7/out_$3" 2>&1 || rc=$?
  assert_eq "全链 ipmi [$1] → exit 0" "$rc" "0"
  if [[ -s "$_tmp7/argv_$3" ]]; then
    assert_eq "全链 ipmi argv 尾部 = [$2]" \
      "$(tail -$(echo "$2" | wc -w) "$_tmp7/argv_$3" | paste -sd' ')" "$2"
  else
    assert_eq "全链 ipmi argv 落盘(fake ipmitool 被调)" "missing" "present"
  fi
}

# d) 全链非默认命令 chassis status(改动前红: runner 不传 --command 时 probe 跑默认 mc info)
_live_ipmi_case 'chassis status' 'chassis status' d

# e) 全链 mc_info 归一(回归锁: 现状 planner 接受 mc_info + probe 默认 mc info 恰好成立;
#    实施后归一化必须保持该行为)
_live_ipmi_case 'mc_info' 'mc info' e

rm -rf "$_tmp7"

assert_summary
