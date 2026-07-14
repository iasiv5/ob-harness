#!/usr/bin/env bash
# tests/integration/ob_dev.sh — ob dev 真实 integration(opt-in, --integration 才跑)。
# 覆盖: list cache / invalid recipe exit 1 / 真实 modify→srctree / devtool reset 清理。
# 需真实 build env + init machine;会真实 devtool modify 一个 recipe + reset 清理(best-effort)。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# 找 init machine
MACHINE=""
for m in workspace/configs/*.init-done; do
    [[ -f "$m" ]] && MACHINE="$(basename "$m" .init-done)" && break
done
[[ -n "$MACHINE" ]] || { echo "skip: no init machine"; exit 0; }
echo "[integration] machine=$MACHINE"

# 0. 确保 cache fresh(避免环境 bblayers 动态变化导致 stale;refresh ~37s)
./ob dev --machine "$MACHINE" refresh 2>/dev/null

# 1. list cache(一次取,避免重复 list)
CACHE_OUT="$(./ob dev --machine "$MACHINE" list 2>/dev/null)"
lines=$(printf '%s\n' "$CACHE_OUT" | wc -l)
echo "list lines=$lines"
[ "$lines" -gt 0 ] || { echo "FAIL: list empty"; exit 1; }

# 2. invalid recipe → exit 1
./ob dev --machine "$MACHINE" modify nonexistent-recipe-xyz >/dev/null 2>&1
rc=$?
echo "invalid recipe rc=$rc (expect 1)"
[ "$rc" -eq 1 ] || { echo "FAIL: invalid recipe should exit 1"; exit 1; }

# 3. 真实 modify(选 cache 首个 target recipe) + srctree 校验
RECIPE="$(printf '%s\n' "$CACHE_OUT" | python3 -c 'import json,sys;print(json.loads(sys.stdin.readline())["recipe"])' 2>/dev/null)"
echo "modify recipe=$RECIPE"
SRCTREE="$(./ob dev --machine "$MACHINE" modify "$RECIPE" 2>/dev/null)"
rc=$?
echo "modify rc=$rc srctree=$SRCTREE"
[ "$rc" -eq 0 ] && [ -n "$SRCTREE" ] && [ -d "$SRCTREE" ] || { echo "FAIL: modify/srctree"; exit 1; }

# 4. devtool reset 清理(best-effort;失败留 modified,提示手动 reset)
OB_NO_MAIN=1 source ./ob >/dev/null 2>&1
(
    cd "$OPENBMC_DIR" || exit 1
    set +u
    # shellcheck disable=SC1091
    source setup "$MACHINE" "$OPENBMC_DIR/build/$MACHINE" >/dev/null 2>&1
    devtool reset "$RECIPE" >/dev/null 2>&1
) 2>/dev/null
echo "[integration] OK (modify $RECIPE → srctree → reset)"
