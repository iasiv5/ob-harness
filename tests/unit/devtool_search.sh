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

MOCK_COMMIT="0123456789abcdef0123456789abcdef01234567"
export MOCK_COMMIT

# mock git(cache_state 比对 openbmc commit;refresh 写 meta 时也取它)
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
# 忽略 -C 等参数,固定 commit(git -C <path> rev-parse HEAD → rev-parse 在 $3)
if [[ "$*" == *rev-parse* ]]; then
    [[ "${FAKE_GIT_FAIL:-0}" == "1" ]] && exit 1
    printf '%s\n' "$MOCK_COMMIT"
    exit 0
fi
exit 1
EOF
chmod +x "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"

MACHINE="testm"
CACHE="$CONFIGS_DIR/$MACHINE.recipes.jsonl"
META="$CONFIGS_DIR/$MACHINE.recipes.meta.json"
TEST_BBLAYERS="$BUILD_DIR/conf/bblayers.conf"
export TEST_CACHE="$CACHE" TEST_META="$META" TEST_BBLAYERS TEST_CONFIGS_DIR="$CONFIGS_DIR" TEST_MACHINE="$MACHINE"

# Fault-injection wrappers for the publication transaction. Disabled unless the
# corresponding exported flag is set by a test below.
cat > "$TMP/bin/cp" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_CP_FAIL_BACKUP:-0}" == "1" && "$1" == "$TEST_CACHE" ]]; then
    exit 1
fi
PATH=/usr/bin:/bin exec cp "$@"
EOF
cat > "$TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_MV_FAIL_CACHE_PUBLISH:-0}" == "1" && "$1" == "$TEST_CACHE".* && "$2" == "$TEST_CACHE" ]]; then
    exit 1
fi
if [[ "${FAKE_MV_FAIL_META_RESTORE:-0}" == "1" && "$1" == "$TEST_CONFIGS_DIR/.${TEST_MACHINE}.recipes.meta.backup."* && "$2" == "$TEST_META" ]]; then
    exit 1
fi
PATH=/usr/bin:/bin exec mv "$@"
EOF
cat > "$TMP/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_BBLAYERS_SHA_FAIL:-0}" == "1" && "$1" == "$TEST_BBLAYERS" ]]; then
    exit 1
fi
if [[ "${FAKE_CACHE_SHA_FAIL:-0}" == "1" && ( "$1" == "$TEST_CACHE" || "$1" == "$TEST_CACHE".* ) ]]; then
    exit 1
fi
PATH=/usr/bin:/bin exec sha256sum "$@"
EOF
cat > "$TMP/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_STAT_FAIL:-0}" == "1" && "$*" == *"$TEST_BBLAYERS"* ]]; then
    exit 1
fi
PATH=/usr/bin:/bin exec stat "$@"
EOF
cat > "$TMP/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_MKTEMP_FAIL_AT:-}" ]]; then
    call_count=0
    [[ -f "$FAKE_MKTEMP_COUNT_FILE" ]] && call_count="$(cat "$FAKE_MKTEMP_COUNT_FILE")"
    call_count=$((call_count + 1))
    printf '%s\n' "$call_count" >"$FAKE_MKTEMP_COUNT_FILE"
    [[ "$call_count" == "$FAKE_MKTEMP_FAIL_AT" ]] && exit 1
fi
PATH=/usr/bin:/bin exec mktemp "$@"
EOF
chmod +x "$TMP/bin/cp" "$TMP/bin/mv" "$TMP/bin/sha256sum" "$TMP/bin/stat" "$TMP/bin/mktemp"

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
REFRESH_JSONL="$JSONL_FIXTURE"

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
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$(cache_sha)" "$(cache_count)"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "cache_state fresh" "$st" "fresh"
# 🔴3: cache 与 meta cache_sha 不一致 → stale(新 cache+旧 meta 场景)
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "WRONG_SHA" "$(cache_count)"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "cache_state stale(cache_sha 不匹配 meta)" "$st" "stale"
# 🟡3: schema_version 不匹配 → stale(旧 cache 自动淘汰)
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$(cache_sha)" "$(cache_count)" "0"
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
    printf '%s\n' "$REFRESH_JSONL" >"$stdout_file"
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
assert_eq "refresh meta count uses valid records" \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["count"])' "$META")" "3"
# refresh 后 cache_state 应 fresh(meta 匹配当前)
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "refresh 后 cache_state=fresh" "$st" "fresh"

# === refresh rejects malformed, blank, or incomplete JSONL before publication ===
rm -f "$CACHE" "$META"
REFRESH_JSONL='{"recipe":"broken"'
rc=0; devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
assert_false "malformed JSONL makes refresh fail" test "$rc" -eq 0
assert_false "malformed JSONL does not publish cache" test -f "$CACHE"
assert_false "malformed JSONL does not publish metadata" test -f "$META"
assert_contains "malformed JSONL diagnostic" "$(cat "$rstderr")" "invalid JSONL"

REFRESH_JSONL='   '
rc=0; devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
assert_false "blank JSONL makes refresh fail" test "$rc" -eq 0
assert_false "blank JSONL does not publish cache" test -f "$CACHE"
assert_false "blank JSONL does not publish metadata" test -f "$META"

REFRESH_JSONL='{"recipe":"incomplete","layer":"meta-test","summary":" "}'
rc=0; devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
assert_false "incomplete JSONL schema makes refresh fail" test "$rc" -eq 0
assert_false "incomplete JSONL does not publish cache" test -f "$CACHE"
assert_false "incomplete JSONL does not publish metadata" test -f "$META"

write_cache '{"recipe":"incomplete","layer":"meta-test","summary":" "}'
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$(cache_sha)" "$(cache_count)"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "semantic-invalid cache_state is stale" "$st" "stale"
REFRESH_JSONL="$JSONL_FIXTURE"

# refresh 失败保留旧 cache
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT"
_devtool_env_exec() { local stage_file="$3"; echo postcondition >"$stage_file"; return 1; }
rc=0
devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
assert_false "refresh 失败 rc!=0" test "$rc" -eq 0
assert_contains "refresh 失败保留旧 cache" "$(cat "$CACHE" 2>/dev/null)" "phosphor-ipmi-host"

# === refresh publication failures retain a recoverable old pair ===
_devtool_env_exec() {
    local stage_file="$3" stdout_file="$4"
    echo command >"$stage_file"
    printf '%s\n' "$REFRESH_JSONL" >"$stdout_file"
    return 0
}
REFRESH_JSONL='{"recipe":"new-recipe","layer":"meta-test","summary":"new"}'

# A failed backup must stop before either new artifact is published.
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$(cache_sha)" "$(cache_count)"
old_cache="$(cat "$CACHE")"; old_meta="$(cat "$META")"
export FAKE_CP_FAIL_BACKUP=1 FAKE_MV_FAIL_CACHE_PUBLISH=1
rc=0
devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
unset FAKE_CP_FAIL_BACKUP FAKE_MV_FAIL_CACHE_PUBLISH
assert_false "backup failure makes refresh fail" test "$rc" -eq 0
assert_eq "backup failure preserves cache" "$(cat "$CACHE")" "$old_cache"
assert_eq "backup failure preserves metadata" "$(cat "$META")" "$old_meta"

# A cache publish failure restores both old artifacts and consumes successful backups.
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$(cache_sha)" "$(cache_count)"
old_cache="$(cat "$CACHE")"; old_meta="$(cat "$META")"
export FAKE_MV_FAIL_CACHE_PUBLISH=1
rc=0
devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
unset FAKE_MV_FAIL_CACHE_PUBLISH
assert_false "cache publish failure makes refresh fail" test "$rc" -eq 0
assert_eq "cache publish failure restores cache" "$(cat "$CACHE")" "$old_cache"
assert_eq "cache publish failure restores metadata" "$(cat "$META")" "$old_meta"
assert_eq "successful rollback leaks no backup" \
    "$(find "$CONFIGS_DIR" -maxdepth 1 -name ".${MACHINE}.recipes.*.backup.*" -print -quit)" ""

# A restore failure must retain the old metadata backup and identify its path.
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$(cache_sha)" "$(cache_count)"
export FAKE_MV_FAIL_CACHE_PUBLISH=1 FAKE_MV_FAIL_META_RESTORE=1
rc=0
devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
unset FAKE_MV_FAIL_CACHE_PUBLISH FAKE_MV_FAIL_META_RESTORE
meta_backup="$(find "$CONFIGS_DIR" -maxdepth 1 -name ".${MACHINE}.recipes.meta.backup.*" -print -quit)"
assert_false "restore failure makes refresh fail" test "$rc" -eq 0
assert_true "restore failure retains metadata backup" test -n "$meta_backup"
assert_contains "restore failure reports retained backup path" "$(cat "$rstderr")" "$meta_backup"
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
assert_eq "restore failure leaves cache stale" "$st" "stale"
rm -f "$meta_backup"

# === strict fingerprint and integrity collection must fail closed ===
prepare_old_pair() {
    write_cache "$JSONL_FIXTURE"
    write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$(cache_sha)" "$(cache_count)"
    old_cache="$(cat "$CACHE")"
    old_meta="$(cat "$META")"
}
assert_old_pair_preserved() {
    local label="$1"
    assert_eq "$label preserves cache" "$(cat "$CACHE")" "$old_cache"
    assert_eq "$label preserves metadata" "$(cat "$META")" "$old_meta"
}

# Initial tempfile allocation failures must preserve the prior pair and retain diagnostics when possible.
run_initial_mktemp_failure_case() {
    local fail_at="$1" label="$2"
    local capture="$TMP/mktemp-$fail_at.stderr"
    local count_file="$TMP/mktemp-$fail_at.count"
    prepare_old_pair
    : >"$capture"
    rm -f "$count_file"
    export FAKE_MKTEMP_FAIL_AT="$fail_at" FAKE_MKTEMP_COUNT_FILE="$count_file"
    rc=0; rstage=""; rstderr=""
    devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr 2>"$capture" || rc=$?
    unset FAKE_MKTEMP_FAIL_AT FAKE_MKTEMP_COUNT_FILE
    assert_false "$label makes refresh fail" test "$rc" -eq 0
    assert_old_pair_preserved "$label"
    if [[ "$fail_at" == "1" ]]; then
        assert_eq "$label has no stderr tempfile" "$rstderr" ""
        assert_contains "$label writes fallback diagnostic" "$(cat "$capture")" "diagnostics tempfile"
    else
        assert_true "$label returns stderr tempfile" test -f "$rstderr"
        assert_contains "$label records diagnostic" "$(cat "$rstderr")" "tempfile"
    fi
}
run_initial_mktemp_failure_case 1 "diagnostics tempfile failure"
run_initial_mktemp_failure_case 2 "stage tempfile failure"
run_initial_mktemp_failure_case 3 "command-output tempfile failure"

prepare_old_pair
export FAKE_GIT_FAIL=1
rc=0; devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
unset FAKE_GIT_FAIL
assert_false "git fingerprint failure makes refresh fail" test "$rc" -eq 0
assert_eq "git fingerprint failure makes cache stale" "$st" "stale"
assert_old_pair_preserved "git fingerprint failure"

prepare_old_pair
export FAKE_BBLAYERS_SHA_FAIL=1
rc=0; devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
unset FAKE_BBLAYERS_SHA_FAIL
assert_false "bblayers hash failure makes refresh fail" test "$rc" -eq 0
assert_eq "bblayers hash failure makes cache stale" "$st" "stale"
assert_old_pair_preserved "bblayers hash failure"

prepare_old_pair
export FAKE_CACHE_SHA_FAIL=1
rc=0; devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
unset FAKE_CACHE_SHA_FAIL
assert_false "cache hash failure makes refresh fail" test "$rc" -eq 0
assert_eq "cache hash failure makes cache stale" "$st" "stale"
assert_old_pair_preserved "cache hash failure"

prepare_old_pair
export FAKE_STAT_FAIL=1
rc=0; devtool_search_refresh "$MACHINE" "$BUILD_DIR" rstage rstderr || rc=$?
st=""; devtool_search_cache_state "$MACHINE" "$BUILD_DIR" st
unset FAKE_STAT_FAIL
assert_false "mtime failure makes refresh fail" test "$rc" -eq 0
assert_eq "mtime failure makes cache stale" "$st" "stale"
assert_old_pair_preserved "mtime failure"

# A reader that validates and renders under one shared lock must only see a complete generation.
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$(cache_sha)" "$(cache_count)"
NEW_CACHE="$TMP/new.recipes.jsonl"
NEW_META="$TMP/new.recipes.meta.json"
printf '%s\n' '{"recipe":"new-recipe","layer":"meta-test","summary":"new"}' >"$NEW_CACHE"
new_sha="$(sha256sum "$NEW_CACHE" | awk '{print $1}')"
new_count="$(wc -l <"$NEW_CACHE" | tr -d ' ')"
printf '{"schema_version":"1","bblayers_hash":"%s","bblayers_mtime":%s,"openbmc_commit":"%s","cache_sha256":"%s","count":%s,"generated_at":"2026-07-14T00:00:00Z"}\n' \
    "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$new_sha" "$new_count" >"$NEW_META"
LOCK="$(devtool_recipes_lock_path "$MACHINE")"
WRITER_READY="$TMP/writer-ready"
(
    exec 9>"$LOCK" || exit 1
    flock -x 9 || exit 1
    cp "$NEW_META" "$META" || exit 1
    touch "$WRITER_READY"
    sleep 0.2
    cp "$NEW_CACHE" "$CACHE"
) &
writer_pid=$!
_lock_attempt=0
while [[ ! -f "$WRITER_READY" && "$_lock_attempt" -lt 100 ]]; do
    sleep 0.01
    _lock_attempt=$((_lock_attempt + 1))
done
assert_true "writer reaches meta/cache window" test -f "$WRITER_READY"
read_state=""
READ_OUT="$TMP/shared-read.out"
devtool_search_read "$MACHINE" "$BUILD_DIR" "" read_state >"$READ_OUT"
writer_rc=0; wait "$writer_pid" || writer_rc=$?
assert_eq "writer completes" "$writer_rc" 0
assert_eq "shared read sees fresh completed generation" "$read_state" "fresh"
assert_contains "shared read renders new generation" "$(cat "$READ_OUT")" "new-recipe"

# Cache clear shares the writer lock, so it cannot erase a generation being read.
write_cache "$JSONL_FIXTURE"
write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT" "$(cache_sha)" "$(cache_count)"
CLEAR_LOCK_READY="$TMP/clear-lock-ready"
(
    exec 9>"$LOCK" || exit 1
    flock -s 9 || exit 1
    touch "$CLEAR_LOCK_READY"
    sleep 0.2
) &
clear_lock_holder_pid=$!
_clear_wait=0
while [[ ! -f "$CLEAR_LOCK_READY" && "$_clear_wait" -lt 100 ]]; do
    sleep 0.01
    _clear_wait=$((_clear_wait + 1))
done
devtool_recipes_clear_cache "$MACHINE" &
clear_pid=$!
sleep 0.05
assert_true "clear waits for shared reader lock(cache remains)" test -f "$CACHE"
assert_true "clear waits for shared reader lock(meta remains)" test -f "$META"
clear_holder_rc=0; wait "$clear_lock_holder_pid" || clear_holder_rc=$?
clear_rc=0; wait "$clear_pid" || clear_rc=$?
assert_eq "shared reader lock holder completes" "$clear_holder_rc" 0
assert_eq "clear completes after shared reader lock" "$clear_rc" 0
assert_false "locked clear removes cache after reader exits" test -f "$CACHE"
assert_false "locked clear removes metadata after reader exits" test -f "$META"

# === clear ===
write_cache "$JSONL_FIXTURE"; write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT"
devtool_recipes_clear_cache "$MACHINE"
assert_false "clear 删 cache" test -f "$CACHE"
assert_false "clear 删 meta" test -f "$META"
# DRY_RUN 预览不删
write_cache "$JSONL_FIXTURE"; write_meta "$(cur_hash)" "$(cur_mtime)" "$MOCK_COMMIT"
DRY_RUN=1 devtool_recipes_clear_cache "$MACHINE"
assert_true "clear DRY_RUN 保留 cache" test -f "$CACHE"
assert_true "clear DRY_RUN 保留 meta" test -f "$META"

assert_summary
