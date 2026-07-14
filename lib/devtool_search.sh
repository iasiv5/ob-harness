#!/usr/bin/env bash
# lib/devtool_search.sh — recipe 元数据检索/JSONL 缓存/stale 检测/refresh/clear. 术语见 CONTEXT.md.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.

# 路径函数
devtool_recipes_cache_path() { echo "${CONFIGS_DIR:?}/$1.recipes.jsonl"; }
devtool_recipes_meta_path()  { echo "${CONFIGS_DIR:?}/$1.recipes.meta.json"; }

# devtool_search_cache_state <machine> <build_dir> <state_outvar>
# 设 state: fresh(cache 存在且 meta 匹配当前 bblayers/commit) / missing(无 cache) / stale(cache 存在但 meta 不匹配/缺失)。不 exit。
devtool_search_cache_state() {
    local machine="$1" build_dir="$2" state_outvar="$3"
    local cache meta state="missing"
    cache="$(devtool_recipes_cache_path "$machine")"
    meta="$(devtool_recipes_meta_path "$machine")"
    if [[ -f "$cache" ]]; then
        if [[ ! -f "$meta" ]]; then
            state="stale"
        else
            local cur_hash cur_mtime cur_commit m_hash m_mtime m_commit
            cur_hash="$(sha256sum "${build_dir}/conf/bblayers.conf" 2>/dev/null | awk '{print $1}' || true)"
            cur_mtime="$(stat -c %Y "${build_dir}/conf/bblayers.conf" 2>/dev/null || echo 0)"
            cur_commit="$(git -C "${OPENBMC_DIR}" rev-parse HEAD 2>/dev/null || echo "")"
            m_hash="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("bblayers_hash",""))' "$meta" 2>/dev/null || true)"
            m_mtime="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("bblayers_mtime",0))' "$meta" 2>/dev/null || true)"
            m_commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("openbmc_commit",""))' "$meta" 2>/dev/null || true)"
            if [[ "$m_hash" == "$cur_hash" && "$m_mtime" == "$cur_mtime" && "$m_commit" == "$cur_commit" ]]; then
                state="fresh"
            else
                state="stale"
            fi
        fi
    fi
    printf -v "$state_outvar" '%s' "$state"
    return 0
}

# devtool_search_list <machine> <pattern>
# 读 cache JSONL,pattern 子串匹配 recipe 字段,逐行原样输出。空 pattern 输出全部。不 exit。
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
# 经 _devtool_env_exec 跑 parse_bitbake_recipes.py;成功才原子写(temp+mv)cache + 写 meta(bblayers hash/mtime + openbmc commit + generated_at);
# 失败/空输出保留旧 cache。回传 stage + stderr_file 路径。不 exit。
devtool_search_refresh() {
    local machine="$1" build_dir="$2" stage_outvar="$3" stderr_file_outvar="$4"
    local stage_file stdout_file stderr_file rc
    stage_file="$(mktemp)"; stdout_file="$(mktemp)"; stderr_file="$(mktemp)"
    rc=0
    mkdir -p "${CONFIGS_DIR}" 2>/dev/null || true
    {
        flock 9
        _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- \
            python3 "${OB_ENTRY_DIR}/tools/parse_bitbake_recipes.py" --build-dir "$build_dir" --machine "$machine" || rc=$?
        if [[ "$rc" -eq 0 && -s "$stdout_file" ]]; then
            local cache meta tmp_cache tmp_meta cur_hash cur_mtime cur_commit sha count
            cache="$(devtool_recipes_cache_path "$machine")"
            meta="$(devtool_recipes_meta_path "$machine")"
            tmp_cache="$(mktemp "${cache}.XXXXXX")"
            if cp "$stdout_file" "$tmp_cache" 2>/dev/null; then
                sha="$(sha256sum "$tmp_cache" 2>/dev/null | awk '{print $1}' || true)"
                count="$(wc -l < "$tmp_cache" 2>/dev/null | tr -d ' ' || echo 0)"
                cur_hash="$(sha256sum "${build_dir}/conf/bblayers.conf" 2>/dev/null | awk '{print $1}' || true)"
                cur_mtime="$(stat -c %Y "${build_dir}/conf/bblayers.conf" 2>/dev/null || echo 0)"
                cur_commit="$(git -C "${OPENBMC_DIR}" rev-parse HEAD 2>/dev/null || echo "")"
                tmp_meta="$(mktemp "${meta}.XXXXXX")"
                if printf '{"bblayers_hash":"%s","bblayers_mtime":%s,"openbmc_commit":"%s","cache_sha256":"%s","count":%s,"generated_at":"%s"}\n' \
                        "$cur_hash" "$cur_mtime" "$cur_commit" "$sha" "$count" \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" > "$tmp_meta" 2>/dev/null; then
                    if ! mv "$tmp_cache" "$cache" 2>/dev/null; then rm -f "$tmp_cache" "$tmp_meta"; rc=1
                    elif ! mv "$tmp_meta" "$meta" 2>/dev/null; then rm -f "$tmp_meta"; rc=1; fi
                else
                    rm -f "$tmp_cache" "$tmp_meta"; rc=1
                fi
            else
                rm -f "$tmp_cache"; rc=1
            fi
        fi
    } 9>"${CONFIGS_DIR}/.${machine}.recipes.lock"
    printf -v "$stage_outvar" '%s' "$(cat "$stage_file" 2>/dev/null || true)"
    printf -v "$stderr_file_outvar" '%s' "$stderr_file"
    rm -f "$stage_file" "$stdout_file"
    return "$rc"
}

# devtool_recipes_clear_cache <machine>
# 删 cache+meta。DRY_RUN==1 只预览不删。不 exit。
devtool_recipes_clear_cache() {
    local machine="$1"
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    rm -f "$(devtool_recipes_cache_path "$machine")" "$(devtool_recipes_meta_path "$machine")"
    return 0
}
