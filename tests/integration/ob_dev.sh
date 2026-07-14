#!/usr/bin/env bash
# tests/integration/ob_dev.sh — ob dev 真实 integration(opt-in, --integration 才跑)。
# 🔴2: 选未 modified recipe(不用 pre-modified 假绿) + trap cleanup_needed(reset 成功才解除) + reset 失败 exit 1。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

OPENBMC_DIR="$(pwd)/workspace/openbmc"
export OPENBMC_DIR

MACHINE="${OB_INTEGRATION_MACHINE:-}"
if [[ -z "$MACHINE" ]]; then
    for m in workspace/configs/*.init-done; do
        [[ -f "$m" ]] && MACHINE="$(basename "$m" .init-done)" && break
    done
fi
[[ -n "$MACHINE" ]] || { echo "skip: no init machine"; exit 0; }
echo "[integration] machine=$MACHINE openbmc=$OPENBMC_DIR"

devtool_in_env() {
    (
        cd "$OPENBMC_DIR" || exit 1
        set +u
        # shellcheck disable=SC1091
        source setup "$MACHINE" "$OPENBMC_DIR/build/$MACHINE" >/dev/null 2>&1
        devtool "$@"
    ) 2>/dev/null
}

# refresh + 断言 rc
./ob dev --machine "$MACHINE" refresh 2>/dev/null
refresh_rc=$?
[ "$refresh_rc" -eq 0 ] || { echo "FAIL: refresh rc=$refresh_rc"; exit 1; }

CACHE_OUT="$(./ob dev --machine "$MACHINE" list 2>/dev/null)"
lines=$(printf '%s\n' "$CACHE_OUT" | wc -l)
echo "list lines=$lines"
[ "$lines" -gt 0 ] || { echo "FAIL: list empty"; exit 1; }

./ob dev --machine "$MACHINE" modify nonexistent-recipe-xyz >/dev/null 2>&1
rc=$?
echo "invalid recipe rc=$rc (expect 1)"
[ "$rc" -eq 1 ] || { echo "FAIL: invalid recipe should exit 1"; exit 1; }

# 🔴2: 选未 modified recipe(devtool status 一次列 modified,从 cache 前 50 选未 modified)
MODIFIED_LIST="$(devtool_in_env status 2>/dev/null | awk -F': ' '{print $1}')"
RECIPE=""
while IFS= read -r _cand; do
    [[ -z "$_cand" ]] && continue
    if ! grep -qxF "$_cand" <<<"$MODIFIED_LIST"; then
        RECIPE="$_cand"; break
    fi
done < <(printf '%s\n' "$CACHE_OUT" | python3 -c 'import json,sys
for l in sys.stdin:
    l=l.strip()
    if l:
        try: print(json.loads(l)["recipe"])
        except: pass' 2>/dev/null | head -50)
[[ -n "$RECIPE" ]] || { echo "skip: no unmodified recipe in cache (first 50)"; exit 0; }
echo "modify recipe=$RECIPE (selected unmodified)"

# 🔴2: trap cleanup_needed(reset 成功才解除;失败 EXIT 重试)
CLEANUP_NEEDED=0
cleanup() {
    if [[ "${CLEANUP_NEEDED:-0}" == "1" && -n "${RECIPE:-}" ]]; then
        if ! devtool_in_env reset "$RECIPE" >/dev/null 2>&1; then
            echo "WARN: cleanup reset failed (recipe $RECIPE 留 modified,手动清理)" >&2
        fi
    fi
}
trap cleanup EXIT

SRCTREE="$(./ob dev --machine "$MACHINE" modify "$RECIPE" 2>/dev/null)"
rc=$?
echo "modify rc=$rc srctree=$SRCTREE"
[ "$rc" -eq 0 ] && [ -n "$SRCTREE" ] && [ -d "$SRCTREE" ] || { echo "FAIL: modify/srctree"; exit 1; }
CLEANUP_NEEDED=1   # modify 成功,trap 需 cleanup

# 显式 reset(成功才解除 trap;失败 trap EXIT 重试 cleanup)
devtool_in_env reset "$RECIPE" >/dev/null 2>&1
reset_rc=$?
[ "$reset_rc" -eq 0 ] || { echo "FAIL: devtool reset rc=$reset_rc (trap EXIT 重试)"; exit 1; }
CLEANUP_NEEDED=0   # reset 成功,trap 不需 cleanup
trap - EXIT
echo "[integration] OK (modify $RECIPE → srctree → reset)"
