#!/usr/bin/env bash
# lib/devtool_finish.sh — devtool finish 执行(落回 recipe 原属 layer + source-preserving + 单 writer)。
#   devtool_finish_run 组装器 + 私有 helper(resolve_layer_root/capture_landing_snapshot/detect_landing)。
#   复用 lib/devtool_workspace.sh 的 _devtool_env_exec / _devtool_parse_status_entry +
#   lib/devtool_reset.sh 的 resolve_workspace/locate_bbappend/classify(ob loader source 全部 lib;
#   bash 运行时按名解析, 不依赖 source 顺序)。
#   Python helper ↔ Bash 用 tempfile NUL framing + __OB_NUL_END__ sentinel 协议; snapshot 用 JSON。
#   finish 物理层镜像 reset(devtool finish 内部 _reset(remove_work=False) 已 source-preserving 归档
#   srctreebase → attic/sources; ob 不做 safety copy, disposition 复用 reset 五态。见 plan v6 规格 A)。
#   术语见 CONTEXT.md ob dev finish / patch landing / ob dev porcelain stdout / ob dev cleanup收尾语义。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断。


# _devtool_resolve_layer_root <base_dir> <file> <layer_root_outvar> <phase_outvar>
# 从 file 向上找最近的 conf/layer.conf → layer root **绝对路径**(给 devtool finish 作 destination)。
#   file 相对 → os.path.join(base_dir, file); file 绝对 → 直接用。从 dirname(file)(或 file 本身若目录) 向上找。
#   找到 → layer_root=abspath; 无(向上到根) → phase=metadata(fail closed, 不回退 root)。
# NUL sentinel(layer_root\0phase\0__OB_NUL_END__\0): bash 先检 python rc(非零→metadata), 再 mapfile -d ''
# 断言字段数==3 + 末字段==sentinel。epilogue rm tempfile, 不安装 trap。返回 rc(不 exit)。
_devtool_resolve_layer_root() {
    local base_dir="$1" file="$2" layer_root_out="$3" phase_out="$4"
    local tempfile pyrc layer_root="" phase=""
    tempfile="$(mktemp 2>/dev/null)"
    python3 - "$base_dir" "$file" >"$tempfile" 2>/dev/null <<'PY'
import os
import sys

base_dir = sys.argv[1]
file = sys.argv[2]
layer_root = ''
phase = ''

try:
    if not os.path.isabs(file):
        file = os.path.join(base_dir, file)
    d = os.path.abspath(file)
    start = d if os.path.isdir(d) else os.path.dirname(d)
    found = ''
    cur = start
    while True:
        if os.path.isfile(os.path.join(cur, 'conf', 'layer.conf')):
            found = cur
            break
        parent = os.path.dirname(cur)
        if parent == cur:   # 到根
            break
        cur = parent
    if found:
        layer_root = os.path.abspath(found)
    else:
        phase = 'metadata'
except Exception:
    phase = 'metadata'


def emit(text):
    sys.stdout.buffer.write(str(text).encode('utf-8', 'surrogateescape') + b'\x00')


emit(layer_root)
emit(phase)
emit('__OB_NUL_END__')
sys.exit(0 if phase == '' else 1)
PY
    pyrc=$?
    if [[ "$pyrc" -ne 0 ]]; then
        phase="metadata"
    else
        local -a result_fields=()
        mapfile -d '' -t result_fields <"$tempfile"
        if [[ ${#result_fields[@]} -ne 3 || "${result_fields[2]}" != "__OB_NUL_END__" ]]; then
            phase="metadata"
        else
            layer_root="${result_fields[0]}"
            phase="${result_fields[1]}"
            [[ -n "$phase" ]] && phase="metadata"
        fi
    fi
    printf -v "$layer_root_out" '%s' "$layer_root"
    printf -v "$phase_out" '%s' "$phase"
    rm -f -- "$tempfile"
    [[ -z "$phase" ]]
}
