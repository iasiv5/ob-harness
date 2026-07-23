#!/usr/bin/env bash
# lib/qemu_binary.sh — QEMU binary provisioning module(下载/Jenkins/manifest/firmware)。术语见 CONTEXT.md QEMU manifest / QEMU source。
# 从 lib/qemu.sh 迁出(2026-07-04, qemu.sh deepening)。
# Exit: direct-exit module(ensure_qemu_binary_community/custom exit 1/2/3;download_* 约定不 exit,caller 拥有 flock/manifest/exit)。


derive_qemu_url_config_path() {
    QEMU_URL_CONFIG_FILE="$WORKSPACE_DIR/qemu-bin/qemu-binary-urls.conf"
}

read_qemu_url_config() {
    local source="$1"
    local arch="$2"
    local key="${source}.${arch}"
    local url
    derive_qemu_url_config_path
    # read_kv_field returns 1 on missing file/key; keep prior "missing → empty" semantics.
    url=$(read_kv_field "$QEMU_URL_CONFIG_FILE" "$key" 2>/dev/null) || url=""
    trim_whitespace "$url"
}

write_qemu_url_config() {
    local source="$1"
    local arch="$2"
    local url="$3"
    local key
    local key_re
    local tmp

    key="${source}.${arch}"
    key_re="${key//./\\.}"
    derive_qemu_url_config_path

    mkdir -p "$(dirname "$QEMU_URL_CONFIG_FILE")"
    if [[ ! -f "$QEMU_URL_CONFIG_FILE" ]]; then
        echo "# qemu binary download URLs — auto-managed by 'ob start-qemu'" > "$QEMU_URL_CONFIG_FILE"
        echo "# key: <source_label>.<QEMU_LAUNCH_SYSTEM_NAME>" >> "$QEMU_URL_CONFIG_FILE"
    fi

    if grep -q "^${key_re}=" "$QEMU_URL_CONFIG_FILE"; then
        tmp=$(mktemp "${TMPDIR:-/tmp}/qemu-url-conf-XXXXXX")
        grep -v "^${key_re}=" "$QEMU_URL_CONFIG_FILE" > "$tmp"
        echo "${key}=${url}" >> "$tmp"
        mv "$tmp" "$QEMU_URL_CONFIG_FILE"
    else
        echo "${key}=${url}" >> "$QEMU_URL_CONFIG_FILE"
    fi
}

write_qemu_binary_manifest() {
    local install_source="$1"
    local arch="$2"
    local source_key="$3"
    local source_value="$4"
    local sha256="$5"
    local build_number="${6:-}"
    local manifest_path="${QEMU_BIN_FILE}.manifest"

    cat > "$manifest_path" <<MANIFEST_EOF
asset=binary
source=${install_source}
arch=${arch}
binary_path=${QEMU_BIN_FILE}
${source_key}=${source_value}
installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sha256=${sha256}
MANIFEST_EOF

    if [[ -n "$build_number" ]]; then
        echo "build_number=${build_number}" >> "$manifest_path"
    fi
}

write_qemu_pcbios_manifest() {
    local install_source="$1"
    local pcbios_source_path="$2"
    local manifest_path="$QEMU_BIN_DIR/pc-bios.manifest"

    cat > "$manifest_path" <<MANIFEST_EOF
asset=pc-bios
source=${install_source}
pcbios_path=${QEMU_BIN_DIR}/pc-bios
pcbios_source=${pcbios_source_path}
installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MANIFEST_EOF
}

# Query Jenkins lastSuccessfulBuild number for a given job URL.
# Args: $1 = Jenkins job base URL (e.g. https://jenkins.openbmc.org/job/latest-qemu-x86)
# Returns: build number via stdout (empty string on failure)
query_jenkins_build_number() {
    local job_url="$1"
    local api_url="${job_url}/lastSuccessfulBuild/api/json?tree=number"
    local raw
    raw=$(curl -s --max-time 5 "$api_url" 2>/dev/null) || return 0
    echo "$raw" | grep -o '"number":[0-9]*' | head -1 | cut -d: -f2
}

# jenkins_job_url_from_url <url>
# 纯决策(无 IO、不 exit): 从 QEMU binary 下载 URL 剥离 lastSuccessfulBuild/artifact 后缀，
# 得到 Jenkins job base URL(供 query_jenkins_build_number 查 lastSuccessfulBuild/api/json)。
# leaf-pure(绝不 exit)。
jenkins_job_url_from_url() {
    local url="$1"
    echo "$url" | sed -E 's|/lastSuccessfulBuild/.*||; s|/artifact/.*||'
}

# download_qemu_binary_core <url> <extract_dir> <arch>
# Shared download→detect→extract→locate→sha256 core for QEMU binaries
# (used by download_and_replace_community_qemu and ensure_qemu_binary_community).
# Sets globals DLQB_BIN_PATH (located binary) and DLQB_SHA256 on success.
# Returns 0=success / 1=download, extract, or locate failure.
# Caller owns: flock/backup/rollback/manifest/exit, the -x executable check,
# and the final mv of DLQB_BIN_PATH to QEMU_BIN_FILE. L3 — never exits.
download_qemu_binary_core() {
    local url="$1"
    local extract_dir="$2"
    local arch="$3"

    local tmp_download="${QEMU_BIN_DIR}/.dlqbc-partial-${arch}"
    verbose "  URL: $url"

    if ! curl -fSL -C - -o "$tmp_download" "$url"; then
        return 1
    fi

    local file_type
    file_type=$(file -b "$tmp_download" 2>/dev/null || echo "")

    local binary=""
    if echo "$file_type" | grep -qi "gzip\|xz"; then
        verbose "  Detected archive, extracting..."
        tar xf "$tmp_download" -C "$extract_dir/" --strip-components=1 2>/dev/null \
            || tar xf "$tmp_download" -C "$extract_dir/" 2>/dev/null
        rm -f "$tmp_download"

        local candidate
        for candidate in "$extract_dir/$arch" "$extract_dir/bin/$arch"; do
            if [[ -f "$candidate" ]]; then
                binary="$candidate"
                break
            fi
        done

        if [[ -z "$binary" ]]; then
            return 1
        fi
    else
        binary="$tmp_download"
    fi

    DLQB_BIN_PATH="$binary"
    DLQB_SHA256=$(sha256sum "$binary" | awk '{print $1}')
    return 0
}

# Download a new QEMU binary and safely replace the existing one.
# Args: $1 = download URL, $2 = remote build number, $3 = arch
# Returns: 0 on success, 1 on failure (caller should continue with old binary)
download_and_replace_community_qemu() {
    local qemu_url="$1"
    local remote_build="$2"
    local arch="$3"
    local manifest="${QEMU_BIN_FILE}.manifest"

    # ── flock: prevent concurrent updates ──
    local lock_file="${QEMU_BIN_FILE}.update.lock"
    exec 200>"$lock_file"
    if ! flock -n 200; then
        warn "Another QEMU binary update is in progress. Skipping."
        exec 200>&-
        return 1
    fi

    # ── Staging dir for extraction (partial path lives in download_qemu_binary_core) ──
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/qemu-update-XXXXXX")

    info "Downloading QEMU binary (build #${remote_build})..."
    if ! download_qemu_binary_core "$qemu_url" "$tmp_dir" "$arch"; then
        warn "Failed to download/extract QEMU binary from: $qemu_url"
        rm -rf "$tmp_dir"
        flock -u 200 2>/dev/null; exec 200>&-
        return 1
    fi
    local new_binary="$DLQB_BIN_PATH"
    local new_sha256="$DLQB_SHA256"

    # ── Verify new binary ──
    chmod +x "$new_binary"
    if ! [[ -x "$new_binary" ]]; then
        warn "Downloaded file is not executable."
        rm -rf "$tmp_dir"
        flock -u 200 2>/dev/null; exec 200>&-
        return 1
    fi

    # ── Backup old binary ──
    local old_build
    old_build=$(read_kv_field "$manifest" build_number 2>/dev/null) || old_build=""
    local bak_suffix="${old_build:-unknown}"
    local bak_file="${QEMU_BIN_FILE}-${bak_suffix}.bak"

    info "Backing up current QEMU binary (build #${bak_suffix})..."
    cp "$QEMU_BIN_FILE" "$bak_file"

    # ── Replace ──
    if ! mv "$new_binary" "$QEMU_BIN_FILE"; then
        warn "Failed to replace QEMU binary."
        if [[ -f "$bak_file" ]]; then
            mv "$bak_file" "$QEMU_BIN_FILE"
        fi
        rm -rf "$tmp_dir"
        flock -u 200 2>/dev/null; exec 200>&-
        return 1
    fi
    chmod +x "$QEMU_BIN_FILE"

    # ── Update manifest ──
    local label
    label=$(read_source_label)
    write_qemu_binary_manifest "$label" "$arch" "url" "$qemu_url" "$new_sha256" "$remote_build"

    # ── Cleanup ──
    rm -rf "$tmp_dir"
    rm -f "$bak_file"
    flock -u 200 2>/dev/null; exec 200>&-

    info "QEMU binary updated to build #${remote_build}."
    verbose "  SHA256: $new_sha256"
    return 0
}

# Check if a newer QEMU binary is available on Jenkins.
# If update available and interactive, prompt user to update.
# Non-interactive: notify only.
# On any failure: silently continue with existing binary.
# qemu_binary_update_decision <local_build> <remote_build> <manifest_url>
# 纯决策(无 IO、不 exit):是否需要更新 community QEMU binary。echo token:
#   skip_no_build / skip_not_jenkins / skip_no_remote / up_to_date / update_available
# 检查顺序:local 空 → 非 jenkins → remote 空 → build 比较(与原 check_jenkins_update 守卫一致)。
qemu_binary_update_decision() {
    local local_build="$1" remote_build="$2" manifest_url="$3"
    if   [[ -z "$local_build" ]];                          then echo "skip_no_build"
    elif [[ "$manifest_url" != *"jenkins.openbmc.org"* ]]; then echo "skip_not_jenkins"
    elif [[ -z "$remote_build" ]];                         then echo "skip_no_remote"
    elif [[ "$remote_build" == "$local_build" ]];          then echo "up_to_date"
    else                                                        echo "update_available"
    fi
}

# qemu_binary_resolve_url <env_url> <config_url> <label> <arch>
# 纯决策(无 IO、不 exit):QEMU binary URL 的来源优先级。echo token:
#   use_env / use_config / default_jenkins / none_aarch64 / needs_input
# 优先级:env > config > community+arm 默认 jenkins > community+aarch64(无) > 其他(需输入)。
qemu_binary_resolve_url() {
    local env_url="$1" config_url="$2" label="$3" arch="$4"
    if   [[ -n "$env_url" ]]; then echo "use_env"
    elif [[ -n "$config_url" ]]; then echo "use_config"
    elif [[ "$label" == "community" && "$arch" == "qemu-system-arm" ]]; then echo "default_jenkins"
    elif [[ "$label" == "community" && "$arch" == "qemu-system-aarch64" ]]; then echo "none_aarch64"
    else echo "needs_input"
    fi
}

check_jenkins_update() {
    local manifest="${QEMU_BIN_FILE}.manifest"

    # ── Guard: manifest must exist ──
    [[ -f "$manifest" ]] || return 0

    local local_build manifest_url
    local_build=$(read_kv_field "$manifest" build_number 2>/dev/null) || local_build=""
    manifest_url=$(read_kv_field "$manifest" url 2>/dev/null) || manifest_url=""

    # 网络规避:local 空 / 非 jenkins 不查 remote(决策函数 skip_no_build/skip_not_jenkins 分支)
    case "$(qemu_binary_update_decision "$local_build" "" "$manifest_url")" in
        skip_*) return 0 ;;
    esac

    # ── extract job URL + query Jenkins ──
    local job_url
    job_url=$(jenkins_job_url_from_url "$manifest_url")
    local remote_build
    remote_build=$(query_jenkins_build_number "$job_url")

    case "$(qemu_binary_update_decision "$local_build" "$remote_build" "$manifest_url")" in
        skip_no_remote) return 0 ;;                                  # Jenkins unreachable
        up_to_date) verbose "QEMU binary is up to date (build #${local_build})."; return 0 ;;
        update_available) ;;
    esac

    # ── Update available ──
    info "QEMU binary update available: build #${local_build} → #${remote_build}"

    # ── Non-interactive: notify and skip ──
    if [[ ! -t 0 ]]; then
        info "Update skipped: non-interactive mode. Re-run in a terminal to update."
        return 0
    fi

    # ── Interactive confirmation ──
    local arch="${QEMU_LAUNCH_SYSTEM_NAME:-qemu-system-arm}"
    echo ""
    local ca_rc=0
    confirm_action "update community QEMU binary" "build #${local_build} → #${remote_build}" || ca_rc=$?
    if [[ "$ca_rc" -eq 0 ]]; then
        echo ""
        if ! download_and_replace_community_qemu "$manifest_url" "$remote_build" "$arch"; then
            warn "QEMU binary update failed. Continuing with existing binary."
        fi
    elif [[ "$ca_rc" -eq 2 ]]; then
        warn "Update cancelled by user."
    fi
    return 0
}

ensure_qemu_binary_community() {
    derive_qemu_paths

    # Already downloaded and executable?
    if [[ -x "$QEMU_BIN_FILE" ]]; then
        verbose "QEMU binary already exists: $QEMU_BIN_FILE"
        check_jenkins_update
        return 0
    fi

    local label
    label=$(read_source_label)
    mkdir -p "$QEMU_BIN_DIR"

    local arch="${QEMU_LAUNCH_SYSTEM_NAME:-qemu-system-arm}"
    local qemu_url=""
    local env_url="${OB_QEMU_BINARY_URL:-}"
    local config_url=""
    # env 空才读 config(匹配原时序,避免 env 已设时多余读)
    [[ -z "$env_url" ]] && { config_url=$(read_qemu_url_config "$label" "$arch" 2>/dev/null) || config_url=""; }

    case "$(qemu_binary_resolve_url "$env_url" "$config_url" "$label" "$arch")" in
        use_env)
            qemu_url="$env_url"
            write_qemu_url_config "$label" "$arch" "$qemu_url"
            ;;
        use_config)
            qemu_url="$config_url"
            ;;
        default_jenkins)
            qemu_url="https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm"
            write_qemu_url_config "$label" "$arch" "$qemu_url"
            info "Using OpenBMC Jenkins default QEMU URL (recorded in $QEMU_URL_CONFIG_FILE)"
            ;;
        none_aarch64|needs_input)
            if [[ "$label" == "community" && "$arch" == "qemu-system-aarch64" ]]; then
                info "Community source provides no aarch64 QEMU binary."
                info "Provide a custom download URL below, or press Enter / Ctrl-C to abort."
            fi

            derive_qemu_url_config_path
            if [[ ! -t 0 ]]; then
                error "QEMU binary URL not configured for '${label}.${arch}'."
                error "Set OB_QEMU_BINARY_URL, or add a line '${label}.${arch}=<url>' to:"
                error "  $QEMU_URL_CONFIG_FILE"
                exit 3
            fi

            local input_url=""
            read -r -p "$(echo -e "${PROMPT_PREFIX} Enter QEMU binary URL for ${label}.${arch}: ")" input_url || true
            input_url="$(trim_whitespace "$input_url")"
            if [[ -z "$input_url" ]]; then
                info "No URL provided — aborting QEMU binary setup."
                exit 2
            fi
            if [[ ! "$input_url" =~ ^https?:// ]]; then
                error "Invalid URL (must start with http:// or https://): $input_url"
                exit 3
            fi

            qemu_url="$input_url"
            write_qemu_url_config "$label" "$arch" "$qemu_url"
            ;;
    esac

    info "Downloading QEMU binary..."
    if ! download_qemu_binary_core "$qemu_url" "$QEMU_BIN_DIR" "$arch"; then
        error "Failed to download/extract QEMU binary from: $qemu_url"
        exit 1
    fi

    # Place the located binary at QEMU_BIN_FILE (download_qemu_binary_core
    # leaves it at DLQB_BIN_PATH; caller owns the final move + executable bit).
    if [[ "$DLQB_BIN_PATH" != "$QEMU_BIN_FILE" ]]; then
        mv "$DLQB_BIN_PATH" "$QEMU_BIN_FILE"
    fi
    chmod +x "$QEMU_BIN_FILE"

    local sha256="$DLQB_SHA256"

    # Query Jenkins for build number (community source only)
    local build_number=""
    if [[ "$qemu_url" == *"jenkins.openbmc.org"* ]]; then
        local job_url
        job_url=$(jenkins_job_url_from_url "$qemu_url")
        build_number=$(query_jenkins_build_number "$job_url")
    fi

    write_qemu_binary_manifest "$label" "$arch" "url" "$qemu_url" "$sha256" "$build_number"

    info "QEMU binary ready: $QEMU_BIN_FILE"
    verbose "  SHA256: $sha256"
    if [[ -n "$build_number" ]]; then
        verbose "  Build: #$build_number"
    fi
}

# Dispatcher: route to community (URL download) or custom (local copy) setup
ensure_qemu_binary() {
    local label
    label=$(read_source_label)
    if [[ "$label" == "community" ]]; then
        ensure_qemu_binary_community
    else
        ensure_qemu_binary_custom
    fi
}

# resolve_custom_binary_candidate <input> <arch> <outvar>
# 纯决策(无 IO 副作用、不 exit): custom QEMU binary 路径解析。outvar 编码:
#   ok:<path>          input 是文件, 或目录下含 <arch>
#   err_dir_no_arch    input 是目录但缺 <arch>
#   err_not_file       input 既非目录也非文件
# leaf-pure; 调用者(ensure_qemu_binary_custom)负责交互循环 + exit。
resolve_custom_binary_candidate() {
    local input="$1" arch="$2" out="$3"
    if [[ -d "$input" ]]; then
        local cand="${input%/}/$arch"
        if [[ ! -f "$cand" ]]; then
            printf -v "$out" '%s' "err_dir_no_arch"
            return 0
        fi
        printf -v "$out" '%s' "ok:$cand"
        return 0
    elif [[ ! -f "$input" ]]; then
        printf -v "$out" '%s' "err_not_file"
        return 0
    fi
    printf -v "$out" '%s' "ok:$input"
    return 0
}

# resolve_custom_pcbios_candidate <input> <outvar>
# 纯决策(无 IO 副作用、不 exit): custom QEMU pc-bios 目录解析(ast27x0_bootrom.bin 查找 +
# pc-bios/ 子目录回退)。outvar 编码:
#   ok:<path>        input(或 input/pc-bios)含 ast27x0_bootrom.bin
#   err_not_dir      input 非目录
#   err_no_bootrom   input 是目录但无 ast27x0_bootrom.bin(含 pc-bios/ 回退)
# leaf-pure。
resolve_custom_pcbios_candidate() {
    local input="$1" out="$2"
    if [[ ! -d "$input" ]]; then
        printf -v "$out" '%s' "err_not_dir"
        return 0
    fi
    local cand="$input"
    if [[ ! -f "$cand/ast27x0_bootrom.bin" ]]; then
        if [[ -f "$cand/pc-bios/ast27x0_bootrom.bin" ]]; then
            cand="$cand/pc-bios"
        else
            printf -v "$out" '%s' "err_no_bootrom"
            return 0
        fi
    fi
    printf -v "$out" '%s' "ok:$cand"
    return 0
}

ensure_qemu_binary_custom() {
    derive_qemu_paths

    # Already present and executable?
    if [[ -x "$QEMU_BIN_FILE" ]]; then
        verbose "QEMU binary already exists: $QEMU_BIN_FILE"
        return 0
    fi

    # Need interactive terminal for prompts
    if [[ ! -t 0 ]]; then
        error "QEMU binary not found at $QEMU_BIN_FILE"
        error "Run 'ob start-qemu $MACHINE' in an interactive terminal to set up the binary."
        exit 3
    fi

    mkdir -p "$QEMU_BIN_DIR"

    local arch="${QEMU_LAUNCH_SYSTEM_NAME:-qemu-system-arm}"

    # --- Step 1: QEMU binary ---
    echo ""
    info "QEMU binary for custom source not found."
    echo ""

    local input_binary=""
    local resolved_binary_path=""
    while true; do
        local pfp_rc=0
        prompt_for_absolute_path "Enter absolute path to QEMU binary ($arch)" || pfp_rc=$?
        if [[ "$pfp_rc" -ne 0 ]]; then
            exit 1
        fi
        input_binary="$PROMPT_PATH_RESULT"

        resolved_binary_path="$input_binary"
        if [[ -d "$input_binary" ]]; then
            resolved_binary_path="${input_binary%/}/$arch"
            if [[ ! -f "$resolved_binary_path" ]]; then
                error "Directory does not contain $arch: $input_binary"
                continue
            fi
        elif [[ ! -f "$input_binary" ]]; then
            error "File not found: $input_binary"
            continue
        fi

        break
    done

    cp "$resolved_binary_path" "$QEMU_BIN_FILE"
    chmod +x "$QEMU_BIN_FILE"
    info "QEMU binary copied: $QEMU_BIN_FILE"

    local input_pcbios=""
    local resolved_pcbios_path=""
    local target_pcbios="$QEMU_BIN_DIR/pc-bios"
    if [[ "$QEMU_LAUNCH_REQUIRES_PCBIOS" == "yes" ]]; then
        echo ""

        while true; do
            local pfp_rc=0
            prompt_for_absolute_path "Enter absolute path to pc-bios directory" || pfp_rc=$?
            if [[ "$pfp_rc" -ne 0 ]]; then
                exit 1
            fi
            input_pcbios="$PROMPT_PATH_RESULT"

            if [[ ! -d "$input_pcbios" ]]; then
                error "Directory not found: $input_pcbios"
                continue
            fi

            resolved_pcbios_path="$input_pcbios"
            if [[ ! -f "$resolved_pcbios_path/ast27x0_bootrom.bin" ]]; then
                if [[ -f "$resolved_pcbios_path/pc-bios/ast27x0_bootrom.bin" ]]; then
                    resolved_pcbios_path="$resolved_pcbios_path/pc-bios"
                else
                    error "Directory does not contain ast27x0_bootrom.bin: $input_pcbios"
                    error "Provide the pc-bios directory itself, or a QEMU root directory that contains pc-bios/."
                    continue
                fi
            fi

            break
        done

        if [[ -d "$target_pcbios" ]]; then
            rm -rf "$target_pcbios"
        fi
        cp -r "$resolved_pcbios_path" "$target_pcbios"
        info "pc-bios directory copied: $target_pcbios"
    elif [[ -d "$target_pcbios" ]]; then
        verbose "Keeping existing pc-bios directory for non-AST2700 machine: $target_pcbios"
    fi

    local sha256=""
    sha256=$(sha256sum "$QEMU_BIN_FILE" | awk '{print $1}')

    write_qemu_binary_manifest "custom" "$arch" "binary_source" "$resolved_binary_path" "$sha256"
    if [[ -n "$resolved_pcbios_path" ]]; then
        write_qemu_pcbios_manifest "custom" "$resolved_pcbios_path"
    fi

    info "QEMU binary setup complete."
    verbose "  Binary : $QEMU_BIN_FILE"
    verbose "  SHA256 : $sha256"
}


#
# QEMU searches for firmware files in this order (with -L <dir>):
#   1. <cwd>/<name>
#   2. <dir>/<name>                        (the -L path)
#   3. <QEMU_BIN_DIR>/../share/qemu-firmware/<name>
#   4. <QEMU_BIN_DIR>/../share/qemu/<name>
#
# Strategy:
# Ensure QEMU firmware directory (pc-bios) is available.
# For custom QEMU, the user provides pc-bios/ during binary setup.
# For community QEMU, pc-bios/ may or may not exist — QEMU will fall back
# to its built-in firmware paths.
ensure_qemu_firmware() {
    QEMU_PCBIOS_DIR="$QEMU_BIN_DIR/pc-bios"

    if [[ "$QEMU_LAUNCH_REQUIRES_PCBIOS" != "yes" ]]; then
        return 0
    fi

    if [[ ! -d "$QEMU_PCBIOS_DIR" ]]; then
        warn "QEMU pc-bios directory not found: $QEMU_PCBIOS_DIR"
        warn "Custom QEMU requires pc-bios/. Ensure it was provided during binary setup."
        return 0
    fi

    require_path "$QEMU_PCBIOS_DIR/ast27x0_bootrom.bin" "AST2700 bootrom" "Provide the pc-bios directory itself, or a QEMU root directory that contains pc-bios/." 3
}

