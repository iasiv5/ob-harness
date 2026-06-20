#!/usr/bin/env bash
# tests/run_all.sh — 分层调度入口。collect-all: 跑完全部再汇总失败。
# 默认只跑 .sh(秒级快速回归);.exp(manual_matrix 等,慢)默认跳过。
# 用法:
#   tests/run_all.sh               快速:protocol/unit/orchestration 的 .sh
#   tests/run_all.sh --full        含 .exp(manual_matrix 交互矩阵,慢)
#   tests/run_all.sh --integration 加 integration 层(init→build E2E,需 workspace)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/.." || exit 1   # 切到仓库根,使 expect 脚本的 spawn ./ob 成立
FULL=0; INTEGRATION=0
for arg in "$@"; do
    case "$arg" in
        --full) FULL=1 ;;
        --integration) INTEGRATION=1 ;;
        *) echo "unknown: $arg" >&2 ;;
    esac
done
LAYERS=(protocol unit orchestration); [[ "$INTEGRATION" == 1 ]] && LAYERS+=(integration)
FAILED=()
run_exp() { # <file>
    command -v expect >/dev/null 2>&1 || { echo "skip $(basename "$1") (no expect)"; return; }
    if expect "$1" >/dev/null 2>&1; then echo "ok   $(basename "$1")"; else echo "FAIL $(basename "$1")"; FAILED+=("$1"); fi
}
for layer in "${LAYERS[@]}"; do
    echo "=== $layer ==="
    shopt -s nullglob
    for f in "tests/$layer"/*.sh; do
        if bash "$f"; then echo "ok   $(basename "$f")"; else echo "FAIL $(basename "$f")"; FAILED+=("$f"); fi
    done
    # .exp 慢(manual_matrix 的 start-qemu cancel 需 bitbake -e):默认跳过
    if [[ "$FULL" == 1 ]] || { [[ "$INTEGRATION" == 1 ]] && [[ "$layer" == "integration" ]]; }; then
        for f in "tests/$layer"/*.exp; do run_exp "$f"; done
    else
        for f in "tests/$layer"/*.exp; do echo "skip $(basename "$f") (--full)"; done
    fi
    shopt -u nullglob
done
echo ""
if (( ${#FAILED[@]} > 0 )); then echo "FAILED (${#FAILED[@]}):"; printf '  %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL GREEN"
