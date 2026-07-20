#!/usr/bin/env bash
# lib/devtool_build.sh — ob dev build 执行(leaf-pure module)。
#   devtool_build_run: status-first(recipe 未 modified → not_modified 信号, 不 build; status 失败 → 回传 stage+rc, 不继续)
#   → devtool build。镜像 devtool_modify_run 结构。消费 lib/devtool_workspace.sh 的 _devtool_env_exec / _devtool_parse_status_all。
#   术语见 CONTEXT.md ob dev build。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断。

# devtool_build_run <machine> <build_dir> <recipe> <stage_outvar> <stderr_file_outvar> <not_modified_outvar>
# step1 devtool status(rc=0 显式初始化; 失败 → 回传 stage+rc, return rc, 不查 modified 不 build)
#   → status 成功 + recipe 不在 modified 列表 → not_modified=1, return 0(前置缺失, cmd_dev exit 3)
#   → 在列 → devtool build <recipe> → 回传 stage+rc。stderr_file 传 caller(dev_relay_result cat+rm)。
devtool_build_run() {
    local machine="$1" build_dir="$2" recipe="$3"
    local stage_outvar="$4" stderr_file_outvar="$5" not_modified_outvar="$6"
    local stage_file stdout_file stderr_file rc=0 entries=""
    stage_file="$(mktemp 2>/dev/null)"; stdout_file="$(mktemp 2>/dev/null)"; stderr_file="$(mktemp 2>/dev/null)"
    # 1. status 查 modified(失败 → 回传 stage+rc, 不继续)
    : > "$stdout_file"
    _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf -v "$not_modified_outvar" '%s' ""
        printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
        printf -v "$stderr_file_outvar" '%s' "$stderr_file"
        rm -f "$stage_file" "$stdout_file"
        return "$rc"
    fi
    entries="$(_devtool_parse_status_all "$stdout_file")"
    if ! grep -qF "$recipe"$'\t' <<<"$entries"; then
        printf -v "$not_modified_outvar" '%s' "1"
        printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
        printf -v "$stderr_file_outvar" '%s' "$stderr_file"
        rm -f "$stage_file" "$stdout_file"
        return 0
    fi
    # 2. modified → devtool build
    rc=0
    : > "$stdout_file"
    _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool build "$recipe" || rc=$?
    printf -v "$not_modified_outvar" '%s' ""
    printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
    printf -v "$stderr_file_outvar" '%s' "$stderr_file"
    rm -f "$stage_file" "$stdout_file"
    return "$rc"
}
