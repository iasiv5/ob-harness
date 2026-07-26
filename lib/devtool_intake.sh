#!/usr/bin/env bash
# lib/devtool_intake.sh — ob dev 命令入口的解析+引导层 module(leaf-pure)。
#   dev_intake_argv: 消费 ob dev argv(--machine/二级子命令/pattern·recipe/全局选项) → 解析为
#   (machine, subcmd, pattern, recipe) 四元组, 经 nameref outvar 回填; -d 设全局 DRY_RUN。return 0/1。
#   dev_intake_tty: 仅当子命令缺失且交互终端时进入的 7 项菜单引导 + 位置参数补齐 + 衔接
#   devtool_pick_modified_recipe。读 stdin, return 0/1/2/3(Task 2 加入)。
#   消费 devtool_pick_modified_recipe / read / error / warn。术语见 CONTEXT.md ob dev command intake。
# Exit: leaf-pure module (ADR-0010/0012); 函数绝不 exit, return 契约值; exit 归 cmd_dev。

# dev_intake_argv <out_machine> <out_subcmd> <out_pattern> <out_recipe> <args...>
# 消费 ob dev 的 argv(--machine/二级子命令/pattern·recipe/全局选项), 解析为四元组经 nameref outvar 回填。
# -d|-D|--dry-run 设全局 DRY_RUN=1(跟 ob 入口 parse_args 对称)。return 0(ok) / 1(usage-error)。
# 前提(调用者保证): 4 个 outvar 名不与本函数 local 同名(nameref 循环引用陷阱)。
dev_intake_argv() {
    local -n _ia_machine="$1" _ia_subcmd="$2" _ia_pattern="$3" _ia_recipe="$4"
    shift 4
    _ia_machine=""; _ia_subcmd=""; _ia_pattern=""; _ia_recipe=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --machine)
                [[ $# -ge 2 ]] || { error "Missing value for --machine" >&2; return 1; }
                _ia_machine="$2"; shift 2
                [[ -z "$_ia_machine" || "$_ia_machine" == -* ]] && { error "ob dev: invalid --machine value '$_ia_machine'" >&2; return 1; } ;;
            --machine=*)
                _ia_machine="${1#--machine=}"; shift
                [[ -z "$_ia_machine" || "$_ia_machine" == -* ]] && { error "ob dev: invalid --machine value '$_ia_machine'" >&2; return 1; } ;;
            -d|-D|--dry-run) DRY_RUN=1; shift ;;
            list|modify|refresh|build|finish|reset|status)
                if [[ -z "$_ia_subcmd" ]]; then
                    _ia_subcmd="$1"
                else
                    case "$_ia_subcmd" in
                        list)   [[ -z "$_ia_pattern" ]] || { error "ob dev list: too many patterns" >&2; return 1; }; _ia_pattern="$1" ;;
                        modify|reset|finish|build) [[ -z "$_ia_recipe" ]] || { error "ob dev $_ia_subcmd: too many recipes" >&2; return 1; }; _ia_recipe="$1" ;;
                        *)      error "ob dev $_ia_subcmd: unexpected argument '$1'" >&2; return 1 ;;
                    esac
                fi
                shift ;;
            -*) error "ob dev: unknown option '$1'" >&2; return 1 ;;
            *)
                case "$_ia_subcmd" in
                    list)   [[ -z "$_ia_pattern" ]] || { error "ob dev list: too many patterns" >&2; return 1; }; _ia_pattern="$1" ;;
                    modify|reset|finish|build) [[ -z "$_ia_recipe" ]] || { error "ob dev $_ia_subcmd: too many recipes" >&2; return 1; }; _ia_recipe="$1" ;;
                    *)      error "ob dev: unexpected positional '$1' (need subcommand first)" >&2; return 1 ;;
                esac
                shift ;;
        esac
    done
    return 0
}
