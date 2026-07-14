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
        set +u &&   # setup 脚本可能用未绑定变量(如 ZSH_NAME),关 nounset(仿 build_env_enter);子 shell 内不影响父
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

# _devtool_parse_srctree <recipe> <status_file> → srctree(字面匹配 recipe 行,不把 recipe 当正则;
# 剥离可选 " (recipefile)" 后缀)。无匹配输出空,返回 1。
_devtool_parse_srctree() {
    local rcp="$1" file="$2"
    awk -v r="$rcp" 'index($0,r": ")==1{s=substr($0,index($0,": ")+2);sub(/ \([^)]*\)$/,"",s);print s;exit}' "$file" 2>/dev/null
}

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
