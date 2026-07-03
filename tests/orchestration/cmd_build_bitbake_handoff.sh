#!/usr/bin/env bash
# tests/orchestration/cmd_build_bitbake_handoff.sh — cmd_build→bitbake handoff 测试。
# build_env_enter 收口改了 cmd_build 的 source 段, 此测试锁住非 dry-run 路径的 handoff
# 契约: (1) 调 bitbake 恰好一次 (2) target=obmc-phosphor-image (3) cwd=BUILD_DIR
# (build_env_enter source setup 后已漂移) (4) bitbake 失败时 cmd_build exit 1 兜底.
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

run_cmd_build() {  # 在子 shell 跑 cmd_build, 返回其 rc; 输出到本 case 专属 $TMP/cmd_build.out
    PATH="$OPENBMC_DIR:$DB:$PATH" OB_NPM_REGISTRY= \
        bash -c '
set -uo pipefail
OB_NO_MAIN=1 source "$1"
OPENBMC_DIR="$2"; CONFIGS_DIR="$3"; SOURCE_MANIFEST_FILE="$3/openbmc-source.manifest"
MACHINE="$4"; BUILD_DIR="$5"; DRY_RUN=0
cmd_build
' _ "$OB" "$OPENBMC_DIR" "$CONFIGS_DIR" "$MACHINE" "$BUILD_DIR" >"$TMP/cmd_build.out" 2>&1
}

# 成功路径(默认 exit 0): 锁 calls=1 + target + cwd + rc
stub_script "$DB" bitbake "pwd > '$DB/.bitbake.pwd'"
rm -f "$DB/.bitbake.calls"
run_cmd_build; rc=$?
assert_eq "cmd_build rc (bitbake ok)"   "$rc"     0
assert_eq "bitbake called once (ok)"    "$(wc -l < "$DB/.bitbake.calls" 2>/dev/null || echo 0)" 1
assert_eq "bitbake target (ok)"         "$(cat "$DB/.bitbake.calls")"  "obmc-phosphor-image"
assert_eq "bitbake runs from build dir" "$(cat "$DB/.bitbake.pwd")"    "$BUILD_DIR"

# 失败路径(stub_exit 1): 锁 calls=1 + target + exit 1 兜底
stub_exit "$DB" bitbake 1
rm -f "$DB/.bitbake.calls"
run_cmd_build; rc=$?
assert_eq "cmd_build rc (bitbake fail)" "$rc"     1
assert_eq "bitbake called once (fail)"  "$(wc -l < "$DB/.bitbake.calls" 2>/dev/null || echo 0)" 1
assert_eq "bitbake target (fail)"       "$(cat "$DB/.bitbake.calls")"  "obmc-phosphor-image"

rm -rf "$TMP" "$DB"
assert_summary
