#!/usr/bin/env bash
# tests/orchestration/qemu_binary_replace.sh — binary acquire/commit 切面 orchestration。
# _dlqbc_stage_binary(stub download_qemu_binary_core, chmod+x 两态) +
# (Task 5 追加) _replace_community_binary(真实 fs 正常事务 + stateful mv swap-fail-rollback)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
QEMU_BIN_DIR="$TMP/qemu-bin/community"
mkdir -p "$QEMU_BIN_DIR"
MACHINE=romulus

# stub download_qemu_binary_core: case 1 成功(写假 binary + 设全局), case 2 失败(return 1)
install_ok_core() {
    download_qemu_binary_core() {
        printf 'NEW' > "$2/$3"
        DLQB_BIN_PATH="$2/$3"
        DLQB_SHA256="deadbeef"
        return 0
    }
}

# --- _dlqbc_stage_binary: core 成功 → chmod+x 校验通过 → return 0 ---
extract_dir="$(mktemp -d)"
install_ok_core
(
    _dlqbc_stage_binary "https://example.com/x" "$extract_dir" "qemu-system-arm"
    echo "RC=$?"
) > "$TMP/a1" 2>&1
assert_eq "acquire core 成功 → rc=0" "$(grep -o 'RC=[01]' "$TMP/a1")" "RC=0"
assert_true "acquire: DLQB_BIN_PATH 已 chmod+x" test -x "$extract_dir/qemu-system-arm"

# --- _dlqbc_stage_binary: core 失败(return 1) → return 1 ---
extract_dir2="$(mktemp -d)"
download_qemu_binary_core() { return 1; }
(
    _dlqbc_stage_binary "https://example.com/x" "$extract_dir2" "qemu-system-arm"
    echo "RC=$?"
) > "$TMP/a2" 2>&1
assert_eq "acquire core 失败 → rc=1" "$(grep -o 'RC=[01]' "$TMP/a2")" "RC=1"

rm -rf "$TMP" "$extract_dir" "$extract_dir2"
assert_summary
