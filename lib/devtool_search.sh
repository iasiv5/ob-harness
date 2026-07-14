#!/usr/bin/env bash
# lib/devtool_search.sh — recipe 元数据检索/JSONL 缓存/stale 检测/refresh/clear. 术语见 CONTEXT.md.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.

# 🟡3: schema 版本(meta schema_version 不匹配/缺 → stale,自动淘汰旧 cache);函数形式(extract_funcs 三段不允许顶层赋值)
_devtool_recipes_schema_version() { echo "1"; }

# _devtool_recipes_backup_file <source> <template> <outvar> <stderr_file>
# Preserve an existing cache artifact before publishing its replacement.
_devtool_recipes_backup_file() {
    local source="$1" template="$2" outvar="$3" stderr_file="$4" backup=""
    if [[ ! -f "$source" ]]; then
        printf -v "$outvar" '%s' ""
        return 0
    fi
    if ! backup="$(mktemp "$template" 2>/dev/null)"; then
        printf 'ob dev refresh: failed to create backup for %s\n' "$source" >>"$stderr_file"
        return 1
    fi
    if ! cp "$source" "$backup" 2>/dev/null; then
        printf 'ob dev refresh: failed to back up %s\n' "$source" >>"$stderr_file"
        if ! rm -f "$backup" 2>/dev/null; then
            printf 'ob dev refresh: incomplete backup retained at %s\n' "$backup" >>"$stderr_file"
        fi
        return 1
    fi
    printf -v "$outvar" '%s' "$backup"
    return 0
}

# _devtool_recipes_restore_file <backup> <target> <had_original> <stderr_file> <label>
# A failed restore must retain the backup so an operator can recover the old pair.
_devtool_recipes_restore_file() {
    local backup="$1" target="$2" had_original="$3" stderr_file="$4" label="$5"
    if [[ "$had_original" == "1" ]]; then
        if mv "$backup" "$target" 2>/dev/null; then
            return 0
        fi
        printf 'ob dev refresh: failed to restore previous %s; backup retained at %s\n' \
            "$label" "$backup" >>"$stderr_file"
        return 1
    fi
    if rm -f "$target" 2>/dev/null; then
        return 0
    fi
    printf 'ob dev refresh: failed to remove newly published %s at %s\n' \
        "$label" "$target" >>"$stderr_file"
    return 1
}

# _devtool_recipes_discard_backup <backup> <stderr_file> <label>
_devtool_recipes_discard_backup() {
    local backup="$1" stderr_file="$2" label="$3"
    [[ -n "$backup" ]] || return 0
    if ! rm -f "$backup" 2>/dev/null; then
        printf 'ob dev refresh: published new cache, but stale %s backup remains at %s\n' \
            "$label" "$backup" >>"$stderr_file"
    fi
    return 0
}

# Strict fingerprint helpers. Unknown metadata is stale, never equal-by-accident.
_devtool_recipes_is_sha256() { [[ "$1" =~ ^[[:xdigit:]]{64}$ ]]; }
_devtool_recipes_is_git_revision() { [[ "$1" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; }
_devtool_recipes_is_nonnegative_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
_devtool_recipes_is_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# _devtool_recipes_validate_jsonl <path> <record_count_outvar>
# Cache records are machine-readable API data: every line must satisfy the full schema.
_devtool_recipes_validate_jsonl() {
    local path="$1" outvar="$2" validated_record_count=""
    [[ -f "$path" ]] || return 1
    validated_record_count="$(python3 - "$path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as cache_file:
        record_count = 0
        for line_number, line in enumerate(cache_file, 1):
            if not line.strip():
                raise ValueError(f"blank JSONL record {line_number}")
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError(f"non-object JSONL record {line_number}")
            for field in ("recipe", "layer", "summary"):
                value = record.get(field)
                if not isinstance(value, str) or not value.strip():
                    raise ValueError(f"invalid {field} in JSONL record {line_number}")
            record_count += 1
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)

if record_count == 0:
    raise SystemExit(1)
print(record_count)
PY
)" || return 1
    _devtool_recipes_is_positive_integer "$validated_record_count" || return 1
    printf -v "$outvar" '%s' "$validated_record_count"
    return 0
}

# _devtool_recipes_read_sha256 <path> <outvar>
_devtool_recipes_read_sha256() {
    local path="$1" outvar="$2" output="" digest=""
    [[ -f "$path" ]] || return 1
    output="$(sha256sum "$path" 2>/dev/null)" || return 1
    digest="${output%%[[:space:]]*}"
    _devtool_recipes_is_sha256 "$digest" || return 1
    printf -v "$outvar" '%s' "$digest"
    return 0
}

# _devtool_recipes_read_mtime <path> <outvar>
_devtool_recipes_read_mtime() {
    local path="$1" outvar="$2" observed_mtime=""
    [[ -f "$path" ]] || return 1
    observed_mtime="$(stat -c %Y "$path" 2>/dev/null)" || return 1
    _devtool_recipes_is_nonnegative_integer "$observed_mtime" || return 1
    printf -v "$outvar" '%s' "$observed_mtime"
    return 0
}

# _devtool_recipes_read_commit <outvar>
_devtool_recipes_read_commit() {
    local outvar="$1" observed_commit=""
    observed_commit="$(git -C "${OPENBMC_DIR}" rev-parse --verify HEAD 2>/dev/null)" || return 1
    _devtool_recipes_is_git_revision "$observed_commit" || return 1
    printf -v "$outvar" '%s' "$observed_commit"
    return 0
}

# _devtool_recipes_collect_source_fingerprint <build_dir> <hash_outvar> <mtime_outvar> <commit_outvar>
_devtool_recipes_collect_source_fingerprint() {
    local build_dir="$1" hash_outvar="$2" mtime_outvar="$3" commit_outvar="$4"
    local bblayers="${build_dir}/conf/bblayers.conf" hash="" mtime="" commit=""
    _devtool_recipes_read_sha256 "$bblayers" hash || return 1
    _devtool_recipes_read_mtime "$bblayers" mtime || return 1
    _devtool_recipes_read_commit commit || return 1
    printf -v "$hash_outvar" '%s' "$hash"
    printf -v "$mtime_outvar" '%s' "$mtime"
    printf -v "$commit_outvar" '%s' "$commit"
    return 0
}

# _devtool_recipes_collect_cache_integrity <cache> <sha_outvar> <count_outvar>
_devtool_recipes_collect_cache_integrity() {
    local cache="$1" sha_outvar="$2" count_outvar="$3" computed_digest="" computed_records=""
    _devtool_recipes_read_sha256 "$cache" computed_digest || return 1
    _devtool_recipes_validate_jsonl "$cache" computed_records || return 1
    printf -v "$sha_outvar" '%s' "$computed_digest"
    printf -v "$count_outvar" '%s' "$computed_records"
    return 0
}

# _devtool_recipes_read_meta_values <meta> <schema_out> <hash_out> <mtime_out> <commit_out> <cache_sha_out> <count_out>
_devtool_recipes_read_meta_values() {
    local meta="$1" schema_outvar="$2" hash_outvar="$3" mtime_outvar="$4"
    local commit_outvar="$5" cache_sha_outvar="$6" count_outvar="$7" values=""
    local -a fields=()
    values="$(python3 - "$meta" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as meta_file:
        data = json.load(meta_file)
except (OSError, ValueError):
    raise SystemExit(1)

keys = ("schema_version", "bblayers_hash", "bblayers_mtime", "openbmc_commit", "cache_sha256", "count")
try:
    schema, layer_hash, mtime, commit, cache_hash, count = (data[key] for key in keys)
except (KeyError, TypeError):
    raise SystemExit(1)

if not all(isinstance(value, str) for value in (schema, layer_hash, commit, cache_hash)):
    raise SystemExit(1)
if any(isinstance(value, bool) or not isinstance(value, int) for value in (mtime, count)):
    raise SystemExit(1)

for value in (schema, layer_hash, mtime, commit, cache_hash, count):
    print(value)
PY
)" || return 1
    mapfile -t fields <<<"$values"
    [[ "${#fields[@]}" -eq 6 ]] || return 1
    printf -v "$schema_outvar" '%s' "${fields[0]}"
    printf -v "$hash_outvar" '%s' "${fields[1]}"
    printf -v "$mtime_outvar" '%s' "${fields[2]}"
    printf -v "$commit_outvar" '%s' "${fields[3]}"
    printf -v "$cache_sha_outvar" '%s' "${fields[4]}"
    printf -v "$count_outvar" '%s' "${fields[5]}"
    return 0
}

# 路径函数
devtool_recipes_cache_path() { echo "${CONFIGS_DIR:?}/$1.recipes.jsonl"; }
devtool_recipes_meta_path()  { echo "${CONFIGS_DIR:?}/$1.recipes.meta.json"; }
devtool_recipes_lock_path()  { echo "${CONFIGS_DIR:?}/.$1.recipes.lock"; }

# _devtool_search_cache_state_unlocked <machine> <build_dir> <state_outvar>
_devtool_search_cache_state_unlocked() {
    local machine="$1" build_dir="$2" state_outvar="$3"
    local cache meta state="missing"
    local m_schema="" m_hash="" m_mtime="" m_commit="" m_cache_sha="" m_count=""
    local cur_hash="" cur_mtime="" cur_commit="" cur_cache_sha="" cur_count=""
    cache="$(devtool_recipes_cache_path "$machine")"
    meta="$(devtool_recipes_meta_path "$machine")"
    if [[ -f "$cache" ]]; then
        state="stale"
        if [[ -f "$meta" ]] &&
           _devtool_recipes_read_meta_values "$meta" m_schema m_hash m_mtime m_commit m_cache_sha m_count &&
           [[ "$m_schema" == "$(_devtool_recipes_schema_version)" ]] &&
           _devtool_recipes_is_sha256 "$m_hash" &&
           _devtool_recipes_is_nonnegative_integer "$m_mtime" &&
           _devtool_recipes_is_git_revision "$m_commit" &&
           _devtool_recipes_is_sha256 "$m_cache_sha" &&
           _devtool_recipes_is_positive_integer "$m_count" &&
           _devtool_recipes_collect_source_fingerprint "$build_dir" cur_hash cur_mtime cur_commit &&
           [[ "$m_hash" == "$cur_hash" && "$m_mtime" == "$cur_mtime" && "$m_commit" == "$cur_commit" ]] &&
           _devtool_recipes_collect_cache_integrity "$cache" cur_cache_sha cur_count &&
           [[ "$m_cache_sha" == "$cur_cache_sha" && "$m_count" == "$cur_count" ]]; then
            state="fresh"
        fi
    fi
    printf -v "$state_outvar" '%s' "$state"
    return 0
}

# _devtool_search_list_unlocked <machine> <pattern>
_devtool_search_list_unlocked() {
    local machine="$1" pattern="$2" cache validated_records=""
    cache="$(devtool_recipes_cache_path "$machine")"
    [[ -f "$cache" ]] || return 0
    _devtool_recipes_validate_jsonl "$cache" validated_records || return 1
    [[ -n "$validated_records" ]] || return 1
    python3 -c '
import json
import sys

cache, pattern = sys.argv[1], sys.argv[2]
records = []
try:
    with open(cache, encoding="utf-8") as cache_file:
        for line in cache_file:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("invalid recipe record")
            for field in ("recipe", "layer", "summary"):
                if not isinstance(record.get(field), str) or not record[field].strip():
                    raise ValueError("invalid recipe record")
            if not pattern or pattern in record["recipe"]:
                records.append(line)
except (OSError, ValueError, TypeError, UnicodeError):
    raise SystemExit(1)

if records:
    print("\n".join(records))
' "$cache" "$pattern" 2>/dev/null
}

# devtool_search_cache_state <machine> <build_dir> <state_outvar>
# Acquires a shared lock so standalone callers never inspect a partial publish.
devtool_search_cache_state() {
    local machine="$1" build_dir="$2" state_outvar="$3" result_state="stale" lock rc=0
    [[ -d "${CONFIGS_DIR}" ]] || { printf -v "$state_outvar" '%s' "missing"; return 0; }
    lock="$(devtool_recipes_lock_path "$machine")"
    {
        if ! flock -s 9; then
            rc=1
        else
            _devtool_search_cache_state_unlocked "$machine" "$build_dir" result_state || rc=$?
        fi
    } 9>"$lock" 2>/dev/null || rc=1
    [[ "$rc" -eq 0 ]] || result_state="stale"
    printf -v "$state_outvar" '%s' "$result_state"
    return "$rc"
}

# devtool_search_list <machine> <pattern>
# Acquires a shared lock for callers that only need JSONL rendering.
devtool_search_list() {
    local machine="$1" pattern="$2" lock rc=0
    [[ -d "${CONFIGS_DIR}" ]] || return 0
    lock="$(devtool_recipes_lock_path "$machine")"
    {
        if ! flock -s 9; then
            rc=1
        else
            _devtool_search_list_unlocked "$machine" "$pattern" || rc=$?
        fi
    } 9>"$lock" 2>/dev/null || rc=1
    return "$rc"
}

# devtool_search_read <machine> <build_dir> <pattern> <state_outvar>
# One shared-lock operation: validate cache and render JSONL from the same generation.
devtool_search_read() {
    local machine="$1" build_dir="$2" pattern="$3" state_outvar="$4"
    local result_state="stale" lock rc=0
    [[ -d "${CONFIGS_DIR}" ]] || { printf -v "$state_outvar" '%s' "missing"; return 0; }
    lock="$(devtool_recipes_lock_path "$machine")"
    {
        if ! flock -s 9; then
            rc=1
        else
            _devtool_search_cache_state_unlocked "$machine" "$build_dir" result_state || rc=$?
            if [[ "$rc" -eq 0 && "$result_state" == "fresh" ]]; then
                _devtool_search_list_unlocked "$machine" "$pattern" || rc=$?
            fi
        fi
    } 9>"$lock" 2>/dev/null || rc=1
    [[ "$rc" -eq 0 ]] || result_state="stale"
    printf -v "$state_outvar" '%s' "$result_state"
    return "$rc"
}

# devtool_search_refresh <machine> <build_dir> <stage_outvar> <stderr_file_outvar>
# A publish failure restores the old cache/meta pair. Backup or restore failures are fail-closed.
# If diagnostics tempfile creation itself fails, stderr is the only remaining error channel.
devtool_search_refresh() {
    local machine="$1" build_dir="$2" stage_outvar="$3" stderr_file_outvar="$4"
    local stage_file="" stdout_file="" stderr_file="" rc=0
    if ! stderr_file="$(mktemp)"; then
        printf 'ob dev refresh: failed to create diagnostics tempfile\n' >&2
        printf -v "$stage_outvar" '%s' ""
        printf -v "$stderr_file_outvar" '%s' ""
        return 1
    fi
    if ! stage_file="$(mktemp)"; then
        printf 'ob dev refresh: failed to create stage tempfile\n' >>"$stderr_file"
        printf -v "$stage_outvar" '%s' ""
        printf -v "$stderr_file_outvar" '%s' "$stderr_file"
        return 1
    fi
    if ! stdout_file="$(mktemp)"; then
        printf 'ob dev refresh: failed to create command-output tempfile\n' >>"$stderr_file"
        rm -f "$stage_file"
        printf -v "$stage_outvar" '%s' ""
        printf -v "$stderr_file_outvar" '%s' "$stderr_file"
        return 1
    fi
    if ! mkdir -p "${CONFIGS_DIR}" 2>/dev/null; then
        printf 'ob dev refresh: failed to create cache directory %s\n' "${CONFIGS_DIR}" >>"$stderr_file"
        printf -v "$stage_outvar" '%s' ""
        printf -v "$stderr_file_outvar" '%s' "$stderr_file"
        rm -f "$stage_file" "$stdout_file"
        return 1
    fi
    local pre_hash="" pre_mtime="" pre_commit=""
    if ! _devtool_recipes_collect_source_fingerprint "$build_dir" pre_hash pre_mtime pre_commit; then
        printf 'ob dev refresh: failed to collect source fingerprint before generation\n' >>"$stderr_file"
        rc=1
    fi
    local lock
    lock="$(devtool_recipes_lock_path "$machine")"
    {
        if ! flock 9; then
            printf 'ob dev refresh: failed to acquire cache lock %s\n' "$lock" >>"$stderr_file"
            rc=1
        else
            if [[ "$rc" -eq 0 ]]; then
                _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- \
                    python3 "${OB_ENTRY_DIR}/tools/parse_bitbake_recipes.py" --build-dir "$build_dir" --machine "$machine" || rc=$?
            fi
            if [[ "$rc" -eq 0 && -s "$stdout_file" ]]; then
                local post_hash="" post_mtime="" post_commit="" generated_record_count=""
                if ! _devtool_recipes_collect_source_fingerprint "$build_dir" post_hash post_mtime post_commit; then
                    printf 'ob dev refresh: failed to collect source fingerprint after generation\n' >>"$stderr_file"
                    rc=1
                elif [[ "$pre_hash" != "$post_hash" || "$pre_mtime" != "$post_mtime" || "$pre_commit" != "$post_commit" ]]; then
                    printf 'ob dev refresh: bblayers or OpenBMC commit changed during generation\n' >>"$stderr_file"
                    rc=1
                elif ! _devtool_recipes_validate_jsonl "$stdout_file" generated_record_count; then
                    printf 'ob dev refresh: recipe index generator produced invalid JSONL\n' >>"$stderr_file"
                    rc=1
                elif [[ -z "$generated_record_count" ]]; then
                    printf 'ob dev refresh: recipe index generator produced no valid records\n' >>"$stderr_file"
                    rc=1
                else
                    local cache meta tmp_cache="" tmp_meta="" staged_cache_sha="" staged_record_count=""
                    local old_cache_bak="" old_meta_bak="" had_cache=0 had_meta=0 meta_published=0
                    cache="$(devtool_recipes_cache_path "$machine")"
                    meta="$(devtool_recipes_meta_path "$machine")"
                    if ! tmp_cache="$(mktemp "${cache}.XXXXXX" 2>/dev/null)"; then
                        printf 'ob dev refresh: failed to stage cache at %s\n' "$cache" >>"$stderr_file"
                        rc=1
                    elif ! cp "$stdout_file" "$tmp_cache" 2>/dev/null; then
                        printf 'ob dev refresh: failed to write staged cache %s\n' "$tmp_cache" >>"$stderr_file"
                        rc=1
                    fi
                    if [[ "$rc" -eq 0 ]]; then
                        if ! _devtool_recipes_collect_cache_integrity "$tmp_cache" staged_cache_sha staged_record_count; then
                            printf 'ob dev refresh: failed to collect staged cache integrity data\n' >>"$stderr_file"
                            rc=1
                        elif ! tmp_meta="$(mktemp "${meta}.XXXXXX" 2>/dev/null)"; then
                            printf 'ob dev refresh: failed to stage metadata at %s\n' "$meta" >>"$stderr_file"
                            rc=1
                        elif ! printf '{"schema_version":"%s","bblayers_hash":"%s","bblayers_mtime":%s,"openbmc_commit":"%s","cache_sha256":"%s","count":%s,"generated_at":"%s"}\n' \
                                "$(_devtool_recipes_schema_version)" "$post_hash" "$post_mtime" "$post_commit" "$staged_cache_sha" "$staged_record_count" \
                                "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" > "$tmp_meta" 2>/dev/null; then
                            printf 'ob dev refresh: failed to write staged metadata %s\n' "$tmp_meta" >>"$stderr_file"
                            rc=1
                        fi
                    fi
                    if [[ "$rc" -eq 0 ]]; then
                        [[ -f "$cache" ]] && had_cache=1
                        [[ -f "$meta" ]] && had_meta=1
                        _devtool_recipes_backup_file "$cache" \
                            "${CONFIGS_DIR}/.${machine}.recipes.cache.backup.XXXXXX" \
                            old_cache_bak "$stderr_file" || rc=1
                        if [[ "$rc" -eq 0 ]]; then
                            _devtool_recipes_backup_file "$meta" \
                                "${CONFIGS_DIR}/.${machine}.recipes.meta.backup.XXXXXX" \
                                old_meta_bak "$stderr_file" || rc=1
                        fi
                    fi
                    if [[ "$rc" -eq 0 ]]; then
                        if mv "$tmp_meta" "$meta" 2>/dev/null; then
                            tmp_meta=""
                            meta_published=1
                            if mv "$tmp_cache" "$cache" 2>/dev/null; then
                                tmp_cache=""
                                _devtool_recipes_discard_backup "$old_cache_bak" "$stderr_file" "cache"
                                _devtool_recipes_discard_backup "$old_meta_bak" "$stderr_file" "metadata"
                                old_cache_bak=""
                                old_meta_bak=""
                            else
                                printf 'ob dev refresh: failed to publish cache %s; restoring previous pair\n' \
                                    "$cache" >>"$stderr_file"
                                rc=1
                                if _devtool_recipes_restore_file "$old_cache_bak" "$cache" "$had_cache" \
                                    "$stderr_file" "cache"; then
                                    old_cache_bak=""
                                fi
                                if _devtool_recipes_restore_file "$old_meta_bak" "$meta" "$had_meta" \
                                    "$stderr_file" "metadata"; then
                                    old_meta_bak=""
                                fi
                            fi
                        else
                            printf 'ob dev refresh: failed to publish metadata %s\n' "$meta" >>"$stderr_file"
                            rc=1
                        fi
                    fi
                    if [[ "$meta_published" -eq 0 ]]; then
                        _devtool_recipes_discard_backup "$old_cache_bak" "$stderr_file" "cache"
                        _devtool_recipes_discard_backup "$old_meta_bak" "$stderr_file" "metadata"
                    fi
                    if [[ -n "$tmp_cache" ]] && ! rm -f "$tmp_cache" 2>/dev/null; then
                        printf 'ob dev refresh: staged cache retained at %s\n' "$tmp_cache" >>"$stderr_file"
                    fi
                    if [[ -n "$tmp_meta" ]] && ! rm -f "$tmp_meta" 2>/dev/null; then
                        printf 'ob dev refresh: staged metadata retained at %s\n' "$tmp_meta" >>"$stderr_file"
                    fi
                fi
            elif [[ "$rc" -eq 0 ]]; then
                printf 'ob dev refresh: recipe index generator produced no records\n' >>"$stderr_file"
                rc=1
            fi
        fi
    } 9>"$lock" 2>/dev/null || rc=1
    printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
    printf -v "$stderr_file_outvar" '%s' "$stderr_file"
    rm -f "$stage_file" "$stdout_file"
    return "$rc"
}

# devtool_recipes_clear_cache <machine>
devtool_recipes_clear_cache() {
    local machine="$1" cache meta lock rc=0
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    [[ -d "${CONFIGS_DIR}" ]] || return 0
    cache="$(devtool_recipes_cache_path "$machine")"
    meta="$(devtool_recipes_meta_path "$machine")"
    lock="$(devtool_recipes_lock_path "$machine")"
    {
        if ! flock 9; then
            rc=1
        elif ! rm -f "$cache" "$meta"; then
            rc=1
        fi
    } 9>"$lock" 2>/dev/null || rc=1
    return "$rc"
}
