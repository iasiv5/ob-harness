#!/usr/bin/env bash
# lib/qemu_instance.sh — QEMU instance 只读视图 + stale 清理 + stop. 术语见 CONTEXT.md QEMU instance / QEMU PID file.
# Exit: leaf-pure module（函数绝不 exit, 只 return; 与 machine_state.sh 同构）.


# module 内部路径拼接（caller 不直接用）；与 lib/qemu.sh derive_qemu_paths 的 QEMU_PIDS_DIR 同源。
_qemu_instance_pid_file() { echo "$WORKSPACE_DIR/qemu-bin/.pids/$1.pid"; }

# shellcheck disable=SC2034  # PIDFILE_* 字段供 caller（lib/commands.sh）跨文件读取
qemu_instance_load() {
    local machine="${1:-}"
    [[ -n "$machine" ]] && QEMU_PID_FILE="$(_qemu_instance_pid_file "$machine")"
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

qemu_instance_is_alive() {
    # return 0=running&match, 1=exited, 2=pid recycled — diagnostic only, NOT part of exit-code protocol
    local pid="$1"
    local expected_binary="$2"
    local expected_machine="$3"

    if [[ ! -d "/proc/$pid" ]]; then
        return 1  # Process exited
    fi

    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || true

    if [[ "$cmdline" != *"$expected_binary"* ]] || [[ "$cmdline" != *"$expected_machine"* ]]; then
        return 2  # PID recycled — different process
    fi

    return 0  # Running and matches
}

# qemu_instance_summarize_full — 读 PIDFILE_* 全局(qemu_instance_load 设置)echo 统一四行实例信息。
# 供 cmd_start_qemu 冲突块与 cmd_stop_qemu 复用(去重;cmd_status 多实例单行呈现不同源,不并入)。
qemu_instance_summarize_full() {
    echo "  PID       : $PIDFILE_PID"
    echo "  Started   : $PIDFILE_STARTED_AT"
    echo "  Ports     : SSH($PIDFILE_SSH_PORT) Redfish($PIDFILE_REDFISH_PORT) IPMI($PIDFILE_IPMI_PORT/UDP)"
    echo "  Serial log: $PIDFILE_SERIAL_LOG"
}

# qemu_instance_stop <pid> <pid_file>
# 统一 stop:kill → 等 /proc/$pid 退出(≤10s)→ SIGKILL 兜底 → 删 PID 文件。best-effort,恒返回 0。
# 供 cmd_start_qemu 冲突 kill(--force / 确认重启)与 cmd_stop_qemu 复用,消除两套分歧实现。
qemu_instance_stop() {
    local pid="$1" pid_file="$2"
    kill "$pid" 2>/dev/null || true
    local wait_count=0
    while [[ -d "/proc/$pid" ]] && [[ $wait_count -lt 10 ]]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done
    if [[ -d "/proc/$pid" ]]; then
        warn "Process $pid did not exit gracefully, sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$pid_file"
}

# qemu_instance_list — 枚举当前 workspace 所有 QEMU PID 文件对应的 machine 名（全集，
# 每行一个）。作 list-source；存活判断不在此（caller 调 qemu_instance_is_alive）。
# 与 lib/qemu.sh derive_qemu_paths 的 QEMU_PIDS_DIR 同源（$WORKSPACE_DIR/qemu-bin/.pids）。
qemu_instance_list() {
    local pid_file
    for pid_file in "$WORKSPACE_DIR/qemu-bin/.pids/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        basename "$pid_file" .pid
    done
}
