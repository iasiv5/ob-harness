#!/usr/bin/env bash
# lib/qemu.sh — QEMU runtime(binary/firmware/ports/SoC/pid/hostkey). 术语见 CONTEXT.md QEMU launch profile / QEMU manifest.
# Exit: direct-exit module（非 leaf-pure, 使用 exit-code 契约值 0/1/2/3）.


derive_qemu_paths() {
    local label arch
    label=$(read_source_label)
    arch="${QEMU_LAUNCH_SYSTEM_NAME:-qemu-system-arm}"
    QEMU_BIN_DIR="$WORKSPACE_DIR/qemu-bin/$label"
    QEMU_BIN_FILE="$QEMU_BIN_DIR/$arch"
    QEMU_PIDS_DIR="$WORKSPACE_DIR/qemu-bin/.pids"
    QEMU_PID_FILE="$QEMU_PIDS_DIR/${MACHINE}.pid"
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

