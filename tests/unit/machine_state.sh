#!/usr/bin/env bash
# tests/unit/machine_state.sh — Machine lifecycle state 单测(unit 层,文件 IO)。
# 覆盖 records / filtered lists / firmware image readiness / orphan diagnostics。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WORKSPACE_DIR="$TMP/workspace"
CONFIGS_DIR="$WORKSPACE_DIR/configs"
OPENBMC_DIR="$WORKSPACE_DIR/openbmc"
mkdir -p "$CONFIGS_DIR" "$OPENBMC_DIR"

write_snapshot() {
    local machine="$1"
    local repo_count="$2"
    local snapshot="$CONFIGS_DIR/$machine.snapshot"

    python3 - "$snapshot" "$machine" "$repo_count" <<'PY'
import json
import sys

snapshot, machine, repo_count = sys.argv[1], sys.argv[2], int(sys.argv[3])
body = {
    "machine": machine,
    "generated_at": "2026-06-23T00:00:00+00:00",
    "openbmc_commit": "deadbeef1234",
    "target_image": "obmc-phosphor-image",
    "sub_repos": [
        {
            "name": f"repo{i}",
            "src_uri": f"git://example/repo{i}",
            "srcrev": "abcdef",
            "local_path": f"workspace/src/{machine}/repo{i}",
            "recipe": f"recipe{i}",
        }
        for i in range(repo_count)
    ],
}
with open(snapshot, "w", encoding="utf-8") as fh:
    json.dump(body, fh, indent=2)
    fh.write("\n")
PY
}

write_marker() {
    local machine="$1"
    local timestamp="${2:-2026-06-23T01:02:03Z}"
    printf '%s\n' "$timestamp" > "$CONFIGS_DIR/$machine.init-done"
}

assert_list_contains_line() {
    local label="$1"
    local output="$2"
    local expected="$3"
    grep -Fxq "$expected" <<< "$output"
    assert_eq "$label" "$?" 0
}

assert_list_not_contains_line() {
    local label="$1"
    local output="$2"
    local unexpected="$3"
    grep -Fxq "$unexpected" <<< "$output"
    assert_eq "$label" "$?" 1
}

assert_false "machine_state_records removed" declare -F machine_state_records
assert_true "machine_state_initialized_machines defined" declare -F machine_state_initialized_machines
assert_true "machine_state_firmware_image_ready_machines defined" declare -F machine_state_firmware_image_ready_machines
assert_true "machine_state_is_initialized defined" declare -F machine_state_is_initialized
assert_true "machine_state_firmware_image_path defined" declare -F machine_state_firmware_image_path
assert_true "machine_state_display_machines defined" declare -F machine_state_display_machines
assert_true "machine_state_orphan_firmware_image_machines defined" declare -F machine_state_orphan_firmware_image_machines
assert_true "machine_state_init_state defined" declare -F machine_state_init_state
assert_true "machine_state_snapshot_state defined" declare -F machine_state_snapshot_state
assert_true "machine_state_init_time defined" declare -F machine_state_init_time
assert_true "machine_state_firmware_image_mtime defined" declare -F machine_state_firmware_image_mtime
assert_true "machine_state_is_firmware_image_ready defined" declare -F machine_state_is_firmware_image_ready
assert_true "machine_state_is_orphan_firmware_image defined" declare -F machine_state_is_orphan_firmware_image

old_machine_state_functions=(
    machine_state_list_records
    machine_state_record_field
    machine_state_build_state
    machine_state_image_path
    machine_state_has_init_done
)
for old_func in "${old_machine_state_functions[@]}"; do
    assert_false "$old_func removed" declare -F "$old_func"
done

display_machines="$(machine_state_display_machines 2>/dev/null || true)"
assert_eq "no state yields empty display machines" "$display_machines" ""
orphan_machines="$(machine_state_orphan_firmware_image_machines 2>/dev/null || true)"
assert_eq "no state yields empty orphan machines" "$orphan_machines" ""

write_snapshot romulus 2
assert_eq "snapshot-only init state query" "$(machine_state_init_state romulus 2>/dev/null || true)" partial
assert_eq "snapshot-only snapshot state query" "$(machine_state_snapshot_state romulus 2>/dev/null || true)" present
assert_eq "snapshot-only repo count query" "$(machine_state_repo_count romulus)" 2
assert_eq "snapshot-only init time query" "$(machine_state_init_time romulus 2>/dev/null || true)" ""
machine_state_firmware_image_path romulus >/dev/null 2>&1
assert_eq "snapshot-only image path rc" "$?" 1
assert_eq "snapshot-only firmware mtime query" "$(machine_state_firmware_image_mtime romulus 2>/dev/null || true)" ""
machine_state_is_firmware_image_ready romulus >/dev/null 2>&1
assert_eq "snapshot-only ready query rc" "$?" 1
machine_state_is_orphan_firmware_image romulus >/dev/null 2>&1
assert_eq "snapshot-only orphan query rc" "$?" 1

write_marker markeronly 2026-06-23T03:04:05Z
assert_eq "marker-only init state query" "$(machine_state_init_state markeronly 2>/dev/null || true)" initialized
assert_eq "marker-only snapshot state query" "$(machine_state_snapshot_state markeronly 2>/dev/null || true)" missing
assert_eq "marker-only repo count query" "$(machine_state_repo_count markeronly)" "?"
assert_eq "marker-only init time query" "$(machine_state_init_time markeronly 2>/dev/null || true)" 2026-06-23T03:04:05Z
machine_state_is_firmware_image_ready markeronly >/dev/null 2>&1
assert_eq "marker-only ready query rc" "$?" 1

printf '{bad json\n' > "$CONFIGS_DIR/bad.snapshot"
assert_eq "bad snapshot init state query" "$(machine_state_init_state bad 2>/dev/null || true)" partial
assert_eq "bad snapshot state query" "$(machine_state_snapshot_state bad 2>/dev/null || true)" present
assert_eq "bad snapshot repo count query" "$(machine_state_repo_count bad)" "?"

write_marker initialized_missing_image
assert_eq "initialized without image state query" "$(machine_state_init_state initialized_missing_image 2>/dev/null || true)" initialized
machine_state_is_firmware_image_ready initialized_missing_image >/dev/null 2>&1
assert_eq "initialized without image ready query rc" "$?" 1
machine_state_is_orphan_firmware_image initialized_missing_image >/dev/null 2>&1
assert_eq "initialized without image orphan query rc" "$?" 1

write_marker ready
deploy_dir="$OPENBMC_DIR/build/ready/tmp/deploy/images/ready"
mkdir -p "$deploy_dir"
touch "$deploy_dir/z.static.mtd" "$deploy_dir/a.static.mtd"
image_path="$(machine_state_firmware_image_path ready)"
assert_eq "image path sorted first" "$image_path" "$deploy_dir/a.static.mtd"
assert_eq "ready init state query" "$(machine_state_init_state ready 2>/dev/null || true)" initialized
machine_state_is_firmware_image_ready ready >/dev/null 2>&1
assert_eq "ready query rc" "$?" 0
machine_state_is_orphan_firmware_image ready >/dev/null 2>&1
assert_eq "ready not orphan query rc" "$?" 1
assert_match "ready firmware image mtime query" "$(machine_state_firmware_image_mtime ready 2>/dev/null || true)" '^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:]+Z$'

machine_state_firmware_image_path markeronly >/dev/null 2>&1
assert_eq "missing image path rc" "$?" 1

machine_state_is_initialized markeronly >/dev/null 2>&1
assert_eq "has init-done rc" "$?" 0
machine_state_is_initialized romulus >/dev/null 2>&1
assert_eq "missing init-done rc" "$?" 1

orphan_dir="$OPENBMC_DIR/build/orphan/tmp/deploy/images/orphan"
mkdir -p "$orphan_dir"
touch "$orphan_dir/orphan.static.mtd"
assert_eq "artifact-only image path query" "$(machine_state_firmware_image_path orphan)" "$orphan_dir/orphan.static.mtd"
assert_eq "artifact-only init state query" "$(machine_state_init_state orphan 2>/dev/null || true)" uninitialized
assert_eq "artifact-only snapshot state query" "$(machine_state_snapshot_state orphan 2>/dev/null || true)" missing
machine_state_is_orphan_firmware_image orphan >/dev/null 2>&1
assert_eq "artifact-only orphan query rc" "$?" 0

write_snapshot partialimg 1
partial_dir="$OPENBMC_DIR/build/partialimg/tmp/deploy/images/partialimg"
mkdir -p "$partial_dir"
touch "$partial_dir/partial.static.mtd"
assert_eq "partial artifact init state query" "$(machine_state_init_state partialimg 2>/dev/null || true)" partial
assert_eq "partial artifact snapshot state query" "$(machine_state_snapshot_state partialimg 2>/dev/null || true)" present
machine_state_is_firmware_image_ready partialimg >/dev/null 2>&1
assert_eq "partial artifact not ready query rc" "$?" 1
machine_state_is_orphan_firmware_image partialimg >/dev/null 2>&1
assert_eq "partial artifact orphan query rc" "$?" 0

mismatch_dir="$OPENBMC_DIR/build/mismatch/tmp/deploy/images/other"
mkdir -p "$mismatch_dir"
touch "$mismatch_dir/ignored.static.mtd"
display_machines="$(machine_state_display_machines 2>/dev/null || true)"
orphan_machines="$(machine_state_orphan_firmware_image_machines 2>/dev/null || true)"
assert_list_not_contains_line "mismatched build machine ignored" "$display_machines" mismatch
assert_list_not_contains_line "mismatched deploy machine ignored" "$display_machines" other
assert_list_not_contains_line "mismatched build machine not orphan" "$orphan_machines" mismatch
assert_list_not_contains_line "mismatched deploy machine not orphan" "$orphan_machines" other

EMPTY_OPENBMC_DIR="$TMP/empty-openbmc"
mkdir -p "$EMPTY_OPENBMC_DIR"
(
    OPENBMC_DIR="$EMPTY_OPENBMC_DIR"
    CONFIGS_DIR="$TMP/empty-configs"
    mkdir -p "$CONFIGS_DIR"
    empty_display_machines="$(machine_state_display_machines)"
    assert_eq "missing build dir yields empty display machines" "$empty_display_machines" ""
    empty_orphan_machines="$(machine_state_orphan_firmware_image_machines)"
    assert_eq "missing build dir yields empty orphan machines" "$empty_orphan_machines" ""
)

initialized_machines="$(machine_state_initialized_machines)"
assert_list_contains_line "initialized list includes marker-only" "$initialized_machines" markeronly
assert_list_contains_line "initialized list includes ready" "$initialized_machines" ready
assert_list_not_contains_line "initialized list skips partial snapshot" "$initialized_machines" romulus
assert_list_not_contains_line "initialized list skips orphan artifact" "$initialized_machines" orphan

ready_machines="$(machine_state_firmware_image_ready_machines)"
assert_list_contains_line "ready list includes ready" "$ready_machines" ready
assert_list_not_contains_line "ready list skips marker-only" "$ready_machines" markeronly
assert_list_not_contains_line "ready list skips orphan artifact" "$ready_machines" orphan
assert_list_not_contains_line "ready list skips partial artifact" "$ready_machines" partialimg

display_machines="$(machine_state_display_machines 2>/dev/null || true)"
assert_list_contains_line "display list includes snapshot-only" "$display_machines" romulus
assert_list_contains_line "display list includes marker-only" "$display_machines" markeronly
assert_list_contains_line "display list includes ready" "$display_machines" ready
assert_list_contains_line "display list includes partial artifact" "$display_machines" partialimg
assert_list_not_contains_line "display list skips artifact-only orphan" "$display_machines" orphan

orphan_machines="$(machine_state_orphan_firmware_image_machines 2>/dev/null || true)"
assert_list_contains_line "orphan list includes artifact-only orphan" "$orphan_machines" orphan
assert_list_contains_line "orphan list includes partial artifact" "$orphan_machines" partialimg
assert_list_not_contains_line "orphan list skips ready" "$orphan_machines" ready

deps_json="$TMP/deps.json"
cat > "$deps_json" <<'EOF'
[
    {
        "name": "repo1",
        "src_uri": "git://example/repo1",
        "srcrev": "1111",
        "recipe": "recipe1"
    },
    {
        "name": "repo2",
        "src_uri": "git://example/repo2",
        "srcrev": "2222",
        "recipe": "recipe2"
    }
]
EOF

DRY_RUN=0
machine_state_write_snapshot snapwrite "$deps_json" cafebabe >/dev/null 2>&1
assert_eq "write snapshot rc" "$?" 0
assert_true "snapshot created" test -f "$CONFIGS_DIR/snapwrite.snapshot"
assert_false "legacy lock not created" test -f "$CONFIGS_DIR/snapwrite.lock"
snap_body="$(cat "$CONFIGS_DIR/snapwrite.snapshot")"
assert_contains "snapshot machine field" "$snap_body" '"machine": "snapwrite"'
assert_contains "snapshot commit field" "$snap_body" '"openbmc_commit": "cafebabe"'
assert_contains "snapshot target image" "$snap_body" '"target_image": "obmc-phosphor-image"'
assert_contains "snapshot local path" "$snap_body" '"local_path": "workspace/src/snapwrite/repo1"'

printf 'keep-me\n' > "$CONFIGS_DIR/failwrite.snapshot"
machine_state_write_snapshot failwrite "$TMP/missing-deps.json" badc0de >/dev/null 2>&1
assert_eq "write snapshot missing deps rc" "$?" 1
assert_eq "failed snapshot write preserves target" "$(cat "$CONFIGS_DIR/failwrite.snapshot")" "keep-me"

machine_state_mark_init_done markwrite >/dev/null 2>&1
assert_eq "mark init-done rc" "$?" 0
assert_true "init-done marker created" test -f "$CONFIGS_DIR/markwrite.init-done"
assert_match "init-done marker UTC" "$(cat "$CONFIGS_DIR/markwrite.init-done")" '^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:]+Z$'

printf 'old marker\n' > "$CONFIGS_DIR/clearme.init-done"
printf 'old snapshot\n' > "$CONFIGS_DIR/clearme.snapshot"
printf 'old lock\n' > "$CONFIGS_DIR/clearme.lock"
machine_state_clear_init_progress clearme >/dev/null 2>&1
assert_eq "clear init progress rc" "$?" 0
assert_false "clear removes marker" test -f "$CONFIGS_DIR/clearme.init-done"
assert_false "clear removes snapshot" test -f "$CONFIGS_DIR/clearme.snapshot"
assert_false "clear removes legacy lock" test -f "$CONFIGS_DIR/clearme.lock"

printf 'dry marker\n' > "$CONFIGS_DIR/dry.init-done"
printf 'dry snapshot\n' > "$CONFIGS_DIR/dry.snapshot"
printf 'dry lock\n' > "$CONFIGS_DIR/dry.lock"
DRY_RUN=1
machine_state_clear_init_progress dry >/dev/null 2>&1
assert_eq "dry-run clear rc" "$?" 0
assert_true "dry-run keeps marker" test -f "$CONFIGS_DIR/dry.init-done"
assert_true "dry-run keeps snapshot" test -f "$CONFIGS_DIR/dry.snapshot"
assert_true "dry-run keeps legacy lock" test -f "$CONFIGS_DIR/dry.lock"
machine_state_write_snapshot drywrite "$deps_json" feedface >/dev/null 2>&1
assert_eq "dry-run snapshot write rc" "$?" 0
assert_false "dry-run snapshot write no file" test -f "$CONFIGS_DIR/drywrite.snapshot"
machine_state_mark_init_done drymark >/dev/null 2>&1
assert_eq "dry-run mark rc" "$?" 0
assert_false "dry-run mark no file" test -f "$CONFIGS_DIR/drymark.init-done"
DRY_RUN=0

assert_summary