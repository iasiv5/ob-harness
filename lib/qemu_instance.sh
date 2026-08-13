#!/usr/bin/env bash
# lib/qemu_instance.sh — QEMU instance 只读视图 + stale 清理 + stop. 术语见 CONTEXT.md QEMU instance / QEMU PID file.
# Exit: leaf-pure module（函数绝不 exit, 只 return; 与 machine_state.sh 同构）.


# module 内部路径拼接（caller 不直接用）；与 lib/qemu.sh derive_qemu_paths 的 QEMU_PIDS_DIR 同源。
_qemu_instance_pid_file() { echo "$WORKSPACE_DIR/qemu-bin/.pids/$1.pid"; }

# per-machine lifecycle lock: serialize instance check/start/stop/manifest writes
# across users. The persistent lock file carries no state; flock ownership does.
_qemu_instance_lifecycle_lock_file() {
    echo "$WORKSPACE_DIR/qemu-bin/.locks/$1.lock"
}

# qemu_instance_lifecycle_lock_acquire <machine> <fd_out> <status_out>
# status: ok / busy / error. Always returns 0; caller owns exit/remedy mapping.
qemu_instance_lifecycle_lock_acquire() {
    local machine="$1" fd_out="$2" status_out="$3"
    local _qila_file _qila_dir _qila_fd=""
    _qila_file="$(_qemu_instance_lifecycle_lock_file "$machine")"
    _qila_dir="$(dirname "$_qila_file")"
    if ! mkdir -p "$_qila_dir"; then
        printf -v "$fd_out" '%s' ""
        printf -v "$status_out" '%s' error
        return 0
    fi
    if ! exec {_qila_fd}>"$_qila_file"; then
        printf -v "$fd_out" '%s' ""
        printf -v "$status_out" '%s' error
        return 0
    fi
    if ! flock -n "$_qila_fd"; then
        exec {_qila_fd}>&- || true
        printf -v "$fd_out" '%s' ""
        printf -v "$status_out" '%s' busy
        return 0
    fi
    printf -v "$fd_out" '%s' "$_qila_fd"
    printf -v "$status_out" '%s' ok
    return 0
}

# qemu_instance_lifecycle_lock_enter <machine> <fd_out> <owned_out> <status_out>
# Reuses a lock inherited from a parent orchestration process (E2E), otherwise
# acquires one. The child writer retains its inherited copy for the command;
# qemu_execute_launch closes only the daemon-side copy before setsid.
qemu_instance_lifecycle_lock_enter() {
    local machine="$1" fd_out="$2" owned_out="$3" status_out="$4"
    local _qile_inherited_fd="${OB_QEMU_LIFECYCLE_LOCK_FD:-}"
    local _qile_inherited_machine="${OB_QEMU_LIFECYCLE_LOCK_MACHINE:-}"
    local _qile_expected_file _qile_actual_file=""
    _qile_expected_file="$(_qemu_instance_lifecycle_lock_file "$machine")"
    if [[ "$_qile_inherited_machine" == "$machine" && "$_qile_inherited_fd" =~ ^[0-9]+$ ]]; then
        _qile_actual_file="$(readlink "/proc/$$/fd/$_qile_inherited_fd" 2>/dev/null || true)"
        if [[ "$_qile_actual_file" == "$_qile_expected_file" ]]; then
            printf -v "$fd_out" '%s' ""
            printf -v "$owned_out" '%s' 0
            printf -v "$status_out" '%s' ok
            return 0
        fi
    fi

    local _qile_acquired_fd="" _qile_acquire_status=""
    qemu_instance_lifecycle_lock_acquire "$machine" _qile_acquired_fd _qile_acquire_status
    printf -v "$fd_out" '%s' "$_qile_acquired_fd"
    printf -v "$owned_out" '%s' 1
    printf -v "$status_out" '%s' "$_qile_acquire_status"
    return 0
}

qemu_instance_lifecycle_lock_release() {
    local lock_fd="$1"
    [[ "$lock_fd" =~ ^[0-9]+$ ]] || return 0
    flock -u "$lock_fd" 2>/dev/null || true
    exec {lock_fd}>&- || true
    return 0
}

# shellcheck disable=SC2034  # PIDFILE_* 字段供 caller（lib/commands.sh）跨文件读取
qemu_instance_load() {
    local machine="${1:-}"
    if [[ -n "$machine" ]]; then
        QEMU_PID_FILE="$(_qemu_instance_pid_file "$machine")"
    elif [[ -z "${QEMU_PID_FILE:-}" ]]; then
        return 1   # 无参且调用者未设 QEMU_PID_FILE → 防御性 return 1（不靠 set -u 中止）
    fi
    if [[ ! -f "$QEMU_PID_FILE" ]]; then
        return 1
    fi

    PIDFILE_PID=""
    PIDFILE_USER=""
    PIDFILE_MACHINE=""
    PIDFILE_BINARY=""
    PIDFILE_STARTED_AT=""
    PIDFILE_PROCESS_START_TICKS=""
    PIDFILE_SSH_PORT=""
    PIDFILE_REDFISH_PORT=""
    PIDFILE_IPMI_PORT=""
    PIDFILE_HTTP_PORT=""
    PIDFILE_SERIAL_LOG=""
    PIDFILE_SERIAL_SOCK=""

    while IFS='=' read -r key value; do
        case "$key" in
            pid)          PIDFILE_PID="$value" ;;
            user)         PIDFILE_USER="$value" ;;
            machine)      PIDFILE_MACHINE="$value" ;;
            binary)       PIDFILE_BINARY="$value" ;;
            started_at)   PIDFILE_STARTED_AT="$value" ;;
            process_start_ticks) PIDFILE_PROCESS_START_TICKS="$value" ;;
            ssh_port)     PIDFILE_SSH_PORT="$value" ;;
            redfish_port) PIDFILE_REDFISH_PORT="$value" ;;
            ipmi_port)    PIDFILE_IPMI_PORT="$value" ;;
            http_port)    PIDFILE_HTTP_PORT="$value" ;;
            serial_log)   PIDFILE_SERIAL_LOG="$value" ;;
            serial_sock)  PIDFILE_SERIAL_SOCK="$value" ;;
        esac
    done < "$QEMU_PID_FILE"

    return 0
}

# _qemu_process_start_ticks <pid> — Linux process generation identifier.
_qemu_process_start_ticks() {
    local pid="$1"
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true
    return 0
}

# _qemu_instance_probe_alive <pid> <expected_binary> <expected_machine> [expected_start_ticks] [expected_serial_sock]
# 私有 leaf-pure seam。
# return 0=running&match, 1=exited, 2=pid recycled。供 qemu_instance_liveness 内部消费（不污染公开面）。
# 输入有效性防线先于 /proc 检查：空字段 PID file 今天会误判 running（空 string 是任意 cmdline 子串），
# 防线让 corrupt/空字段落 1=exited → clean_stale（ADR-0024 评审 🔴1，bug 修正非行为保持）。
_qemu_instance_probe_alive() {
    local pid="$1"
    local expected_binary="$2"
    local expected_machine="$3"
    local expected_start_ticks="${4:-}"
    local expected_serial_sock="${5:-}"

    # 防线：pid 非空且纯数字、binary/machine 非空，否则 return 1（exited）
    [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ || -z "$expected_binary" || -z "$expected_machine" ]] && return 1

    if [[ ! -d "/proc/$pid" ]]; then
        return 1  # Process exited
    fi

    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || true

    if [[ "$cmdline" != *"$expected_binary"* ]] || [[ "$cmdline" != *"$expected_machine"* ]]; then
        return 2  # PID recycled — different process
    fi
    if [[ -n "$expected_serial_sock" && "$cmdline" != *"$expected_serial_sock"* ]]; then
        return 2
    fi
    if [[ -n "$expected_start_ticks" && "$(_qemu_process_start_ticks "$pid")" != "$expected_start_ticks" ]]; then
        return 2  # PID recycled — different process
    fi

    return 0  # Running and matches
}

# qemu_instance_liveness <machine> <status_outvar> — 公开 leaf-pure，恒 return 0（ADR-0024）。
# 吸收 load + probe 两步：printf -v 写 running/exited/recycled/nopid 到 outvar，消灭 set-e 多态返回 footgun。
# non-nopid 下 PIDFILE_* 已填（caller 在 running 分支读 PIDFILE_SSH_PORT 等），nopid 下已清空。
# shellcheck disable=SC2034  # PIDFILE_* 清空为 nopid 不变量;字段供 caller 跨文件读取
qemu_instance_liveness() {
    local machine="$1"
    local status_outvar="$2"

    # 清空 PIDFILE_*（nopid 路径保持清空：qemu_instance_load 失败时不重置这些字段）
    PIDFILE_PID=""; PIDFILE_USER=""; PIDFILE_MACHINE=""; PIDFILE_BINARY=""
    PIDFILE_STARTED_AT=""; PIDFILE_PROCESS_START_TICKS=""; PIDFILE_SSH_PORT=""
    PIDFILE_REDFISH_PORT=""; PIDFILE_IPMI_PORT=""; PIDFILE_HTTP_PORT=""
    PIDFILE_SERIAL_LOG=""; PIDFILE_SERIAL_SOCK=""

    if ! qemu_instance_load "$machine"; then
        printf -v "$status_outvar" '%s' nopid
        return 0
    fi

    local _rc=0
    _qemu_instance_probe_alive "$PIDFILE_PID" "$PIDFILE_BINARY" "$PIDFILE_MACHINE" \
        "$PIDFILE_PROCESS_START_TICKS" "$PIDFILE_SERIAL_SOCK" || _rc=$?
    case "$_rc" in
        0) printf -v "$status_outvar" '%s' running ;;
        2) printf -v "$status_outvar" '%s' recycled ;;
        *) printf -v "$status_outvar" '%s' exited ;;   # 1=exited；防御 * 一并落 exited
    esac
    return 0
}

# qemu_instance_summarize_full — 读 PIDFILE_* 全局(qemu_instance_load 设置)echo 统一四行实例信息。
# 供 cmd_start_qemu 冲突块与 cmd_stop_qemu 确认时复用(四行详情);cmd_status 走 summarize_brief(单行)。
qemu_instance_summarize_full() {
    echo "  PID       : $PIDFILE_PID"
    echo "  Started   : $PIDFILE_STARTED_AT"
    echo "  Ports     : SSH($PIDFILE_SSH_PORT) Redfish($PIDFILE_REDFISH_PORT) IPMI($PIDFILE_IPMI_PORT/UDP)"
    echo "  Serial log: $PIDFILE_SERIAL_LOG"
}

# qemu_instance_summarize_brief <machine> — echo 单行实例详情（PID + 三端口 + 状态）。
# machine 名不含（caller 决定布局）；running 标 ✅，stale（exited/recycled/nopid）标 ⚠️。
# 内部走 qemu_instance_liveness（恒 return 0 + outvar 状态），统一存活判断。
qemu_instance_summarize_brief() {
    local machine="$1"
    local _liv=""
    qemu_instance_liveness "$machine" _liv
    case "$_liv" in
        running)
            echo "PID ${PIDFILE_PID}   SSH(${PIDFILE_SSH_PORT}) Redfish(${PIDFILE_REDFISH_PORT}) IPMI(${PIDFILE_IPMI_PORT}/UDP)   ✅ running"
            ;;
        nopid)
            echo "⚠️ stale"   # PID 文件消失（race）或不可读 → 视作 stale，避免 caller 显示空行
            ;;
        exited|recycled)
            echo "PID ${PIDFILE_PID}   SSH(${PIDFILE_SSH_PORT}) Redfish(${PIDFILE_REDFISH_PORT}) IPMI(${PIDFILE_IPMI_PORT}/UDP)   ⚠️ stale"
            ;;
    esac
    return 0
}

# qemu_instance_clean_stale <machine> — rm stale PID 文件（best-effort，恒返回 0）。
# owner = start-qemu 冲突块 / stop-qemu；cmd_status（只读）不调用。
qemu_instance_clean_stale() {
    local machine="$1"
    rm -f "$(_qemu_instance_pid_file "$machine")" 2>/dev/null || true
    return 0
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
    rm -f "$pid_file" 2>/dev/null || true
    return 0
}

# qemu_instance_list — 枚举当前 workspace 所有 QEMU PID 文件对应的 machine 名（全集，
# 每行一个）。作 list-source；存活判断不在此（caller 走 qemu_instance_liveness）。
# 与 lib/qemu.sh derive_qemu_paths 的 QEMU_PIDS_DIR 同源（$WORKSPACE_DIR/qemu-bin/.pids）。
qemu_instance_list() {
    local pid_file
    for pid_file in "$WORKSPACE_DIR/qemu-bin/.pids/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        basename "$pid_file" .pid
    done
}
