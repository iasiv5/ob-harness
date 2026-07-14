#!/usr/bin/env bash
# tests/integration/ob_dev.sh — ob dev 真实 integration(opt-in, --integration 才跑)。
# 覆盖: list/invalid recipe exit 1/真实 modify→srctree/devtool reset 清理。
# 需真实 build env + init machine;支持 OB_INTEGRATION_MACHINE 覆盖。
# 🔴4: 不 source ob(避免重置 MACHINE/OPENBMC_DIR);modify 前查 pre-modified,只 reset 本测试创建的;reset 失败 exit 1。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

OPENBMC_DIR="$(pwd)/workspace/openbmc"
export OPENBMC_DIR

# 选 machine(OB_INTEGRATION_MACHINE 覆盖,否则首个 init-done)
MACHINE="${OB_INTEGRATION_MACHINE:-}"
if [[ -z "$MACHINE" ]]; then
    for m in workspace/configs/*.init-done; do
        [[ -f "$m" ]] && MACHINE="$(basename "$m" .init-done)" && break
    done
fi
[[ -n "$MACHINE" ]] || { echo "skip: no init machine"; exit 0; }
echo "[integration] machine=$MACHINE openbmc=$OPENBMC_DIR"

# build env 进入 + devtool 子 shell(set +u 关 nounset,仿 ob _devtool_env_exec)
devtool_in_env() {
    (
        cd "$OPENBMC_DIR" || exit 1
        set +u
        # shellcheck disable=SC1091
        source setup "$MACHINE" "$OPENBMC_DIR/build/$MACHINE" >/dev/null 2>&1
        devtool "$@"
    ) 2>/dev/null
}

# 0. 确保 cache fresh(refresh ~37s)
./ob dev --machine "$MACHINE" refresh 2>/dev/null

# 1. list cache(一次取)
CACHE_OUT="$(./ob dev --machine "$MACHINE" list 2>/dev/null)"
lines=$(printf '%s\n' "$CACHE_OUT" | wc -l)
echo "list lines=$lines"
[ "$lines" -gt 0 ] || { echo "FAIL: list empty"; exit 1; }

# 2. invalid recipe → exit 1
./ob dev --machine "$MACHINE" modify nonexistent-recipe-xyz >/dev/null 2>&1
rc=$?
echo "invalid recipe rc=$rc (expect 1)"
[ "$rc" -eq 1 ] || { echo "FAIL: invalid recipe should exit 1"; exit 1; }

# 3. 真实 modify(选 cache 首个 recipe)
RECIPE="$(printf '%s\n' "$CACHE_OUT" | python3 -c 'import json,sys;print(json.loads(sys.stdin.readline())["recipe"])' 2>/dev/null)"
echo "modify recipe=$RECIPE"

# modify 前查 recipe 是否已 modified(只 reset 本测试创建的,避免删用户工作)
PRE_MODIFIED="no"
if devtool_in_env status 2>/dev/null | grep -q "^${RECIPE}: "; then
    PRE_MODIFIED="yes"
fi
echo "pre-modified=$PRE_MODIFIED"

# trap: 测试退出时,只 reset 本测试创建的(pre-modified=no)
cleanup() {
    if [[ "${PRE_MODIFIED:-no}" == "no" && -n "${RECIPE:-}" ]]; then
        devtool_in_env reset "$RECIPE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

SRCTREE="$(./ob dev --machine "$MACHINE" modify "$RECIPE" 2>/dev/null)"
rc=$?
echo "modify rc=$rc srctree=$SRCTREE"
[ "$rc" -eq 0 ] && [ -n "$SRCTREE" ] && [ -d "$SRCTREE" ] || { echo "FAIL: modify/srctree"; exit 1; }

# 4. 显式 reset 验证(清 trap,手动 reset + 检查 rc)
trap - EXIT
if [[ "$PRE_MODIFIED" == "no" ]]; then
    devtool_in_env reset "$RECIPE" >/dev/null 2>&1
    reset_rc=$?
    [ "$reset_rc" -eq 0 ] || { echo "FAIL: devtool reset rc=$reset_rc (recipe $RECIPE 留 modified,手动清理)"; exit 1; }
fi
echo "[integration] OK (modify $RECIPE → srctree → reset)"
