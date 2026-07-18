#!/usr/bin/env bash
# tests/protocol/test_runner_contract.sh — run_all argument and shell-test skip contracts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/lib/assert.sh"
assert_reset

assert_true "integration harness passes ShellCheck" shellcheck "$ROOT/tests/integration/ob_dev.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tests/protocol" "$TMP/tests/unit" "$TMP/tests/orchestration" "$TMP/tests/integration"
cp "$ROOT/tests/run_all.sh" "$TMP/tests/run_all.sh"

cat > "$TMP/tests/protocol/ordinary_diagnostic.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok before"
echo "skip note: ordinary diagnostic"
echo "ok after"
EOF
cat > "$TMP/tests/unit/intentional_skip.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP: intentional fixture"
exit 77
EOF
chmod +x "$TMP/tests/protocol/ordinary_diagnostic.sh" "$TMP/tests/unit/intentional_skip.sh"

runner_rc=0
runner_output="$(bash "$TMP/tests/run_all.sh" --integration 2>&1)" || runner_rc=$?
assert_eq "runner accepts explicit skip exit code" "$runner_rc" 0
assert_contains "ordinary diagnostic output is retained" "$runner_output" "ok before"
assert_contains "ordinary diagnostic remains a pass" "$runner_output" "ok   ordinary_diagnostic.sh"
assert_contains "explicit skip marker is shown" "$runner_output" "SKIP: intentional fixture"
assert_contains "explicit skip is classified separately" "$runner_output" "skip intentional_skip.sh"
assert_false "explicit skip is not reported as pass" grep -q "ok   intentional_skip.sh" <<<"$runner_output"

cat > "$TMP/tests/orchestration/malformed_skip.sh" <<'EOF'
#!/usr/bin/env bash
echo "missing skip marker"
exit 77
EOF
chmod +x "$TMP/tests/orchestration/malformed_skip.sh"
runner_rc=0
runner_output="$(bash "$TMP/tests/run_all.sh" --integration 2>&1)" || runner_rc=$?
assert_eq "exit 77 without marker fails runner" "$runner_rc" 1
assert_contains "missing skip marker diagnosis" "$runner_output" "rc=77 without SKIP: protocol marker"
rm -f "$TMP/tests/orchestration/malformed_skip.sh"

mkdir -p "$TMP/bin"
EXPECT_LOG="$TMP/expect.log"
export EXPECT_LOG
cat > "$TMP/bin/expect" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$EXPECT_LOG"
EOF
cat > "$TMP/tests/protocol/full_only.exp" <<'EOF'
#!/usr/bin/env expect
exit 0
EOF
cat > "$TMP/tests/integration/combined_flags.sh" <<'EOF'
#!/usr/bin/env bash
echo "combined flags integration"
EOF
chmod +x "$TMP/bin/expect" "$TMP/tests/integration/combined_flags.sh"
runner_rc=0
runner_output="$(PATH="$TMP/bin:$PATH" bash "$TMP/tests/run_all.sh" --full --integration 2>&1)" || runner_rc=$?
assert_eq "--full --integration enables both layers" "$runner_rc" 0
assert_contains "--full runs expect tests" "$(cat "$EXPECT_LOG")" "full_only.exp"
assert_contains "--integration runs integration shell tests" "$runner_output" "ok   combined_flags.sh"

unknown_rc=0
unknown_output="$(bash "$TMP/tests/run_all.sh" --integraton 2>&1)" || unknown_rc=$?
assert_eq "unknown runner argument exits 1" "$unknown_rc" 1
assert_contains "unknown runner argument shows usage" "$unknown_output" "Usage: tests/run_all.sh"

assert_summary
