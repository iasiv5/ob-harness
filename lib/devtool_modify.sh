#!/usr/bin/env bash
# lib/devtool_modify.sh — devtool modify 执行 + _devtool_env_exec 子 shell build env helper(同一 subshell + 输出隔离 + postcondition). 术语见 CONTEXT.md.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.

# === 函数区(T2 填充: _devtool_env_exec + devtool_modify_run) ===
