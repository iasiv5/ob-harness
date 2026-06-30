#!/usr/bin/env bash
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WORKSPACE_DIR="$TMP/workspace"
CONFIGS_DIR="$WORKSPACE_DIR/configs"
OPENBMC_DIR="$WORKSPACE_DIR/openbmc"
SOURCE_MANIFEST_FILE="$CONFIGS_DIR/openbmc-source.manifest"
mkdir -p "$CONFIGS_DIR" "$OPENBMC_DIR"
mkdir -p "$OPENBMC_DIR/.git"

write_snapshot() {
    local machine="$1"
    cat > "$CONFIGS_DIR/$machine.snapshot" <<EOF
{
  "machine": "$machine",
  "generated_at": "2026-06-23T00:00:00+00:00",
  "openbmc_commit": "deadbeef1234",
  "target_image": "obmc-phosphor-image",
  "sub_repos": [
    {
      "name": "repo1",
      "src_uri": "git://example/repo1",
      "srcrev": "1111",
      "local_path": "workspace/src/$machine/repo1",
      "recipe": "recipe1"
    }
  ]
}
EOF
}

write_marker() {
    local machine="$1"
    printf '2026-06-23T01:02:03Z\n' > "$CONFIGS_DIR/$machine.init-done"
}

printf '{"sub_repos": []}\n' > "$CONFIGS_DIR/legacy.lock"
write_snapshot snaponly
write_marker markeronly
write_marker failm
mkdir -p "$OPENBMC_DIR/build/failm"
write_marker built
deploy_dir="$OPENBMC_DIR/build/built/tmp/deploy/images/built"
mkdir -p "$deploy_dir"
touch "$deploy_dir/built.static.mtd"
orphan_dir="$OPENBMC_DIR/build/orphan/tmp/deploy/images/orphan"
mkdir -p "$orphan_dir"
touch "$orphan_dir/orphan.static.mtd"

status_records_calls_file="$TMP/status_records_calls"
eval "$(declare -f machine_state_records | sed '1s/machine_state_records/_status_test_machine_state_records/')"
machine_state_records() {
  printf 'called\n' >> "$status_records_calls_file"
  _status_test_machine_state_records "$@"
}

: > "$status_records_calls_file"
output="$(cmd_status 2>&1)"; rc=$?
assert_eq "status machine-state rc" "$rc" 0
status_records_calls=$(wc -l < "$status_records_calls_file")
assert_eq "status discovers machine records once" "$status_records_calls" 1
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

rm -f "$CONFIGS_DIR/markeronly.init-done" "$CONFIGS_DIR/failm.init-done"
rm -rf "$OPENBMC_DIR/build/failm"

: > "$status_records_calls_file"
output="$(cmd_status 2>&1)"; rc=$?
assert_eq "status built+partial rc" "$rc" 0
status_records_calls=$(wc -l < "$status_records_calls_file")
assert_eq "status discovers machine records once after state change" "$status_records_calls" 1
assert_false "partial machine does not trigger build tip" grep -Fq "Run 'ob build <machine>' to produce a firmware image." <<< "$output"

assert_summary