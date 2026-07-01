#!/usr/bin/env bash
# tests/unit/repo_previously_initialized.sh — repo machine selection UI consumes machine_state query interface.
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CONFIGS_DIR="$TMP/configs"
mkdir -p "$CONFIGS_DIR"
printf '{"sub_repos": []}\n' > "$CONFIGS_DIR/legacy.lock"
records_calls_file="$TMP/records_calls"
initialized_calls_file="$TMP/initialized_calls"
init_time_calls_file="$TMP/init_time_calls"
: > "$records_calls_file"
: > "$initialized_calls_file"
: > "$init_time_calls_file"

machine_state_initialized_machines() {
    printf 'called\n' >> "$initialized_calls_file"
    printf 'romulus\n'
}

machine_state_records() {
    printf 'called\n' >> "$records_calls_file"
    printf 'machine=romulus\tdiscovered_by=snapshot,init_done\tinit_state=initialized\tsnapshot_state=present\trepo_count=1\tfirmware_image_ready=no\tfirmware_image_orphaned=no\tfirmware_image_path=\tfirmware_image_mtime=\tinit_time=2026-06-23T01:02:03Z\n'
    printf 'machine=partial\tdiscovered_by=snapshot\tinit_state=partial\tsnapshot_state=present\trepo_count=1\tfirmware_image_ready=no\tfirmware_image_orphaned=no\tfirmware_image_path=\tfirmware_image_mtime=\tinit_time=\n'
}

machine_state_init_time() {
    printf 'called\n' >> "$init_time_calls_file"
    [[ "$1" == "romulus" ]] && printf '2026-06-23T01:02:03Z\n'
}

machine_arr=(alpha romulus partial zeta)
output="$(print_previously_initialized machine_arr)"

assert_contains "previously initialized prints done machine" "$output" "romulus"
assert_contains "previously initialized keeps original index" "$output" "2)"
assert_contains "previously initialized formats raw time" "$output" "2026-06-23"
assert_false "previously initialized skips partial" grep -Fq "partial" <<< "$output"
assert_false "previously initialized ignores legacy lock" grep -Fq "legacy" <<< "$output"
records_calls=$(wc -l < "$records_calls_file")
initialized_calls=$(wc -l < "$initialized_calls_file")
init_time_calls=$(wc -l < "$init_time_calls_file")
assert_eq "previously initialized does not read records" "$records_calls" 0
assert_eq "previously initialized reads initialized list once" "$initialized_calls" 1
assert_eq "previously initialized reads init time once" "$init_time_calls" 1

assert_summary
