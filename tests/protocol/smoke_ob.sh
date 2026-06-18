#!/usr/bin/env bash
# ob 冒烟测试 —— 只测非交互路径的退出码。零依赖、不触发 main、不跑 QEMU、不需 workspace。
# 归属 test layer 的 protocol 层(退出码协议)。
#
# 【什么时候用】
#   - 日常回归:改了 ob 之后随手跑一下(秒级),确认参数解析/前提检查没退化
#   - CI 或提交前的快速 sanity check(不依赖 workspace / QEMU / expect)
#
# 【怎么用】
#   $ bash tests/protocol/smoke_ob.sh
#   输出:每个 case 一行 ok/FAIL,末尾 PASS=N FAIL=M。FAIL=0 → exit 0。
#
# 【覆盖项】(非交互退出码)
#   parse_args --help → 0    parse_args unknown opt → 1
#   parse_args missing val → 1    ob build(空 workspace)→ 3
#
# 【原理】
#   - 加载:source tests/lib/ob_loader.sh(OB_NO_MAIN=1,只定义函数不跑 main)。
#     ob 顶部 set -euo pipefail 经 source 泄漏,ob_loader 关 errexit 防首个非零
#     assert 整批中止(保留 nounset/pipefail)。$OB 由 ob_loader 提供,可移植。
#   - --dry-run 等需 machine 的路径这里测不了(resolve_machine 先于 dry-run,
#     空 workspace 直接 exit 3)——交给 manual_matrix.exp 覆盖。
#
# 【由来】ob 日常零依赖回归基线;交互/取消分支由 protocol/manual_matrix.exp 补。
#        2026-06-17 迁自 tests/smoke_ob.sh,加载改用 ob_loader,修原 :56 硬编码路径。
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"   # 加载 ob 函数 + $OB,errexit 已关
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# --- parse_args exit codes (each case runs in its own subshell via assert_rc) ---
assert_rc 0 "parse_args --help"      bash -c 'OB_NO_MAIN=1 source "$1"; parse_args --help'             _ "$OB"
assert_rc 1 "parse_args unknown opt" bash -c 'OB_NO_MAIN=1 source "$1"; parse_args start-qemu --bogus-opt' _ "$OB"
assert_rc 1 "parse_args missing val" bash -c 'OB_NO_MAIN=1 source "$1"; parse_args start-qemu --ssh-port'  _ "$OB"
# --- dispatch + prerequisites (baseline: ob build in empty workspace -> exit 3) ---
TMPWS="$(mktemp -d)"
assert_rc 3 "ob build in empty workspace" \
    bash -c 'cd "$1"; OB_NO_MAIN=1 source "$2"; set +e; parse_args build; cmd_build' _ "$TMPWS" "$OB"
rm -rf "$TMPWS"
# NOTE: --dry-run has no machineless path (resolve_machine runs first, exits 3 in empty
# workspace) — covered by the manual matrix, not automated here.

assert_summary
