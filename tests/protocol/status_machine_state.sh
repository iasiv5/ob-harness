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
SOURCE_LOCK_FILE="$CONFIGS_DIR/openbmc-source.lock"
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

output="$(cmd_status 2>&1)"; rc=$?
assert_eq "status machine-state rc" "$rc" 0
assert_false "legacy lock machine hidden" grep -Fq "legacy" <<< "$output"
assert_false "legacy ignored not shown" grep -Fq "legacy ignored" <<< "$output"
assert_contains "snapshot-only machine listed" "$output" "snaponly"
assert_contains "snapshot-only partial listed" "$output" "partial"
markeronly_line="$(grep -F "markeronly" <<< "$output" || true)"
assert_contains "marker-only machine listed" "$output" "markeronly"
assert_contains "marker-only row shows done state" "$markeronly_line" "✅ done"
assert_contains "failed build machine listed" "$output" "failm"
assert_contains "failed build state listed" "$output" "❌ failed"
assert_contains "succeeded build listed" "$output" "succeeded"
assert_contains "init-done without successful build shows build tip" "$output" "Run 'ob build' to build a machine."

rm -f "$CONFIGS_DIR/markeronly.init-done" "$CONFIGS_DIR/failm.init-done"
rm -rf "$OPENBMC_DIR/build/failm"

output="$(cmd_status 2>&1)"; rc=$?
assert_eq "status built+partial rc" "$rc" 0
assert_false "partial machine does not trigger build tip" grep -Fq "Run 'ob build' to build a machine." <<< "$output"

assert_summary