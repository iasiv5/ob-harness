#!/usr/bin/env bash
# lib/qemu_port_reuse.sh — restart 端口复用注入 resolver。术语见 CONTEXT.md 端口解析链.
# Exit: leaf-no-exit（leaf-pure module）; 恒 return 0, exit 由 L1 cmd_* 收口。
# 消费旧实例 4 端口(argv), 按 cli_first（X-α, -z guard）注入到 QEMU_*_PORT（CLI flag 层）;
# HTTP 额外跳过 'none' sentinel（qemu.sh:160 空值回写 none）。
# ob start-qemu（restart）/ ob deploy-to-qemu（build-first restart）共享——
# ADR-0022 统一 deploy 到 cli_first（修 deploy+--ssh-port 静默丢弃; 0021 future-candidate #1）。
# 不含 interactive 协商 / check_ports_available（那些有 exit, 留 qemu_prepare_launch 消费）。
resolve_qemu_port_reuse() {
    local old_ssh="$1" old_redfish="$2" old_ipmi="$3" old_http="$4"
    [[ -z "$QEMU_SSH_PORT" ]]     && QEMU_SSH_PORT="$old_ssh"
    [[ -z "$QEMU_REDFISH_PORT" ]] && QEMU_REDFISH_PORT="$old_redfish"
    [[ -z "$QEMU_IPMI_PORT" ]]    && QEMU_IPMI_PORT="$old_ipmi"
    [[ -n "$old_http" && "$old_http" != "none" && -z "$QEMU_HTTP_PORT" ]] && QEMU_HTTP_PORT="$old_http"
    return 0   # 契约「恒 return 0」: 末条 AND-list 在 HTTP guard 不成立时 rc=1, set -e 下裸调会中止
               # restart(实测 bash 5.2.21 复现: inline 形态享 && 链豁免、函数调用不享)。显式 return 0 兜底。
}
