#!/usr/bin/env bash
# shellcheck disable=SC1091   # source setup 是动态文件;_devtool_env_exec 在 && 链中 source,行级 disable 不可用(SC1126),故文件级
# lib/devtool_modify.sh — devtool modify 执行 + _devtool_env_exec 子 shell build env helper(同一 subshell + 输出隔离 + postcondition). 术语见 CONTEXT.md.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.

# _devtool_env_exec <machine> <build_dir> <stage_file> <stdout_file> <stderr_file> -- <cmd...>
# 同一 subshell(&& 链,无 exit 字面量);只有 <cmd> stdout → stdout_file;setup/postcondition 输出 → stderr_file。
# stage 写 stage_file: cd/setup/postcondition/command。返回 rc(不 exit)。
_devtool_env_exec() {
    local machine="$1" build_dir="$2" stage_file="$3" stdout_file="$4" stderr_file="$5"
    shift 5
    [[ "$1" == "--" ]] && shift
    (
        echo cd >"$stage_file"
        cd "$OPENBMC_DIR" &&
        echo setup >"$stage_file" &&
        source setup "$machine" "$build_dir" >>"$stderr_file" 2>&1 &&
        echo postcondition >"$stage_file" &&
        [[ -f "$build_dir/conf/local.conf" ]] &&
        command -v devtool >>"$stderr_file" &&
        command -v bitbake-layers >>"$stderr_file" &&
        echo command >"$stage_file" &&
        "$@" >"$stdout_file"
    ) 2>>"$stderr_file"
    return $?
}

# devtool_modify_run <machine> <build_dir> <recipe> <srctree_outvar> <stage_outvar> <stderr_file_outvar>
# 三段: status 查已 modify → 未命中 devtool modify → 成功后再次 status 解析 srctree。
# 通过 outvar 回传 srctree(内容) + 最终 stage(内容) + stderr_file(路径,供 cmd_dev 读诊断)。返回 rc(不 exit)。
devtool_modify_run() {
    local machine="$1" build_dir="$2" recipe="$3"
    local srctree_outvar="$4" stage_outvar="$5" stderr_file_outvar="$6"
    local stage_file stdout_file stderr_file rc srctree=""
    stage_file="$(mktemp)"; stdout_file="$(mktemp)"; stderr_file="$(mktemp)"
    rc=0
    # 1. status 查已 modify
    _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        srctree="$(grep "^${recipe}: " "$stdout_file" | head -1 | sed 's/^[^:]*: //' || true)"
    else
        srctree=""
    fi
    # 2. 未命中 → modify + 再次 status
    if [[ -z "$srctree" ]]; then
        rc=0
        _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool modify "$recipe" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            rc=0
            _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
            if [[ "$rc" -eq 0 ]]; then
                srctree="$(grep "^${recipe}: " "$stdout_file" | head -1 | sed 's/^[^:]*: //' || true)"
            fi
        fi
    fi
    # 回传
    printf -v "$srctree_outvar" '%s' "$srctree"
    printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
    printf -v "$stderr_file_outvar" '%s' "$stderr_file"
    rm -f "$stage_file" "$stdout_file"
    return "$rc"
}
