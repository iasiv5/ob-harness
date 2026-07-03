#!/usr/bin/env bash
# tests/protocol/build_env_enter_structure.sh — build_env_enter 结构回归锁。
# 防三处调用点内联 source setup 回潮, 锁 build_env_enter 必调 source setup.
set -uo pipefail

source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_SH="$ROOT/lib/commands.sh"
INIT_PIPELINE_SH="$ROOT/lib/init_pipeline.sh"
BUILD_ENV_SH="$ROOT/lib/build_env.sh"

extract_shell_function() {
    local file="$1" function_name="$2"
    awk -v fn="$function_name" '
        BEGIN { in_fn = 0; found = 0 }
        $0 ~ "^" fn "[(][)] [{$]" || $0 ~ "^" fn "[(][)]$" { in_fn = 1; found = 1; print; next }
        in_fn && $0 ~ "^[A-Za-z_][A-Za-z0-9_]*[(][)] [{$]" { in_fn = 0; exit }
        in_fn { print }
        END { if (!found) exit 42 }
    ' "$file"
}

# regex 匹配: 优先 rg, 无 rg 回退 grep -E(POSIX; [[:space:]] 等字符类两者都支持).
# ubuntu-24.04 CI runner 不预装 ripgrep(已核实 actions/runner-images Ubuntu2404-Readme),
# 回退保证结构锁在无 rg 环境也真测(否则 assert_function_match 因 rg 缺失误 fail).
match_regex() {
    local pattern="$1" text="$2"
    if command -v rg >/dev/null 2>&1; then
        printf '%s' "$text" | rg -q --no-messages -e "$pattern"
    else
        printf '%s' "$text" | grep -E -q -- "$pattern"
    fi
}

assert_function_not_match() {
    local label="$1" file="$2" function_name="$3" pattern="$4" body
    body=$(extract_shell_function "$file" "$function_name") || {
        _assert_bad "$label (function '$function_name' not found)"; return; }
    if match_regex "$pattern" "$body"; then
        _assert_bad "$label (matched /$pattern/)"
    else
        _assert_ok "$label"
    fi
}

# 正向 regex helper(先例 qemu_launch_profile_structure.sh 只有 not_match/contains,
# 正向 match 是本计划新增): 函数体匹配 pattern 才算通过.
assert_function_match() {
    local label="$1" file="$2" function_name="$3" pattern="$4" body
    body=$(extract_shell_function "$file" "$function_name") || {
        _assert_bad "$label (function '$function_name' not found)"; return; }
    if match_regex "$pattern" "$body"; then
        _assert_ok "$label"
    else
        _assert_bad "$label (no match /$pattern/)"
    fi
}

# 行首 source setup 命令级正则(DRY-RUN 的 echo 不在行首不误匹配; 要求 setup 后是空白/行尾, 排除 source setupx)
INLINE_RE='^[[:space:]]*source[[:space:]]+setup([[:space:]]|$)'

assert_function_not_match "cmd_build no inline source setup"          "$COMMANDS_SH"       cmd_build          "$INLINE_RE"
assert_function_not_match "init_bitbake_env no inline source setup"   "$INIT_PIPELINE_SH" init_bitbake_env   "$INLINE_RE"
assert_function_not_match "generate_dep_graph no inline source setup" "$INIT_PIPELINE_SH" generate_dep_graph "$INLINE_RE"
# 正向锁: build_env_enter 必须真正调用 source setup(行首命令级, 排除注释/说明文字)
assert_function_match    "build_env_enter must call source setup"     "$BUILD_ENV_SH"      build_env_enter    "$INLINE_RE"

# 缺失函数必须 fail, 不能返回空体骗过扫描
if extract_shell_function "$BUILD_ENV_SH" __missing >/dev/null 2>&1; then
    _assert_bad "extract_shell_function missing target fails"
else
    _assert_ok "extract_shell_function missing target fails"
fi

assert_summary
