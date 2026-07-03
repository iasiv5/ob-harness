#!/usr/bin/env bash
# tests/orchestration/qemu_binary_download.sh — binary 下载链 stub characterization。
# 吃掉 agents 标的 #1 盲区: download_qemu_binary_core + ensure_qemu_binary_community。
# flat-binary 路径(curl 写假脚本、真 file/sha256sum,非 gzip→raw binary)。PATH-injection。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
source "$(dirname "$0")/../lib/qemu_stubs.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OB="$ROOT/ob"
TMP="$(mktemp -d)"
DB="$(mktemp -d)"

# ── 公共环境 ──
WORKSPACE_DIR="$TMP/workspace"
CONFIGS_DIR="$WORKSPACE_DIR/configs"
QEMU_BIN_DIR="$WORKSPACE_DIR/qemu-bin/community"
mkdir -p "$CONFIGS_DIR" "$QEMU_BIN_DIR"
cat > "$CONFIGS_DIR/openbmc-source.manifest" <<MS
source_label=community
MS
MACHINE=romulus
QEMU_LAUNCH_SYSTEM_NAME="qemu-system-arm"
make_qemu_curl_fake "$DB"            # curl: 下载写假脚本 + Jenkins api/json → build 42
export QEMU_FAKE_JENKINS_BUILD=42
PATH="$DB:$PATH"

# ── Case 1: download_qemu_binary_core(flat binary 路径)──
extract_dir="$(mktemp -d)"
(
    download_qemu_binary_core "https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm" "$extract_dir" "qemu-system-arm"
    echo "RC=$?"
    echo "DLQB_BIN_PATH=[$DLQB_BIN_PATH]"
    echo "DLQB_SHA256=[$DLQB_SHA256]"
) > "$TMP/c1" 2>&1
c1_rc=$?
c1=$(cat "$TMP/c1")
assert_eq "download_core succeeds" "$c1_rc" "0"
assert_match "download_core sets DLQB_BIN_PATH" "$c1" 'DLQB_BIN_PATH=\[/'
assert_match "download_core sets DLQB_SHA256" "$c1" 'DLQB_SHA256=\[[0-9a-f]'

# ── Case 2: ensure_qemu_binary_community(全流程:无 binary → 下载 → mv → manifest)──
# 删掉 Case1 可能残留,确保 QEMU_BIN_FILE 起始不存在
QEMU_BIN_FILE="$QEMU_BIN_DIR/qemu-system-arm"
rm -f "$QEMU_BIN_FILE" "$QEMU_BIN_FILE.manifest"
(
    ensure_qemu_binary_community
    echo "RC=$?"
) > "$TMP/c2" 2>&1
c2_rc=$?
assert_eq "ensure_qemu_binary_community succeeds" "$c2_rc" "0"
assert_true "binary installed" test -x "$QEMU_BIN_FILE"
assert_true "manifest written" test -f "$QEMU_BIN_FILE.manifest"
manifest=$(cat "$QEMU_BIN_FILE.manifest")
assert_contains "manifest has jenkins url" "$manifest" "jenkins.openbmc.org"
assert_contains "manifest has build_number 42" "$manifest" "build_number=42"
assert_contains "manifest has sha256" "$manifest" "sha256="

rm -rf "$TMP" "$DB" "$extract_dir"
assert_summary
