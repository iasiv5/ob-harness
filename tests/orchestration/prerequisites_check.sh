#!/usr/bin/env bash
# tests/orchestration/prerequisites_check.sh — 前置检查编排测试(orchestration 层)。
# 减法 PATH:tmpbin symlink 必要命令(含 git),只排除目标工具 → command -v 失败 → exit 3。
# 不能用 empty_path(PATH=空会让 uname 先消失,失败在 OS check,假绿)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# 构造 tmpbin:symlink 必要命令(含 git),按需排除目标
make_tmpbin() { # <exclude>
    local exclude="$1" d src; d="$(mktemp -d)"
    for cmd in git python3 uname curl df sh; do
        [[ "$cmd" == "$exclude" ]] && continue
        src=""
        local p
        for p in /usr/bin /bin /usr/local/bin; do [[ -x "$p/$cmd" ]] && src="$p/$cmd" && break; done
        [[ -n "$src" ]] && ln -s "$src" "$d/$cmd"
    done
    printf '%s' "$d"
}

# 缺 git → exit 3 + 提示 git
d="$(make_tmpbin git)"
err="$(bash -c 'export PATH="$1"; shift; OB_NO_MAIN=1 source "$1"; prerequisites_check' _ "$d" "$OB" 2>&1)"; rc=$?
assert_eq "missing git rc"        "$rc" 3
assert_contains "missing git msg" "$err" "Required tool not found: git"
rm -rf "$d"

# 缺 python3(git 仍在)→ exit 3 + 提示 python3
d="$(make_tmpbin python3)"
err="$(bash -c 'export PATH="$1"; shift; OB_NO_MAIN=1 source "$1"; prerequisites_check' _ "$d" "$OB" 2>&1)"; rc=$?
assert_eq "missing python3 rc"        "$rc" 3
assert_contains "missing python3 msg" "$err" "Required tool not found: python3"
rm -rf "$d"

assert_summary
