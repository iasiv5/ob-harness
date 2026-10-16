#!/usr/bin/env bash
# tests/unit/build_progress_filter.sh — bitbake_progress_filter 单测 + build_obmc_image 非 tty 进度分支。
# 覆盖: 透传不变 / Running task 与 Tasks Summary、ERROR 抽取进 progress 文件 / 非 tty 分支 rc 经 PIPESTATUS 收敛。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- case 1: 过滤器透传字节不变 + 抽取 task/summary/error 行 ---
PF="$TMP/m1.build.progress"
INPUT="$(printf '%s\n' \
    'NOTE: recipe zlib-1.3-r0: task do_package: Succeeded' \
    'NOTE: Running task 7 of 100 (/x/zlib.bb:do_compile)' \
    'plain passthrough line' \
    'ERROR: Something bad happened' \
    'NOTE: Tasks Summary: Attempted 100 tasks of which 3 didn'"'"'t need to be rerun and all succeeded.')"
printf '%s\n' "$INPUT" | bitbake_progress_filter "$PF" > "$TMP/passthrough.out"
assert_eq "passthrough byte-identical" "$(cat "$TMP/passthrough.out")" "$INPUT"
assert_contains "task line captured" "$(cat "$PF")" "Running task 7 of 100"
assert_contains "summary captured"   "$(cat "$PF")" "Tasks Summary:"
assert_contains "error captured"     "$(cat "$PF")" "ERROR: Something bad happened"
assert_false "non-matching line not captured" grep -q "plain passthrough" "$PF"
assert_true "epoch prefix on capture" grep -Eq '^[0-9]+[[:space:]]' "$PF"

# --- case 2: 空 progress_file 路径护栏由调用方负责; 这里验证重复追加语义(append 不清旧) ---
printf 'NOTE: Running task 8 of 100\n' | bitbake_progress_filter "$PF" >/dev/null
assert_contains "append semantics" "$(cat "$PF")" "Running task 8 of 100"

# --- case 3: build_obmc_image 非 tty 分支(stdout 重定向) → progress 写入 + rc 收敛 ---
DB="$(mktemp -d)"
mkfake_bin "$DB" bitbake
build_env_enter() { :; }
resolve_npm_registry() { :; }
apply_npm_registry() { :; }
CONFIGS_DIR="$TMP/cfg"
mkdir -p "$CONFIGS_DIR"
cat > "$DB/bitbake" <<'STUB'
#!/usr/bin/env bash
echo "stub-bitbake called: $*" >> "${STUB_CALLS:?}"
echo "NOTE: Running task 1 of 9 (stub:do_build)"
exit "${STUB_RC:-0}"
STUB
chmod +x "$DB/bitbake"

STUB_CALLS="$TMP/calls" STUB_RC=0 PATH="$DB:$PATH" build_obmc_image m1 /tmp/build >/dev/null 2>&1
assert_eq "non-tty ok → rc 0" "$?" 0
assert_contains "non-tty progress written" "$(cat "$CONFIGS_DIR/m1.build.progress")" "Running task 1 of 9"
assert_eq "progress file truncated per run (no case-1 residue)" \
    "$(grep -c 'Tasks Summary' "$CONFIGS_DIR/m1.build.progress")" 0

rm -f "$TMP/calls"
STUB_CALLS="$TMP/calls" STUB_RC=1 PATH="$DB:$PATH" build_obmc_image m1 /tmp/build >/dev/null 2>&1
assert_eq "non-tty bitbake fail → rc 1 via PIPESTATUS[0]" "$?" 1
assert_contains "fail run still records dispatch line" \
    "$(cat "$CONFIGS_DIR/m1.build.progress")" "Running task 1 of 9"

assert_summary
