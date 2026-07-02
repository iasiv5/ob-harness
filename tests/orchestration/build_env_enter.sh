#!/usr/bin/env bash
# tests/orchestration/build_env_enter.sh — build_env_enter 行为测试(orchestration 层)。
# 假 setup stub 验证 current-shell build environment 进入原语的副作用契约:
#   1. build_env_enter 先 cd 到 OPENBMC_DIR(stub 入口断言 PWD)
#   2. cwd 漂移到 build_dir(模拟 setup 的 oe-init-build-env 行为)
#   3. source setup 真执行(标记变量)
#   4. nounset 状态被 save/restore
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OB="$ROOT/ob"

TMP="$(mktemp -d)"
FAKE_OPENBMC="$TMP/openbmc"
BUILD_DIR="$FAKE_OPENBMC/build/romulus"
mkdir -p "$FAKE_OPENBMC"
# 假 setup: 先断言 source 时 PWD==OPENBMC_DIR(锁 build_env_enter 的 cd 契约),
# 再模拟 setup 的 mkdir build_dir + cd build_dir + 标记.
# 单靠 PATH 命中 stub 不够: bash 从 PATH 找 setup 不依赖 cwd(cd / && PATH=<fake>
# source setup 也命中), 必须在 stub 里断言 PWD 才能锁住 cd 契约.
cat > "$FAKE_OPENBMC/setup" <<'SETUP'
#!/usr/bin/env bash
[[ "$PWD" == "$__EXPECTED_OPENBMC" ]] || { echo "WRONG_PWD=$PWD"; return 7; }
__FAKE_SETUP_SOURCED=1
mkdir -p "$2"
cd "$2"
SETUP
chmod +x "$FAKE_OPENBMC/setup"

out=$(PATH="$FAKE_OPENBMC:$PATH" __EXPECTED_OPENBMC="$FAKE_OPENBMC" bash -c '
set -uo pipefail
OB_NO_MAIN=1 source "$1"
OPENBMC_DIR="$2"
build_env_enter romulus "$3"
echo "CWD=$PWD"
echo "MARKER=${__FAKE_SETUP_SOURCED:-0}"
case $- in *u*) echo "NOUNSET=1";; *) echo "NOUNSET=0";; esac
' _ "$OB" "$FAKE_OPENBMC" "$BUILD_DIR" 2>&1)

assert_contains "enter cds into build dir"     "$out" "CWD=$BUILD_DIR"
assert_contains "enter actually sourced setup" "$out" "MARKER=1"
assert_contains "enter restores nounset"       "$out" "NOUNSET=1"
if grep -q "WRONG_PWD" <<<"$out"; then
    _assert_bad "enter cds to OPENBMC_DIR first ($out)"
else
    _assert_ok "enter cds to OPENBMC_DIR first"
fi
rm -rf "$TMP"

assert_summary
