#!/usr/bin/env bash
# tests/unit/machine_state.sh — Machine lifecycle state 单测(unit 层,文件 IO)。
# 覆盖 records / image path / build state / snapshot JSON 容错。
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

record_for() {
    local machine="$1"
    machine_state_list_records | awk -v prefix="machine=${machine}" '$1 == prefix { print; exit }'
}

assert_true "machine_state_list_records defined" declare -F machine_state_list_records
assert_true "machine_state_image_path defined" declare -F machine_state_image_path
assert_true "machine_state_has_init_done defined" declare -F machine_state_has_init_done

records="$(machine_state_list_records)"
assert_eq "no state yields empty records" "$records" ""

write_snapshot romulus 2
romulus_record="$(record_for romulus)"
assert_contains "snapshot-only machine listed" "$romulus_record" "machine=romulus"
assert_contains "snapshot-only init partial" "$romulus_record" "init=partial"
assert_contains "snapshot present" "$romulus_record" "snapshot=yes"
assert_contains "snapshot repo count" "$romulus_record" "repos=2"
assert_contains "snapshot-only build never" "$romulus_record" "build=never"
assert_contains "snapshot-only no image" "$romulus_record" "image=no"
assert_contains "snapshot-only empty init time" "$romulus_record" "init_time="

write_marker markeronly 2026-06-23T03:04:05Z
marker_record="$(record_for markeronly)"
assert_contains "marker-only machine listed" "$marker_record" "machine=markeronly"
assert_contains "marker-only init done" "$marker_record" "init=done"
assert_contains "marker-only no snapshot" "$marker_record" "snapshot=no"
assert_contains "marker-only repo unknown" "$marker_record" "repos=?"
assert_contains "marker-only build never" "$marker_record" "build=never"
assert_contains "marker-only raw init time" "$marker_record" "init_time=2026-06-23T03:04:05Z"

printf '{bad json\n' > "$CONFIGS_DIR/bad.snapshot"
bad_record="$(record_for bad)"
assert_contains "bad snapshot listed" "$bad_record" "machine=bad"
assert_contains "bad snapshot partial" "$bad_record" "init=partial"
assert_contains "bad snapshot repo unknown" "$bad_record" "repos=?"

write_marker failed
mkdir -p "$OPENBMC_DIR/build/failed"
failed_record="$(record_for failed)"
assert_contains "top-level build dir without image is failed" "$failed_record" "build=failed"
assert_contains "failed build has no image" "$failed_record" "image=no"

write_marker built
deploy_dir="$OPENBMC_DIR/build/built/tmp/deploy/images/built"
mkdir -p "$deploy_dir"
touch "$deploy_dir/z.static.mtd" "$deploy_dir/a.static.mtd"
built_record="$(record_for built)"
assert_contains "image build succeeded" "$built_record" "build=succeeded"
assert_contains "image flag yes" "$built_record" "image=yes"
image_path="$(machine_state_image_path built)"
assert_eq "image path sorted first" "$image_path" "$deploy_dir/a.static.mtd"

machine_state_image_path markeronly >/dev/null 2>&1
assert_eq "missing image path rc" "$?" 1

machine_state_has_init_done markeronly >/dev/null 2>&1
assert_eq "has init-done rc" "$?" 0
machine_state_has_init_done romulus >/dev/null 2>&1
assert_eq "missing init-done rc" "$?" 1

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