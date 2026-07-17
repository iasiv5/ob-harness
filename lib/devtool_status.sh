#!/usr/bin/env bash
# lib/devtool_status.sh — devtool status 子命令底层组装器(leaf-pure module)。
#   devtool_status_run: 经 _devtool_env_exec 跑 devtool status → _devtool_parse_status_all 全量解析 → outvar。
#   消费 lib/devtool_workspace.sh 的 _devtool_env_exec / _devtool_parse_status_all(全局命名空间)。
#   ob loader source 全部 lib; bash 运行时按名解析,不依赖 source 顺序。术语见 CONTEXT.md ob dev porcelain stdout。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断。

# devtool_status_run <machine> <build_dir> <entries_outvar> <stage_outvar> <stderr_file_outvar>
# leaf-pure 组装器: env_exec 跑 devtool status → _devtool_parse_status_all 全量解析 → outvar 回传。
# entries = 换行分隔 "recipe<TAB>srctree" 串(空列表→空串); stage = cd/setup/postcondition/command;
# stderr_file 传 caller(cat+rm); 内部 stdout_file 解析后 rm。返回 rc(不 exit)。
devtool_status_run() {
    local machine="$1" build_dir="$2"
    local entries_outvar="$3" stage_outvar="$4" stderr_file_outvar="$5"
    local stage_file stdout_file stderr_file rc entries=""
    stage_file="$(mktemp)"; stdout_file="$(mktemp)"; stderr_file="$(mktemp)"
    rc=0
    : > "$stdout_file"
    _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        entries="$(_devtool_parse_status_all "$stdout_file")"
    fi
    printf -v "$entries_outvar" '%s' "$entries"
    printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
    printf -v "$stderr_file_outvar" '%s' "$stderr_file"
    rm -f "$stage_file" "$stdout_file"
    return "$rc"
}
