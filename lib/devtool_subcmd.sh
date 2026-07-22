#!/usr/bin/env bash
# lib/devtool_subcmd.sh — ob dev subcommand handler module（leaf-pure）。
#   每个 dev_subcmd_<name> 封装一个 ob dev 二级子命令（list/modify/refresh/reset/
#   finish/status/build）的 porcelain 生命周期编排：前置（dry-run gate / recipe 前置）
#   → execute（调 devtool_*_run / devtool_search_*）→ relay（dev_relay_result）/
#   emit（dev_emit_*）按各子命令真实形状 → return exit-code 契约值。
#   共享入口契约 (machine, build_dir, recipe, pattern, dry_run) → return 0/1/2/3；
#   run→relay→emit 段不强求统一模板（形状分 4 类，见 CONTEXT.md subcommand handler）。
#   消费 devtool_*_run / devtool_search_* / dev_relay_result / dev_emit_* / notice / warn / error。
# Exit: leaf-pure module (ADR-0012); 函数绝不 exit，return 0/1/2/3；exit 归 cmd_dev。

# _dev_dryrun_gate <dry_run> <notice_msg>
# dry-run 命中（dry_run==1）→ notice（notice_msg, stderr）+ return 0（handler 应 return 0）；
# 否则 return 1（handler 继续）。notice_msg 须含 [DRY-RUN] 前缀（orchestration 断言依赖）。
_dev_dryrun_gate() {
    local dry_run="$1" notice_msg="$2"
    if [[ "$dry_run" == "1" ]]; then
        notice "$notice_msg" >&2
        return 0
    fi
    return 1
}

# _dev_recipe_precondition <machine> <recipe> <subcmd>
# recipe 空 → error "no recipe specified" + remedy（按 subcmd: modify/reset→list, finish/build→status）
# + return 3；否则 return 0。TOCTOU 再校验：非 TTY 路径不经 cmd_dev TTY guide，靠此兜底。
_dev_recipe_precondition() {
    local machine="$1" recipe="$2" subcmd="$3"
    if [[ -z "$recipe" ]]; then
        error "ob dev $subcmd: no recipe specified." >&2
        case "$subcmd" in
            modify|reset) error "Run 'ob dev --machine $machine list [pattern]' to discover recipes first." >&2 ;;
            finish|build) error "Run 'ob dev --machine $machine status' to list modified recipes first." >&2 ;;
        esac
        return 3
    fi
    return 0
}

# dev_subcmd_status <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1
# 不需 recipe 前置（status 无参）；调 devtool_status_run → relay → 判空 warn / emit JSONL。
dev_subcmd_status() {
    local machine="$1" build_dir="$2" recipe="$3" pattern="$4" dry_run="$5"
    _dev_dryrun_gate "$dry_run" "[DRY-RUN] ob dev status: would list modified recipes via devtool status." && return 0
    local _st_entries="" _st_stage="" _st_stderr_file="" _st_rc=0
    devtool_status_run "$machine" "$build_dir" _st_entries _st_stage _st_stderr_file || _st_rc=$?
    dev_relay_result status "$_st_stderr_file" "$_st_stage" "" "${_st_rc:-0}" || return 1
    if [[ -z "$_st_entries" ]]; then
        warn "No modified recipes for $machine." >&2
        return 0
    fi
    dev_emit_status_jsonl "$_st_entries" || { error "ob dev status: failed to encode result JSONL." >&2; return 1; }
    return 0
}

# dev_subcmd_refresh <machine> <build_dir> <recipe> <pattern> <dry_run> → return 0/1
# 不调 relay/emit：自己做 cat+rm stderr，空 stdout（cache 重建无 porcelain 输出）。
dev_subcmd_refresh() {
    local machine="$1" build_dir="$2" recipe="$3" pattern="$4" dry_run="$5"
    _dev_dryrun_gate "$dry_run" "[DRY-RUN] ob dev refresh: would regenerate recipe cache via tinfoil." && return 0
    local _rstage="" _rstderr="" _rrc=0
    devtool_search_refresh "$machine" "$build_dir" _rstage _rstderr || _rrc=$?
    cat "$_rstderr" >&2 2>/dev/null || true
    rm -f "$_rstderr" 2>/dev/null
    if [[ "$_rrc" -ne 0 ]]; then error "ob dev refresh: failed (stage=$_rstage)." >&2; return 1; fi
    return 0
}
