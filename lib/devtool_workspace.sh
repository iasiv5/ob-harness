#!/usr/bin/env bash
# shellcheck disable=SC1091   # source setup 是动态文件;_devtool_env_exec 在 && 链中 source,行级 disable 不可用(SC1126),故文件级(从原 modify.sh:2 随函数搬入)
# lib/devtool_workspace.sh — devtool workspace 交互原语(leaf-pure module)。
#   _devtool_env_exec(进 build env 跑 devtool 子命令 + tempfile 协议 + stage 追踪 + postcondition)
#   + _devtool_parse_srctree(单条 status→srctree) + _devtool_parse_status_all(全量 status→entries)。
#   被 devtool_modify/devtool_reset/devtool_search/devtool_status 消费(全局命名空间)。
#   ob loader(ob:73-76 for f in lib/*.sh)source 全部 lib; bash 函数运行时按名解析,
#   不依赖 source 顺序(字母序无关——曾误判为约束,已澄清)。术语见 CONTEXT.md function semantic layer / ob dev porcelain stdout。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev/各 *_run)负责 exit-code/remedy/诊断。

# _devtool_env_exec <machine> <build_dir> <stage_file> <stdout_file> <stderr_file> -- <cmd...>
# 同一 subshell(&& 链,无 exit 字面量);只有 <cmd> stdout → stdout_file;setup/postcondition 输出 → stderr_file。
# stage 写 stage_file: cd/setup/postcondition/command。返回 rc(不 exit)。
_devtool_env_exec() {
    local machine="$1" build_dir="$2" stage_file="$3" stdout_file="$4" stderr_file="$5"
    shift 5
    [[ "$1" == "--" ]] && shift
    (
        echo cd >"$stage_file"
        cd "$OPENBMC_DIR" &&
        echo setup >"$stage_file" &&
        set +u &&   # setup 脚本可能用未绑定变量(如 ZSH_NAME),关 nounset(仿 build_env_enter);子 shell 内不影响父
        source setup "$machine" "$build_dir" >>"$stderr_file" 2>&1 &&
        echo postcondition >"$stage_file" &&
        [[ -f "$build_dir/conf/local.conf" ]] &&
        command -v devtool >>"$stderr_file" &&
        command -v bitbake-layers >>"$stderr_file" &&
        echo command >"$stage_file" &&
        "$@" >"$stdout_file"
    ) 2>>"$stderr_file"
    return $?
}

# _devtool_parse_srctree <recipe> <status_file> → srctree(字面匹配 recipe 行,不把 recipe 当正则;
# 剥离可选 " (recipefile)" 后缀)。无匹配输出空。
_devtool_parse_srctree() {
    local rcp="$1" file="$2"
    awk -v r="$rcp" 'index($0,r": ")==1{s=substr($0,index($0,": ")+2);sub(/ \([^)]*\)$/,"",s);print s;exit}' "$file" 2>/dev/null
}

# _devtool_parse_status_all <status_file> → stdout 每行 "recipe<TAB>srctree"
# 全量解析 devtool status: 行内首个 ": " 前=recipe(非空、不含空白),后=srctree(剥 "(recipefile)" 后缀)。
# 跳过 header/空行/无 ": "/recipe 空。纯函数(读 file, 输出 stdout), 绝不 exit。
_devtool_parse_status_all() {
    local file="$1"
    awk '{
        pos = index($0, ": ")
        if (pos <= 1) next
        recipe = substr($0, 1, pos - 1)
        if (recipe == "") next
        srctree = substr($0, pos + 2)
        sub(/ \([^)]*\)$/, "", srctree)
        if (recipe ~ /^(NOTE|WARNING|ERROR|DEBUG|CRITICAL)$/) next   # bitbake 诊断 token(防 WARNING: /abs/path 漏网)
        if (recipe !~ /^[A-Za-z0-9._+-]+$/) next                     # PN 字符集(挡含空白噪声行)
        if (srctree !~ /^\//) next                                   # srctree 必须绝对路径(devtool EXTERNALSRC)
        print recipe "\t" srctree
    }' "$file" 2>/dev/null
}

# _devtool_parse_status_entry <recipe> <status_file> <srctree_outvar> <recipefile_outvar>
# 单条 status 行解析: "recipe: srctree (recipefile)" → srctree + recipefile(剥括号);
# 无 (recipefile) → recipefile 空, srctree 仍出; 无匹配行 → 两者空。
# (与 _devtool_parse_srctree 对偶: srctree 只剥后缀; 本函数同时取 recipefile 供 finish destination 解析;
#  recipefile 绝对/相对原样交调用者用 base_dir 解析)。纯函数(读 file, 填 outvar), 绝不 exit。
_devtool_parse_status_entry() {
    local rcp="$1" file="$2" srctree_out="$3" recipefile_out="$4"
    local _parsed _srctree="" _recipefile=""
    _parsed="$(awk -v r="$rcp" '
        index($0, r": ")==1 {
            s = substr($0, index($0, ": ")+2)   # "srctree" 或 "srctree (recipefile)"
            if (match(s, / \([^)]*\)$/)) {
                recipefile = substr(s, RSTART+2, RLENGTH-3)   # 括号内(去 " (" + ")")
                srctree = substr(s, 1, RSTART-1)              # srctree(去 " (recipefile)")
            } else {
                srctree = s
                recipefile = ""
            }
            print srctree "\t" recipefile
            done = 1
        }
    ' "$file" 2>/dev/null)"
    if [[ -n "$_parsed" ]]; then
        _srctree="${_parsed%%$'\t'*}"
        _recipefile="${_parsed#*$'\t'}"
    fi
    printf -v "$srctree_out" '%s' "$_srctree"
    printf -v "$recipefile_out" '%s' "$_recipefile"
}
