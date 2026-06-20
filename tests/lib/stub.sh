#!/usr/bin/env bash
# tests/lib/stub.sh — PATH 注入 stub 生成器 + 减法 PATH。
# mkfake_bin <dir> <cmd...>     在 <dir> 生成 fake 命令(记录调用,输出预设)
# stub_out   <dir> <cmd> <text> 设 fake <cmd> 的预设输出
# stub_script <dir> <cmd> <sh>  fake <cmd> source 自定义逻辑(按参数分支)
# stub_exit  <dir> <cmd> <rc>   fake <cmd> 返回 <rc>(失败路径)
# with_stub  <dir> -- <cmd...>  当前 shell 前置 PATH 跑 <cmd>,跑完恢复(函数调用可见)
# empty_path <cmd...>           减法 PATH: PATH=<空dir> 跑(测 command -v 缺失分支)
mkfake_bin() {
    local dir="$1"; shift; mkdir -p "$dir"
    local c
    for c in "$@"; do
        cat > "$dir/$c" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$dir/.$c.calls"        # 记录调用参数(供断言序列)
[[ -f "$dir/.$c.out" ]] && cat "$dir/.$c.out"   # 预设输出
[[ -f "$dir/.$c.sh" ]] && source "$dir/.$c.sh"  # 自定义逻辑(按 \$@ 分支,供失败路径)
[[ -f "$dir/.$c.rc" ]] && exit "\$(cat "$dir/.$c.rc")"  # 指定退出码
exit 0
STUB
        chmod +x "$dir/$c"
    done
}
stub_out()    { printf '%s' "$3" > "$1/.$2.out"; }   # fake <cmd> 输出 <text>
stub_script() { printf '%s\n' "$3" > "$1/.$2.sh"; }  # fake <cmd> source 自定义逻辑(按参数分支)。注意:失败路径须 `exit <rc>`,不要 `return <rc>`——source 的 return 后 fake 仍继续到 exit 0
stub_exit()   { printf '%s' "$3" > "$1/.$2.rc"; }    # fake <cmd> 返回 <rc>(失败路径)
with_stub() {
    local dir="$1"; shift; [[ "${1:-}" == "--" ]] && shift
    local _sp="$PATH"; PATH="$dir:$PATH"; "$@"; local _r=$?; PATH="$_sp"; return $_r
}
empty_path() {
    local _sp="$PATH"; PATH="$(mktemp -d)"; "$@"; local _r=$?; PATH="$_sp"; return $_r
}
