#!/usr/bin/env bash
# lib/build_env.sh — current-shell build environment 进入原语.
# Leaf module: 函数绝不 exit (leaf-no-exit), 调用者负责 exit-code/remedy/诊断.
# 有副作用 (cd OPENBMC_DIR + source setup), 刻意非 pure — 与 lib/bitbake_env.sh
# 的子进程隔离查询对偶 (泄漏 vs 隔离). 术语见 CONTEXT.md `current-shell build environment`.

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
