#!/usr/bin/env bash
# tests/orchestration/cmd_build_bitbake_handoff.sh — cmd_build→bitbake handoff 测试。
# build_env_enter 收口改了 cmd_build 的 source 段, 此测试锁住非 dry-run 路径仍正确
# handoff 到 bitbake, 且 bitbake 失败时 cmd_build exit 1 兜底(快速集覆盖, 免 integration).
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OB="$ROOT/ob"

TMP="$(mktemp -d)"
OPENBMC_DIR="$TMP/openbmc"
CONFIGS_DIR="$TMP/configs"
MACHINE="romulus"
BUILD_DIR="$OPENBMC_DIR/build/$MACHINE"
mkdir -p "$OPENBMC_DIR/.git" "$CONFIGS_DIR" "$BUILD_DIR"

# fake 前置: require_path(OPENBMC_DIR/.git + source manifest) + machine_state_is_initialized(init-done)
touch "$CONFIGS_DIR/openbmc-source.manifest"
touch "$CONFIGS_DIR/$MACHINE.init-done"

# fake setup(build_env_enter source 它): 模拟 setup 的 mkdir build_dir + cd build_dir
cat > "$OPENBMC_DIR/setup" <<'SETUP'
#!/usr/bin/env bash
mkdir -p "$2"
cd "$2"
SETUP
chmod +x "$OPENBMC_DIR/setup"

DB="$(mktemp -d)"
mkfake_bin "$DB" bitbake

run_cmd_build() {  # 在子 shell 跑 cmd_build, 返回其 rc
    PATH="$OPENBMC_DIR:$DB:$PATH" OB_NPM_REGISTRY= \
        bash -c '
set -uo pipefail
OB_NO_MAIN=1 source "$1"
OPENBMC_DIR="$2"; CONFIGS_DIR="$3"; SOURCE_MANIFEST_FILE="$3/openbmc-source.manifest"
MACHINE="$4"; BUILD_DIR="$5"; DRY_RUN=0
cmd_build
' _ "$OB" "$OPENBMC_DIR" "$CONFIGS_DIR" "$MACHINE" "$BUILD_DIR" >/tmp/cmd_build.out 2>&1
}

# 1. bitbake 成功(默认 exit 0) → cmd_build 正常结束, bitbake 被调恰好一次
rm -f "$DB/.bitbake.calls"
run_cmd_build; rc=$?
calls=$(wc -l < "$DB/.bitbake.calls" 2>/dev/null || echo 0)
assert_eq "cmd_build rc (bitbake ok)"  "$rc"    0
assert_eq "bitbake called once (ok)"   "$calls" 1

# 2. bitbake 失败 → cmd_build exit 1 兜底, bitbake 仍被调一次
stub_exit "$DB" bitbake 1
rm -f "$DB/.bitbake.calls"
run_cmd_build; rc=$?
calls=$(wc -l < "$DB/.bitbake.calls" 2>/dev/null || echo 0)
assert_eq "cmd_build rc (bitbake fail)" "$rc"    1
assert_eq "bitbake called once (fail)"  "$calls" 1

rm -rf "$TMP" "$DB"
assert_summary
