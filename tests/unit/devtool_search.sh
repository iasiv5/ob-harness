#!/usr/bin/env bash
# tests/unit/devtool_search.sh — devtool_search_* + parse_bitbake_recipes 协议单测。
# 覆盖: list/pattern、cache_state 三态(fresh/missing/stale)、refresh(写 JSONL+meta,失败保留旧)、clear、layer schema。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"; export TMP
trap 'rm -rf "$TMP"' EXIT
CONFIGS_DIR="$TMP/workspace/configs"
BUILD_DIR="$TMP/build"
OPENBMC_DIR="$TMP/openbmc"
export CONFIGS_DIR BUILD_DIR OPENBMC_DIR
mkdir -p "$CONFIGS_DIR" "$BUILD_DIR/conf" "$OPENBMC_DIR" "$TMP/bin"
printf 'BBLAYERS mock content\n' > "$BUILD_DIR/conf/bblayers.conf"
touch "$BUILD_DIR/conf/local.conf"

# mock git(cache_state 比对 openbmc commit;refresh 写 meta 时也取它)
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
# 忽略 -C 等参数,固定 commit(git -C <path> rev-parse HEAD → rev-parse 在 $3)
if [[ "$*" == *rev-parse* ]]; then echo "mockcommit123"; exit 0; fi
EOF
chmod +x "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"

MACHINE="testm"
CACHE="$CONFIGS_DIR/$MACHINE.recipes.jsonl"
META="$CONFIGS_DIR/$MACHINE.recipes.meta.json"

write_cache() { printf '%s\n' "$1" > "$CACHE"; }
write_meta() {
    # $1=hash $2=mtime $3=commit [$4=cache_sha $5=count $6=schema_version]
    printf '{"schema_version":"%s","bblayers_hash":"%s","bblayers_mtime":%s,"openbmc_commit":"%s","cache_sha256":"%s","count":%s,"generated_at":"2026-07-14T00:00:00Z"}\n' \
        "${6:-${_DEVTOOL_RECIPES_SCHEMA_VERSION:-1}}" "$1" "$2" "$3" "${4:-}" "${5:-0}" > "$META"
}
cache_sha() { sha256sum "$CACHE" | awk '{print $1}'; }
cache_count() { wc -l < "$CACHE" | tr -d ' '; }
cur_hash() { sha256sum "$BUILD_DIR/conf/bblayers.conf" | awk '{print $1}'; }
cur_mtime() { stat -c %Y "$BUILD_DIR/conf/bblayers.conf"; }

JSONL_FIXTURE='{"recipe":"phosphor-ipmi-host","layer":"meta-phosphor","summary":"IPMI host interface"}
{"recipe":"bmcweb","layer":"meta-phosphor","summary":"BMC web server"}
{"recipe":"phosphor-state-manager","layer":"meta-phosphor","summary":"State manager"}'

# === list + pattern ===
write_cache "$JSONL_FIXTURE"
out="$(devtool_search_list "$MACHINE" "")"
assert_eq "list 无 pattern → 3 行" "$(printf '%s\n' "$out" | grep -c .) " "3 "
out_ipmi="$(devtool_search_list "$MACHINE" "ipmi")"
assert_contains "list pattern ipmi → 含 phosphor-ipmi-host" "$out_ipmi" "phosphor-ipmi-host"
assert_false "list pattern ipmi → 不含 bmcweb" grep -q bmcweb <<<"$out_ipmi"
# schema: 每行合法 JSON + layer 非空
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    layer="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["layer"])' "$line" 2>/dev/null)"
    assert_true "list JSONL layer 非空" test -n "$layer"
done <<<"$out"

# === cache_state 三态 ===
# fresh: meta 匹配当前(含 cache_sha256/count 一致)
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "mockcommit123" "$(cache_sha)" "$(cache_count)"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "cache_state fresh" "$st" "fresh"
# 🔴3: cache 与 meta cache_sha 不一致 → stale(新 cache+旧 meta 场景)
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "mockcommit123" "WRONG_SHA" "$(cache_count)"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "cache_state stale(cache_sha 不匹配 meta)" "$st" "stale"
# 🟡3: schema_version 不匹配 → stale(旧 cache 自动淘汰)
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "mockcommit123" "$(cache_sha)" "$(cache_count)" "0"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "cache_state stale(schema_version 不匹配)" "$st" "stale"
# missing: 删 cache
rm -f "$CACHE"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "cache_state missing(无 cache)" "$st" "missing"
# stale: cache 存在但 meta commit 不匹配
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "WRONG_COMMIT"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "cache_state stale(meta commit 不匹配)" "$st" "stale"
# stale: cache 存在但无 meta
rm -f "$META"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "cache_state stale(无 meta)" "$st" "stale"

# === refresh: mock _devtool_env_exec 写 JSONL,refresh 原子写 cache+meta ===
# 重定义 _devtool_env_exec(返回 fixture JSONL 到 stdout_file)
_devtool_env_exec() {
    local stage_file="$3" stdout_file="$4"
    echo command >"$stage_file"
    printf '%s\n' "$JSONL_FIXTURE" >"$stdout_file"
    return 0
}
rm -f "$CACHE" "$META"
rc=0
devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
assert_eq "refresh rc=0" "$rc" 0
assert_eq "refresh stage=command" "$rstage" "command"
assert_true "refresh stderr_file 存在" test -f "$rstderr"
assert_contains "refresh 写 cache(JSONL)" "$(cat "$CACHE" 2>/dev/null)" "phosphor-ipmi-host"
assert_true "refresh 写 meta" test -f "$META"
# refresh 后 cache_state 应 fresh(meta 匹配当前)
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "refresh 后 cache_state=fresh" "$st" "fresh"

# refresh 失败保留旧 cache
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "mockcommit123"
_devtool_env_exec() { local stage_file="$3"; echo postcondition >"$stage_file"; return 1; }
rc=0
devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
assert_false "refresh 失败 rc!=0" test "$rc" -eq 0
assert_contains "refresh 失败保留旧 cache" "$(cat "$CACHE" 2>/dev/null)" "phosphor-ipmi-host"

# === clear ===
write_cache "$JSONL_FIXTURE"; write_meta "$(cur_hash)" "$(cur_mtime)" "mockcommit123"
devtool_recipes_clear_cache "$MACHINE"
assert_false "clear 删 cache" test -f "$CACHE"
assert_false "clear 删 meta" test -f "$META"
# DRY_RUN 预览不删
write_cache "$JSONL_FIXTURE"; write_meta "$(cur_hash)" "$(cur_mtime)" "mockcommit123"
DRY_RUN=1 devtool_recipes_clear_cache "$MACHINE"
assert_true "clear DRY_RUN 保留 cache" test -f "$CACHE"
assert_true "clear DRY_RUN 保留 meta" test -f "$META"

assert_summary
