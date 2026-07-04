#!/usr/bin/env bash
# tests/run_all.sh — 分层调度入口。collect-all: 跑完全部再汇总失败。
# 默认只跑 .sh(秒级快速回归);.exp(manual_matrix 等,慢)默认跳过。
# 用法:
#   tests/run_all.sh               快速:protocol/unit/orchestration 的 .sh
#   tests/run_all.sh --full        安全全量:默认三层的 .sh + .exp;不进入 integration
#   tests/run_all.sh --integration 追加 integration 层(可能 build / 启动 QEMU / 占端口 / 耗时)
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
    local file base output rc tmp_root
    file="$1"
    base="$(basename "$file")"
    command -v expect >/dev/null 2>&1 || { echo "skip $base (no expect)"; return; }
    tmp_root="${TMPDIR:-/tmp}"
    output="$(mktemp "$tmp_root/ob-run-exp.XXXXXX")" || { echo "FAIL $base (mktemp failed)"; FAILED+=("$file"); return; }
    expect "$file" >"$output" 2>&1
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        if grep -q '^skip ' "$output"; then
            grep '^skip ' "$output"
        else
            echo "ok   $base"
        fi
        rm -f "$output"
        return
    fi
    echo "FAIL $base (rc=$rc)"
    sed 's/^/  | /' "$output"
    FAILED+=("$file")
    rm -f "$output"
}
if [[ "$FULL" == 1 && "$INTEGRATION" != 1 ]]; then
    echo "note --full excludes integration layer; add --integration for real build/QEMU tests"
fi
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
