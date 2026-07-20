#!/usr/bin/env bash
# lib/devtool_dispatch.sh — cmd_dev 分支共享的 failure-relay(leaf-pure module)。
#   dev_relay_result: 调完 devtool_*_run 后的标准动作 — cat+rm stderr_file + stage/phase/rc 诊断 → 返回 0/1。
#   被 cmd_dev(modify/status/reset/finish/build)消费。per-subcmd verbatim message 表(逐字对齐 cmd_dev 现状,
#   字节 faithful); refresh/list 不套本 relay(结构特殊)。token (phase=<phase>)/(stage=<stage>)/(rc=<rc>) 保留。
#   ob loader source 全部 lib; bash 运行时按名解析。术语见 CONTEXT.md function semantic layer / ob dev porcelain stdout。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断(ADR-0010)。

# dev_relay_result <subcmd> <stderr_file> <stage> <phase> <rc>
# cat+rm stderr_file → stage(cd/setup/postcondition → "build env not ready", 4 subcmd 共享)
#   → phase(reset/finish verbatim 表, metadata token 在句中) → rc(per-subcmd 表: modify/reset/finish/build="devtool failed (rc,stage)";
#   status="devtool status failed (rc)", 无 stage) → 返回 0(干净) / 1(已诊断, 调用者 exit 1)。
dev_relay_result() {
    local subcmd="$1" stderr_file="$2" stage="$3" phase="$4" rc="$5"
    cat -- "$stderr_file" >&2 2>/dev/null || true
    rm -f -- "$stderr_file" 2>/dev/null || true
    case "$stage" in
        cd|setup|postcondition)
            error "ob dev $subcmd: build env not ready (stage=$stage)." >&2
            return 1 ;;
    esac
    if [[ -n "$phase" ]]; then
        case "$subcmd:$phase" in
            reset:metadata)  error "ob dev reset: metadata error (phase=metadata); cannot safely reset." >&2 ;;
            finish:metadata) error "ob dev finish: metadata error (phase=metadata); cannot safely finish." >&2 ;;
            reset:status|finish:status) error "ob dev $subcmd: devtool status failed (phase=status)." >&2 ;;
            reset:reset)     error "ob dev reset: devtool reset failed (phase=reset)." >&2 ;;
            finish:finish)   error "ob dev finish: devtool finish failed (phase=finish)." >&2 ;;
            finish:landing)  error "ob dev finish: landing detection failed (phase=landing); verify patches landed manually." >&2 ;;
            reset:postcondition|finish:postcondition) error "ob dev $subcmd: postcondition failed (phase=postcondition)." >&2 ;;
            *)               error "ob dev $subcmd: failed (phase=$phase)." >&2 ;;
        esac
        return 1
    fi
    if [[ "$rc" -ne 0 ]]; then
        case "$subcmd" in
            status) error "ob dev status: devtool status failed (rc=$rc)." >&2 ;;
            *)      error "ob dev $subcmd: devtool failed (rc=$rc, stage=$stage)." >&2 ;;   # modify/reset/finish/build
        esac
        return 1
    fi
    return 0
}
