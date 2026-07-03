#!/usr/bin/env bash
# lib/qemu_launch_profile.sh — QEMU 启动画像决策 module(ADR-0007)。术语见 CONTEXT.md QEMU launch profile / QB variable.
# 从 lib/qemu.sh 迁出(2026-07-04, qemu.sh deepening)。
# Exit: direct-exit module(resolve_qemu_launch_profile exit 1/3 on 证据冲突/缺失;纯 helper 约定不 exit)。


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
