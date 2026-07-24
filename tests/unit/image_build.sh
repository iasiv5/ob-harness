#!/usr/bin/env bash
# tests/unit/image_build.sh — build_obmc_image leaf-pure 单测(unit 层)。
# stub build_env_enter/resolve_npm_registry/apply_npm_registry(函数 override) + bitbake(PATH fake),
# 覆盖 成功/失败/enter失败 三态。聚焦 enter→bitbake→rc 链; npm 装配由 tests/unit/npm_registry.sh 专门测。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

DB="$(mktemp -d)"
mkfake_bin "$DB" bitbake
trap 'rm -rf "$DB"' EXIT

# stub: build_env_enter 默认 noop 成功, _BUILD_ENV_RC 控制 enter 失败; resolve/apply noop。
build_env_enter() { [[ "${_BUILD_ENV_RC:-0}" -eq 0 ]] || return "$_BUILD_ENV_RC"; }
resolve_npm_registry() { :; }
apply_npm_registry() { :; }

# --- 态 1: bitbake 成功 → build_obmc_image return 0 + calls=1 + target 正确 ---
_BUILD_ENV_RC=0
stub_exit "$DB" bitbake 0
PATH="$DB:$PATH" build_obmc_image romulus /tmp/build >/dev/null 2>&1
assert_eq "bitbake ok → rc 0" "$?" 0
assert_eq "bitbake called once" "$(wc -l < "$DB/.bitbake.calls")" 1
assert_eq "bitbake target" "$(cat "$DB/.bitbake.calls")" "obmc-phosphor-image"

# --- 态 2: bitbake 失败 → build_obmc_image return 1 ---
rm -f "$DB/.bitbake.calls"
stub_exit "$DB" bitbake 1
PATH="$DB:$PATH" build_obmc_image romulus /tmp/build >/dev/null 2>&1
assert_eq "bitbake fail → rc 1" "$?" 1
assert_eq "bitbake called once (fail)" "$(wc -l < "$DB/.bitbake.calls")" 1

# --- 态 3: build_env_enter 失败 → build_obmc_image return 1, bitbake 不该被调 ---
rm -f "$DB/.bitbake.calls"
_BUILD_ENV_RC=1
stub_exit "$DB" bitbake 0   # bitbake 设成功, 但 enter 失败不该到 bitbake
PATH="$DB:$PATH" build_obmc_image romulus /tmp/build >/dev/null 2>&1
assert_eq "enter fail → rc 1" "$?" 1
# bitbake 未被调 → .calls 不存在; 用 assert_false test -f(与 deploy_to_qemu.sh 场景④ 同款),
# 避免 wc -l < miss 的 bash 重定向错误噪音(2>/dev/null 吞不掉 bash 层 < 打开失败)。
assert_false "enter fail: bitbake not called" test -f "$DB/.bitbake.calls"

assert_summary
