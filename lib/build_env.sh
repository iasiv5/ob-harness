#!/usr/bin/env bash
# lib/build_env.sh — current-shell build environment 进入原语(cd+source setup, 副作用刻意留在当前 shell, 与 bitbake_env 子进程隔离对偶). 术语见 CONTEXT.md current-shell build environment.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.

build_env_enter() {
    local machine="$1" build_dir="$2"
    cd "$OPENBMC_DIR" || return 1
    local prev_opts
    prev_opts=$(set +o | grep nounset)
    set +u
    # shellcheck disable=SC1091
    source setup "$machine" "$build_dir"   # 返回码 silent (本仓两份 setup 抽样不可靠);
                                            # stderr 透传, 调用者按需 2>/dev/null
    eval "$prev_opts"
}
