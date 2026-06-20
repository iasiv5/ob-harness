#!/usr/bin/env bash
# tests/unit/paths.sh — 路径/推导类纯函数单测(unit 层)。
# 覆盖 derive_bitbake_git_mirror_path / derive_qemu_url_config_path /
#       detect_harness_root / detect_wsl / calc_parallelism。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# --- derive_bitbake_git_mirror_path: SRC_URI → bare mirror gitsrcname 路径 ---
ref="$(mktemp -d)"
out="$(derive_bitbake_git_mirror_path "$ref" 'https://github.com/openbmc/openbmc.git')"
assert_contains "gitsrcname https" "$out" "$ref/github.com.openbmc.openbmc.git"
# 带分号(;branch=main 等参数应被截断)
out="$(derive_bitbake_git_mirror_path "$ref" 'https://github.com/openbmc/openbmc.git;branch=main')"
assert_contains "gitsrcname strip params" "$out" "$ref/github.com.openbmc.openbmc.git"
# 空 src_uri → 非 0(python3 sys.exit 1)
derive_bitbake_git_mirror_path "$ref" '' >/dev/null 2>&1; assert_eq "empty src_uri rc" "$?" 1
rm -rf "$ref"

# --- derive_qemu_url_config_path: 设全局 QEMU_URL_CONFIG_FILE(用临时 WORKSPACE_DIR) ---
WORKSPACE_DIR="/tmp/ob-unit-paths-$$"
derive_qemu_url_config_path
assert_eq "qemu url config path" "$QEMU_URL_CONFIG_FILE" "$WORKSPACE_DIR/qemu-bin/qemu-binary-urls.conf"

# --- detect_harness_root: 设全局(基于 ob 的 BASH_SOURCE → 仓库根) ---
detect_harness_root
assert_eq "harness root = ob dir" "$HARNESS_ROOT" "$OB_DIR"
assert_eq "workspace dir" "$WORKSPACE_DIR" "$HARNESS_ROOT/workspace"
assert_eq "configs dir" "$CONFIGS_DIR" "$HARNESS_ROOT/workspace/configs"

# --- detect_wsl: 返回码应 = 直接 grep microsoft /proc/version ---
detect_wsl; dw=$?
grep -qi microsoft /proc/version 2>/dev/null; gp=$?
assert_eq "detect_wsl matches /proc/version" "$dw" "$gp"

# --- calc_parallelism: 正整数且 ≤ nproc ---
p="$(calc_parallelism)"
assert_match "parallelism positive int" "$p" '^[1-9][0-9]*$'
cores="$(nproc 2>/dev/null || echo 1)"
assert_true "parallelism <= nproc" bash -c "(($p <= $cores))"

assert_summary
