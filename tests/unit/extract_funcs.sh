#!/usr/bin/env bash
# tests/unit/extract_funcs.sh — extract_funcs.py 三段纯函数定义检查。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXTRACT_FUNCS="$DIR/tools/extract_funcs.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/lib"

cat >"$TMP/lib/clean.sh" <<'EOF'
#!/usr/bin/env bash
# clean lib fixture
foo() { :; }
bar() { :; }
EOF
assert_rc 0 "clean lib fixture passes" python3 "$EXTRACT_FUNCS" "$TMP/lib/clean.sh"

cat >"$TMP/lib/header.sh" <<'EOF'
#!/usr/bin/env bash
echo "header side effect"
foo() { :; }
EOF
out="$(python3 "$EXTRACT_FUNCS" "$TMP/lib/header.sh" 2>&1)"; rc=$?
assert_eq "header top-level rc" "$rc" "1"
assert_contains "header top-level reported" "$out" "HEADER_TOPLEVEL"

cat >"$TMP/lib/gap.sh" <<'EOF'
#!/usr/bin/env bash
foo() { :; }
echo "gap side effect"
bar() { :; }
EOF
out="$(python3 "$EXTRACT_FUNCS" "$TMP/lib/gap.sh" 2>&1)"; rc=$?
assert_eq "gap top-level rc" "$rc" "1"
assert_contains "gap top-level reported" "$out" "GAP foo -> bar"

cat >"$TMP/lib/footer.sh" <<'EOF'
#!/usr/bin/env bash
foo() { :; }
echo "footer side effect"
EOF
out="$(python3 "$EXTRACT_FUNCS" "$TMP/lib/footer.sh" 2>&1)"; rc=$?
assert_eq "footer top-level rc" "$rc" "1"
assert_contains "footer top-level reported" "$out" "FOOTER_TOPLEVEL"

assert_summary