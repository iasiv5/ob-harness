#!/usr/bin/env bash
# tests/unit/devtool_build.sh — devtool_build_run 单测(unit 层)。
# 覆盖: status-first(recipe 未 modified → not_modified 信号, 不 build; status 失败 → 回传 stage+rc, 不继续 build)
#       → recipe 已 modified → devtool build。镜像 devtool_modify_run status-first 结构。
# 🔴2 回归锁: status 失败必须走 stage+rc 路径(not_modified=""), 不得误报 not_modified=1(否则 cmd_dev exit 3 而非 1)。
# leaf-pure: 失败路径 return rc(非 exit)——单测能跑到 assert_summary 即证明; exit_contract Y 静态保证(devtool_build.sh 在 LEAF 表)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT

# === mock build env ===
OPENBMC_DIR="$TMP/openbmc"
BUILD_DIR="$TMP/build"
export OPENBMC_DIR BUILD_DIR
MOCK_DEVTOOL_STATE="$TMP/devtool_state"
MOCK_BUILD_LOG="$TMP/build_log"
export MOCK_DEVTOOL_STATE MOCK_BUILD_LOG
mkdir -p "$OPENBMC_DIR" "$BUILD_DIR/conf" "$TMP/bin" "$TMP/workspace/sources"
: > "$MOCK_DEVTOOL_STATE"
: > "$MOCK_BUILD_LOG"

cat > "$OPENBMC_DIR/setup" <<'EOF'
#!/usr/bin/env bash
export SETUP_DONE=1
echo "MOCK_SETUP_NOISE_TO_STDOUT"
EOF
chmod +x "$OPENBMC_DIR/setup"

# mock devtool: status 输出 state; build 记录调用(MOCK_BUILD_LOG 行数=调用次数) + exit MOCK_BUILD_RC
cat > "$TMP/bin/devtool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status)
    [[ -f "$MOCK_DEVTOOL_STATE" ]] && cat "$MOCK_DEVTOOL_STATE"
    exit "${MOCK_STATUS_RC:-0}"
    ;;
  build)
    printf '%s\n' "$2" >> "$MOCK_BUILD_LOG"
    exit "${MOCK_BUILD_RC:-0}"
    ;;
esac
EOF
chmod +x "$TMP/bin/devtool"

printf '#!/usr/bin/env bash\necho mock-bitbake-layers\n' > "$TMP/bin/bitbake-layers"
chmod +x "$TMP/bin/bitbake-layers"
export PATH="$TMP/bin:$PATH"

MACHINE="testm"
touch "$BUILD_DIR/conf/local.conf" "$BUILD_DIR/conf/bblayers.conf"
RECIPE="phosphor-ipmi-host"

# === ① recipe 未 modified(status 无该行) → not_modified=1, build 未调, stage=command, rc=0 ===
: > "$MOCK_DEVTOOL_STATE"; : > "$MOCK_BUILD_LOG"
stage_var=""; stderr_var=""; notmod_var=""; rc=0
devtool_build_run "$MACHINE" "$BUILD_DIR" "$RECIPE" stage_var stderr_var notmod_var || rc=$?
assert_eq "① 未 modified: rc=0" "$rc" "0"
assert_eq "① 未 modified: not_modified=1" "$notmod_var" "1"
assert_eq "① 未 modified: stage=command" "$stage_var" "command"
assert_eq "① 未 modified: build 未被调" "$(wc -l < "$MOCK_BUILD_LOG")" "0"
assert_true "① 未 modified: stderr_file 存在(交 caller cat+rm)" test -f "$stderr_var"

# === ② recipe 已 modified → build 被调一次, not_modified="", stage=command, rc=0 ===
printf '%s: %s\n' "$RECIPE" "$TMP/workspace/sources/$RECIPE" > "$MOCK_DEVTOOL_STATE"
: > "$MOCK_BUILD_LOG"
stage_var=""; stderr_var=""; notmod_var=""; rc=0
devtool_build_run "$MACHINE" "$BUILD_DIR" "$RECIPE" stage_var stderr_var notmod_var || rc=$?
assert_eq "② 已 modified: rc=0" "$rc" "0"
assert_eq "② 已 modified: not_modified 空" "$notmod_var" ""
assert_eq "② 已 modified: stage=command" "$stage_var" "command"
assert_eq "② 已 modified: build 调一次" "$(wc -l < "$MOCK_BUILD_LOG")" "1"
assert_eq "② 已 modified: build 收到 recipe" "$(cat "$MOCK_BUILD_LOG")" "$RECIPE"

# === ③ status 失败(MOCK_STATUS_RC=1, devtool status 命令 exit 1) → not_modified="" + stage=command + rc≠0, build 未调(🔴2 核心) ===
# 注: stage=command 非 setup——_devtool_env_exec 在 "$@"(devtool status) 失败前已 echo command; setup 是 source setup 失败才触发。
# 🔴2 锁的是"status 失败不 fall-through 跑 build、不误报 not_modified=1", 非 stage 具体值。
: > "$MOCK_DEVTOOL_STATE"; : > "$MOCK_BUILD_LOG"
export MOCK_STATUS_RC=1
stage_var=""; stderr_var=""; notmod_var="MUST_STAY_EMPTY"; rc=0
devtool_build_run "$MACHINE" "$BUILD_DIR" "$RECIPE" stage_var stderr_var notmod_var 2>/dev/null || rc=$?
unset MOCK_STATUS_RC
assert_false "③ status 失败: rc≠0" test "$rc" -eq 0
assert_eq "③ status 失败: not_modified 空(非 1, 🔴2 回归锁)" "$notmod_var" ""
assert_eq "③ status 失败: stage=command(非空, 回传给 relay)" "$stage_var" "command"
assert_eq "③ status 失败: build 未被调(不 fall-through)" "$(wc -l < "$MOCK_BUILD_LOG")" "0"

# === ④ build 失败(MOCK_BUILD_RC=1, status 成功 + recipe modified) → not_modified="", stage=command, rc=1 ===
printf '%s: %s\n' "$RECIPE" "$TMP/workspace/sources/$RECIPE" > "$MOCK_DEVTOOL_STATE"
: > "$MOCK_BUILD_LOG"
export MOCK_BUILD_RC=1
stage_var=""; stderr_var=""; notmod_var=""; rc=0
devtool_build_run "$MACHINE" "$BUILD_DIR" "$RECIPE" stage_var stderr_var notmod_var 2>/dev/null || rc=$?
unset MOCK_BUILD_RC
assert_eq "④ build 失败: rc=1" "$rc" "1"
assert_eq "④ build 失败: not_modified 空" "$notmod_var" ""
assert_eq "④ build 失败: stage=command" "$stage_var" "command"
assert_eq "④ build 失败: build 调一次" "$(wc -l < "$MOCK_BUILD_LOG")" "1"

# leaf-pure: ③/④ 用 || rc=$? 捕获失败 return rc, 单测能跑到此即证明函数 return(非 exit); exit_contract Y 静态守卫。
assert_summary
