#!/usr/bin/env bash
# tests/unit/repo_previously_initialized.sh — repo machine selection UI consumes machine_state records.
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CONFIGS_DIR="$TMP/configs"
mkdir -p "$CONFIGS_DIR"
printf '{"sub_repos": []}\n' > "$CONFIGS_DIR/legacy.lock"

machine_state_list_records() {
    printf 'machine=romulus\tinit=done\tsnapshot=yes\trepos=1\tbuild=never\timage=no\tinit_time=2026-06-23T01:02:03Z\n'
    printf 'machine=partial\tinit=partial\tsnapshot=yes\trepos=1\tbuild=never\timage=no\tinit_time=\n'
}

machine_arr=(alpha romulus partial zeta)
output="$(print_previously_initialized machine_arr)"

assert_contains "previously initialized prints done machine" "$output" "romulus"
assert_contains "previously initialized keeps original index" "$output" "2)"
assert_contains "previously initialized formats raw time" "$output" "2026-06-23"
assert_false "previously initialized skips partial" grep -Fq "partial" <<< "$output"
assert_false "previously initialized ignores legacy lock" grep -Fq "legacy" <<< "$output"

assert_summary