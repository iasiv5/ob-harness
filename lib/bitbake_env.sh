#!/usr/bin/env bash
# lib/bitbake_env.sh — BitBake environment one-shot 查询(子进程隔离, 副作用不泄漏到当前 shell). 术语见 CONTEXT.md BitBake environment support module.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.


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