#!/usr/bin/env bash
# tests/unit/npm_registry.sh — apply_npm_registry leaf-pure 单测(unit 层)。
# 消费 NPM_REGISTRY_RESOLVED 全局, 直接设值喂 apply, 不碰 resolve 的网络 probe
# (resolve_npm_registry/probe_npm_registry 当前零单测, 属另一任务)。
# 不全局关 nounset: 引用可能未设的 export 变量时用 ${var:-} 显式安全取值(红态/回归时优雅 FAIL
# 而非中止), 区分 unset vs 空用 ${var+x}; 文件其余代码仍受 nounset 保护。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

VERBOSE=0
EXP_VARS="npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor"
_out="$(mktemp "${TMPDIR:-/tmp}/ob_npm_unit.XXXXXX")"   # 唯一名, 避免并行竞态
trap 'rm -f "$_out"' EXIT

# --- 态 1: skip → return 0, 不污染环境, 无 stdout ---
unset npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout \
      npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor BB_ENV_PASSTHROUGH_ADDITIONS
NPM_REGISTRY_RESOLVED="skip"
apply_npm_registry >"$_out"
assert_eq "skip rc=0" "$?" 0
assert_eq "skip 无 stdout" "$(cat "$_out")" ""
assert_eq "skip: npm_config_registry 未 export" "${npm_config_registry+x}" ""
assert_eq "skip: BB_ENV_PASSTHROUGH_ADDITIONS 未设" "${BB_ENV_PASSTHROUGH_ADDITIONS+x}" ""

# --- 态 2: resolve + 空 existing → 5 变量 export + BB=_vars(无前缀) ---
unset npm_config_registry npm_config_fetch_timeout npm_config_fetch_retry_maxtimeout \
      npm_config_fetch_retry_mintimeout npm_config_fetch_retry_factor BB_ENV_PASSTHROUGH_ADDITIONS
NPM_REGISTRY_RESOLVED="https://reg.example.com/"
apply_npm_registry >"$_out"
assert_eq "resolve rc=0" "$?" 0
assert_eq "npm_config_registry export" "${npm_config_registry:-}" "https://reg.example.com/"
assert_eq "npm_config_fetch_timeout" "${npm_config_fetch_timeout:-}" "600000"
assert_eq "npm_config_fetch_retry_maxtimeout" "${npm_config_fetch_retry_maxtimeout:-}" "120000"
assert_eq "npm_config_fetch_retry_mintimeout" "${npm_config_fetch_retry_mintimeout:-}" "30000"
assert_eq "npm_config_fetch_retry_factor" "${npm_config_fetch_retry_factor:-}" "2"
assert_eq "BB empty-existing(无前缀)" "${BB_ENV_PASSTHROUGH_ADDITIONS:-}" "$EXP_VARS"

# --- 态 3: resolve + 非空 existing → BB="FOO BAR <vars>" ---
# 锁 existing 前置方式(existing 必须在 vars 前); 5 变量内部相对顺序由态 2(空 existing, BB==$EXP_VARS)字面锁定。
unset npm_config_registry BB_ENV_PASSTHROUGH_ADDITIONS
NPM_REGISTRY_RESOLVED="https://reg.example.com/"
BB_ENV_PASSTHROUGH_ADDITIONS="FOO BAR"
apply_npm_registry >"$_out"
assert_eq "nonempty rc=0" "$?" 0
assert_eq "BB existing 前置" "${BB_ENV_PASSTHROUGH_ADDITIONS:-}" "FOO BAR $EXP_VARS"

# --- 态 4: resolve="" (空串, 等价 npm 默认 registry) → 仍装配 ---
# apply 判定是 != "skip"(非 [ -n ]), 空串 != skip 为真 → export 空 registry + BB 含 vars。
# 锁死"!= skip 即装配"语义, 防将来误改成 [ -n ] && != skip 导致空 registry 不装配(行为偏移无告警)。
unset npm_config_registry BB_ENV_PASSTHROUGH_ADDITIONS
NPM_REGISTRY_RESOLVED=""
apply_npm_registry >"$_out"
assert_eq "empty-registry rc=0" "$?" 0
assert_eq "空 registry 已 export(设但空)" "${npm_config_registry+x}" "x"
assert_eq "空 registry 值为空" "${npm_config_registry:-}" ""
assert_eq "空 registry: BB 含 vars" "${BB_ENV_PASSTHROUGH_ADDITIONS:-}" "$EXP_VARS"

assert_summary
