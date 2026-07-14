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

# 路径函数
devtool_recipes_cache_path() { echo "${CONFIGS_DIR:?}/$1.recipes.jsonl"; }
devtool_recipes_meta_path()  { echo "${CONFIGS_DIR:?}/$1.recipes.meta.json"; }

# devtool_search_cache_state <machine> <build_dir> <state_outvar>
# fresh: cache 存在 + meta schema_version 匹配 + bblayers/commit + cache_sha256/count 一致。missing/stale 否则。不 exit。
devtool_search_cache_state() {
    local machine="$1" build_dir="$2" state_outvar="$3"
    local cache meta state="missing"
    cache="$(devtool_recipes_cache_path "$machine")"
    meta="$(devtool_recipes_meta_path "$machine")"
    if [[ -f "$cache" ]]; then
        if [[ ! -f "$meta" ]]; then
            state="stale"
        else
            local m_schema
            m_schema="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("schema_version",""))' "$meta" 2>/dev/null || true)"
            state="stale"
            if [[ "$m_schema" == "$(_devtool_recipes_schema_version)" ]]; then
                local cur_hash cur_mtime cur_commit m_hash m_mtime m_commit
                cur_hash="$(sha256sum "${build_dir}/conf/bblayers.conf" 2>/dev/null | awk '{print $1}' || true)"
                cur_mtime="$(stat -c %Y "${build_dir}/conf/bblayers.conf" 2>/dev/null || echo 0)"
                cur_commit="$(git -C "${OPENBMC_DIR}" rev-parse HEAD 2>/dev/null || echo "")"
                m_hash="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("bblayers_hash",""))' "$meta" 2>/dev/null || true)"
                m_mtime="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("bblayers_mtime",0))' "$meta" 2>/dev/null || true)"
                m_commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("openbmc_commit",""))' "$meta" 2>/dev/null || true)"
                if [[ "$m_hash" == "$cur_hash" && "$m_mtime" == "$cur_mtime" && "$m_commit" == "$cur_commit" ]]; then
                    local cur_cache_sha cur_count m_cache_sha m_count
                    cur_cache_sha="$(sha256sum "$cache" 2>/dev/null | awk '{print $1}' || true)"
                    cur_count="$(wc -l < "$cache" 2>/dev/null | tr -d ' ' || echo 0)"
                    m_cache_sha="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cache_sha256",""))' "$meta" 2>/dev/null || true)"
                    m_count="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("count",0))' "$meta" 2>/dev/null || true)"
                    if [[ -n "$m_cache_sha" && "$m_cache_sha" == "$cur_cache_sha" && "$m_count" == "$cur_count" ]]; then
                        state="fresh"
                    fi
                fi
            fi
        fi
    fi
    printf -v "$state_outvar" '%s' "$state"
    return 0
}

# devtool_search_list <machine> <pattern>
devtool_search_list() {
    local machine="$1" pattern="$2"
    local cache
    cache="$(devtool_recipes_cache_path "$machine")"
    [[ -f "$cache" ]] || return 0
    python3 -c '
import json, sys
cache, pattern = sys.argv[1], sys.argv[2]
try:
    f = open(cache)
except OSError:
    sys.exit(0)
for line in f:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if not pattern or pattern in d.get("recipe", ""):
        print(line)
' "$cache" "$pattern" 2>/dev/null || true
    return 0
}

# devtool_search_refresh <machine> <build_dir> <stage_outvar> <stderr_file_outvar>
# A publish failure restores the old cache/meta pair. Backup or restore failures are fail-closed.
devtool_search_refresh() {
    local machine="$1" build_dir="$2" stage_outvar="$3" stderr_file_outvar="$4"
    local stage_file stdout_file stderr_file rc
    stage_file="$(mktemp)"; stdout_file="$(mktemp)"; stderr_file="$(mktemp)"
    rc=0
    if ! mkdir -p "${CONFIGS_DIR}" 2>/dev/null; then
        printf -v "$stage_outvar" '%s' ""; printf -v "$stderr_file_outvar" '%s' "$stderr_file"
        rm -f "$stage_file" "$stdout_file"; return 1
    fi
    local pre_hash pre_commit
    pre_hash="$(sha256sum "${build_dir}/conf/bblayers.conf" 2>/dev/null | awk '{print $1}' || true)"
    pre_commit="$(git -C "${OPENBMC_DIR}" rev-parse HEAD 2>/dev/null || echo "")"
    local lock="${CONFIGS_DIR}/.${machine}.recipes.lock"
    {
        if ! flock 9; then
            printf 'ob dev refresh: failed to acquire cache lock %s\n' "$lock" >>"$stderr_file"
            rc=1
        else
            _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- \
                python3 "${OB_ENTRY_DIR}/tools/parse_bitbake_recipes.py" --build-dir "$build_dir" --machine "$machine" || rc=$?
            if [[ "$rc" -eq 0 && -s "$stdout_file" ]]; then
                local post_hash post_commit
                post_hash="$(sha256sum "${build_dir}/conf/bblayers.conf" 2>/dev/null | awk '{print $1}' || true)"
                post_commit="$(git -C "${OPENBMC_DIR}" rev-parse HEAD 2>/dev/null || echo "")"
                if [[ "$pre_hash" != "$post_hash" || "$pre_commit" != "$post_commit" ]]; then
                    printf 'ob dev refresh: bblayers or OpenBMC commit changed during generation\n' >>"$stderr_file"
                    rc=1
                else
                    local cache meta tmp_cache="" tmp_meta="" cur_mtime sha count
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
                        sha="$(sha256sum "$tmp_cache" 2>/dev/null | awk '{print $1}' || true)"
                        count="$(wc -l < "$tmp_cache" 2>/dev/null | tr -d ' ' || echo 0)"
                        cur_mtime="$(stat -c %Y "${build_dir}/conf/bblayers.conf" 2>/dev/null || echo 0)"
                        if ! tmp_meta="$(mktemp "${meta}.XXXXXX" 2>/dev/null)"; then
                            printf 'ob dev refresh: failed to stage metadata at %s\n' "$meta" >>"$stderr_file"
                            rc=1
                        elif ! printf '{"schema_version":"%s","bblayers_hash":"%s","bblayers_mtime":%s,"openbmc_commit":"%s","cache_sha256":"%s","count":%s,"generated_at":"%s"}\n' \
                                "$(_devtool_recipes_schema_version)" "$post_hash" "$cur_mtime" "$post_commit" "$sha" "$count" \
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
    local machine="$1"
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    rm -f "$(devtool_recipes_cache_path "$machine")" "$(devtool_recipes_meta_path "$machine")"
    return 0
}
