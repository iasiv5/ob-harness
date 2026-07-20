#!/usr/bin/env bash
# tests/unit/devtool_dispatch.sh — dev_relay_result 单测(unit 层)。
# 覆盖: stage(cd/setup/postcondition → "build env not ready") / phase(reset+finish verbatim 表, metadata token
#       句中 + 副句; 兜底 *)) / rc(per-subcmd 表: modify/reset/finish/build="devtool failed (rc,stage)";
#       status="devtool status failed (rc)" 无 stage) / cat+rm stderr_file / 返回 0(干净)/1(已诊断)。
# 锁 per-subcmd verbatim message 表字节, 防 drift(message 表与 cmd_dev 现状逐字对齐)。
# message 主体用 assert_contains(字面子串 glob)断言——error() 带 [ERROR] 前缀+颜色码, 子串跳过前缀锁主体整条。
# leaf-pure 隐式证明: relay 若误 exit 1 会退出本脚本(不到 assert_summary); 全部 case 跑完即 return 非 exit。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# relay_arg <subcmd> <stage> <phase> <rc> <stderr_content>: 建 stderr tempfile → 调 dev_relay_result
#   → 捕获 rc 到 _rc, stderr 到 _err(message 主体 + cat 出的 stderr_file 内容)。返回后 stderr_file 应被 rm。
relay_arg() {
    local subcmd="$1" stage="$2" phase="$3" rc="$4" content="$5"
    _stderr_file="$(mktemp)"
    [[ -n "$content" ]] && printf '%s' "$content" > "$_stderr_file"
    _rc=0
    _err="$(dev_relay_result "$subcmd" "$_stderr_file" "$stage" "$phase" "$rc" 2>&1 >/dev/null)" || _rc=$?
}

# === ① stage=cd/setup/postcondition(4 subcmd 共享) → "build env not ready", rc=1 ===
relay_arg reset setup "" 0 ""
assert_eq "stage=setup: rc=1" "$_rc" "1"
assert_contains "stage=setup message" "$_err" "ob dev reset: build env not ready (stage=setup)."
relay_arg modify cd "" 0 ""
assert_contains "stage=cd message" "$_err" "ob dev modify: build env not ready (stage=cd)."
relay_arg finish postcondition "" 0 ""
assert_contains "stage=postcondition message" "$_err" "ob dev finish: build env not ready (stage=postcondition)."

# === ② phase=metadata subcmd=reset → 句中 token + 副句(🔴1 关键 case) ===
relay_arg reset command metadata 0 ""
assert_eq "reset phase=metadata: rc=1" "$_rc" "1"
assert_contains "reset phase=metadata message(token 句中)" "$_err" "ob dev reset: metadata error (phase=metadata); cannot safely reset."

# === ③ phase=metadata subcmd=finish ===
relay_arg finish command metadata 0 ""
assert_contains "finish phase=metadata message" "$_err" "ob dev finish: metadata error (phase=metadata); cannot safely finish."

# === ④ phase=finish subcmd=finish ===
relay_arg finish command finish 0 ""
assert_contains "finish phase=finish message" "$_err" "ob dev finish: devtool finish failed (phase=finish)."

# === ⑤ phase=landing subcmd=finish ===
relay_arg finish command landing 0 ""
assert_contains "finish phase=landing message" "$_err" "ob dev finish: landing detection failed (phase=landing); verify patches landed manually."

# === ⑥ phase=postcondition(reset/finish 共享) ===
relay_arg reset command postcondition 0 ""
assert_contains "reset phase=postcondition message" "$_err" "ob dev reset: postcondition failed (phase=postcondition)."
relay_arg finish command postcondition 0 ""
assert_contains "finish phase=postcondition message" "$_err" "ob dev finish: postcondition failed (phase=postcondition)."

# reset 共享表分支: status / reset
relay_arg reset command status 0 ""
assert_contains "reset phase=status message" "$_err" "ob dev reset: devtool status failed (phase=status)."
relay_arg reset command reset 0 ""
assert_contains "reset phase=reset message" "$_err" "ob dev reset: devtool reset failed (phase=reset)."
relay_arg finish command status 0 ""
assert_contains "finish phase=status message" "$_err" "ob dev finish: devtool status failed (phase=status)."

# === ⑦ *) 兜底 phase=unknown subcmd=reset → failed (phase=unknown) ===
relay_arg reset command unknown 0 ""
assert_contains "兜底 phase=unknown message" "$_err" "ob dev reset: failed (phase=unknown)."

# === ⑧ rc 表 per-subcmd(stage=command, phase="", rc≠0) ===
relay_arg modify command "" 2 ""
assert_eq "modify rc=2: rc=1" "$_rc" "1"
assert_contains "modify rc 表(default: devtool failed rc,stage)" "$_err" "ob dev modify: devtool failed (rc=2, stage=command)."
relay_arg status command "" 2 ""
assert_contains "status rc 表(无 stage, 多 status)" "$_err" "ob dev status: devtool status failed (rc=2)."
relay_arg finish command "" 2 ""
assert_contains "finish rc 表(default)" "$_err" "ob dev finish: devtool failed (rc=2, stage=command)."
relay_arg reset command "" 5 ""
assert_contains "reset rc 表(default)" "$_err" "ob dev reset: devtool failed (rc=5, stage=command)."

# === ⑨ stage=command phase="" rc=0 → return 0, 无诊断(cat 仍执行 stderr_file 内容到 >&2) ===
relay_arg reset command "" 0 "RAW_STDERR_NOISE_FROM_DEVTOOL"
assert_eq "rc=0 干净: return 0" "$_rc" "0"
assert_contains "rc=0 cat stderr_file 内容到 >&2" "$_err" "RAW_STDERR_NOISE_FROM_DEVTOOL"
assert_false "rc=0 无诊断 [ERROR]" grep -q "\[ERROR\]" <<<"$_err"

# === ⑩ 调用后 stderr_file 被 rm(⑨ 的 _stderr_file) ===
assert_false "stderr_file 被 rm" test -e "$_stderr_file"

# === build subcmd 前瞻锁(B2 接线; relay 已服务 build, 无 phase, rc 走 default 表) ===
relay_arg build setup "" 0 ""
assert_contains "build stage message" "$_err" "ob dev build: build env not ready (stage=setup)."
relay_arg build command "" 2 ""
assert_contains "build rc 表(default)" "$_err" "ob dev build: devtool failed (rc=2, stage=command)."

# leaf-pure 隐式证明: 失败路径 return 1(非 exit 1)——单测能跑到 assert_summary 即证明 relay 不 exit 脚本
assert_summary
