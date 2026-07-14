#!/usr/bin/env bash
# lib/devtool_search.sh — recipe 元数据检索/JSONL 缓存/stale 检测/refresh/clear. 术语见 CONTEXT.md.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.

# 路径函数
devtool_recipes_cache_path() { echo "${CONFIGS_DIR:?}/$1.recipes.jsonl"; }
devtool_recipes_meta_path()  { echo "${CONFIGS_DIR:?}/$1.recipes.meta.json"; }

# devtool_search_cache_state <machine> <build_dir> <state_outvar>
# 设 state: fresh(cache 存在 + meta 匹配当前 bblayers/commit + cache_sha256/count 一致) / missing / stale。不 exit。
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
            state="stale"
            if [[ "$m_hash" == "$cur_hash" && "$m_mtime" == "$cur_mtime" && "$m_commit" == "$cur_commit" ]]; then
                # 🔴3: 校验 cache_sha256 + count(防新 cache+旧 meta 误判 fresh;cache 与 meta 必须一致)
                local cur_cache_sha cur_count m_cache_sha m_count
                cur_cache_sha="$(sha256sum "$cache" 2>/dev/null | awk '{print $1}' || true)"
                cur_count="$(wc -l < "$cache" 2>/dev/null | tr -d ' ' || echo 0)"
                m_cache_sha="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cache_sha256",""))' "$meta" 2>/dev/null || true)"
                m_count="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("count",0))' "$meta" 2>/dev/null || true)"
                local m_degraded
                m_degraded="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("degraded","false"))' "$meta" 2>/dev/null || true)"
                if [[ "$m_degraded" != "true" && -n "$m_cache_sha" && "$m_cache_sha" == "$cur_cache_sha" && "$m_count" == "$cur_count" ]]; then
                    state="fresh"
                fi
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
# 经 _devtool_env_exec 跑 parse_bitbake_recipes.py;成功 + 生成前后指纹一致才发布。
# 🔴2: mkdir/flock/9>lock 任一失败 → rc=1 不写 cache; 🔴3: 生成前后 bblayers/commit 指纹比对 +
# cache_sha256/count 入 meta + 先 mv meta 后 mv cache(meta 失败保留旧 cache)。不 exit。
devtool_search_refresh() {
    local machine="$1" build_dir="$2" stage_outvar="$3" stderr_file_outvar="$4"
    local stage_file stdout_file stderr_file rc
    stage_file="$(mktemp)"; stdout_file="$(mktemp)"; stderr_file="$(mktemp)"
    rc=0
    # 🔴2: mkdir 检查(失败 → rc=1,不进锁/不写)
    if ! mkdir -p "${CONFIGS_DIR}" 2>/dev/null; then
        printf -v "$stage_outvar" '%s' ""; printf -v "$stderr_file_outvar" '%s' "$stderr_file"
        rm -f "$stage_file" "$stdout_file"; return 1
    fi
    # 🔴3: 生成前指纹(生成期间 bblayers/commit 变化 → 放弃,保留旧)
    local pre_hash pre_commit
    pre_hash="$(sha256sum "${build_dir}/conf/bblayers.conf" 2>/dev/null | awk '{print $1}' || true)"
    pre_commit="$(git -C "${OPENBMC_DIR}" rev-parse HEAD 2>/dev/null || echo "")"
    local lock="${CONFIGS_DIR}/.${machine}.recipes.lock"
    # 🔴2: flock 失败 → rc=1; 9>lock 失败 → 命令组失败 → || rc=1
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
                    rc=1   # 🔴3: 生成期间环境变化,放弃
                else
                    local cache meta tmp_cache tmp_meta cur_mtime sha count
                    cache="$(devtool_recipes_cache_path "$machine")"
                    meta="$(devtool_recipes_meta_path "$machine")"
                    tmp_cache="$(mktemp "${cache}.XXXXXX")"
                    if cp "$stdout_file" "$tmp_cache" 2>/dev/null; then
                        sha="$(sha256sum "$tmp_cache" 2>/dev/null | awk '{print $1}' || true)"
                        count="$(wc -l < "$tmp_cache" 2>/dev/null | tr -d ' ' || echo 0)"
                        cur_mtime="$(stat -c %Y "${build_dir}/conf/bblayers.conf" 2>/dev/null || echo 0)"
                        tmp_meta="$(mktemp "${meta}.XXXXXX")"
                        local _skipped degraded="false"
                        _skipped="$(grep -oE 'skipped=[0-9]+' "$stderr_file" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo 0)"
                        [[ "$_skipped" -gt 0 ]] && degraded="true"
                        if printf '{"bblayers_hash":"%s","bblayers_mtime":%s,"openbmc_commit":"%s","cache_sha256":"%s","count":%s,"degraded":"%s","generated_at":"%s"}\n' \
                                "$post_hash" "$cur_mtime" "$post_commit" "$sha" "$count" "$degraded" \
                                "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" > "$tmp_meta" 2>/dev/null; then
                            # 🔴3: 先 mv meta,成功后才 mv cache(meta 失败保留旧 cache+meta)
                            if ! mv "$tmp_meta" "$meta" 2>/dev/null; then rm -f "$tmp_cache" "$tmp_meta"; rc=1
                            elif ! mv "$tmp_cache" "$cache" 2>/dev/null; then rm -f "$tmp_cache"; rc=1; fi
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
# 删 cache+meta。DRY_RUN==1 只预览不删。不 exit。
devtool_recipes_clear_cache() {
    local machine="$1"
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    rm -f "$(devtool_recipes_cache_path "$machine")" "$(devtool_recipes_meta_path "$machine")"
    return 0
}
