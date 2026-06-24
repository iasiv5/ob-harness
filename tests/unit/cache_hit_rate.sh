#!/usr/bin/env bash
# tests/unit/cache_hit_rate.sh — cache_hit_rate.py 逻辑自测(unit 层)。
# 用 fixture jsonl 钉死 usage 聚合与命中率口径(cache_read/(input+creation+cache_read)),
# 含主路径(session/TOTAL/buckets 数字)/错误路径(rc 1)/--recent 限流。
# fixture 镜像 Claude Code transcript 的 message.usage 结构。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$DIR/tools/cache_hit_rate.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# long.jsonl: 101 行高命中 (n=101 -> hot bucket; input=1010, cache_read=99990 -> rate 99.0%)
: > "$TMP/long.jsonl"
for _ in $(seq 1 101); do
  printf '%s\n' '{"message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":990,"output_tokens":5}}}' >> "$TMP/long.jsonl"
done

# short.jsonl: 1 行低命中 (n=1 -> cold bucket; input=400, cache_read=100 -> rate 20.0%)
cat > "$TMP/short.jsonl" <<'EOF'
{"message":{"usage":{"input_tokens":400,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":50}}}
EOF

# --- 1. 主路径: 聚合正确, TOTAL = (100090 cache_read / 101500 total) = 98.6% ---
out="$(python3 "$TOOL" "$TMP" 2>&1)"; rc=$?
assert_eq "main path rc 0" "$rc" "0"
assert_contains "long session rate 99.0%" "$out" "99.0%"
assert_contains "short session rate 20.0%" "$out" "20.0%"
assert_contains "TOTAL rate 98.6%" "$out" "98.6%"
assert_contains "prints TOTAL row" "$out" "TOTAL"
assert_contains "prints buckets section" "$out" "buckets"
assert_contains "cold bucket present" "$out" "cold"
assert_contains "hot bucket present" "$out" "hot"

# --- 2. 错误路径: 不存在目录 rc 1 ---
assert_rc 1 "nonexistent dir rc 1" python3 "$TOOL" "$TMP/nope_dir"

# --- 3. --recent 1: 字母序 long<short, files[-1]=short, 排除 long ---
out="$(python3 "$TOOL" "$TMP" --recent 1 2>&1)"; rc=$?
assert_eq "--recent 1 rc 0" "$rc" "0"
assert_contains "--recent 1 keeps short" "$out" "20.0%"
assert_true "--recent 1 excludes long (99.0% absent)" test -z "$(printf '%s' "$out" | grep '99.0%')"

assert_summary
