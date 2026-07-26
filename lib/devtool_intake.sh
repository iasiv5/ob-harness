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

# dev_intake_tty <machine> <build_dir> <out_subcmd> <out_pattern> <out_recipe>
# 前提(调用者保证): dev_subcmd 空 + 交互终端(-t 0) + machine initialized。
# 7 项子命令菜单引导 + 各子命令位置参数补齐 + reset/finish/build 衔接 devtool_pick_modified_recipe。
# 读 stdin; return 0(ok, outvars 补全) / 1(read-fail·invalid) / 2(cancel) / 3(empty-modified-recipes)。
# 输出流照搬原 cmd_dev TTY 段(菜单 echo 走 stdout; porcelain 契约的 stdout→stderr 修正是独立改动, 不混入本次抽取)。
dev_intake_tty() {
    local machine="$1" build_dir="$2"
    local -n _it_subcmd="$3" _it_pattern="$4" _it_recipe="$5"
    # 1) 子命令菜单(列已实现 7 个: list/modify/refresh/reset/status/finish/build; deploy 已退役, 迁至 ob deploy-to-qemu)
    echo "  ob dev subcommands:"
    echo "    1) list     Search/list recipes (read-only, reads cache)"
    echo "    2) modify   devtool modify a recipe (outputs srctree path)"
    echo "    3) refresh  Regenerate recipe metadata cache"
    echo "    4) reset    devtool reset a recipe (outputs disposition JSON)"
    echo "    5) status   List modified recipes (read-only, outputs JSONL)"
    echo "    6) finish   devtool finish a recipe (land patches back to layer, outputs JSON)"
    echo "    7) build   devtool build a recipe (outputs nothing on stdout, exit code carries result)"
    local _choice=""
    if ! read -r -p "$(echo -e "${PROMPT_PREFIX} Select subcommand [1-7] (0 to cancel): ")" _choice; then
        error "Unable to read subcommand selection from stdin." >&2
        return 1
    fi
    case "$_choice" in
        0) warn "ob dev cancelled by user."; return 2 ;;
        1) _it_subcmd="list" ;;
        2) _it_subcmd="modify" ;;
        3) _it_subcmd="refresh" ;;
        4) _it_subcmd="reset" ;;
        5) _it_subcmd="status" ;;
        6) _it_subcmd="finish" ;;
        7) _it_subcmd="build" ;;
        *) error "ob dev: invalid subcommand selection '$_choice'." >&2; return 1 ;;
    esac
    # 2) 按子命令补必填/可选位置参数
    case "$_it_subcmd" in
        list)
            if ! read -r -p "$(echo -e "${PROMPT_PREFIX} pattern (Enter = all recipes): ")" _it_pattern; then
                error "Unable to read pattern." >&2
                return 1
            fi
            ;;
        modify)
            if ! read -r -p "$(echo -e "${PROMPT_PREFIX} recipe name: ")" _it_recipe; then
                error "Unable to read recipe name." >&2
                return 1
            fi
            if [[ -z "$_it_recipe" ]]; then
                error "ob dev modify: no recipe specified." >&2
                error "Run 'ob dev --machine $machine list [pattern]' to discover recipes first." >&2
                return 3
            fi
            ;;
        reset|finish|build)
            # TTY 选 modified recipe → helper(leaf-pure, 5 态 status_outvar) + exit-code 映射留 cmd_dev
            local _pick_st=""
            devtool_pick_modified_recipe "$machine" "$build_dir" "$_it_subcmd" _pick_st
            case "$_pick_st" in
                ok:*)
                    _it_recipe="${_pick_st#ok:}" ;;
                empty)
                    warn "No modified recipes for $machine." >&2
                    error "Run 'ob dev --machine $machine modify <recipe>' first." >&2
                    return 3 ;;
                cancel)
                    return 2 ;;
                read-fail|status-failed)
                    # read-fail: read_list_choice 读失败; status-failed: 文案已由 dev_relay_result 打印
                    return 1 ;;
            esac
            ;;
        refresh|status) ;;
    esac
    return 0
}
