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

# --- _replace_community_binary: 正常事务(backup→swap→manifest→cleanup bak) ---
# 显式设 SOURCE_MANIFEST_FILE: read_source_label(repo.sh:8) → read_manifest_field(util.sh:422)
# → read_kv_field "$SOURCE_MANIFEST_FILE" 读的是这个全局(非 CONFIGS_DIR); ob_loader 加载时
# 它为空(ob:15), 仅设 CONFIGS_DIR 会靠 fallback "community" 碰巧过——约束须在测试里显式成立。
CONFIGS_DIR="$TMP/configs"; mkdir -p "$CONFIGS_DIR"
SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
printf 'source_label=community\n' > "$SOURCE_MANIFEST_FILE"
QEMU_BIN_FILE="$QEMU_BIN_DIR/qemu-system-arm"
printf 'OLD' > "$QEMU_BIN_FILE"
printf 'build_number=40\nurl=https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm\n' > "$QEMU_BIN_FILE.manifest"
new_binary="$TMP/newbin"; printf 'NEW' > "$new_binary"; chmod +x "$new_binary"
(
    _replace_community_binary "$new_binary" "deadbeef" "https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm" "42" "qemu-system-arm"
    echo "RC=$?"
) > "$TMP/c1" 2>&1
assert_eq "commit 正常 → rc=0" "$(grep -o 'RC=[01]' "$TMP/c1")" "RC=0"
assert_true "commit 正常: binary 已换新" grep -q NEW "$QEMU_BIN_FILE"
assert_true "commit 正常: bak 已清理" test ! -f "$QEMU_BIN_FILE-40.bak"
assert_true "commit 正常: manifest build_number=42" grep -q 'build_number=42' "$QEMU_BIN_FILE.manifest"

# --- _replace_community_binary: swap-fail-rollback(stateful mv: 第1次 swap fail / 第2次 rollback real) ---
printf 'OLD' > "$QEMU_BIN_FILE"
printf 'build_number=40\nurl=https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm\n' > "$QEMU_BIN_FILE.manifest"
new_binary2="$TMP/newbin2"; printf 'NEW' > "$new_binary2"; chmod +x "$new_binary2"
(
    _mv_n=0
    mv() { _mv_n=$((_mv_n+1)); if (( _mv_n == 1 )); then return 1; fi; command mv "$@"; }
    _replace_community_binary "$new_binary2" "deadbeef" "https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm" "42" "qemu-system-arm"
    echo "RC=$?"
) > "$TMP/c2" 2>&1
assert_eq "swap-fail → rc=1(rollback 后)" "$(grep -o 'RC=[01]' "$TMP/c2")" "RC=1"
assert_true "rollback 恢复旧 binary" grep -q OLD "$QEMU_BIN_FILE"

rm -rf "$TMP" "$extract_dir" "$extract_dir2"
assert_summary
