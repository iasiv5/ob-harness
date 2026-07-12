#!/usr/bin/env bash
# lib/bare_mirror.sh - bare mirror provisioning + per-run report state. See CONTEXT.md.
# Exit: leaf-pure module (functions never exit; file/process/network side effects are allowed).


# 私有:重置本轮 provisioning 状态。每次 provision 入口调用,确保上一轮残留不泄漏。
_bare_mirror_reset() {
    _BARE_MIRROR_INITIALIZED=0
    _BARE_MIRROR_BASE=""
    _BARE_MIRROR_NEW=()
    _BARE_MIRROR_EXISTING=()
    _BARE_MIRROR_FAILED=()
}

# 私有:一次性 NUL-framed bare mirror planner:单次 Python 读 deps.json,输出 total\0 + 每条
# name\0clone_url\0src_uri\0mirror_path\0。mirror_path 含 BitBake gitsrcname 算法(本仓唯一实现)。
# malformed/empty src_uri 输出空 mirror_path,仍占四个字段位。失败(损坏 JSON 等)由 python 非零退出
# 传播;caller 必须用可检查返回码的直接调用承载,禁止 $() / <()。
_bare_mirror_emit_plan() {
    local deps_json="$1"
    local mirror_base="$2"
    python3 - "$deps_json" "$mirror_base" <<'PY'
import json
import pathlib
import sys
from urllib.parse import urlparse

items = json.load(open(sys.argv[1]))


def emit(text):
    sys.stdout.buffer.write(str(text).encode('utf-8', 'surrogateescape') + b'\x00')


emit(len(items))
for item in items:
    # name / clone_url 必填:缺字段 → KeyError → planner exit 1(schema 损坏 fatal,对齐旧实现
    # 用 json[...] 索引的必填语义)。src_uri optional:空/malformed → 空 mirror_path → skipped。
    name = item['name']
    clone_url = item['clone_url']
    src_uri = item.get('src_uri', '')
    if not isinstance(src_uri, str):
        src_uri = ''   # null/数字/数组等非字符串 src_uri → 视为 malformed → 空 mirror_path → skipped
    mirror_path = ''
    su = src_uri.split(';', 1)[0].strip()
    if su:
        try:
            parsed = urlparse(su)
            host = parsed.netloc or parsed.path.split('/')[0]
            path = parsed.path if parsed.netloc else parsed.path[len(host):]
            if host and path:
                gitsrcname = '{host}{path}'.format(
                    host=host.replace(':', '.'),
                    path=path.replace('/', '.').replace('*', '.')
                             .replace(' ', '_').replace('(', '_').replace(')', '_'),
                )
                if gitsrcname.startswith('.'):
                    gitsrcname = gitsrcname[1:]
                mirror_path = str(pathlib.Path(sys.argv[2]) / gitsrcname)
        except Exception:
            mirror_path = ''
    emit(name)
    emit(clone_url)
    emit(src_uri)
    emit(mirror_path)
PY
}

# bare_mirror_provision <deps_json> <mirror_base> <build_dir>
# 重置 module 私有状态 -> 批量 NUL planning -> URL expansion/runtime Git mirror host/local.conf
# fallback/URL rewrite/command-scoped clone/cleanup/disposition/immediate summary。individual entry
# failure 非致命(记录后继续,让 BitBake 后续 fetch)。完整遍历成功后设 _BARE_MIRROR_INITIALIZED=1。
# mktemp/planner/open/首字段读取/record count 校验失败:清理临时资源、保持 initialized=0、return 1。
# 只 return,不 exit;fatal 由 caller(clone_sub_repos adapter)收口为 exit 1。
bare_mirror_provision() {
    local deps_json="$1"
    local mirror_base="$2"
    local build_dir="$3"

    _bare_mirror_reset
    _BARE_MIRROR_BASE="$mirror_base"
    # leaf-pure module 不依赖 caller errexit(adapter 用 `if !` 调用,函数体 errexit 关闭),
    # 故必须成功的文件系统操作要显式检查返回码:mirror_base 建不出来(e.g. 同名普通文件占位)是 fatal。
    if ! mkdir -p "$mirror_base"; then
        error "Failed to create bare mirror cache directory: $mirror_base"
        return 1
    fi
    info "Mirror cache: $mirror_base"

    local name clone_url src_uri mirror_path
    local total processed=0 failed=0
    local plan_file plan_fd
    local _clone_err="$build_dir/clone-errors.log"

    # 一次性 NUL-framed planning:整批 dependency 的字段 + mirror path 在一个 Python 进程内算完
    # ($2+4N -> 1 planner)。plan 文件只建在 ${TMPDIR:-/tmp},planner 成功后 open FD 并立即 unlink。
    plan_file=$(mktemp "${TMPDIR:-/tmp}/ob-bare-mirror-plan.XXXXXX") || {
        error "Failed to create temporary bare mirror plan."
        return 1
    }
    if ! _bare_mirror_emit_plan "$deps_json" "$mirror_base" > "$plan_file"; then
        rm -f "$plan_file" 2>/dev/null || warn "Failed to remove temporary bare mirror plan after planner failure."
        error "Failed to plan bare mirrors from $deps_json."
        return 1
    fi
    if ! exec {plan_fd}<"$plan_file"; then
        rm -f "$plan_file" 2>/dev/null || warn "Failed to remove temporary bare mirror plan after open failure."
        error "Failed to open bare mirror plan."
        return 1
    fi
    # open FD 成功后立即 unlink(plan 不是持久化状态文件,见 CONTEXT.md);unlink 失败 = fatal。
    if ! rm -f "$plan_file"; then
        exec {plan_fd}<&- || true
        error "Failed to clean up temporary bare mirror plan."
        return 1
    fi

    if ! IFS= read -r -d '' total <&"$plan_fd" || ! [[ "$total" =~ ^[0-9]+$ ]]; then
        exec {plan_fd}<&- || true
        error "Failed to plan bare mirrors from $deps_json."
        return 1
    fi

    while [[ "$processed" -lt "$total" ]]; do
        # 精确读 total 组四字段记录:任一字段读取失败(字段截断/提前 EOF)→ protocol failure。
        if ! IFS= read -r -d '' name <&"$plan_fd" ||
           ! IFS= read -r -d '' clone_url <&"$plan_fd" ||
           ! IFS= read -r -d '' src_uri <&"$plan_fd" ||
           ! IFS= read -r -d '' mirror_path <&"$plan_fd"; then
            exec {plan_fd}<&- || true
            error "Failed to plan bare mirrors from $deps_json."
            return 1
        fi
        processed=$((processed + 1))
        info "[$processed/$total] Processing: $name"
        verbose "  src_uri=$src_uri"

        # Expand any remaining ${VAR} references in clone_url.
        # These come from BitBake variables (e.g. ${GITLAB_IP}) that weren't
        # resolved during deps.json generation (e.g. variable not in config).
        if [[ "$clone_url" == *'${'* ]]; then
            # GITLAB_IP/GIT_MIRROR_HOST 优先走 detect_runtime_git_host(拿空仍回退 local.conf);
            # 其他 ${VAR} 直接回退 build/conf/local.conf。
            local _local_conf="$build_dir/conf/local.conf"
            # Extract all ${VAR} names from clone_url
            local _var_names
            _var_names=$(echo "$clone_url" | grep -oP '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | sort -u || true)
            for _vk in $_var_names; do
                local _vn="${_vk#\$\{}"
                _vn="${_vn%\}}"
                local _vv=""

                if [[ "$_vn" == "GITLAB_IP" || "$_vn" == "GIT_MIRROR_HOST" ]]; then
                    detect_runtime_git_host >/dev/null   # direct call:缓存不穿透 $() subshell
                    _vv="${_RUNTIME_GIT_HOST:-}"
                fi

                if [[ -z "$_vv" && -f "$_local_conf" ]]; then
                    _vv=$(grep -oP "^$_vn\s*[:?]?=\s*[\"']?\\K[^\"'\s#]+" "$_local_conf" 2>/dev/null | head -1 || true)
                fi

                if [[ -n "$_vv" ]]; then
                    clone_url="${clone_url//$_vk/$_vv}"
                    verbose "Expanded $_vk -> $_vv in clone_url"
                fi
            done
            # If still unexpanded, warn and skip (non-fatal).
            if [[ "$clone_url" == *'${'* ]]; then
                warn "Unresolved BitBake variable in clone_url for $name: $clone_url"
                _BARE_MIRROR_FAILED+=("$name (unresolved variable in clone URL)")
                failed=$((failed + 1))
                continue
            fi
        fi

        # ---------- URL rewrite table ----------
        # Rewrite unreachable git:// URLs to accessible HTTPS mirrors.
        # Each entry: original_url  rewritten_url
        # Add new entries here as needed.
        local _url_rewrites=(
            "git://git.infradead.org/mtd-utils.git"
            "https://github.com/sigma-star/mtd-utils.git"
        )
        for (( _i=0; _i<${#_url_rewrites[@]}; _i+=2 )); do
            if [[ "$clone_url" == "${_url_rewrites[_i]}" ]]; then
                verbose "URL rewrite: $clone_url -> ${_url_rewrites[_i+1]}"
                clone_url="${_url_rewrites[_i+1]}"
                break
            fi
        done
        # ----------------------------------------

        local _clone_err="$build_dir/clone-errors.log"
        # http.postBuffer 提到 512MiB 只作用于本次 clone(大仓单包;默认 1MB 会触发 curl 18
        # "transfer closed with outstanding read data remaining")。用 `git -c` 而非
        # `git config --global`,避免写用户全局 Git 配置(见下方 clone 命令)。

        # --- Phase A: Ensure bare mirror exists in DL_DIR/git2/ ---
        # mirror_path 来自 plan(已含 gitsrcname 算法);空 = malformed/empty src_uri(BitBake 自行 fetch)。
        if [[ -z "$mirror_path" ]]; then
            # Cannot derive mirror path (malformed SRC_URI) — skip, BitBake will fetch from remote.
            verbose "Cannot derive mirror path for $name, skipping (BitBake will fetch from remote)"
        elif [[ -d "$mirror_path" ]]; then
            # Mirror exists — skip; BitBake maintains DL_DIR/git2/ during builds.
            verbose "Mirror already exists: $mirror_path"
            _BARE_MIRROR_EXISTING+=("$name")
        else
            # Mirror missing — create full bare clone from remote
            verbose "Creating bare mirror: $clone_url -> $mirror_path"
            if ! mkdir -p "$(dirname "$mirror_path")"; then
                exec {plan_fd}<&- || true
                error "Failed to create parent directory for bare mirror: $mirror_path"
                return 1
            fi
            if git -c http.postBuffer=536870912 clone --bare "$clone_url" "$mirror_path" 2>>"$_clone_err"; then
                _BARE_MIRROR_NEW+=("$name")
            else
                # clone 失败必须清理 partial mirror:残留会被下次 [[ -d "$mirror_path" ]] 误判为
                # existing(缓存污染)。cleanup 失败 = fatal(不能让脏 mirror 进入 BitBake 视野),
                # 整批 return 1 并保持 initialized=0。
                if ! rm -rf "$mirror_path"; then
                    exec {plan_fd}<&- || true
                    error "Failed to clean up partial bare mirror for $name: $mirror_path"
                    return 1
                fi
                warn "Failed to create bare mirror for $name (BitBake will fetch from remote during build)"
                _BARE_MIRROR_FAILED+=("$name (bare mirror clone failed)")
                failed=$((failed + 1))
                continue
            fi
        fi
    done
    # 读完 total 条完整记录后,FD 必须干净 EOF:无残余完整字段(read 返回 0 = 又读到一个 NUL 终止字段)、
    # 无残片字节(read 失败但 _trailing 非空)。否则 planner 输出与 total 不符(protocol corruption),
    # 整批 planning failure。caller 永远不会观察 producer 的半写尾部。
    local _trailing=""
    if IFS= read -r -d '' _trailing <&"$plan_fd" 2>/dev/null || [[ -n "$_trailing" ]]; then
        exec {plan_fd}<&- || true
        error "Failed to plan bare mirrors from $deps_json."
        return 1
    fi
    exec {plan_fd}<&- || true

    info "Mirrors: ${#_BARE_MIRROR_NEW[@]} new, ${#_BARE_MIRROR_EXISTING[@]} existing in $mirror_base"
    if [[ "$failed" -gt 0 ]]; then
        warn "$failed mirrors failed. See $build_dir/clone-errors.log"
    fi

    _BARE_MIRROR_INITIALIZED=1
    return 0
}

# bare_mirror_base:输出本轮 effective bare mirror 目录,供 Step 8 report 的 `Mirror dir:` 行。
# 未初始化/dry-run/fatal failure 后输出空行(保持原行位置,不破坏 report 布局)。
bare_mirror_base() {
    if [[ "${_BARE_MIRROR_INITIALIZED:-0}" == "1" ]]; then
        echo "${_BARE_MIRROR_BASE:-}"
    else
        echo ""
    fi
}

# bare_mirror_print_status MACHINE:按旧 print_report 顺序输出本轮 mirror counts、cache path、
# failed entries 与 troubleshooting block。未初始化/dry-run/fatal failure 后安全无输出。
# caller 不需要传入或读取任何数组,只跨 public interface。
bare_mirror_print_status() {
    local machine="$1"
    if [[ "${_BARE_MIRROR_INITIALIZED:-0}" != "1" ]]; then
        return 0
    fi

    echo "Mirrors populated: ${#_BARE_MIRROR_NEW[@]} new, ${#_BARE_MIRROR_EXISTING[@]} existing"
    echo "  Mirror cache: $_BARE_MIRROR_BASE"
    echo ""

    if [[ ${#_BARE_MIRROR_FAILED[@]} -gt 0 ]]; then
        echo "Failed mirrors: ${#_BARE_MIRROR_FAILED[@]}"
        for entry in "${_BARE_MIRROR_FAILED[@]}"; do
            echo "  [FAIL] $entry"
        done
        echo ""
        echo "[WARN] Troubleshooting guide:"
        echo "  A) Network flakiness      -> retry: ob init $machine"
        echo "  B) Server network block   -> specific domains (e.g. infradead.org) may be unreachable"
        echo "  C) BitBake will fetch from remote during build if mirror is missing"
        echo ""
    fi
}
