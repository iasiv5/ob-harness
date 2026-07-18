#!/usr/bin/env bash
# lib/devtool_modify.sh — devtool modify 执行(devtool_modify_run;消费 lib/devtool_workspace.sh 的
#   _devtool_env_exec / _devtool_parse_srctree)。术语见 CONTEXT.md。
# Exit: leaf-pure module(函数绝不 exit); 调用者(cmd_dev)负责 exit-code/remedy/诊断。

# devtool_modify_run <machine> <build_dir> <recipe> <srctree_outvar> <stage_outvar> <stderr_file_outvar>
# 三段: status 查已 modify(status 失败则不进 modify) → 未命中 devtool modify → 再次 status 解析 srctree。
# srctree 校验: 非空 + 绝对路径 + 目录存在,否则失败。通过 outvar 回传。返回 rc(不 exit)。
devtool_modify_run() {
    local machine="$1" build_dir="$2" recipe="$3"
    local srctree_outvar="$4" stage_outvar="$5" stderr_file_outvar="$6"
    local stage_file stdout_file stderr_file rc srctree=""
    stage_file="$(mktemp)"; stdout_file="$(mktemp)"; stderr_file="$(mktemp)"
    rc=0
    # 1. status 查已 modify(失败则不进 modify——build env/devtool 坏)
    _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        srctree="$(_devtool_parse_srctree "$recipe" "$stdout_file")"
    fi
    # 2. 未命中(status 成功但无目标行) → modify + 再次 status
    if [[ "$rc" -eq 0 && -z "$srctree" ]]; then
        _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool modify "$recipe" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
            if [[ "$rc" -eq 0 ]]; then
                srctree="$(_devtool_parse_srctree "$recipe" "$stdout_file")"
                # modify 成功但二次 status 无目标行 → 失败(空 srctree)
                [[ -z "$srctree" ]] && rc=1
            fi
        fi
    fi
    # srctree 校验: 非空 + 绝对路径 + 目录存在
    if [[ "$rc" -eq 0 && ( -z "$srctree" || "$srctree" != /* || ! -d "$srctree" ) ]]; then
        rc=1
    fi
    printf -v "$srctree_outvar" '%s' "$srctree"
    printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
    printf -v "$stderr_file_outvar" '%s' "$stderr_file"
    rm -f "$stage_file" "$stdout_file"
    return "$rc"
}
