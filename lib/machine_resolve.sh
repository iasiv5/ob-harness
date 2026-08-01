#!/usr/bin/env bash
# lib/machine_resolve.sh — command machine resolution module(leaf-pure)。术语见 CONTEXT.md command machine resolution.
#   resolve_command_machine: cmd_build/cmd_dev/cmd_deploy_to_qemu 的 machine 解析编排收口——
#   given 快路径 verify / empty 路径 guard+pick+verify / exit-3 remedy / rc 映射, return 0/1/2/3, set $MACHINE。
#   设计见 ADR-0019(路 A: seam own remedy + return 契约, cmd_* 字面 case 收口)。
# Exit: leaf-pure module（同 machine_selection_guard.sh/image_build.sh）;函数绝不 exit, return 契约值;
#   exit 归 cmd_*(exit_contract Y 规则守, LEAF_EXIT_EXCEPTIONS_BY_BASENAME 中 machine_resolve.sh 例外集空)。


# resolve_command_machine <list_fn> <verb> <pick_stream> <nontty_remedy>
# 消费 machine_selection_guard + pick_machine + machine_state_is_initialized, 收口 cmd_* 的 machine 解析 ritual。
# 后置条件: return 0 ⟹ 全局 $MACHINE 已 initialized(pick_machine 在当前 shell 设 $MACHINE, 不造 nameref)。
#   范围: 单次命令内 init-done 不消失(ob 自身不 mid-command 删 marker); 并发外部进程删 marker 的 TOCTOU 需
#   flock 防、超本 seam 范围——verify-then-use 窗口仍在, 故 empty 路径不重复 verify(重复 verify 只给假安全)。
#   given 路径($MACHINE 非空, 调用方显式 argv): verify-init 通过 → return 0;
#     未通过 → verify remedy(stderr) + return 3。
#   empty 路径($MACHINE 空): guard 恒返回 0, 经 outvar 回传 empty/nontty/ok——
#     empty → empty remedy(stderr) + return 3;nontty → nontty_remedy(stderr) + return 3;
#     ok → pick_machine(按 pick_stream 决定 >&2: dev=stderr 护 porcelain stdout 契约, build/deploy=stdout)
#          rc 0→return 0(pick 自 list_fn=initialized_machines, 源可信, 不重复 verify; given 路径 own verify)
#              / 2→warn "<verb> cancelled by user."(stdout) + return 2 / 否则 read-fail return 1。
# 两类 remedy 不混用: verify remedy(given 未 init, 带括号诊断) ≠ empty remedy(集合空, 不同文案)。
# caller 边界: confirm / repo 显示 / DRY_RUN / 展示块留 cmd_*;nontty_remedy 与 pick_stream 由 caller 传入。
# leaf-pure: 绝不 exit;前置 _prc=0/_gstat 是 ob set -u 必需(成功路径 || _prc=$? 不执行, 不预初始化则 nounset 崩)。
resolve_command_machine() {
    local list_fn="$1" verb="$2" pick_stream="$3" nontty_remedy="$4"
    local _gstat="" _prc=0

    # given 快路径: 调用方已设 $MACHINE(显式 argv)。verify-init 是 seam 拥有的统一前置(ADR-0019)。
    if [[ -n "$MACHINE" ]]; then
        if machine_state_is_initialized "$MACHINE"; then
            return 0
        fi
        error "Machine '$MACHINE' is not initialized (no completed init-done marker - a previous init may have been interrupted)."
        error "Run 'ob init $MACHINE' first."
        return 3
    fi

    # empty 路径: 交互选 machine。guard 恒返回 0, 经 outvar 回传 empty/nontty/ok(对照 cmd_build 旧 case 结构)。
    machine_selection_guard "$list_fn" _gstat
    case "$_gstat" in
        empty)
            error "No initialized machines found."
            error "Run 'ob init <machine>' first."
            return 3
            ;;
        nontty)
            error "$nontty_remedy"
            return 3
            ;;
        ok)
            # pick_stream=stderr 把 pick 的列表渲染/prompt 重定向到 stderr, 护 ob dev porcelain stdout 契约。
            if [[ "$pick_stream" == "stderr" ]]; then
                pick_machine "$list_fn" "$verb" >&2 || _prc=$?
            else
                pick_machine "$list_fn" "$verb" || _prc=$?
            fi
            case "$_prc" in
                0) return 0 ;;
                2) warn "$verb cancelled by user."; return 2 ;;
                *) return 1 ;;
            esac
            ;;
    esac
}
