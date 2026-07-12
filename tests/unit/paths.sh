#!/usr/bin/env bash
# tests/unit/paths.sh — 路径/推导类纯函数单测(unit 层)。
# 覆盖 derive_qemu_url_config_path / detect_harness_root / detect_wsl / calc_parallelism。
# (SRC_URI → bare mirror path 推导已并入 bare mirror 批量 planner,行为金标在
#  orchestration/clone_sub_repos.sh 与 orchestration/bare_mirror_cost.sh 覆盖。)
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

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
