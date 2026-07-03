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

# qemu_prepare_launch <machine> <image_file>
# launch 编排的"准备"半段(Shape 2): resolve_profile → binary/firmware provisioning →
# 端口协商 → check_ports → build_qemu_cmd。产出 QEMU_LAUNCH_*_PORT/SERIAL_* 全局 + QEMU_CMD。
# 有 I/O(可能联网下载 binary、TTY 端口协商),但不 setsid、不写 PID(那些归 execute)。
# 调用者负责:冲突实例处理(须在本函数之前,因 check_ports_available 占用即 exit 3)、
# 前置 guard、confirm、exit 收口。
qemu_prepare_launch() {
    local machine="$1"
    local image_file="$2"

    resolve_qemu_launch_profile "$machine"

    ensure_qemu_binary
    qemu_launch_profile_apply_binary_machine_override

    ensure_qemu_firmware

    # ── Resolve ports: CLI > env var > default ──
    QEMU_LAUNCH_SSH_PORT="${QEMU_SSH_PORT:-${OB_QEMU_SSH_PORT:-2222}}"
    QEMU_LAUNCH_REDFISH_PORT="${QEMU_REDFISH_PORT:-${OB_QEMU_REDFISH_PORT:-2443}}"
    QEMU_LAUNCH_IPMI_PORT="${QEMU_IPMI_PORT:-${OB_QEMU_IPMI_PORT:-2623}}"
    QEMU_LAUNCH_HTTP_PORT="${QEMU_HTTP_PORT:-${OB_QEMU_HTTP_PORT:-}}"
    QEMU_LAUNCH_SERIAL_LOG="${QEMU_SERIAL_LOG:-${OB_QEMU_SERIAL_LOG:-${HOME%/}/tmp/qemu-${machine}-serial.log}}"
    QEMU_LAUNCH_SERIAL_SOCK="${QEMU_LAUNCH_SERIAL_LOG%.log}.sock"

    # ── Interactive port conflict resolution for additional QEMU instances ──
    resolve_qemu_ports_interactive QEMU_LAUNCH_SSH_PORT QEMU_LAUNCH_REDFISH_PORT QEMU_LAUNCH_IPMI_PORT QEMU_LAUNCH_HTTP_PORT

    # ── Port availability ──
    local -a ports_to_check=("tcp" "$QEMU_LAUNCH_SSH_PORT" "tcp" "$QEMU_LAUNCH_REDFISH_PORT" "udp" "$QEMU_LAUNCH_IPMI_PORT")
    if [[ -n "$QEMU_LAUNCH_HTTP_PORT" ]]; then
        ports_to_check+=("tcp" "$QEMU_LAUNCH_HTTP_PORT")
    fi
    check_ports_available "${ports_to_check[@]}"

    build_qemu_cmd "$image_file" "$QEMU_LAUNCH_SSH_PORT" "$QEMU_LAUNCH_REDFISH_PORT" "$QEMU_LAUNCH_IPMI_PORT" "$QEMU_LAUNCH_HTTP_PORT" "$QEMU_LAUNCH_SERIAL_LOG" "$QEMU_LAUNCH_SERIAL_SOCK"
}

# qemu_execute_launch — launch 编排的"执行"半段(Shape 2): setsid 启动 + PID 写入 +
# BMC-ready 等待 + hostkey 检测 + 连接 summary。读 prepare 产出的 QEMU_LAUNCH_* 全局。
# 副作用重(setsid 真启动、写 PID 文件、ssh 轮询);启动失败 exit 1。调用者负责 DRY_RUN 短路与 exit 收口。
qemu_execute_launch() {
    mkdir -p "$(dirname "$QEMU_LAUNCH_SERIAL_LOG")"

    local qemu_stderr
    qemu_stderr=$(mktemp "${TMPDIR:-/tmp}/qemu-stderr-XXXXXX")
    if ! setsid "${QEMU_CMD[@]}" >"$qemu_stderr" 2>&1; then
        error "QEMU failed to start."
        local qemu_err_msg
        qemu_err_msg=$(grep -v "^qemu-system.*: warning:" "$qemu_stderr" 2>/dev/null || true)
        if [[ -n "$qemu_err_msg" ]]; then
            error "$(echo "$qemu_err_msg" | head -5)"
        fi
        error "Check serial log: $QEMU_LAUNCH_SERIAL_LOG"
        error "Verify QEMU binary: $QEMU_BIN_FILE"
        rm -f "$qemu_stderr"
        exit 1
    fi
    rm -f "$qemu_stderr"

    # ── Write PID file ──
    sleep 1
    local qemu_pid=""
    # 用 serial socket 路径(每实例唯一)+ 当前用户过滤定位 PID,避免多用户同 SoC
    # (如 ast2700a1-evb)machine 名相同导致 pgrep 误匹配到他人 QEMU。fallback 用 binary 路径。
    qemu_pid=$(pgrep -u "$(whoami)" -f "$QEMU_LAUNCH_SERIAL_SOCK" 2>/dev/null | head -1 || true)
    if [[ -z "$qemu_pid" ]]; then
        qemu_pid=$(pgrep -u "$(whoami)" -f "$QEMU_BIN_FILE" 2>/dev/null | head -1 || true)
    fi

    mkdir -p "$QEMU_PIDS_DIR"
    cat > "$QEMU_PID_FILE" <<PIDFILE_EOF
pid=$qemu_pid
user=$(whoami)
machine=$MACHINE
binary=$QEMU_BIN_FILE
qemu_machine=$QEMU_LAUNCH_MACHINE_NAME
started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ssh_port=$QEMU_LAUNCH_SSH_PORT
redfish_port=$QEMU_LAUNCH_REDFISH_PORT
ipmi_port=$QEMU_LAUNCH_IPMI_PORT
http_port=${QEMU_LAUNCH_HTTP_PORT:-none}
serial_log=$QEMU_LAUNCH_SERIAL_LOG
serial_sock=$QEMU_LAUNCH_SERIAL_SOCK
PIDFILE_EOF

    verbose "PID file written: $QEMU_PID_FILE (PID: $qemu_pid)"

    # ── Wait for BMC ready (unless --no-wait) ──
    if [[ "$QEMU_NO_WAIT" -eq 0 ]]; then
        echo ""
        info "Waiting for BMC to become ready (SSH on port $QEMU_LAUNCH_SSH_PORT)..."
        local attempts=0
        local max_attempts=30
        local ready=0

        while [[ $attempts -lt $max_attempts ]]; do
            attempts=$((attempts + 1))
            if sshpass -p 0penBmc ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
                 -o UserKnownHostsFile=/dev/null -p "$QEMU_LAUNCH_SSH_PORT" root@localhost echo "OK" >/dev/null 2>&1; then
                ready=1
                break
            fi
            printf "\r  Waiting... attempt %d/%d" "$attempts" "$max_attempts"
            sleep 5
        done
        echo ""

        if [[ $ready -eq 0 ]]; then
            warn "BMC did not become SSH-ready within $((max_attempts * 5)) seconds."
            warn "It may still be booting. Check serial log: $QEMU_LAUNCH_SERIAL_LOG"
        else
            info "BMC ready after attempt $attempts (~$((attempts * 5))s)"
        fi
    fi

    # ── Detect stale SSH host key (image rebuild regenerates host keys) ──
    check_ssh_hostkey_conflict "$QEMU_LAUNCH_SSH_PORT"

    # ── Print connection summary ──
    echo ""
    echo -e "${GREEN}✅ QEMU started for '$MACHINE'${NC} (PID $qemu_pid)"
    echo ""
    echo "Connect:"
    echo "  SSH     : ssh root@localhost -p $QEMU_LAUNCH_SSH_PORT  (password: 0penBmc)"
    echo "  WebUI   : https://localhost:$QEMU_LAUNCH_REDFISH_PORT  (root / 0penBmc)"
    echo "  Redfish : curl -sk -u root:0penBmc https://localhost:$QEMU_LAUNCH_REDFISH_PORT/redfish/v1"
    echo "  IPMI    : ipmitool -I lanplus -H localhost -p $QEMU_LAUNCH_IPMI_PORT -U root -P 0penBmc mc info"
    echo "  Console : socat -,rawer,escape=0x1d UNIX-CONNECT:$QEMU_LAUNCH_SERIAL_SOCK"
    echo "            (Ctrl+] to exit socat session)"
    echo ""
    echo "Logs:"
    echo "  Serial  : $QEMU_LAUNCH_SERIAL_LOG"
    echo "  PID file: $QEMU_PID_FILE"
    echo ""
    echo "Stop:"
    echo "  ob stop-qemu $MACHINE"
    echo ""
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

