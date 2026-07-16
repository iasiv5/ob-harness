#!/usr/bin/env bash
# tests/unit/ob_dev_integration_safety.sh — fault-inject the opt-in devtool integration harness.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_ROOT="$TMP/repo"
FAKE_BIN="$TMP/bin"
FAKE_LOG="$TMP/calls.log"
FAKE_STATE="$TMP/devtool-status"
FAKE_SRCTREE="$TMP/workspace/sources/user-recipe"
export FAKE_LOG FAKE_STATE FAKE_SRCTREE
mkdir -p "$FAKE_ROOT/workspace/openbmc" "$FAKE_ROOT/workspace/configs" "$FAKE_BIN"
touch "$FAKE_ROOT/workspace/configs/testm.init-done"

cat > "$FAKE_ROOT/workspace/openbmc/setup" <<EOF
export PATH="$FAKE_BIN:\$PATH"
EOF
cat > "$FAKE_ROOT/ob" <<'EOF'
#!/usr/bin/env bash
printf 'ob:%s\n' "$*" >>"$FAKE_LOG"
case "${4:-}" in
    refresh) exit 0 ;;
    list)
        [[ "${FAKE_SCENARIO:-}" == "list-fail" ]] && exit 71
        printf '{"recipe":"user-recipe","layer":"meta-test","summary":"test"}\n'
        exit 0
        ;;
    modify)
        [[ "${5:-}" == "nonexistent-recipe-xyz" ]] && exit 1
        if [[ "${FAKE_SCENARIO:-}" == "modify-partial-fail" ]]; then
            printf 'user-recipe: %s\n' "$FAKE_SRCTREE" >"$FAKE_STATE"
            mkdir -p "$FAKE_SRCTREE"
            exit 1
        fi
        if [[ "${FAKE_SCENARIO:-}" == "reset-fail" ]]; then
            printf 'user-recipe: %s\n' "$FAKE_SRCTREE" >"$FAKE_STATE"
            mkdir -p "$FAKE_SRCTREE"
            printf '%s\n' "$FAKE_SRCTREE"
            exit 0
        fi
        exit 1
        ;;
    reset)
        if [[ "${FAKE_SCENARIO:-}" == "reset-fail" ]]; then exit 1; fi
        : > "$FAKE_STATE"
        printf '{"recipe":"%s","srctree":"","srctreebase":"","disposition":"noop","destination_parent":null,"destination":null}\n' "${5:-}"
        exit 0
        ;;
esac
exit 1
EOF
cat > "$FAKE_BIN/devtool" <<'EOF'
#!/usr/bin/env bash
printf 'devtool:%s\n' "$*" >>"$FAKE_LOG"
case "$1" in
    status)
        [[ "${FAKE_SCENARIO:-}" == "status-fail" ]] && exit 42
        cat "$FAKE_STATE"
        ;;
    reset)
        printf 'reset:%s\n' "$2" >>"$FAKE_LOG"
        : >"$FAKE_STATE"
        ;;
esac
EOF
chmod +x "$FAKE_ROOT/ob" "$FAKE_BIN/devtool"

OB_DEV_INTEGRATION_NO_MAIN=1 source "$ROOT/tests/integration/ob_dev.sh"

run_harness() {
    local scenario="$1" err
    err="$(mktemp)"
    RUN_RC=0
    RUN_OUT="$(
        cd "$FAKE_ROOT" &&
        FAKE_SCENARIO="$scenario" \
        OB_DEV_INTEGRATION_ROOT="$FAKE_ROOT" \
        OB_INTEGRATION_MACHINE=testm \
        ob_dev_integration_main
    )" 2>"$err" || RUN_RC=$?
    RUN_ERR="$(cat "$err")"
    rm -f "$err"
}

# A failed status must not turn a known user workspace into an integration cleanup target.
printf 'user-recipe: %s\n' "$FAKE_SRCTREE" >"$FAKE_STATE"
: >"$FAKE_LOG"
run_harness status-fail
assert_eq "status failure fails integration" "$RUN_RC" 1
assert_false "status failure does not call candidate modify" grep -q '^ob:dev --machine testm modify user-recipe$' "$FAKE_LOG"
assert_false "status failure does not reset user recipe" grep -q '^reset:user-recipe$' "$FAKE_LOG"

# A list failure is a real harness failure, not an empty list that gets skipped.
: >"$FAKE_STATE"; : >"$FAKE_LOG"
run_harness list-fail
assert_eq "list failure fails integration" "$RUN_RC" 1
assert_false "list failure does not query devtool status" grep -q '^devtool:status$' "$FAKE_LOG"

# If ob reports failure after devtool has modified the recipe, the EXIT cleanup rechecks and resets it.
: >"$FAKE_STATE"; : >"$FAKE_LOG"
run_harness modify-partial-fail
assert_eq "partial modify failure fails integration" "$RUN_RC" 1
assert_contains "partial modify failure resets recipe" "$(cat "$FAKE_LOG")" "reset:user-recipe"
assert_eq "partial modify cleanup leaves no modified recipe" "$(cat "$FAKE_STATE")" ""

# No viable candidate remains an explicit skip, so the runner can distinguish it from a pass.
printf 'user-recipe: %s\n' "$FAKE_SRCTREE" >"$FAKE_STATE"
: >"$FAKE_LOG"
run_harness normal
assert_eq "all sampled recipes modified is a skip" "$RUN_RC" 77
assert_contains "skip outcome is explicit" "$RUN_OUT" "SKIP: no safe candidate"
assert_true "skip outcome matches runner protocol" grep -q '^SKIP: ' <<<"$RUN_OUT"

# reset 段失败(reset-fail) → integration exit 1, trap cleanup 仍按 ADR-0008 权威 status recheck 清 modified recipe
: >"$FAKE_STATE"; : >"$FAKE_LOG"
run_harness reset-fail
assert_eq "reset failure fails integration" "$RUN_RC" 1
assert_contains "reset failure cleanup resets recipe(ADR-0008 recheck)" "$(cat "$FAKE_LOG")" "reset:user-recipe"
assert_eq "reset failure cleanup leaves no modified recipe" "$(cat "$FAKE_STATE")" ""

# 候选已有孤儿 appends/<recipe>(status 不含但 appends 存在) → 跳过该候选 → SKIP 77(不选用户遗留)
: >"$FAKE_STATE"; : >"$FAKE_LOG"
mkdir -p "$FAKE_ROOT/workspace/openbmc/build/testm/workspace/appends/user-recipe"
run_harness orphan-appends
assert_eq "orphan appends → SKIP 77(不选用户遗留)" "$RUN_RC" 77
assert_false "orphan appends 不调 candidate modify(user-recipe)" grep -q '^ob:dev --machine testm modify user-recipe$' "$FAKE_LOG"
rm -rf "$FAKE_ROOT/workspace/openbmc/build/testm/workspace/appends"

# 继承的 EXTERNAL_SRCTREE 不被 cleanup 误删(入口清空 + canonical 校验双重保险)
_victim="$(mktemp -d)"; echo precious > "$_victim/file"
: >"$FAKE_STATE"; : >"$FAKE_LOG"
EXTERNAL_SRCTREE="$_victim" run_harness reset-fail
assert_eq "继承 EXTERNAL_SRCTREE + reset-fail: integration exit 1" "$RUN_RC" 1
assert_true "继承的 EXTERNAL_SRCTREE 未被 cleanup 误删" test -f "$_victim/file"
rm -rf "$_victim"

assert_summary
