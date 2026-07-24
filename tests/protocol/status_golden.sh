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
#   ① TMP 目录(mktemp 真实返回 $TMP,动态锚 regex-escaped)→ <TMP>。不硬编码 /tmp 前缀——
#      TMPDIR 任意(/tmp、VSCode-server tmp、macOS /var/folders)都稳(R4 F1 跨环境假阴性修复)。
#   ② PID 数字(stalebox 固定 99999999 / recycbox=测试进程 $$ 变化)→ <pid>。
# expected 存的是已归一化的 <TMP>/<pid> 占位符版本(环境无关);live 同样归一化后比对。
_esc_tmp=$(printf '%s' "$TMP" | sed 's/[][\\.^$*]/\\&/g')
normalize() { sed -e "s|$_esc_tmp|<TMP>|g" -e 's|PID [0-9][0-9]*|PID <pid>|g' "$1"; }
diff -u <(normalize "$(dirname "$0")/status_golden.expected") <(normalize "$TMP/live.out")
