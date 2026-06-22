#!/usr/bin/env bash
# tests/unit/conf_read.sh — local.conf 读取类半纯函数单测(unit 层,文件 IO)。
# 覆盖 read_local_conf_var / resolve_effective_dl_dir / resolve_effective_sstate_dir。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"

# --- read_local_conf_var:python3 正则匹配 VAR ??=/?=/:=/=,去注释/引号 ---
cat > "$TMP/local.conf" <<EOF
DL_DIR = "/custom/dl"
SSTATE_DIR ?= "/custom/sstate"
MACHINE ??= "romulus"
# COMMENT = "ignored"
NPM = value # trailing comment
EOF
assert_eq "read DL_DIR"        "$(read_local_conf_var "$TMP/local.conf" DL_DIR)"      "/custom/dl"
assert_eq "read SSTATE_DIR"    "$(read_local_conf_var "$TMP/local.conf" SSTATE_DIR)"  "/custom/sstate"
assert_eq "read MACHINE"       "$(read_local_conf_var "$TMP/local.conf" MACHINE)"     "romulus"
assert_eq "read strip comment" "$(read_local_conf_var "$TMP/local.conf" NPM)"         "value"
read_local_conf_var "$TMP/local.conf" NOPE     >/dev/null 2>&1; assert_eq "missing var rc"  "$?" 1
read_local_conf_var /nonexistent/conf NOPE    >/dev/null 2>&1; assert_eq "missing file rc" "$?" 1

# --- read_local_conf_var: 空值赋值行 → exit 0 (ADR-0005 依赖) ---
# ob 的 DL_DIR/SSTATE_DIR/PREMIRRORS 判定靠这个 exit code 区分"用户写空(禁用)"与"未写(补默认)"。
# 有赋值行(即使值为空)→ exit 0; 无赋值行 → exit 1。
cat > "$TMP/empty.conf" <<EOF
PREMIRRORS = ""
EOF
read_local_conf_var "$TMP/empty.conf" PREMIRRORS >/dev/null 2>&1
assert_eq "empty-value assignment → rc 0" "$?" 0

# --- resolve_effective_dl_dir/sstate_dir:无 DL_DIR/SSTATE_DIR → 默认 WORKSPACE_DIR/* ---
WORKSPACE_DIR="$TMP/ws"; BUILD_DIR="$TMP/build"; mkdir -p "$BUILD_DIR/conf"
: > "$BUILD_DIR/conf/local.conf"   # 空 local.conf → 用默认
assert_eq "dl_dir default"    "$(resolve_effective_dl_dir)"    "$WORKSPACE_DIR/downloads"
assert_eq "sstate_dir default" "$(resolve_effective_sstate_dir)" "$WORKSPACE_DIR/sstate-cache"

rm -rf "$TMP"
assert_summary
