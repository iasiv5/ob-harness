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


# _devtool_finish_capture_landing_snapshot <openbmc_dir> <snapshot_outfile> <phase_outvar>
# python: git -C openbmc_dir status --porcelain=v1 -z --untracked-files=all → 解析 entry(XY+path, rename/copy取dest)
#   → 过滤 build//workspace//attic/(顶层) → 对 .patch/.bb/.bbappend 算 sha256(文件内容) →
#   JSON {"paths":{relpath:{"status":XY,"sha256":hex}}} 写 snapshot_outfile(relpath 相对 openbmc_dir=git根)。
#   git rev-parse 不真 / status 失败 / 写失败 → phase=landing(fail closed, landing 观测层失败)。
#   T5 runtime + T8 integration 复用同一 helper(避免漂移)。leaf-pure 不 trap。返回 rc(不 exit)。
_devtool_finish_capture_landing_snapshot() {
    local openbmc_dir="$1" snapshot_outfile="$2" phase_out="$3"
    local phase=""
    python3 - "$openbmc_dir" "$snapshot_outfile" <<'PY'
import hashlib
import json
import os
import subprocess
import sys

openbmc_dir = sys.argv[1]
snapshot_outfile = sys.argv[2]
phase = ''

try:
    rev = subprocess.run(['git', '-C', openbmc_dir, 'rev-parse', '--is-inside-work-tree'],
                         capture_output=True)
    if rev.returncode != 0 or rev.stdout.strip() != b'true':
        phase = 'landing'
    if not phase:
        st = subprocess.run(['git', '-C', openbmc_dir, 'status', '--porcelain=v1', '-z',
                             '--untracked-files=all'], capture_output=True)
        if st.returncode != 0:
            phase = 'landing'
        else:
            parts = st.stdout.split(b'\x00')
            paths = {}
            i = 0
            while i < len(parts):
                p = parts[i]
                if not p:
                    i += 1
                    continue
                entry = p.decode('utf-8', 'surrogateescape')
                xy = entry[:2]
                path = entry[3:]   # skip "XY "
                if xy[0] in ('R', 'C') and i + 1 < len(parts) and parts[i + 1]:
                    i += 1   # rename/copy: next part is dest
                    path = parts[i].decode('utf-8', 'surrogateescape')
                i += 1
                relpath = path   # git porcelain path 相对 git 根(openbmc_dir)
                top = relpath.split('/', 1)[0]
                if top in ('build', 'workspace', 'attic'):   # 过滤 build/workspace/attic 顶层
                    continue
                digest = ''
                if os.path.splitext(relpath)[1] in ('.patch', '.bb', '.bbappend'):
                    try:
                        with open(os.path.join(openbmc_dir, relpath), 'rb') as f:
                            digest = hashlib.sha256(f.read()).hexdigest()
                    except Exception:
                        digest = ''   # deleted/不可读 → 空 digest
                paths[relpath] = {'status': xy, 'sha256': digest}
            with open(snapshot_outfile, 'w') as f:
                json.dump({'paths': paths}, f)
except Exception:
    phase = 'landing'

sys.exit(0 if phase == '' else 1)
PY
    local pyrc=$?
    [[ "$pyrc" -ne 0 ]] && phase="landing"
    printf -v "$phase_out" '%s' "$phase"
    [[ -z "$phase" ]]
}


# _devtool_finish_detect_landing <openbmc_dir> <pre_json> <post_json> <mode_out> <patches_out>
#                               <recipe_files_out> <srcrev_out> <landing_layer_out> <phase_out>
# python 读两份 JSON snapshot → diff "post有pre无 / status变 / digest变"(识别 dirty-to-dirty digest 变):
#   deleted .patch/.bb/.bbappend[pre有post无] → phase=landing(fail closed, 不塞进 patches/recipe_files);
#   .patch→patches, .bb/.bbappend→recipe_files; mode 推断(patches非空→patch[含patch-only], recipe_files非空→srcrev,
#   无变化/非patch-recipe→landing); mode=srcrev 读 post recipe SRCREV;
#   每增量文件向上找 conf/layer.conf(openbmc_dir 作 base), 多 root/无 root → phase=landing; landing_layer 相对 openbmc_dir。
# NUL 7 字段(mode\0patches_json\0recipe_files_json\0srcrev\0landing_layer\0phase\0sentinel) + epilogue rm, 不 trap。返回 rc(不 exit)。
_devtool_finish_detect_landing() {
    local openbmc_dir="$1" pre_json="$2" post_json="$3"
    local mode_out="$4" patches_out="$5" recipe_files_out="$6" srcrev_out="$7" landing_layer_out="$8" phase_out="$9"
    local tempfile pyrc
    local mode="" patches="" recipe_files="" srcrev="" landing_layer="" phase=""
    tempfile="$(mktemp 2>/dev/null)"
    python3 - "$openbmc_dir" "$pre_json" "$post_json" >"$tempfile" 2>/dev/null <<'PY'
import json
import os
import re
import sys

openbmc_dir = sys.argv[1]
pre_path = sys.argv[2]
post_path = sys.argv[3]
mode = ''
patches = []
recipe_files = []
srcrev = ''
landing_layer = ''
phase = ''


def find_layer_root(relpath):
    full = os.path.join(openbmc_dir, relpath)
    cur = os.path.dirname(os.path.abspath(full))
    while True:
        if os.path.isfile(os.path.join(cur, 'conf', 'layer.conf')):
            return os.path.abspath(cur)
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


try:
    pre = json.load(open(pre_path))['paths']
    post = json.load(open(post_path))['paths']
except Exception:
    phase = 'landing'

if not phase:
    deleted_relevant = [p for p in pre if p not in post and p.endswith(('.patch', '.bb', '.bbappend'))]
    if deleted_relevant:
        phase = 'landing'

if not phase:
    changed = []
    for p in set(pre) | set(post):
        in_pre, in_post = p in pre, p in post
        if in_post and not in_pre:
            changed.append(p)
        elif in_pre and in_post:
            if pre[p].get('status') != post[p].get('status') or pre[p].get('sha256') != post[p].get('sha256'):
                changed.append(p)
    for p in changed:
        ext = os.path.splitext(p)[1]
        if ext == '.patch':
            patches.append(p)
        elif ext in ('.bb', '.bbappend'):
            recipe_files.append(p)
    if not changed:
        phase = 'landing'
    elif patches:
        mode = 'patch'
    elif recipe_files:
        mode = 'srcrev'
        for rf in recipe_files:
            try:
                m = re.search(r'^SRCREV\s*=\s*"([^"]+)"', open(os.path.join(openbmc_dir, rf)).read(), re.M)
                if m:
                    srcrev = m.group(1)
                    break
            except Exception:
                pass
    else:
        phase = 'landing'   # 增量但非 patch/recipe(异常)

    if not phase and changed:
        roots = set()
        for p in changed:
            r = find_layer_root(p)
            if r is None:
                phase = 'landing'
                break
            roots.add(r)
        if not phase:
            if len(roots) > 1:
                phase = 'landing'
            else:
                landing_layer = os.path.relpath(sorted(roots)[0], openbmc_dir)

patches.sort()
recipe_files.sort()


def emit(text):
    sys.stdout.buffer.write(str(text).encode('utf-8', 'surrogateescape') + b'\x00')


emit(mode)
emit(json.dumps(patches))
emit(json.dumps(recipe_files))
emit(srcrev)
emit(landing_layer)
emit(phase)
emit('__OB_NUL_END__')
sys.exit(0 if phase == '' else 1)
PY
    pyrc=$?
    if [[ "$pyrc" -ne 0 ]]; then
        phase="landing"
    else
        local -a result_fields=()
        mapfile -d '' -t result_fields <"$tempfile"
        if [[ ${#result_fields[@]} -ne 7 || "${result_fields[6]}" != "__OB_NUL_END__" ]]; then
            phase="landing"
        else
            mode="${result_fields[0]}"
            patches="${result_fields[1]}"
            recipe_files="${result_fields[2]}"
            srcrev="${result_fields[3]}"
            landing_layer="${result_fields[4]}"
            phase="${result_fields[5]}"
        fi
    fi
    printf -v "$mode_out" '%s' "$mode"
    printf -v "$patches_out" '%s' "$patches"
    printf -v "$recipe_files_out" '%s' "$recipe_files"
    printf -v "$srcrev_out" '%s' "$srcrev"
    printf -v "$landing_layer_out" '%s' "$landing_layer"
    printf -v "$phase_out" '%s' "$phase"
    rm -f -- "$tempfile"
    [[ -z "$phase" ]]
}
