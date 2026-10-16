#!/usr/bin/env bash
# lib/build_env.sh — current-shell build environment 进入原语(cd+source setup, 副作用刻意留在当前 shell, 与 bitbake_env 子进程隔离对偶). 术语见 GLOSSARY.md current-shell build environment.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.

build_env_enter() {
    local machine="$1" build_dir="$2"
    cd "$OPENBMC_DIR" || return 1
    local prev_opts
    prev_opts=$(set +o | grep nounset)
    set +u
    # shellcheck disable=SC1091
    source setup "$machine" "$build_dir"   # 返回码 silent (本仓两份 setup 抽样不可靠);
                                            # stderr 透传, 调用者按需 2>/dev/null
    eval "$prev_opts"
}

# build_env_stale_conf_paths <build_dir> — 既有 machine build conf 的搬迁遗留诊断(只诊断, 绝不修改)。
# 场景: harness 根目录整体搬迁后, conf 里的旧绝对前缀(bblayers.conf 的 BBLAYERS 条目、
# local.conf/conf/*.inc 的 KEY = "/abs" 赋值)指向不存在目录; bitbake 对缺失 BBLAYERS 目录直接失败。
# 豁免: 含 $/~ 的值(bitbake/_shell 变量引用, 如 ${TOPDIR}/${COREBASE})、单引号值(TZ 类)、空值、注释行。
# 输出: record "file_rel|path"(file_rel 相对 conf/); 结果数组 _BUILD_ENV_STALE_RECORDS(函数内重置)。
# 返回: 0=无 stale(或 conf 不存在); 1=有 stale。局限: 尚未创建的合法缓存目录(如首跑前的 xdg-cache)
#       会被计入——warn 文案已注明"若属有意后建可忽略"。
build_env_stale_conf_paths() {
    local build_dir="$1"
    local conf_dir="$build_dir/conf"
    _BUILD_ENV_STALE_RECORDS=()
    [[ -d "$conf_dir" ]] || return 0

    local tokens p file_rel f
    # bblayers.conf: 只扫 BBLAYERS 赋值块(跨行续行直到闭引号), 按空白分词取 / 开头的字面条目。
    # BBMASK += "/recipe.bb" 这类 mask 通配是相对 BBFILES 的掩码模式, 必须排除(2026-10-16 真机误报实证);
    # ${TOPDIR}/${OEROOT} 等变量形态条目不以 / 开头, 天然跳过; 注释行跳过。
    tokens=$(awk '
        inb == 1 {
            s = $0
            gsub(/["\\]/, " ", s)
            n = split(s, toks, /[ \t]+/)
            for (i = 1; i <= n; i++) if (toks[i] ~ /^\//) print toks[i]
            if ($0 ~ /"[[:space:]]*$/) inb = 0
            next
        }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*BBLAYERS[^A-Za-z0-9_]/ && /=/ && /"/ {
            inb = 1
            s = $0
            sub(/^[^"]*"/, "", s)
            gsub(/["\\]/, " ", s)
            n = split(s, toks, /[ \t]+/)
            for (i = 1; i <= n; i++) if (toks[i] ~ /^\//) print toks[i]
            if ($0 !~ /\\[[:space:]]*$/) inb = 0
            next
        }
    ' "$conf_dir/bblayers.conf" 2>/dev/null)
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if [[ ! -e "$p" ]]; then
            _BUILD_ENV_STALE_RECORDS+=("bblayers.conf|$p")
        fi
    done <<< "$tokens"

    # local.conf + conf/*.inc: 双引号赋值形态(KEY = "/abs"、export KEY = "/abs"、KEY:append = "/abs")
    for f in "$conf_dir/local.conf" "$conf_dir"/*.inc; do
        [[ -f "$f" ]] || continue
        file_rel="${f##*/}"
        tokens=$(awk '
            /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*[:+?.]*=[[:space:]]*"/ {
                rest = substr($0, index($0, "=") + 1)
                sub(/^[[:space:]]*"/, "", rest)
                idx = index(rest, "\"")
                if (idx > 1) {
                    p = substr(rest, 1, idx - 1)
                    if (p ~ /^\// && p !~ /[$~]/) print p
                }
            }
        ' "$f" 2>/dev/null)
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            if [[ ! -e "$p" ]]; then
                _BUILD_ENV_STALE_RECORDS+=("$file_rel|$p")
            fi
        done <<< "$tokens"
    done

    [[ ${#_BUILD_ENV_STALE_RECORDS[@]} -eq 0 ]] && return 0
    return 1
}
