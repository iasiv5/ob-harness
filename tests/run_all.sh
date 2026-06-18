#!/usr/bin/env bash
# tests/run_all.sh — 分层调度入口。collect-all: 跑完全部再汇总失败。
# 用法: tests/run_all.sh [--integration]
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/.."   # 切到仓库根,使 expect 脚本的 `spawn ./ob` 成立
INTEGRATION=0; [[ "${1:-}" == "--integration" ]] && INTEGRATION=1
LAYERS=(protocol unit orchestration); [[ "$INTEGRATION" == 1 ]] && LAYERS+=(integration)
FAILED=()
for layer in "${LAYERS[@]}"; do
    echo "=== $layer ==="
    shopt -s nullglob
    for f in "tests/$layer"/*.sh "tests/$layer"/*.exp; do
        if [[ "$f" == *.exp ]]; then
            command -v expect >/dev/null 2>&1 || { echo "skip $f (no expect)"; continue; }
            if expect "$f" >/dev/null 2>&1; then echo "ok   $(basename "$f")"; else echo "FAIL $(basename "$f")"; FAILED+=("$f"); fi
        else
            if bash "$f"; then echo "ok   $(basename "$f")"; else echo "FAIL $(basename "$f")"; FAILED+=("$f"); fi
        fi
    done
    shopt -u nullglob
done
echo ""
if (( ${#FAILED[@]} > 0 )); then echo "FAILED (${#FAILED[@]}):"; printf '  %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL GREEN"
