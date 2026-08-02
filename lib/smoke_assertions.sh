#!/usr/bin/env bash
# lib/smoke_assertions.sh — ob smoke 的断言判定函数族(leaf-pure)。术语见 CONTEXT.md function semantic layer / ob smoke.
#   每个函数消费一个接口的原始信号(HTTP code+body / ipmitool rc / tcp rc),return 0=pass / 1=fail,
#   并向 stdout 打印一行 ✓/✗ + 断言名(+ 失败时附简短诊断)。
#   调用方(cmd_smoke, lib/qemu_commands.sh)在 fail 时额外打印该接口的完整 RAW response 做定位。
#   原始信号的采集(probe: curl/ipmitool/tcp)归 exit-seam(cmd_smoke 私有 _smoke_probe_*);本 module 只判。
#   设计为可被 protocol 层用 STUBBED 信号单元/协议测试(无需真实 QEMU)。
# Exit: leaf-pure module（函数绝不 exit, 只 return; exit_contract Y 规则守, LEAF_EXIT_EXCEPTIONS_BY_BASENAME
#   中 smoke_assertions.sh 例外集空——判函数必须不 exit, 把 exit 收口留 exit-seam cmd_smoke）。


# smoke_judge_redfish_root <http_code> <response_body>
#   pass ⟺ HTTP 200 AND body 含 Redfish 根的结构标记之一。结构标记判定(非纯 200): 防 BMC
#   暂时只回 placeholder/错误页也误判 pass。接受的等价标记(任一即可):
#     @Redfish.Copyright   — legacy OpenBMC bmcweb(DMTF 版权注释)
#     RedfishVersion       — Redfish 根的标准属性(所有 ServiceRoot 必带)
#     ServiceRoot.v1       — 根资源的 @odata.type 片段(现代 bmcweb 已弃用 @Redfish.Copyright)
smoke_judge_redfish_root() {
    local code="$1" body="$2"
    if [[ "$code" == "200" ]] && {
           [[ "$body" == *"@Redfish.Copyright"* ]] \
        || [[ "$body" == *"RedfishVersion"* ]] \
        || [[ "$body" == *"ServiceRoot.v1"* ]]; }; then
        echo "  ✓ Redfish root reachable (HTTP 200, Redfish structural marker present)"
        return 0
    fi
    echo "  ✗ Redfish root reachable (HTTP ${code:-<none>}, no Redfish structural marker)"
    return 1
}

# smoke_judge_ipmi_lan <ipmitool_rc> [<output_excerpt>]
#   pass ⟺ ipmitool mc info 退出码 0(IPMI over LAN 的受控成功返回)。
#   rc=0 是机器判定(非人眼读输出);output_excerpt 仅供 fail 行摘要。
#
# 已知环境约束(evidence, 2026-08-02): gb200nvl-obmc image 不含 RMCP+ LAN responder
#   — `systemctl is-enabled phosphor-ipmi-netbridged` = not-found, BMC 上无 ipmitool。
#   故该 image 上此断言合法 fail("Unable to establish IPMI v2 / RMCP+ session"), 非测试代码缺陷。
#   断言保持严格(不降级、不切换 in-band/D-Bus): 在装了 RMCP+ 的 image(如 romulus)上会 pass,
#   正确性由 tests/protocol/smoke_assertions_judgment.sh stub-喂 rc=0 验证。lib/qemu.sh:29 已正确
#   发 hostfwd=udp::ipmi_port-:623, 故非转发问题, 是 image 侧缺 netbridged。
smoke_judge_ipmi_lan() {
    local rc="$1"
    local excerpt="${2:-}"
    if [[ "$rc" == "0" ]]; then
        echo "  ✓ IPMI over LAN works (ipmitool mc info exit 0)"
        return 0
    fi
    local detail=""
    [[ -n "$excerpt" ]] && detail=" — $(printf '%s' "$excerpt" | head -c 120)"
    echo "  ✗ IPMI over LAN works (ipmitool exit ${rc:-<none>})${detail}"
    return 1
}

# smoke_judge_system_ready <tcp_connect_rc>
#   pass ⟺ SSH 转发端口 TCP 可连(BMC sshd up 的机器判定, sshpass-independent)。
#   复用 lib/qemu.sh BMC-ready 概念的协议版: 端口可连 = system ready 信号。
smoke_judge_system_ready() {
    local rc="$1"
    if [[ "$rc" == "0" ]]; then
        echo "  ✓ System ready signal (SSH port TCP-connectable)"
        return 0
    fi
    echo "  ✗ System ready signal (SSH port not TCP-connectable, rc=${rc:-<none>})"
    return 1
}
