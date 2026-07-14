#!/usr/bin/env bash
# lib/devtool_search.sh — recipe 元数据检索/JSONL 缓存/stale 检测/refresh/clear. 术语见 CONTEXT.md.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.

# 🟡3: schema 版本(meta schema_version 不匹配/缺 → stale,自动淘汰旧 cache);函数形式(extract_funcs 三段不允许顶层赋值)
_devtool_recipes_schema_version() { echo "1"; }

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
# 🔴1: py skipped>0 → return 1 → rc!=0 不发布; 🟡3: meta schema_version; 🟡4: 备份旧 cache+meta,失败恢复。不 exit。
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
        if ! flock 9; then rc=1
        else
            _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- \
                python3 "${OB_ENTRY_DIR}/tools/parse_bitbake_recipes.py" --build-dir "$build_dir" --machine "$machine" || rc=$?
            if [[ "$rc" -eq 0 && -s "$stdout_file" ]]; then
                local post_hash post_commit
                post_hash="$(sha256sum "${build_dir}/conf/bblayers.conf" 2>/dev/null | awk '{print $1}' || true)"
                post_commit="$(git -C "${OPENBMC_DIR}" rev-parse HEAD 2>/dev/null || echo "")"
                if [[ "$pre_hash" != "$post_hash" || "$pre_commit" != "$post_commit" ]]; then
                    rc=1
                else
                    local cache meta tmp_cache tmp_meta cur_mtime sha count old_cache_bak="" old_meta_bak=""
                    cache="$(devtool_recipes_cache_path "$machine")"
                    meta="$(devtool_recipes_meta_path "$machine")"
                    tmp_cache="$(mktemp "${cache}.XXXXXX")"
                    if cp "$stdout_file" "$tmp_cache" 2>/dev/null; then
                        sha="$(sha256sum "$tmp_cache" 2>/dev/null | awk '{print $1}' || true)"
                        count="$(wc -l < "$tmp_cache" 2>/dev/null | tr -d ' ' || echo 0)"
                        cur_mtime="$(stat -c %Y "${build_dir}/conf/bblayers.conf" 2>/dev/null || echo 0)"
                        tmp_meta="$(mktemp "${meta}.XXXXXX")"
                        if printf '{"schema_version":"%s","bblayers_hash":"%s","bblayers_mtime":%s,"openbmc_commit":"%s","cache_sha256":"%s","count":%s,"generated_at":"%s"}\n' \
                                "$(_devtool_recipes_schema_version)" "$post_hash" "$cur_mtime" "$post_commit" "$sha" "$count" \
                                "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" > "$tmp_meta" 2>/dev/null; then
                            # 🟡4: 备份旧 cache+meta(失败恢复一致对)
                            [[ -f "$cache" ]] && { old_cache_bak="$(mktemp)"; cp "$cache" "$old_cache_bak" 2>/dev/null || old_cache_bak=""; }
                            [[ -f "$meta" ]] && { old_meta_bak="$(mktemp)"; cp "$meta" "$old_meta_bak" 2>/dev/null || old_meta_bak=""; }
                            # 先 mv meta,成功后 mv cache;cache mv 失败恢复旧 meta
                            if ! mv "$tmp_meta" "$meta" 2>/dev/null; then rm -f "$tmp_cache" "$tmp_meta" "$old_cache_bak" "$old_meta_bak"; rc=1
                            elif ! mv "$tmp_cache" "$cache" 2>/dev/null; then
                                [[ -n "$old_meta_bak" ]] && mv "$old_meta_bak" "$meta" 2>/dev/null
                                rm -f "$tmp_cache" "$old_cache_bak" "$old_meta_bak"; rc=1
                            else
                                rm -f "$old_cache_bak" "$old_meta_bak"
                            fi
                        else
                            rm -f "$tmp_cache" "$tmp_meta"; rc=1
                        fi
                    else
                        rm -f "$tmp_cache"; rc=1
                    fi
                fi
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
