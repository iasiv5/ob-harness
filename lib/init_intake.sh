#!/usr/bin/env bash
# lib/init_intake.sh — ob init 命令入口的解析+引导+确认层 module(leaf-pure)。
#   init_intake: 消费 $MACHINE(全局) + list_available_machines, 把 ob init 的机器解析决策树
#   (empty 前置 / arg 校验快路径 / 非 TTY 拦截 / pick_machine + confirm) 封装为一个入口。
#   return 0/1/2/3; $MACHINE 沿用全局(fastpath 给定值 / pick 路径 pick_machine 设值)。
#   消费 list_available_machines / print_previously_initialized / pick_machine / confirm_action / error / warn / info。
#   术语见 CONTEXT.md ob init command intake; guard 第 3 消费暂缓见 ADR-0016。
# Exit: leaf-pure module(横切惯例, 同 devtool_intake.sh); 函数绝不 exit, return 契约值; exit 归 cmd_init。

# init_intake
# ob init 机器解析决策树(原样保留 cmd_init 既有控制流, 不调 machine_selection_guard——ADR-0016):
#   empty 前置 → arg 校验快路径(给定合法 machine 不 confirm) → (未给定/非法) 非 TTY 拦截 → pick_machine + confirm。
# return 0(解析+确认成功, $MACHINE 就绪) / 1(读失败) / 2(用户取消, pick 或 confirm) / 3(前置缺失: 空列表/非TTY/arg非法且非TTY)。
# remedy 文案(empty="No machines found/re-clone")独立保留, 不与 build/dev 合并。
# print_previously_initialized 两处调用复刻既有 L281/L298 双语义: fastpath 走 nameref 直印(_machines
# 数组名)、pick 路径走 $(...) stdout 捕获作 post_list_msg——两者语义不同, 勿合并/勿改写法。
init_intake() {
    local -a _machines=()
    local _m
    while IFS= read -r _m; do
        [[ -n "$_m" ]] && _machines+=("$_m")
    done < <(list_available_machines)

    if [[ ${#_machines[@]} -eq 0 ]]; then
        error "No machines found in $OPENBMC_DIR."
        error "Check the OpenBMC main repository, or re-clone: cd $OPENBMC_DIR && git pull"
        return 3
    fi

    if [[ -n "$MACHINE" ]] && printf '%s\n' "${_machines[@]}" | grep -qx -- "$MACHINE"; then
        print_previously_initialized _machines
        info "Machine '$MACHINE' confirmed."
        return 0
    fi

    if [[ -n "$MACHINE" ]]; then
        warn "Machine '$MACHINE' is not in the available list."
    else
        warn "No machine specified."
    fi

    if [[ ! -t 0 ]]; then
        error "No valid machine and no interactive terminal. Pass a valid machine: ob init <machine>"
        return 3
    fi

    local _pm_rc=0
    pick_machine list_available_machines "init" "$(print_previously_initialized _machines)" || _pm_rc=$?
    case "$_pm_rc" in
        0) ;;
        2) warn "init cancelled by user."; return 2 ;;
        *) return 1 ;;
    esac

    local _ca_rc=0
    confirm_action "init" "$MACHINE" || _ca_rc=$?
    case "$_ca_rc" in
        0) ;;
        2) warn "init cancelled by user."; return 2 ;;
        *) return 1 ;;
    esac

    echo ""
    info "Init confirmed for machine '$MACHINE'."
    return 0
}
