#!/usr/bin/env bash
# tests/unit/cache_hit_rate.sh — cache_hit_rate.py 逻辑自测(unit 层)。
# 用 fixture jsonl 钉死 usage 聚合与命中率口径(缓存命中 ÷ 总输入),
# 含主路径(摘要卡片/明细/合计/buckets 数字 + 中文单位)/错误路径(rc 1)/--recent。
# fixture 镜像 Claude Code transcript 的 message.usage 结构。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$DIR/tools/cache_hit_rate.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# long.jsonl: 101 行高命中 (n=101 -> hot bucket; 总输入 101000, 缓存命中 99990 -> 99.0%)
: > "$TMP/long.jsonl"
for _ in $(seq 1 101); do
  printf '%s\n' '{"message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":990,"output_tokens":5}}}' >> "$TMP/long.jsonl"
done

# short.jsonl: 1 行低命中 (n=1 -> cold bucket; 总输入 500, 缓存命中 100 -> 20.0%)
cat > "$TMP/short.jsonl" <<'EOF'
{"message":{"usage":{"input_tokens":400,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":50}}}
EOF

# --- 1. 主路径: 合计命中率 = 100090/101500 = 98.6% ---
out="$(python3 "$TOOL" "$TMP" 2>&1)"; rc=$?
assert_eq "main path rc 0" "$rc" "0"
assert_contains "long session 命中率 99.0%" "$out" "99.0%"
assert_contains "short session 命中率 20.0%" "$out" "20.0%"
assert_contains "合计命中率 98.6%" "$out" "98.6%"
assert_contains "摘要含 总输入" "$out" "总输入"
assert_contains "摘要含 缓存命中" "$out" "缓存命中"
assert_contains "摘要含 总输出 (输入/输出区分)" "$out" "总输出"
assert_contains "含单位 Tokens" "$out" "Tokens"
assert_contains "含中文单位 亿或万" "$out" "万"
assert_contains "cold bucket" "$out" "cold"
assert_contains "hot bucket" "$out" "hot"
assert_contains "飞轮证据 section" "$out" "飞轮"
assert_contains "明细表含输出列 (long 输出 505)" "$out" "505"
assert_contains "摘要缓存写入行说明 GLM 口径(并入)" "$out" "并入"

# --- 2. 错误路径: 不存在目录 rc 1 ---
assert_rc 1 "nonexistent dir rc 1" python3 "$TOOL" "$TMP/nope_dir"

# --- 3. --recent 1: 字母序 long<short, files[-1]=short, 排除 long ---
out="$(python3 "$TOOL" "$TMP" --recent 1 2>&1)"; rc=$?
assert_eq "--recent 1 rc 0" "$rc" "0"
assert_contains "--recent 1 保留 short" "$out" "20.0%"
assert_true "--recent 1 排除 long (99.0% 不出现)" test -z "$(printf '%s' "$out" | grep '99.0%')"

assert_summary
