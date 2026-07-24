#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/status_fixtures.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
status_build_fixture "$TMP"

# live 输出用子壳+重定向捕获(禁用 $(...) 命令替换——吞末尾换行,与 expected 字节不对称,N1)。
( cmd_status ) > "$TMP/live.out" 2>&1

# 抹平 run-specific 值再 diff(否则 golden 跨 run 不可能字节稳定):
#   ① mktemp TMP 目录(出现在 Local path / orphan Path)→ <TMP>
#   ② PID 数字(stalebox 固定 99999999 / recycbox=测试进程 $$ 变化)→ <pid>
# 只抹已知非确定 token,格式/结构/文案变化仍被 diff 抓住。
normalize() { sed -e 's|/tmp/tmp\.[A-Za-z0-9]*|<TMP>|g' -e 's|PID [0-9][0-9]*|PID <pid>|g' "$1"; }
diff -u <(normalize "$(dirname "$0")/status_golden.expected") <(normalize "$TMP/live.out")
