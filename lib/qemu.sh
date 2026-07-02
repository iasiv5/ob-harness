#!/usr/bin/env bash
# lib/qemu.sh — ob §4 QEMU(binary/firmware/ports/SoC/pid/hostkey),被 ob source。纯函数定义集。


derive_qemu_paths() {
    local label arch
    label=$(read_source_label)
    arch="${QEMU_LAUNCH_SYSTEM_NAME:-qemu-system-arm}"
    QEMU_BIN_DIR="$WORKSPACE_DIR/qemu-bin/$label"
    QEMU_BIN_FILE="$QEMU_BIN_DIR/$arch"
    QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
    QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
}

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

reset_qemu_launch_profile() {
    QEMU_LAUNCH_SOC_TYPE=""
    QEMU_LAUNCH_SOC_SOURCE=""
    QEMU_LAUNCH_SOC_CONFIDENCE=""
    QEMU_LAUNCH_SYSTEM_NAME=""
    QEMU_LAUNCH_MACHINE_NAME=""
    QEMU_LAUNCH_MACHINE_NAME_SOURCE=""
    QEMU_LAUNCH_MEM_FLAG=""
    QEMU_LAUNCH_REQUIRES_PCBIOS=""
    QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB=""
    QEMU_LAUNCH_BOOTLOADER_UBOOT_DTB=""
    QEMU_LAUNCH_BOOTLOADER_BL31=""
    QEMU_LAUNCH_BOOTLOADER_OPTEE=""
    QEMU_LAUNCH_BOOTLOADER_UBOOT_SIZE=""
}

qemu_launch_profile_apply_system_name() {
    local system_name="$1"
    local evidence_source="${2:-bitbake}"

    case "$system_name" in
        qemu-system-arm)
            QEMU_LAUNCH_SYSTEM_NAME="$system_name"
            qemu_launch_profile_record_soc_evidence "ast2600" "$evidence_source" "strong"
            ;;
        qemu-system-aarch64)
            QEMU_LAUNCH_SYSTEM_NAME="$system_name"
            qemu_launch_profile_record_soc_evidence "ast2700" "$evidence_source" "strong"
            ;;
        "")
            ;;
        *)
            warn "Unknown QB_SYSTEM_NAME '$system_name' — will use QEMU launch profile fallback evidence."
            QEMU_LAUNCH_SYSTEM_NAME=""
            ;;
    esac
}

qemu_launch_profile_extract_bitbake_var() {
    local bitbake_output="$1"
    local var_name="$2"
    local raw=""

    raw=$(awk -v name="$var_name" '
        index($0, name "=") == 1 {
            print substr($0, length(name) + 2)
            exit 0
        }
    ' <<< "$bitbake_output")

    raw=$(trim_whitespace "$raw")
    raw="${raw#\"}"; raw="${raw%\"}"
    raw="${raw#\'}"; raw="${raw%\'}"
    printf '%s\n' "$raw"
}

qemu_launch_profile_record_soc_evidence() {
    local soc_type="$1"
    local source="$2"
    local confidence="$3"

    [[ -z "$soc_type" ]] && return 0
    if [[ -n "$QEMU_LAUNCH_SOC_TYPE" && "$QEMU_LAUNCH_SOC_TYPE" != "$soc_type" ]]; then
        error "SoC type conflict: $QEMU_LAUNCH_SOC_SOURCE says '$QEMU_LAUNCH_SOC_TYPE', $source says '$soc_type'"
        error "Resolve the mismatch before continuing."
        exit 1
    fi
    if [[ -z "$QEMU_LAUNCH_SOC_TYPE" ]]; then
        QEMU_LAUNCH_SOC_TYPE="$soc_type"
        QEMU_LAUNCH_SOC_SOURCE="$source"
        QEMU_LAUNCH_SOC_CONFIDENCE="$confidence"
    fi
}

qemu_launch_profile_apply_machine_name() {
    local qb_machine_name="$1"
    local machine_name="$2"
    local evidence_source="${3:-bitbake}"

    if [[ -n "$qb_machine_name" ]]; then
        QEMU_LAUNCH_MACHINE_NAME="$qb_machine_name"
        QEMU_LAUNCH_MACHINE_NAME_SOURCE="$evidence_source"
        return 0
    fi

    local prefix="${machine_name%%-*}"
    if [[ "$prefix" == "$machine_name" ]]; then
        error "Cannot determine QEMU machine name for machine '$machine_name'."
        error "Define QB_MACHINE in the machine conf, then retry."
        exit 3
    fi

    QEMU_LAUNCH_MACHINE_NAME="${prefix}-bmc"
    QEMU_LAUNCH_MACHINE_NAME_SOURCE="legacy-name"
    warn "QB_MACHINE not defined; derived QEMU machine name from machine name: $QEMU_LAUNCH_MACHINE_NAME"
}

qemu_binary_supports_machine() {
    local machine_name="$1"

    [[ -n "$machine_name" && -x "$QEMU_BIN_FILE" ]] || return 1
    "$QEMU_BIN_FILE" -machine help 2>/dev/null | awk -v name="$machine_name" '$1 == name { found = 1; exit } END { exit(found ? 0 : 1) }'
}

qemu_launch_profile_apply_binary_machine_override() {
    local prefix="${MACHINE%%-*}"
    local candidate=""
    local previous=""
    local previous_source=""

    [[ -n "$QEMU_LAUNCH_MACHINE_NAME" ]] || return 0
    [[ "$prefix" != "$MACHINE" ]] || return 0

    candidate="${prefix}-bmc"
    [[ "$candidate" != "$QEMU_LAUNCH_MACHINE_NAME" ]] || return 0
    qemu_binary_supports_machine "$candidate" || return 0

    previous="$QEMU_LAUNCH_MACHINE_NAME"
    previous_source="$QEMU_LAUNCH_MACHINE_NAME_SOURCE"
    QEMU_LAUNCH_MACHINE_NAME="$candidate"
    QEMU_LAUNCH_MACHINE_NAME_SOURCE="qemu-binary"
    info "Using QEMU binary-supported machine '$candidate' (overrides '$previous' from $previous_source)."
}

qemu_launch_profile_uses_external_ast2700_loaders() {
    [[ "$QEMU_LAUNCH_SOC_TYPE" == "ast2700" ]] || return 1

    case "$QEMU_LAUNCH_MACHINE_NAME" in
        ast2700a1-evb|ast2700a2-evb|ast2700-evb)
            return 0
            ;;
    esac

    return 1
}

qemu_launch_profile_system_name_for_soc() {
    local soc_type="$1"

    case "$soc_type" in
        ast2600) echo "qemu-system-arm" ;;
        ast2700) echo "qemu-system-aarch64" ;;
    esac
}

qemu_launch_profile_apply_machine_conf() {
    local machine_conf="$1"

    [[ -f "$machine_conf" ]] || return 0
    if machine_conf_chain_contains "$machine_conf" 'ast2700-sdk\.inc|ast2700[^[:space:]#]*\.inc|aspeed-g7'; then
        qemu_launch_profile_record_soc_evidence "ast2700" "machine-conf" "strong"
    elif machine_conf_chain_contains "$machine_conf" 'ast2600[^[:space:]#]*\.inc|ast2600-default|aspeed-g6'; then
        qemu_launch_profile_record_soc_evidence "ast2600" "machine-conf" "strong"
    fi
}

qemu_launch_profile_find_machine_conf() {
    find "$OPENBMC_DIR" -path "*/conf/machine/$MACHINE.conf" -type f -print -quit 2>/dev/null || true
}

qemu_launch_profile_deploy_evidence() {
    local deploy_dir="$BUILD_DIR/tmp/deploy/images/$MACHINE"
    local has_uboot_nodtb=0
    local has_uboot_dtb=0
    local has_bl31=0
    local has_optee=0

    QEMU_PROFILE_DEPLOY_HAS_STATIC_MTD="no"
    QEMU_PROFILE_DEPLOY_AST2700_EVIDENCE="none"

    [[ -d "$deploy_dir" ]] || return 0

    if compgen -G "$deploy_dir/*.static.mtd" >/dev/null; then
        QEMU_PROFILE_DEPLOY_HAS_STATIC_MTD="yes"
    fi
    [[ -f "$deploy_dir/u-boot-nodtb.bin" ]] && has_uboot_nodtb=1
    [[ -f "$deploy_dir/u-boot.dtb" ]] && has_uboot_dtb=1
    [[ -f "$deploy_dir/bl31.bin" ]] && has_bl31=1
    [[ -f "$deploy_dir/optee/tee-raw.bin" ]] && has_optee=1

    local count=$((has_uboot_nodtb + has_uboot_dtb + has_bl31 + has_optee))
    if [[ "$count" -eq 4 ]]; then
        QEMU_PROFILE_DEPLOY_AST2700_EVIDENCE="explicit"
    elif [[ "$count" -gt 0 ]]; then
        QEMU_PROFILE_DEPLOY_AST2700_EVIDENCE="partial"
    fi
}

qemu_launch_profile_resolve_ast2700_bootloaders() {
    local deploy_dir="$BUILD_DIR/tmp/deploy/images/$MACHINE"

    QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB="$deploy_dir/u-boot-nodtb.bin"
    QEMU_LAUNCH_BOOTLOADER_UBOOT_DTB="$deploy_dir/u-boot.dtb"
    QEMU_LAUNCH_BOOTLOADER_BL31="$deploy_dir/bl31.bin"
    QEMU_LAUNCH_BOOTLOADER_OPTEE="$deploy_dir/optee/tee-raw.bin"

    local -a missing=()
    [[ -f "$QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB" ]] || missing+=("u-boot-nodtb.bin ($QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB)")
    [[ -f "$QEMU_LAUNCH_BOOTLOADER_UBOOT_DTB" ]] || missing+=("u-boot.dtb ($QEMU_LAUNCH_BOOTLOADER_UBOOT_DTB)")
    [[ -f "$QEMU_LAUNCH_BOOTLOADER_BL31" ]] || missing+=("bl31.bin ($QEMU_LAUNCH_BOOTLOADER_BL31)")
    [[ -f "$QEMU_LAUNCH_BOOTLOADER_OPTEE" ]] || missing+=("optee/tee-raw.bin ($QEMU_LAUNCH_BOOTLOADER_OPTEE)")

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "AST2700 bootloader files are missing for machine '$MACHINE'."
        local missing_file
        for missing_file in "${missing[@]}"; do
            error "  Missing: $missing_file"
        done
        error "Run 'ob build $MACHINE' first."
        exit 3
    fi

    QEMU_LAUNCH_BOOTLOADER_UBOOT_SIZE=$(stat --format=%s -L "$QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB" 2>/dev/null || echo "0")
}

qemu_launch_profile_find_qemuboot_conf() {
    local deploy_dir="$BUILD_DIR/tmp/deploy/images/$MACHINE"
    local newest=""
    local newest_ts=0
    local conf

    [[ -d "$deploy_dir" ]] || return 0
    for conf in "$deploy_dir"/*.qemuboot.conf; do
        [[ -f "$conf" ]] || continue
        local ts
        ts=$(stat --format=%Y "$conf" 2>/dev/null || echo 0)
        if (( ts >= newest_ts )); then
            newest_ts="$ts"
            newest="$conf"
        fi
    done

    printf '%s\n' "$newest"
}

qemu_launch_profile_extract_qemuboot_var() {
    local qemuboot_conf="$1"
    local var_name="$2"
    local raw=""

    raw=$(awk -F= -v name="$var_name" '
        /^[[:space:]]*(#|$)/ { next }
        {
            key = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == name) {
                sub(/^[^=]*=/, "")
                print
                exit 0
            }
        }
    ' "$qemuboot_conf")

    trim_whitespace "$raw"
}

resolve_qemu_launch_profile() {
    local machine_name="${1:-$MACHINE}"
    MACHINE="$machine_name"
    reset_qemu_launch_profile

    require_path "$BUILD_DIR" "Build directory" "Run 'ob init $MACHINE' first." 3
    require_path "$OPENBMC_DIR/setup" "OpenBMC setup script" "Run 'ob init' first." 3

    local qb_machine_raw
    local qb_mem_raw
    local qb_system_raw
    local qb_source="bitbake"
    local qemuboot_conf=""
    qemuboot_conf=$(qemu_launch_profile_find_qemuboot_conf)
    if [[ -n "$qemuboot_conf" ]]; then
        info "Resolving QEMU launch profile from qemuboot.conf..."
        verbose "  qemuboot.conf → $qemuboot_conf"
        qb_source="qemuboot"
        qb_machine_raw=$(qemu_launch_profile_extract_qemuboot_var "$qemuboot_conf" qb_machine)
        qb_mem_raw=$(qemu_launch_profile_extract_qemuboot_var "$qemuboot_conf" qb_mem)
        qb_system_raw=$(qemu_launch_profile_extract_qemuboot_var "$qemuboot_conf" qb_system_name)
    else
        info "Resolving QEMU launch profile via BitBake (this can take a while)..."
        local bitbake_output
        local bitbake_rc=0
        bitbake_output=$(bitbake_env_query_vars "$MACHINE" "$BUILD_DIR") || bitbake_rc=$?
        if [[ "$bitbake_rc" -ne 0 || -z "$bitbake_output" ]]; then
            # An empty `bitbake -e` means the build environment itself is unhealthy,
            # not merely a missing QB input that profile fallback can repair.
            error "Failed to run 'bitbake -e' for machine '$MACHINE'."
            error "Ensure the build environment is healthy (try 'ob init $MACHINE' if unsure)."
            exit 1
        fi

        qb_machine_raw=$(qemu_launch_profile_extract_bitbake_var "$bitbake_output" QB_MACHINE)
        qb_mem_raw=$(qemu_launch_profile_extract_bitbake_var "$bitbake_output" QB_MEM)
        qb_system_raw=$(qemu_launch_profile_extract_bitbake_var "$bitbake_output" QB_SYSTEM_NAME)
    fi

    local qb_machine_name=""
    if [[ -n "$qb_machine_raw" ]]; then
        qb_machine_name=$(echo "$qb_machine_raw" | sed 's/^-machine[[:space:]]*//' | awk '{print $1}')
    fi

    QEMU_LAUNCH_MEM_FLAG="$qb_mem_raw"
    qemu_launch_profile_apply_system_name "$qb_system_raw" "$qb_source"

    if [[ "$qb_source" != "qemuboot" || -z "$QEMU_LAUNCH_SOC_TYPE" ]]; then
        local machine_conf=""
        machine_conf=$(qemu_launch_profile_find_machine_conf)
        qemu_launch_profile_apply_machine_conf "$machine_conf"
    fi

    qemu_launch_profile_deploy_evidence
    if [[ "$QEMU_PROFILE_DEPLOY_AST2700_EVIDENCE" == "explicit" ]]; then
        qemu_launch_profile_record_soc_evidence "ast2700" "deploy" "deploy"
    elif [[ "$QEMU_PROFILE_DEPLOY_AST2700_EVIDENCE" == "partial" && "$QEMU_LAUNCH_SOC_TYPE" == "ast2600" ]]; then
        warn "Found partial AST2700 deploy evidence, but strong evidence selects AST2600; ignoring stale deploy artifacts."
    fi

    if [[ -z "$QEMU_LAUNCH_SOC_TYPE" ]]; then
        if [[ "$QEMU_PROFILE_DEPLOY_AST2700_EVIDENCE" == "partial" ]]; then
            error "Cannot determine SoC type for machine '$MACHINE'."
            error "Define QB_SYSTEM_NAME or include an ast2600/ast2700 machine conf fragment, then retry."
            exit 3
        elif [[ "$QEMU_PROFILE_DEPLOY_HAS_STATIC_MTD" == "yes" ]]; then
            QEMU_LAUNCH_SOC_TYPE="ast2600"
            QEMU_LAUNCH_SOC_SOURCE="legacy-deploy"
            QEMU_LAUNCH_SOC_CONFIDENCE="legacy"
            warn "Falling back to legacy AST2600 assumption because deploy image exists."
        else
            error "Cannot determine SoC type for machine '$MACHINE'."
            error "Define QB_SYSTEM_NAME or include an ast2600/ast2700 machine conf fragment, then retry."
            exit 3
        fi
    fi

    if [[ -z "$QEMU_LAUNCH_SYSTEM_NAME" ]]; then
        QEMU_LAUNCH_SYSTEM_NAME=$(qemu_launch_profile_system_name_for_soc "$QEMU_LAUNCH_SOC_TYPE")
    fi
    qemu_launch_profile_apply_machine_name "$qb_machine_name" "$MACHINE" "$qb_source"

    if [[ "$QEMU_LAUNCH_SOC_TYPE" == "ast2700" ]]; then
        QEMU_LAUNCH_REQUIRES_PCBIOS="yes"
        qemu_launch_profile_resolve_ast2700_bootloaders
    else
        QEMU_LAUNCH_REQUIRES_PCBIOS="no"
    fi

    verbose "  QEMU_LAUNCH_SOC_TYPE → $QEMU_LAUNCH_SOC_TYPE"
    verbose "  QEMU_LAUNCH_SOC_SOURCE → $QEMU_LAUNCH_SOC_SOURCE"
    verbose "  QEMU_LAUNCH_SOC_CONFIDENCE → $QEMU_LAUNCH_SOC_CONFIDENCE"
    verbose "  QEMU_LAUNCH_SYSTEM_NAME → $QEMU_LAUNCH_SYSTEM_NAME"
    verbose "  QEMU_LAUNCH_MACHINE_NAME → $QEMU_LAUNCH_MACHINE_NAME"
    verbose "  QEMU_LAUNCH_MACHINE_NAME_SOURCE → $QEMU_LAUNCH_MACHINE_NAME_SOURCE"
    verbose "  QEMU_LAUNCH_MEM_FLAG → $QEMU_LAUNCH_MEM_FLAG"
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
check_jenkins_update() {
    local manifest="${QEMU_BIN_FILE}.manifest"

    # ── Guard: manifest must exist ──
    [[ -f "$manifest" ]] || return 0

    # ── Guard: build_number must be present ──
    local local_build
    local_build=$(read_kv_field "$manifest" build_number 2>/dev/null) || local_build=""
    [[ -z "$local_build" ]] && return 0

    # ── Guard: URL must be Jenkins ──
    local manifest_url
    manifest_url=$(read_kv_field "$manifest" url 2>/dev/null) || manifest_url=""
    [[ "$manifest_url" != *"jenkins.openbmc.org"* ]] && return 0

    # ── Guard: extract job URL ──
    local job_url
    job_url=$(echo "$manifest_url" | sed -E 's|/lastSuccessfulBuild/.*||; s|/artifact/.*||')

    # ── Query Jenkins ──
    local remote_build
    remote_build=$(query_jenkins_build_number "$job_url")
    [[ -z "$remote_build" ]] && return 0  # Jenkins unreachable

    # ── Same version? ──
    if [[ "$remote_build" == "$local_build" ]]; then
        verbose "QEMU binary is up to date (build #${local_build})."
        return 0
    fi

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

    if [[ -n "${OB_QEMU_BINARY_URL:-}" ]]; then
        qemu_url="$OB_QEMU_BINARY_URL"
        write_qemu_url_config "$label" "$arch" "$qemu_url"
    else
        qemu_url="$(read_qemu_url_config "$label" "$arch")"
    fi

    if [[ -z "$qemu_url" ]]; then
        if [[ "$label" == "community" && "$arch" == "qemu-system-arm" ]]; then
            qemu_url="https://jenkins.openbmc.org/job/latest-qemu-x86/lastSuccessfulBuild/artifact/qemu/build/qemu-system-arm"
            write_qemu_url_config "$label" "$arch" "$qemu_url"
            info "Using OpenBMC Jenkins default QEMU URL (recorded in $QEMU_URL_CONFIG_FILE)"
        else
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
        fi
    fi

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
        job_url=$(echo "$qemu_url" | sed -E 's|/lastSuccessfulBuild/.*||; s|/artifact/.*||')
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

build_qemu_cmd() {
    local image_file="$1"
    local ssh_port="$2"
    local redfish_port="$3"
    local ipmi_port="$4"
    local http_port="$5"
    local serial_log="$6"
    local serial_sock="$7"

    # Port forwarding string
    local hostfwd_args=""
    hostfwd_args+="hostfwd=tcp::${ssh_port}-:22,"
    hostfwd_args+="hostfwd=tcp::${redfish_port}-:443,"
    hostfwd_args+="hostfwd=udp::${ipmi_port}-:623"
    if [[ -n "$http_port" ]]; then
        hostfwd_args+=",hostfwd=tcp::${http_port}-:80"
    fi

    # Start building command array
    QEMU_CMD=(
        "$QEMU_BIN_FILE"
        "-machine" "$QEMU_LAUNCH_MACHINE_NAME"
    )

    # SoC-specific parameters
    if qemu_launch_profile_uses_external_ast2700_loaders; then
        QEMU_CMD+=(
            "-device" "loader,force-raw=on,addr=0x400000000,file=$QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB"
            "-device" "loader,force-raw=on,addr=$((0x400000000 + QEMU_LAUNCH_BOOTLOADER_UBOOT_SIZE)),file=$QEMU_LAUNCH_BOOTLOADER_UBOOT_DTB"
            "-device" "loader,force-raw=on,addr=0x430000000,file=$QEMU_LAUNCH_BOOTLOADER_BL31"
            "-device" "loader,force-raw=on,addr=0x430080000,file=$QEMU_LAUNCH_BOOTLOADER_OPTEE"
            "-device" "loader,cpu-num=0,addr=0x430000000"
            "-device" "loader,cpu-num=1,addr=0x430000000"
            "-device" "loader,cpu-num=2,addr=0x430000000"
            "-device" "loader,cpu-num=3,addr=0x430000000"
            "-smp" "4"
        )
    fi
    # AST2600: bootloader is embedded in MTD image, no extra params needed

    # QB_MEM (-m flag): include only if resolved from bitbake
    if [[ -n "$QEMU_LAUNCH_MEM_FLAG" ]]; then
        local -a qemu_mem_args=()
        read -r -a qemu_mem_args <<< "$QEMU_LAUNCH_MEM_FLAG"
        QEMU_CMD+=("${qemu_mem_args[@]}")
    fi

    # Common tail: drive, network, serial, display
    QEMU_CMD+=(
        "-drive" "file=$image_file,format=raw,if=mtd"
        "-net" "nic,netdev=net0"
        "-netdev" "user,id=net0,$hostfwd_args"
        "-chardev" "socket,id=serial0,path=$serial_sock,server=on,wait=off,logfile=$serial_log"
        "-serial" "chardev:serial0"
        "-serial" "null"
        "-monitor" "none"
        "-display" "none"
    )
    if [[ "$QEMU_LAUNCH_REQUIRES_PCBIOS" == "yes" && -d "$QEMU_PCBIOS_DIR" ]]; then
        QEMU_CMD+=("-L" "$QEMU_PCBIOS_DIR")
    fi
    QEMU_CMD+=("-daemonize")
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

resolve_machine_conf_include() {
    local current_file="$1"
    local include_spec="$2"

    if [[ -z "$include_spec" ]]; then
        return 1
    fi

    if [[ "$include_spec" == /* && -f "$include_spec" ]]; then
        echo "$include_spec"
        return 0
    fi

    local layer_root="${current_file%%/conf/*}"
    if [[ -n "$layer_root" && -f "$layer_root/$include_spec" ]]; then
        echo "$layer_root/$include_spec"
        return 0
    fi

    find "$OPENBMC_DIR" -path "*/$include_spec" -type f -print -quit 2>/dev/null
}

machine_conf_chain_contains() {
    local start_file="$1"
    local pattern="$2"

    [[ -f "$start_file" ]] || return 1

    local -a queue=("$start_file")
    local -a seen=()

    while [[ ${#queue[@]} -gt 0 ]]; do
        local current="${queue[0]}"
        queue=("${queue[@]:1}")

        [[ -f "$current" ]] || continue

        local canonical=""
        canonical=$(readlink -f "$current" 2>/dev/null || echo "$current")

        local visited=0
        local seen_file
        for seen_file in "${seen[@]}"; do
            if [[ "$seen_file" == "$canonical" ]]; then
                visited=1
                break
            fi
        done
        if [[ "$visited" -eq 1 ]]; then
            continue
        fi
        seen[${#seen[@]}]="$canonical"

        if grep -Eq "$pattern" "$current" 2>/dev/null; then
            return 0
        fi

        while IFS= read -r include_spec; do
            local resolved_include=""
            resolved_include=$(resolve_machine_conf_include "$current" "$include_spec")
            if [[ -n "$resolved_include" ]]; then
                queue+=("$resolved_include")
            fi
        done < <(
            sed -nE 's/^[[:space:]]*(require|include)[[:space:]]+([^[:space:]#]+).*$/\2/p' "$current" 2>/dev/null
        )
    done

    return 1
}

check_ports_available() {
    local -a port_args=("$@")
    local -a conflicts=()

    local i
    for (( i=0; i<${#port_args[@]}; i+=2 )); do
        local proto="${port_args[$i]}"   # "tcp" or "udp"
        local port="${port_args[$((i+1))]}"

        local occupants=""
        occupants=$(get_port_occupants "$proto" "$port")

        if [[ -n "$occupants" ]]; then
            local pid_info
            pid_info=$(echo "$occupants" | head -1 | grep -oP 'pid=\K[0-9]+' | head -1 || echo "?")
            conflicts+=("$proto $port — used by process $pid_info")
        fi
    done

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        echo ""
        error "Port(s) already in use:"
        local c
        for c in "${conflicts[@]}"; do
            echo -e "  ${RED}$c${NC}"
        done
        echo ""
        echo "  Set a different port:"
        echo "    ob start-qemu $MACHINE --ssh-port <port> --redfish-port <port> --ipmi-port <port>"
        echo "  Or export:"
        echo "    export OB_QEMU_SSH_PORT=<port>"
        echo "    export OB_QEMU_REDFISH_PORT=<port>"
        echo "    export OB_QEMU_IPMI_PORT=<port>"
        exit 3
    fi
}

get_port_occupants() {
    local proto="$1"
    local port="$2"

    if [[ "$proto" == "tcp" ]]; then
        ss -tlnpH "sport = :$port" 2>/dev/null | grep -v "^State" || true
    else
        ss -ulnpH "sport = :$port" 2>/dev/null | grep -v "^State" || true
    fi
}

prompt_for_available_port() {
    local port_var_name="$1"
    local service_label="$2"
    local proto="$3"
    shift 3

    local -n port_ref="$port_var_name"
    local -a reserved_ports=("$@")

    while true; do
        local reserved_port=""
        local candidate
        for candidate in "${reserved_ports[@]}"; do
            if [[ -n "$candidate" && "$candidate" == "$port_ref" ]]; then
                reserved_port="$candidate"
                break
            fi
        done

        local occupants=""
        occupants=$(get_port_occupants "$proto" "$port_ref")

        if [[ -z "$reserved_port" && -z "$occupants" ]]; then
            return 0
        fi

        if [[ ! -t 0 ]]; then
            return 1
        fi

        echo ""
        if [[ -n "$reserved_port" ]]; then
            warn "$service_label port $port_ref/$proto conflicts with another requested $proto port."
        else
            local pid_info
            pid_info=$(echo "$occupants" | head -1 | grep -oP 'pid=\K[0-9]+' | head -1 || echo "?")
            warn "$service_label port $port_ref/$proto is already in use by process $pid_info."
        fi

        local input_port=""
        if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Enter new $service_label $proto port: ")" input_port; then
            error "Unable to read port from stdin."
            exit 1
        fi
        input_port=$(trim_whitespace "$input_port")

        if [[ -z "$input_port" ]]; then
            error "$service_label port cannot be empty."
            continue
        fi

        if [[ ! "$input_port" =~ ^[0-9]+$ ]]; then
            error "$service_label port must be a number: $input_port"
            continue
        fi

        if (( input_port < 1 || input_port > 65535 )); then
            error "$service_label port must be between 1 and 65535: $input_port"
            continue
        fi

        port_ref="$input_port"
    done
}

resolve_qemu_ports_interactive() {
    local -n ssh_ref="$1"
    local -n redfish_ref="$2"
    local -n ipmi_ref="$3"
    local -n http_ref="$4"

    if [[ ! -t 0 ]]; then
        return 0
    fi

    if ! prompt_for_available_port ssh_ref "SSH" "tcp" "$redfish_ref" "$http_ref"; then
        return 1
    fi
    if ! prompt_for_available_port redfish_ref "Redfish" "tcp" "$ssh_ref" "$http_ref"; then
        return 1
    fi
    if ! prompt_for_available_port ipmi_ref "IPMI" "udp"; then
        return 1
    fi
    if [[ -n "$http_ref" ]]; then
        if ! prompt_for_available_port http_ref "HTTP" "tcp" "$ssh_ref" "$redfish_ref"; then
            return 1
        fi
    fi

    return 0
}

read_pid_file() {
    if [[ ! -f "$QEMU_PID_FILE" ]]; then
        return 1
    fi

    PIDFILE_PID=""
    PIDFILE_USER=""
    PIDFILE_MACHINE=""
    PIDFILE_BINARY=""
    PIDFILE_STARTED_AT=""
    PIDFILE_SSH_PORT=""
    PIDFILE_REDFISH_PORT=""
    PIDFILE_IPMI_PORT=""
    PIDFILE_HTTP_PORT=""
    PIDFILE_SERIAL_LOG=""

    while IFS='=' read -r key value; do
        case "$key" in
            pid)          PIDFILE_PID="$value" ;;
            user)         PIDFILE_USER="$value" ;;
            machine)      PIDFILE_MACHINE="$value" ;;
            binary)       PIDFILE_BINARY="$value" ;;
            started_at)   PIDFILE_STARTED_AT="$value" ;;
            ssh_port)     PIDFILE_SSH_PORT="$value" ;;
            redfish_port) PIDFILE_REDFISH_PORT="$value" ;;
            ipmi_port)    PIDFILE_IPMI_PORT="$value" ;;
            http_port)    PIDFILE_HTTP_PORT="$value" ;;
            serial_log)   PIDFILE_SERIAL_LOG="$value" ;;
        esac
    done < "$QEMU_PID_FILE"

    return 0
}

validate_pid() {
    # return 0=running&match, 1=exited, 2=pid recycled — diagnostic only, NOT part of exit-code protocol
    local pid="$1"
    local expected_binary="$2"
    local expected_machine="$3"

    if [[ ! -d "/proc/$pid" ]]; then
        return 1  # Process exited
    fi

    local cmdline
    cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || true)

    if [[ "$cmdline" != *"$expected_binary"* ]] || [[ "$cmdline" != *"$expected_machine"* ]]; then
        return 2  # PID recycled — different process
    fi

    return 0  # Running and matches
}

# Parse "Offending <TYPE> key in <file>:<line>" from an ssh changed-key stderr blob.
# Stdout: "<file> <line>" on match; empty otherwise. Always exits 0 (pure parser,
# safe under `set -euo pipefail`).
parse_hostkey_offending() {
    local stderr_blob="$1"
    local re='Offending [A-Z0-9]+ key in ([^:]+):([0-9]+)'
    if [[ "$stderr_blob" =~ $re ]]; then
        printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
}

# Detect a stale SSH host key for [localhost]:<port> in the user's real
# known_hosts and offer to clear it. Runs ONE mirror ssh probe (BatchMode, no
# password): host-key check happens before auth, so no password is needed.
# Silent unless a *changed*-key conflict is found. Safe under `set -euo pipefail`.
# Args: $1 = ssh_port
check_ssh_hostkey_conflict() {
    local port="$1"
    [[ -z "$port" ]] && return 0

    local target="[localhost]:${port}"

    # ── Local pre-screen: does known_hosts hold an entry for the target? ──
    # Pure local file read — independent of sshd / network. Silent if none.
    local kh_probe=""
    kh_probe=$(ssh-keygen -F "$target" 2>/dev/null || true)
    if [[ -z "$kh_probe" ]]; then
        return 0  # No entry → nothing can conflict; stay silent.
    fi

    # ── Probe sshd to confirm whether the entry is actually stale ──
    # Mirror the user's manual ssh: real known_hosts, default strict checking.
    # Wrap in 'if' so set -e does not propagate ssh's non-zero exit.
    local probe_out=""
    if ! probe_out=$(ssh -o BatchMode=yes -o ConnectTimeout=3 \
                        -p "$port" root@localhost true 2>&1); then
        :
    fi

    # Track A — cryptographically confirmed stale: sshd up, key mismatch.
    if [[ "$probe_out" == *"REMOTE HOST IDENTIFICATION HAS CHANGED"* ]]; then
        _clear_stale_hostkey_menu "$target" "$probe_out"
        return 0
    fi

    # Entry still matches the live key (sshd up, probe reached auth). No cleanup.
    if [[ "$probe_out" == *"Permission denied"* ]]; then
        verbose "Host key for ${target} still matches current image; no cleanup needed."
        return 0
    fi

    # Track B — sshd not reachable / status unknown. Entry exists but we can't
    # confirm it's stale. Warn + give the clear command; do NOT auto-delete —
    # the entry may still be valid if the user only re-ran start-qemu (no rebuild).
    warn "Found a known_hosts entry for ${target}, but BMC sshd is not reachable yet — cannot confirm whether it's stale."
    if [[ "$probe_out" == *"Connection refused"* || "$probe_out" == *"Connection timed out"* ]]; then
        warn "BMC sshd not ready on port ${port} (still booting)."
    fi
    echo "    If you just rebuilt the image, this entry is stale and manual ssh will report a host key error."
    echo "    Clear it yourself when ready:"
    echo "      ssh-keygen -R '${target}'"
    echo "    (ob won't auto-delete — only you know whether you rebuilt the image.)"
    return 0
}

# Interactive menu to clear a cryptographically-confirmed stale SSH host key.
# Only called once ssh has proved the known_hosts entry mismatches the live key,
# so removal is justified by proof (zero risk of deleting a still-valid entry).
# Args: $1 = target ("[localhost]:<port>"), $2 = ssh probe stderr blob.
_clear_stale_hostkey_menu() {
    local target="$1" probe_out="$2"
    local parsed="" file="" line="" display_cmd="" confirm=""

    parsed=$(parse_hostkey_offending "$probe_out")
    if [[ -n "$parsed" ]]; then
        read -r file line <<< "$parsed"
    fi

    warn "Stale SSH host key for ${target} in your known_hosts (image rebuilt -> host key regenerated); manual ssh will be rejected."
    if [[ -n "$file" && -n "$line" ]]; then
        echo "    Offending entry (${file}:${line}):"
        sed -n "${line}p" "$file" 2>/dev/null | sed 's/^/      /' || true
        display_cmd="ssh-keygen -f \"${file}\" -R \"${target}\""
    else
        display_cmd="ssh-keygen -R \"${target}\""
    fi
    echo "    Removes only the ${target} entry; original backed up as known_hosts.old."
    echo "    Clear command: ${display_cmd}"

    if ! command -v ssh-keygen >/dev/null 2>&1; then
        warn "ssh-keygen not found; run the clear command above manually."
        return 0
    fi

    if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Type (Y/y) to clear the stale key, anything else to skip: ")" confirm; then
        info "Non-interactive mode; run the clear command above manually."
        return 0
    fi

    local rc=0
    case "$confirm" in
        [Yy]*)
            if [[ -n "$file" ]]; then
                ssh-keygen -f "$file" -R "$target" >/dev/null 2>&1 || rc=$?
            else
                ssh-keygen -R "$target" >/dev/null 2>&1 || rc=$?
            fi
            if [[ "$rc" -eq 0 ]]; then
                info "Cleared stale host key for ${target} (backup: known_hosts.old)."
            else
                warn "ssh-keygen -R exited ${rc}; run the clear command above manually."
            fi
            ;;
        *)
            info "Skipped. Run manually: ${display_cmd}"
            ;;
    esac
    return 0
}

