#!/usr/bin/env bash
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

source "$(dirname "$0")/../lib/status_fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
status_build_fixture "$TMP"

status_records_calls_file="$TMP/status_records_calls"
machine_state_records() {
  printf 'called\n' >> "$status_records_calls_file"
}

: > "$status_records_calls_file"
output="$(cmd_status 2>&1)"; rc=$?
assert_eq "status machine-state rc" "$rc" 0
status_records_calls=$(wc -l < "$status_records_calls_file")
assert_eq "status does not call machine records" "$status_records_calls" 0
assert_false "legacy lock machine hidden" grep -Fq "legacy" <<< "$output"
assert_false "legacy ignored not shown" grep -Fq "legacy ignored" <<< "$output"
assert_contains "snapshot-only machine listed" "$output" "snaponly"
assert_contains "snapshot-only partial listed" "$output" "partial"
assert_contains "firmware image column listed" "$output" "Firmware Image"
markeronly_line="$(grep -F "markeronly" <<< "$output" || true)"
assert_contains "marker-only machine listed" "$output" "markeronly"
assert_contains "marker-only row shows initialized state" "$markeronly_line" "✅ initialized"
assert_contains "failed build machine listed" "$output" "failm"
assert_contains "missing firmware image state listed" "$output" "— missing"
assert_contains "ready firmware image listed" "$output" "📦 ready"
assert_contains "init-done without firmware image shows build tip" "$output" "Run 'ob build <machine>' to produce a firmware image."
assert_contains "diagnostics section listed" "$output" "Diagnostics"
assert_contains "orphan diagnostics title listed" "$output" "Orphan firmware image artifacts"
assert_contains "orphan artifact listed" "$output" "orphan"
assert_contains "orphan next step listed" "$output" "Next step : ob init orphan"
assert_false "orphan not in main machine table" grep -Eq '^  orphan[[:space:]]' <<< "$output"
assert_false "status avoids invalid image wording" grep -Fq "invalid image" <<< "$output"
qemu_word="QEMU"
image_word="image"
assert_false "status avoids stale firmware wording" grep -Fq "$qemu_word $image_word" <<< "$output"

# QEMU 实例（exited + recycled 都显示 ⚠️ stale；status 只读，文件保留）
stalebox_line="$(grep -F "stalebox" <<< "$output" || true)"
recycbox_line="$(grep -F "recycbox" <<< "$output" || true)"
assert_contains "status shows exited instance stale" "$stalebox_line" "⚠️ stale"
assert_contains "status shows recycled instance stale" "$recycbox_line" "⚠️ stale"
assert_true "status keeps exited stale pid file" test -f "$QEMU_PIDS_DIR/stalebox.pid"
assert_true "status keeps recycled stale pid file" test -f "$QEMU_PIDS_DIR/recycbox.pid"

rm -f "$CONFIGS_DIR/markeronly.init-done" "$CONFIGS_DIR/failm.init-done"
rm -rf "$OPENBMC_DIR/build/failm"

: > "$status_records_calls_file"
output="$(cmd_status 2>&1)"; rc=$?
assert_eq "status built+partial rc" "$rc" 0
status_records_calls=$(wc -l < "$status_records_calls_file")
assert_eq "status does not call machine records after state change" "$status_records_calls" 0
assert_false "partial machine does not trigger build tip" grep -Fq "Run 'ob build <machine>' to produce a firmware image." <<< "$output"

assert_summary
