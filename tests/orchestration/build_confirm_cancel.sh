#!/usr/bin/env bash
# tests/orchestration/build_confirm_cancel.sh — cmd_build inline confirm-cancel 测试。
# 锁 build 的 confirm 路径迁 inline case+warn 后的 cancel 行为（替 exit_on_user_cancel, 保 warn）:
#   rc=2 + 合并输出（2>&1）含 "Build cancelled by user."。弥补 interact.sh 不再断 exit_on_user_cancel（ADR-0019）。
# 不依赖 expect/真实 workspace: function-override stub resolve_command_machine（return 0 + set $MACHINE,
#   模拟交互选号成功 → interactive_selection → confirm）+ confirm_action（return 2 cancel）。
# cmd_build 在 command substitution 子 shell 跑, 其 exit 2 不杀测试脚本。对照 cmd_build_bitbake_handoff.sh。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OPENBMC_DIR="$TMP/openbmc"; CONFIGS_DIR="$TMP/configs"
SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
DRY_RUN=0
export OPENBMC_DIR CONFIGS_DIR SOURCE_MANIFEST_FILE DRY_RUN
mkdir -p "$OPENBMC_DIR/.git" "$CONFIGS_DIR"
touch "$SOURCE_MANIFEST_FILE"

# stub: seam 解析成功（set $MACHINE + return 0 → caller 进 interactive_selection confirm 门）。
resolve_command_machine(){ MACHINE="romulus"; return 0; }
# stub: confirm 取消（rc=2）。
confirm_action(){ return 2; }

# MACHINE 置空 → had_explicit=0 → seam(stub) 设 $MACHINE + return 0 → interactive_selection=1 → confirm cancel。
MACHINE=""
rc=0
out=$(cmd_build 2>&1) || rc=$?
assert_eq "confirm cancel rc=2" "$rc" "2"
# warn() 走 stdout（util.sh:10 无 >&2），合并 2>&1 捕获；只查 stderr 会假失败。
assert_contains "confirm cancel warn (merged)" "$out" "Build cancelled by user."

assert_summary
