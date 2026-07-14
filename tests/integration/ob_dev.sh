#!/usr/bin/env bash
# shellcheck disable=SC1091
# tests/integration/ob_dev.sh — ob dev real integration (opt-in via --integration).
# Select an unmodified recipe and clean it even if modify succeeds before reporting failure.
set -uo pipefail

devtool_in_env() {
    local machine="$1"
    shift
    (
        cd "$OPENBMC_DIR" &&
        set +u &&
        source setup "$machine" "$OPENBMC_DIR/build/$machine" >/dev/null 2>&1 &&
        devtool "$@"
    ) 2>/dev/null
}

# ob_dev_integration_status_has_recipe <recipe> <devtool-status-output>
ob_dev_integration_status_has_recipe() {
    local recipe="$1" status_output="$2"
    awk -F': ' -v recipe="$recipe" '$1 == recipe { found=1; exit } END { exit !found }' \
        <<<"$status_output"
}

ob_dev_integration_cleanup() {
    local status_output="" status_rc=0
    [[ "${CLEANUP_NEEDED:-0}" == "1" && -n "${RECIPE:-}" ]] || return 0

    status_output="$(devtool_in_env "$MACHINE" status)" || status_rc=$?
    if [[ "$status_rc" -ne 0 ]]; then
        echo "WARN: cleanup status failed; recipe $RECIPE may remain modified, clean it manually" >&2
        return 1
    fi
    if ! ob_dev_integration_status_has_recipe "$RECIPE" "$status_output"; then
        CLEANUP_NEEDED=0
        return 0
    fi
    if ! devtool_in_env "$MACHINE" reset "$RECIPE" >/dev/null 2>&1; then
        echo "WARN: cleanup reset failed; recipe $RECIPE remains modified, clean it manually" >&2
        return 1
    fi
    CLEANUP_NEEDED=0
    return 0
}

ob_dev_integration_main() {
    local root_dir refresh_rc list_rc cache_record_count candidates_rc status_rc modify_rc invalid_recipe_rc
    local candidate="" CACHE_OUT="" CANDIDATES="" STATUS_OUT=""

    root_dir="${OB_DEV_INTEGRATION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    cd "$root_dir" || exit 1

    OPENBMC_DIR="$(pwd)/workspace/openbmc"
    export OPENBMC_DIR

    MACHINE="${OB_INTEGRATION_MACHINE:-}"
    if [[ -z "$MACHINE" ]]; then
        local machine_marker
        for machine_marker in workspace/configs/*.init-done; do
            [[ -f "$machine_marker" ]] && MACHINE="$(basename "$machine_marker" .init-done)" && break
        done
    fi
    [[ -n "$MACHINE" ]] || { echo "SKIP: no init machine"; exit 77; }
    echo "[integration] machine=$MACHINE openbmc=$OPENBMC_DIR"

    ./ob dev --machine "$MACHINE" refresh >/dev/null 2>&1
    refresh_rc=$?
    [[ "$refresh_rc" -eq 0 ]] || { echo "FAIL: refresh rc=$refresh_rc"; exit 1; }

    list_rc=0
    CACHE_OUT="$(./ob dev --machine "$MACHINE" list 2>/dev/null)" || list_rc=$?
    [[ "$list_rc" -eq 0 ]] || { echo "FAIL: list rc=$list_rc"; exit 1; }
    cache_record_count="$(awk 'NF { count++ } END { print count + 0 }' <<<"$CACHE_OUT")"
    echo "list records=$cache_record_count"
    [[ "$cache_record_count" -gt 0 ]] || { echo "FAIL: list returned no JSONL records"; exit 1; }

    ./ob dev --machine "$MACHINE" modify nonexistent-recipe-xyz >/dev/null 2>&1
    invalid_recipe_rc=$?
    echo "invalid recipe rc=$invalid_recipe_rc (expect 1)"
    [[ "$invalid_recipe_rc" -eq 1 ]] || { echo "FAIL: invalid recipe should exit 1"; exit 1; }

    candidates_rc=0
    CANDIDATES="$(python3 -c '
import json
import sys

recipes = []
record_count = 0
for line_number, line in enumerate(sys.stdin, 1):
    line = line.strip()
    if not line:
        continue
    try:
        record = json.loads(line)
    except json.JSONDecodeError as error:
        sys.stderr.write(f"invalid JSONL record {line_number}: {error}\n")
        raise SystemExit(1)
    if not isinstance(record, dict) or not isinstance(record.get("recipe"), str) or not record["recipe"]:
        sys.stderr.write(f"invalid JSONL record {line_number}: missing recipe\n")
        raise SystemExit(1)
    record_count += 1
    if len(recipes) < 50:
        recipes.append(record["recipe"])

if record_count == 0:
    sys.stderr.write("list returned no JSONL records\n")
    raise SystemExit(1)
print("\n".join(recipes))
' <<<"$CACHE_OUT")" || candidates_rc=$?
    [[ "$candidates_rc" -eq 0 ]] || { echo "FAIL: list returned invalid JSONL"; exit 1; }

    status_rc=0
    STATUS_OUT="$(devtool_in_env "$MACHINE" status)" || status_rc=$?
    [[ "$status_rc" -eq 0 ]] || { echo "FAIL: devtool status rc=$status_rc"; exit 1; }

    RECIPE=""
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if ! ob_dev_integration_status_has_recipe "$candidate" "$STATUS_OUT"; then
            RECIPE="$candidate"
            break
        fi
    done <<<"$CANDIDATES"
    [[ -n "$RECIPE" ]] || { echo "SKIP: no unmodified recipe in cache (first 50)"; exit 77; }
    echo "modify recipe=$RECIPE (selected unmodified)"

    CLEANUP_NEEDED=0
    trap ob_dev_integration_cleanup EXIT

    # Set this before modify: a later status/srctree failure may follow a successful side effect.
    CLEANUP_NEEDED=1
    modify_rc=0
    SRCTREE="$(./ob dev --machine "$MACHINE" modify "$RECIPE" 2>/dev/null)" || modify_rc=$?
    echo "modify rc=$modify_rc srctree=$SRCTREE"
    [[ "$modify_rc" -eq 0 && -n "$SRCTREE" && -d "$SRCTREE" ]] || {
        echo "FAIL: modify/srctree"
        exit 1
    }

    if ! ob_dev_integration_cleanup; then
        echo "FAIL: devtool reset failed (trap EXIT will retry)"
        exit 1
    fi
    trap - EXIT
    echo "[integration] OK (modify $RECIPE -> srctree -> reset)"
}

if [[ "${OB_DEV_INTEGRATION_NO_MAIN:-0}" != "1" ]]; then
    ob_dev_integration_main "$@"
fi
