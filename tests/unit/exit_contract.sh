#!/usr/bin/env bash
# tests/unit/exit_contract.sh — exit_contract.py 逻辑自测(unit 层)。
# 通过子进程跑 Python 扫描器(不 source ob 函数),用 fixture 钉死真·bash-exit
# 判定的假阳排除(sys.exit/awk/散文/exited 子串)与真阳捕获(exit 4/§2 误 exit/
# 空 remedy)。fixture 严格镜像 ob 行规:一行一语句、闭合 } 独占行(Z(b) 的「前置行」
# 模型与 extract_funcs 的 ^} 定界都依赖此)。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXIT_CONTRACT="$DIR/tools/exit_contract.py"
OB="$DIR/ob"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. 假阳排除 (rc 0): sys.exit / awk exit / 散文 exit / exited 子串 都不当真 exit ---
cat >"$TMP/fp.sh" <<'EOF'
fp() {
    python3 - "$x" <<'PY'
import sys
sys.exit(1)
PY
    awk "BEGIN { exit !(1 < 2) }"
    echo "Ctrl+] to exit socat session"
    warn "ssh-keygen -R exited ${rc}"
    return 1
    exit 1
}
EOF
assert_rc 0 "false-positive exits (sys.exit/awk/prose/exited) not counted" \
    python3 "$EXIT_CONTRACT" "$TMP/fp.sh"

# --- 2. X 真阳 (rc 1): 非法字面 exit 4 ---
cat >"$TMP/x.sh" <<'EOF'
bad() {
    exit 4
}
EOF
assert_rc 1 "exit 4 caught (X)" python3 "$EXIT_CONTRACT" "$TMP/x.sh"

# --- 3. Y 真阳 (rc 1): util.sh 函数 exit 但不在 EXIT_EXCEPTIONS (Y-c basename) ---
mkdir -p "$TMP/lib"
cat >"$TMP/lib/util.sh" <<'EOF'
#!/usr/bin/env bash
myhelper() {
    exit 1
}
EOF
: >"$TMP/ob"   # 空入口桩
assert_rc 1 "util.sh unexpected exit caught (Y-c basename)" \
    python3 "$EXIT_CONTRACT" "$TMP/ob" "$TMP/lib/util.sh"

# --- 4. Y 真阳 (rc 1): machine_state.sh 函数不得 exit ---
cat >"$TMP/lib/machine_state.sh" <<'EOF'
#!/usr/bin/env bash
machine_state_helper() {
    exit 1
}
EOF
out="$(python3 "$EXIT_CONTRACT" "$TMP/ob" "$TMP/lib/machine_state.sh" 2>&1)"; rc=$?
assert_eq "machine_state.sh unexpected exit caught (Y-c basename rc)" "$rc" "1"
assert_contains "machine_state.sh unexpected exit mentions basename" "$out" "machine_state.sh"
assert_contains "machine_state.sh unexpected exit mentions function" "$out" "machine_state_helper"

# --- 5. Z 空 remedy 真阳 (rc 1): require_path 第 3 入参空 ---
cat >"$TMP/z1.sh" <<'EOF'
r() {
    require_path /x lab "" 3
}
EOF
assert_rc 1 "empty require_path remedy caught (Z)" python3 "$EXIT_CONTRACT" "$TMP/z1.sh"

# --- 6. Z 有 remedy 假阳 (rc 0): direct exit-3 前有 forward remedy ---
cat >"$TMP/z2.sh" <<'EOF'
d() {
    error "Run 'ob init' first."
    exit 3
}
EOF
assert_rc 0 "direct exit-3 with remedy OK (Z)" python3 "$EXIT_CONTRACT" "$TMP/z2.sh"

# --- 7. Z 诊断-only (rc 0 + WARN): direct exit-3 前是回溯诊断行 ---
cat >"$TMP/z3.sh" <<'EOF'
e() {
    error "Invalid URL from env"
    exit 3
}
EOF
out="$(python3 "$EXIT_CONTRACT" "$TMP/z3.sh" 2>&1)"; rc=$?
assert_eq "diagnostic-only exit-3 warns not fails (rc)" "$rc" "0"
assert_contains "warns on diagnostic-only exit-3" "$out" "WARN"

# --- 8. ob 裁决可观察: X/Y/Z 三裁决行都在 (Task 6/7 前 Z 可能 FAIL/WARN,只断言行可观察) ---
out="$(python3 "$EXIT_CONTRACT" "$OB" 2>&1)"
assert_contains "ob prints X verdict" "$out" "X:"
assert_contains "ob prints Y verdict" "$out" "Y:"
assert_contains "ob prints Z verdict" "$out" "Z:"

assert_summary
