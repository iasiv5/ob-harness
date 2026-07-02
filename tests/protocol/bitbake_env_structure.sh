#!/usr/bin/env bash
# tests/protocol/bitbake_env_structure.sh — BitBake environment helper structure locks.
set -uo pipefail

source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BITBAKE_ENV_SH="$ROOT/lib/bitbake_env.sh"
REPO_SH="$ROOT/lib/repo.sh"
QEMU_SH="$ROOT/lib/qemu.sh"
INIT_PIPELINE_SH="$ROOT/lib/init_pipeline.sh"
COMMANDS_SH="$ROOT/lib/commands.sh"
EXIT_CONTRACT_PY="$ROOT/tools/exit_contract.py"

extract_shell_function() {
    local file="$1"
    local function_name="$2"

    awk -v fn="$function_name" '
        BEGIN { in_fn = 0; found = 0 }
        $0 ~ "^" fn "[(][)] [{$]" || $0 ~ "^" fn "[(][)]$" {
            in_fn = 1
            found = 1
            print
            next
        }
        in_fn && $0 ~ "^[A-Za-z_][A-Za-z0-9_]*[(][)] [{$]" {
            in_fn = 0
            exit
        }
        in_fn { print }
        END { if (!found) exit 42 }
    ' "$file"
}

assert_file_exists() {
    local label="$1"
    local file="$2"

    if [[ -f "$file" ]]; then
        _assert_ok "$label"
    else
        _assert_bad "$label (missing $file)"
    fi
}

assert_file_contains() {
    local label="$1"
    local file="$2"
    local needle="$3"

    if [[ ! -f "$file" ]]; then
        _assert_bad "$label (missing $file)"
        return
    fi
    if grep -Fq "$needle" "$file"; then
        _assert_ok "$label"
    else
        _assert_bad "$label (missing '$needle')"
    fi
}

assert_function_contains() {
    local label="$1"
    local file="$2"
    local function_name="$3"
    local needle="$4"
    local body

    body=$(extract_shell_function "$file" "$function_name") || {
        _assert_bad "$label (function '$function_name' not found)"
        return
    }
    assert_contains "$label" "$body" "$needle"
}

assert_function_not_match() {
    local label="$1"
    local file="$2"
    local function_name="$3"
    local pattern="$4"
    local body

    body=$(extract_shell_function "$file" "$function_name") || {
        _assert_bad "$label (function '$function_name' not found)"
        return
    }
    if rg -q "$pattern" <<< "$body"; then
        _assert_bad "$label (matched /$pattern/)"
    else
        _assert_ok "$label"
    fi
}

assert_no_real_exit_command() {
    local label="$1"
    local file="$2"
    local hits

    if [[ ! -f "$file" ]]; then
        _assert_bad "$label (missing $file)"
        return
    fi
    hits=$(grep -nE '(^|[[:space:];&|])exit($|[[:space:];&|])' "$file" | grep -v '^[0-9]*:[[:space:]]*#' || true)
    if [[ -n "$hits" ]]; then
        _assert_bad "$label (found exit command)"
        printf '%s\n' "$hits"
    else
        _assert_ok "$label"
    fi
}

assert_file_exists "bitbake_env module exists" "$BITBAKE_ENV_SH"
assert_file_contains "bitbake_env registered leaf-pure" "$EXIT_CONTRACT_PY" "'bitbake_env.sh': set()"
assert_no_real_exit_command "bitbake_env has no exit command" "$BITBAKE_ENV_SH"

assert_function_contains "repo machine list uses bitbake_env helper" "$REPO_SH" list_available_machines "bitbake_env_list_available_machines"
assert_function_contains "qemu profile uses bitbake_env query" "$QEMU_SH" resolve_qemu_launch_profile "bitbake_env_query_vars"

assert_function_not_match "init_bitbake_env keeps current-shell setup" "$INIT_PIPELINE_SH" init_bitbake_env 'bitbake_env_'
assert_function_not_match "generate_dep_graph keeps current-shell setup" "$INIT_PIPELINE_SH" generate_dep_graph 'bitbake_env_'
assert_function_not_match "cmd_build keeps current-shell setup" "$COMMANDS_SH" cmd_build 'bitbake_env_'

assert_summary