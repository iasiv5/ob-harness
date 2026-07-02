#!/usr/bin/env bash
# lib/bitbake_env.sh — BitBake environment one-shot helpers, sourced by ob.
# Leaf-pure support module: no exit; callers own exit-code/remedy semantics.


bitbake_env_list_available_machines() {
    # Listing treats a missing checkout as an empty list; query helpers fail closed.
    [[ -n "${OPENBMC_DIR:-}" && -d "$OPENBMC_DIR" ]] || return 0

    local raw
    raw=$(
        cd "$OPENBMC_DIR"
        set +u
        # setup prints "Use one of:" on some OpenBMC trees and may return non-zero.
        # shellcheck disable=SC1091
        source setup 2>&1 || true
    )

    echo "$raw" \
      | sed -n '/Use one of:/,$p' \
      | tail -n +2 \
      | tr -s ' \t' '\n' \
      | sed '/^$/d' \
      | sort -u
}

bitbake_env_query_vars() {
    local machine="$1"
    local build_dir="$2"

    [[ -n "${OPENBMC_DIR:-}" && -d "$OPENBMC_DIR" ]] || return 1

    (
        cd "$OPENBMC_DIR"
        set +u
        # shellcheck disable=SC1091
        source setup "$machine" "$build_dir" 2>/dev/null && bitbake -e 2>/dev/null
    )
}