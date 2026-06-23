#!/usr/bin/env bash
# lib/qemu.sh — ob §4 QEMU(binary/firmware/ports/SoC/pid/hostkey),被 ob source。纯函数定义集。


derive_qemu_paths() {
    local label arch
    label=$(read_source_label)
    arch="${QB_SYSTEM_NAME:-qemu-system-arm}"
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
        echo "# key: <source_label>.<QB_SYSTEM_NAME>" >> "$QEMU_URL_CONFIG_FILE"
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
    local arch="${QB_SYSTEM_NAME:-qemu-system-arm}"
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

    local arch="${QB_SYSTEM_NAME:-qemu-system-arm}"
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

    local arch="${QB_SYSTEM_NAME:-qemu-system-arm}"

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
    if [[ "$SOC_TYPE" == "ast2700" ]]; then
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

find_ast2700_bootloaders() {
    local deploy_dir="$BUILD_DIR/tmp/deploy/images/$MACHINE"

    require_path "$deploy_dir" "Deploy directory" "Run 'ob build' for machine '$MACHINE' first." 3

    BOOTLOADER_UBOOT_NODTB="$deploy_dir/u-boot-nodtb.bin"
    BOOTLOADER_UBOOT_DTB="$deploy_dir/u-boot.dtb"
    BOOTLOADER_BL31="$deploy_dir/bl31.bin"
    BOOTLOADER_OPTEE="$deploy_dir/optee/tee-raw.bin"

    # Validate each file
    local -a missing=()
    for desc_file in \
        "u-boot-nodtb.bin:$BOOTLOADER_UBOOT_NODTB" \
        "u-boot.dtb:$BOOTLOADER_UBOOT_DTB" \
        "bl31.bin:$BOOTLOADER_BL31" \
        "optee/tee-raw.bin:$BOOTLOADER_OPTEE"
    do
        local desc="${desc_file%%:*}"
        local fpath="${desc_file#*:}"
        if [[ ! -f "$fpath" ]]; then
            missing+=("$desc ($fpath)")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "AST2700 bootloader files not found in deploy directory:"
        for m in "${missing[@]}"; do
            error "  Missing: $m"
        done
        error "Ensure 'ob build' completed successfully for '$MACHINE'."
        exit 3
    fi

    # Get u-boot-nodtb.bin size for DTB load offset calculation
    BOOTLOADER_UBOOT_SIZE=$(stat --format=%s -L "$BOOTLOADER_UBOOT_NODTB" 2>/dev/null || echo "0")

    verbose "AST2700 bootloaders:"
    verbose "  u-boot-nodtb.bin : $BOOTLOADER_UBOOT_NODTB ($BOOTLOADER_UBOOT_SIZE bytes)"
    verbose "  u-boot.dtb       : $BOOTLOADER_UBOOT_DTB"
    verbose "  bl31.bin         : $BOOTLOADER_BL31"
    verbose "  tee-raw.bin      : $BOOTLOADER_OPTEE"
}

build_qemu_cmd() {
    local image_file="$1"
    local ssh_port="$2"
    local redfish_port="$3"
    local ipmi_port="$4"
    local http_port="$5"
    local serial_log="$6"

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
        "-machine" "$QB_MACHINE_NAME"
    )

    # SoC-specific parameters
    if [[ "$SOC_TYPE" == "ast2700" ]]; then
        find_ast2700_bootloaders
        QEMU_CMD+=(
            "-device" "loader,force-raw=on,addr=0x400000000,file=$BOOTLOADER_UBOOT_NODTB"
            "-device" "loader,force-raw=on,addr=$((0x400000000 + BOOTLOADER_UBOOT_SIZE)),file=$BOOTLOADER_UBOOT_DTB"
            "-device" "loader,force-raw=on,addr=0x430000000,file=$BOOTLOADER_BL31"
            "-device" "loader,force-raw=on,addr=0x430080000,file=$BOOTLOADER_OPTEE"
            "-device" "loader,cpu-num=0,addr=0x430000000"
            "-device" "loader,cpu-num=1,addr=0x430000000"
            "-device" "loader,cpu-num=2,addr=0x430000000"
            "-device" "loader,cpu-num=3,addr=0x430000000"
            "-smp" "4"
        )
    fi
    # AST2600: bootloader is embedded in MTD image, no extra params needed

    # QB_MEM (-m flag): include only if resolved from bitbake
    if [[ -n "$QB_MEM_SIZE_FLAG" ]]; then
        local -a qemu_mem_args=()
        read -r -a qemu_mem_args <<< "$QB_MEM_SIZE_FLAG"
        QEMU_CMD+=("${qemu_mem_args[@]}")
    fi

    local serial_log="$6"
    local serial_sock="$7"

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
    if [[ -d "$QEMU_PCBIOS_DIR" ]]; then
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

    if [[ "$SOC_TYPE" != "ast2700" ]]; then
        return 0
    fi

    if [[ ! -d "$QEMU_PCBIOS_DIR" ]]; then
        warn "QEMU pc-bios directory not found: $QEMU_PCBIOS_DIR"
        warn "Custom QEMU requires pc-bios/. Ensure it was provided during binary setup."
        return 0
    fi

    require_path "$QEMU_PCBIOS_DIR/ast27x0_bootrom.bin" "AST2700 bootrom" "Provide the pc-bios directory itself, or a QEMU root directory that contains pc-bios/." 3
}

resolve_qb_vars() {
    # Validate build environment exists
    require_path "$BUILD_DIR" "Build directory" "Run 'ob init $MACHINE' first." 3

    require_path "$OPENBMC_DIR/setup" "OpenBMC setup script" "Run 'ob init' first." 3

    info "Resolving QEMU variables via BitBake (this takes a few seconds)..."

    local bitbake_output
    bitbake_output=$(cd "$OPENBMC_DIR" && set +u; source setup "$MACHINE" "$BUILD_DIR" 2>/dev/null && bitbake -e 2>/dev/null)

    if [[ -z "$bitbake_output" ]]; then
        error "Failed to run 'bitbake -e' for machine '$MACHINE'."
        error "Ensure the build environment is healthy (try 'ob init $MACHINE' if unsure)."
        exit 1
    fi

    QB_MACHINE_NAME=""
    QB_MEM_SIZE_FLAG=""
    QB_SYSTEM_NAME=""

    # Extract QB_MACHINE
    local qb_machine_raw
    qb_machine_raw=$(echo "$bitbake_output" | grep '^QB_MACHINE=' | head -1 | cut -d= -f2-)
    qb_machine_raw=$(trim_whitespace "$qb_machine_raw")
    # Strip quotes
    qb_machine_raw="${qb_machine_raw#\"}"
    qb_machine_raw="${qb_machine_raw%\"}"
    qb_machine_raw="${qb_machine_raw#\'}"
    qb_machine_raw="${qb_machine_raw%\'}"

    if [[ -z "$qb_machine_raw" ]]; then
        warn "QB_MACHINE not defined for machine '$MACHINE' — will derive from machine name or SoC fallback."
        QB_MACHINE_NAME=""
    else
        # Extract the machine name from "-machine <name>"
        QB_MACHINE_NAME=$(echo "$qb_machine_raw" | sed 's/^-machine[[:space:]]*//' | awk '{print $1}')
        if [[ -z "$QB_MACHINE_NAME" ]]; then
            warn "Could not parse QEMU machine name from QB_MACHINE='$qb_machine_raw' — will use fallback."
            QB_MACHINE_NAME=""
        fi
    fi

    # Extract QB_MEM
    local qb_mem_raw
    qb_mem_raw=$(echo "$bitbake_output" | grep '^QB_MEM=' | head -1 | cut -d= -f2-)
    qb_mem_raw=$(trim_whitespace "$qb_mem_raw")
    qb_mem_raw="${qb_mem_raw#\"}"
    qb_mem_raw="${qb_mem_raw%\"}"
    qb_mem_raw="${qb_mem_raw#\'}"
    qb_mem_raw="${qb_mem_raw%\'}"

    if [[ -z "$qb_mem_raw" ]]; then
        verbose "QB_MEM not defined for machine '$MACHINE' — QEMU will use default memory."
        QB_MEM_SIZE_FLAG=""
    else
        QB_MEM_SIZE_FLAG="$qb_mem_raw"
    fi

    # Extract QB_SYSTEM_NAME (qemu-system-arm | qemu-system-aarch64)
    local qb_system_raw
    qb_system_raw=$(echo "$bitbake_output" | grep '^QB_SYSTEM_NAME=' | head -1 | cut -d= -f2-)
    qb_system_raw=$(trim_whitespace "$qb_system_raw")
    qb_system_raw="${qb_system_raw#\"}"
    qb_system_raw="${qb_system_raw%\"}"
    qb_system_raw="${qb_system_raw#\'}"
    qb_system_raw="${qb_system_raw%\'}"

    if [[ -z "$qb_system_raw" ]]; then
        warn "QB_SYSTEM_NAME not defined for machine '$MACHINE' — will detect from SoC fallback."
        QB_SYSTEM_NAME=""
    else
        QB_SYSTEM_NAME="$qb_system_raw"
    fi

    verbose "  QB_MACHINE → -machine $QB_MACHINE_NAME"
    verbose "  QB_MEM → $QB_MEM_SIZE_FLAG"
    verbose "  QB_SYSTEM_NAME → $QB_SYSTEM_NAME"
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

    find "$OPENBMC_DIR" -path "*/$include_spec" -type f 2>/dev/null | head -1
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

detect_soc_type() {
    # 1. If QB_SYSTEM_NAME already set by bitbake, infer directly
    if [[ -n "$QB_SYSTEM_NAME" ]]; then
        case "$QB_SYSTEM_NAME" in
            qemu-system-aarch64) SOC_TYPE="ast2700" ;;
            qemu-system-arm)     SOC_TYPE="ast2600" ;;
            *)
                warn "Unknown QB_SYSTEM_NAME '$QB_SYSTEM_NAME' — cannot infer SoC type."
                SOC_TYPE=""
                ;;
        esac
        if [[ -n "$SOC_TYPE" ]]; then
            verbose "SoC detected from QB_SYSTEM_NAME: $SOC_TYPE"
            return 0
        fi
    fi

    # 2. Deploy directory file detection
    local deploy_dir="$BUILD_DIR/tmp/deploy/images/$MACHINE"
    local deploy_hint=""
    if [[ -d "$deploy_dir" ]]; then
        if [[ -f "$deploy_dir/bl31-ast2700.bin" ]]; then
            deploy_hint="ast2700"
        else
            deploy_hint="ast2600"
        fi
    fi
    verbose "SoC deploy hint: ${deploy_hint:-<none>} (from $deploy_dir)"

    # 3. Machine conf include chain detection
    local conf_hint=""
    local machine_conf=""
    machine_conf=$(find "$OPENBMC_DIR" -path "*/conf/machine/$MACHINE.conf" -type f 2>/dev/null | head -1 || true)

    if [[ -n "$machine_conf" && -f "$machine_conf" ]]; then
        if machine_conf_chain_contains "$machine_conf" 'ast2700-sdk\.inc|ast2700[^[:space:]#]*\.inc'; then
            conf_hint="ast2700"
        elif machine_conf_chain_contains "$machine_conf" 'ast2600[^[:space:]#]*\.inc|ast2600-default'; then
            conf_hint="ast2600"
        fi
    fi
    verbose "SoC conf hint: ${conf_hint:-<none>} (from machine conf include chain)"

    # 4. Cross-validate
    if [[ -n "$deploy_hint" && -n "$conf_hint" && "$deploy_hint" != "$conf_hint" ]]; then
        error "SoC type conflict: deploy dir says '$deploy_hint', machine conf says '$conf_hint'"
        error "Resolve the mismatch before continuing."
        exit 1
    fi

    # 5. Determine SOC_TYPE
    if [[ -n "$deploy_hint" ]]; then
        SOC_TYPE="$deploy_hint"
    elif [[ -n "$conf_hint" ]]; then
        SOC_TYPE="$conf_hint"
    else
        error "Cannot determine SoC type for machine '$MACHINE'."
        error "Neither QB_SYSTEM_NAME, deploy artifacts, nor machine conf provide SoC information."
        exit 3
    fi

    # 6. Backfill QB_SYSTEM_NAME if still empty
    if [[ -z "$QB_SYSTEM_NAME" ]]; then
        case "$SOC_TYPE" in
            ast2700) QB_SYSTEM_NAME="qemu-system-aarch64" ;;
            ast2600) QB_SYSTEM_NAME="qemu-system-arm" ;;
        esac
        verbose "Backfilled QB_SYSTEM_NAME=$QB_SYSTEM_NAME from SoC detection"
    fi

    info "SoC detected: $SOC_TYPE (arch: $QB_SYSTEM_NAME)"
}

derive_qemu_machine_name() {
    # If QB_MACHINE_NAME already resolved from bitbake, use it directly
    if [[ -n "$QB_MACHINE_NAME" ]]; then
        verbose "QEMU machine name from QB_MACHINE: $QB_MACHINE_NAME"
        return 0
    fi

    # Fallback: extract first segment before '-' and append '-bmc'
    # e.g. b865g8-bytedance → b865g8-bmc, k709g8-bytedance → k709g8-bmc
    local prefix="${MACHINE%%-*}"
    if [[ "$prefix" == "$MACHINE" ]]; then
        error "Cannot derive QEMU machine name from '$MACHINE' (no '-' separator)."
        error "Define QB_MACHINE in your machine conf, or use a machine name with 'xxx-yyy' format."
        exit 3
    fi

    QB_MACHINE_NAME="${prefix}-bmc"
    info "QEMU machine name derived: $QB_MACHINE_NAME (from machine '$MACHINE')"
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

