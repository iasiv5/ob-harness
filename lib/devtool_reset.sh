#!/usr/bin/env bash
# lib/devtool_reset.sh — devtool reset 执行(默认 source-preserving reset,无 --remove-work)。
#   devtool_reset_run 组装器 + 3 私有 helper(resolve_workspace/locate_bbappend/classify)。
#   复用 lib/devtool_workspace.sh 的 _devtool_env_exec / _devtool_parse_srctree(ob loader source 全部 lib; bash 运行时按名解析,不依赖 source 顺序)。
#   Python helper ↔ Bash 用 tempfile NUL framing + __OB_NUL_END__ sentinel 协议。
# 术语见 CONTEXT.md ob dev porcelain stdout / ob dev cleanup收尾语义。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断。


# _devtool_reset_resolve_workspace <build_dir> <raw_outvar> <effective_outvar> <phase_outvar>
# 严格解析 effective devtool workspace_path(镜像 devtool os.path.join(build_dir,"workspace") 默认):
#   - 文件不存在 / 无 [General].workspace_path → 默认(raw=effective=<build_dir>/workspace)。
#   - 字段有效 → raw=configparser.get 未 canonicalize 字面; effective 按 build_dir 解析(相对路径 join build_dir)。
#   - 文件存在但非普通文件(目录等)/无法读/解析/字段空 → phase=metadata, 不静默回退。
# NUL sentinel(raw\0effective\0phase\0__OB_NUL_END__\0): bash 先检 python rc(非零→metadata 不解析),
# 再 mapfile -d '' 断言字段数==4 + 末字段==sentinel。epilogue rm tempfile, 不安装 trap。返回 rc(不 exit)。
_devtool_reset_resolve_workspace() {
    local build_dir="$1" raw_out="$2" effective_out="$3" phase_out="$4"
    local tempfile pyrc raw="" effective="" phase=""
    tempfile="$(mktemp 2>/dev/null)"
    python3 - "$build_dir" >"$tempfile" 2>/dev/null <<'PY'
import configparser
import os
import sys

build_dir = sys.argv[1]
conf = os.path.join(build_dir, 'conf', 'devtool.conf')
default_ws = os.path.join(build_dir, 'workspace')   # 镜像 devtool os.path.join(build_dir, "workspace")
raw = ''
effective = ''
phase = ''

if not os.path.exists(conf):
    # 文件不存在 → 默认(与无 [General] 同)
    raw = default_ws
    effective = default_ws
elif not os.path.isfile(conf):
    # 存在但非普通文件(目录等) → 不可读 → metadata
    phase = 'metadata'
else:
    try:
        cp = configparser.ConfigParser()   # 镜像 devtool 默认插值(%%→%; 单 % 非法→InterpolationSyntaxError→metadata)
        with open(conf) as f:
            cp.read_file(f)
        if not cp.has_option('General', 'workspace_path'):
            # 无 [General] / 无 workspace_path 字段 → 默认
            raw = default_ws
            effective = default_ws
        else:
            wp = cp.get('General', 'workspace_path')
            if wp.strip() == '':
                # 空字符串歧义 → metadata(不静默回退默认)
                phase = 'metadata'
            else:
                raw = wp   # 未 canonicalize 的 effective string
                effective = wp if os.path.isabs(wp) else os.path.join(build_dir, wp)
    except Exception:
        # 无法读/解析 → metadata
        phase = 'metadata'


def emit(text):
    sys.stdout.buffer.write(str(text).encode('utf-8', 'surrogateescape') + b'\x00')


emit(raw)
emit(effective)
emit(phase)
emit('__OB_NUL_END__')
sys.exit(0 if phase == '' else 1)
PY
    pyrc=$?
    if [[ "$pyrc" -ne 0 ]]; then
        phase="metadata"   # python 非零退出(含算出 metadata / 崩溃) → 不解析 tempfile
    else
        local -a result_fields=()
        mapfile -d '' -t result_fields <"$tempfile"
        if [[ ${#result_fields[@]} -ne 4 || "${result_fields[3]}" != "__OB_NUL_END__" ]]; then
            phase="metadata"   # NUL framing 损坏(字段数/截断/sentinel 不符) → metadata
        else
            raw="${result_fields[0]}"
            effective="${result_fields[1]}"
            phase="${result_fields[2]}"
            [[ -n "$phase" ]] && phase="metadata"   # 保险: rc=0 时 phase 应空
        fi
    fi
    printf -v "$raw_out" '%s' "$raw"
    printf -v "$effective_out" '%s' "$effective"
    printf -v "$phase_out" '%s' "$phase"
    rm -f -- "$tempfile"
    [[ -z "$phase" ]]
}


# _devtool_reset_locate_bbappend <workspace> <recipe> <status_srctree> <srctreebase_raw_outvar> <phase_outvar>
# 鲁棒定位 recipe 的 bbappend + 取 srctreebase: 扫 <workspace>/appends/*.bbappend, 字面解析
# EXTERNALSRC:pn-<recipe>(字符串 ==, 不进 grep/awk 正则——PN 含 . 也不误匹配); 校验 EXTERNALSRC==status_srctree;
# 恰好一个匹配(单文件多冲突行 / 多 bbappend / 零匹配 / EXTERNALSRC 不一致 → phase=metadata, 不降级 noop)。
# 读匹配 bbappend 的 # srctreebase: 注释; 无注释 → srctreebase_raw=status_srctree。
# NUL sentinel(srctreebase_raw\0phase\0__OB_NUL_END__\0) + epilogue rm, 不 trap。返回 rc(不 exit)。
_devtool_reset_locate_bbappend() {
    local workspace="$1" recipe="$2" status_srctree="$3" srctreebase_raw_out="$4" phase_out="$5"
    local tempfile pyrc srctreebase_raw="" phase=""
    tempfile="$(mktemp 2>/dev/null)"
    python3 - "$workspace" "$recipe" "$status_srctree" >"$tempfile" 2>/dev/null <<'PY'
import glob
import os
import sys

workspace = sys.argv[1]
recipe = sys.argv[2]
status_srctree = sys.argv[3]
PREFIX = 'EXTERNALSRC:pn-'
srctreebase_raw = ''
phase = ''

all_matches = []   # [(bb_path, externalsrc_value, srctreebase_comment)]
appends_dir = os.path.join(workspace, 'appends')
for bb in sorted(glob.glob(os.path.join(appends_dir, '*.bbappend'))):
    try:
        with open(bb) as f:
            content = f.read()
    except Exception:
        continue
    # 第一遍: 整文件找 # srctreebase 注释(顺序无关——注释在 EXTERNALSRC 前后均生效)
    bb_comment = None
    for line in content.splitlines():
        s = line.lstrip()
        if s.startswith('# srctreebase:'):
            bb_comment = s[len('# srctreebase:'):].strip()
    # 第二遍: 字面解析 EXTERNALSRC:pn-<recipe>(每行匹配, 保留单文件多冲突行 → metadata 检测)
    for line in content.splitlines():
        s = line.lstrip()
        if s.startswith('#'):
            continue
        if s.startswith(PREFIX):
            rest = s[len(PREFIX):]
            pn = ''
            for ch in rest:
                if ch in ' \t=:':
                    break
                pn += ch
            if pn == recipe:   # 字符串 == (字面, PN 含 . / 前缀相近都不误匹配)
                eq = rest.find('=')
                if eq >= 0:
                    val = rest[eq + 1:].strip().strip('"').strip("'").strip()
                    all_matches.append((bb, val, bb_comment))

if len(all_matches) != 1:
    phase = 'metadata'   # 零 / 多(单文件多冲突行 / 多 bbappend)
else:
    _bb, val, comment = all_matches[0]
    if val != status_srctree:
        phase = 'metadata'   # EXTERNALSRC 与 status srctree 不一致
    else:
        srctreebase_raw = comment if comment else status_srctree


def emit(text):
    sys.stdout.buffer.write(str(text).encode('utf-8', 'surrogateescape') + b'\x00')


emit(srctreebase_raw)
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
            srctreebase_raw="${result_fields[0]}"
            phase="${result_fields[1]}"
            [[ -n "$phase" ]] && phase="metadata"
        fi
    fi
    printf -v "$srctreebase_raw_out" '%s' "$srctreebase_raw"
    printf -v "$phase_out" '%s' "$phase"
    rm -f -- "$tempfile"
    [[ -z "$phase" ]]
}


# _devtool_reset_classify <build_dir> <workspace_path_raw> <workspace_path_effective> <srctreebase_raw> <expected_outvar> <phase_outvar>
# reset 前算 expected_disposition(含重叠/歧义拒绝):
#   P(raw 字面 startswith, 镜像 Poky standard.py:2079): srctreebase_raw.startswith(join(ws_raw,"sources"))
#   O(canonical proper-descendant): realpath(srctreebase) 是 realpath(ws_eff/sources) 的真后代
#   moved 分类仅对 nonempty_dir 且 P==O==true; P!=O 一律 fail closed(phase=metadata)。
#   重叠(与 appends/recipes desc_or_eq) / 非目录 / 无法 stat / canonicalization 失败 → metadata。
#   pre_state: nonempty→P/O; empty_dir→removed; missing→absent。
# NUL sentinel(expected\0phase\0__OB_NUL_END__\0) + epilogue rm, 不 trap。返回 rc(不 exit)。
_devtool_reset_classify() {
    local build_dir="$1" ws_raw="$2" ws_eff="$3" srctreebase_raw="$4" expected_out="$5" phase_out="$6"
    local tempfile pyrc expected="" phase=""
    tempfile="$(mktemp 2>/dev/null)"
    python3 - "$build_dir" "$ws_raw" "$ws_eff" "$srctreebase_raw" >"$tempfile" 2>/dev/null <<'PY'
import os
import sys

build_dir = sys.argv[1]
ws_raw = sys.argv[2]
ws_eff = sys.argv[3]
srctreebase_raw = sys.argv[4]
expected = ''
phase = ''


def canon(path, base):
    if not os.path.isabs(path):
        path = os.path.join(base, path)
    return os.path.realpath(path)


def lexical(path, base):
    if not os.path.isabs(path):
        path = os.path.join(base, path)
    return os.path.abspath(path)   # lexical 绝对路径(不 follow symlink, 与 canon realpath 对偶)


def desc_or_eq(child, parent):
    try:
        return os.path.commonpath([child, parent]) == parent
    except ValueError:
        return False


def proper_desc(child, parent):
    return child != parent and desc_or_eq(child, parent)


try:
    sb_lex = lexical(srctreebase_raw, build_dir)
    sb_canon = canon(srctreebase_raw, build_dir)
    sources_root = canon(os.path.join(ws_eff, 'sources'), build_dir)
    appends_root = canon(os.path.join(ws_eff, 'appends'), build_dir)
    recipes_root = canon(os.path.join(ws_eff, 'recipes'), build_dir)
except Exception:
    phase = 'metadata'   # canonicalization 失败 → fail closed

if phase == '':
    # 重叠: srctreebase 与 devtool metadata 路径(appends/recipes, desc_or_eq 含相等)
    if desc_or_eq(sb_canon, appends_root) or desc_or_eq(sb_canon, recipes_root):
        phase = 'metadata'

if phase == '':
    # pre_state 用 lexical path lstat: dangling symlink(lexical 存在但目标无法 stat)→metadata,
    # 仅 lexical ENOENT→absent(不把 dangling 折叠为 absent)
    if not os.path.lexists(sb_lex):
        expected = 'absent'
    elif not os.path.isdir(sb_lex):
        phase = 'metadata'   # 非目录 / dangling symlink / 无法 stat
    elif not os.listdir(sb_canon):
        expected = 'removed'   # 空目录(Poky 直接 rmdir, 不做 startswith 分类)
    else:
        # nonempty_dir: P/O 双向 predicate 对齐
        p = srctreebase_raw.startswith(os.path.join(ws_raw, 'sources'))
        o = proper_desc(sb_canon, sources_root)
        if p and o:
            expected = 'moved'
        elif (not p) and (not o):
            expected = 'retained'
        else:
            phase = 'metadata'   # P != O 一律 fail closed(双向)


def emit(text):
    sys.stdout.buffer.write(str(text).encode('utf-8', 'surrogateescape') + b'\x00')


emit(expected)
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
            expected="${result_fields[0]}"
            phase="${result_fields[1]}"
            [[ -n "$phase" ]] && phase="metadata"
        fi
    fi
    printf -v "$expected_out" '%s' "$expected"
    printf -v "$phase_out" '%s' "$phase"
    rm -f -- "$tempfile"
    [[ -z "$phase" ]]
}


# devtool_reset_run <machine> <build_dir> <recipe> <srctree_outvar> <srctreebase_outvar>
#                   <disposition_outvar> <destination_parent_outvar> <phase_outvar> <stage_outvar> <stderr_file_outvar>
# 组装器(默认 source-preserving reset, 无 --remove-work):
#   resolve_workspace(_resolved_*) → status(无行 noop) → locate_bbappend(srctreebase) →
#   classify expected(_classified_*) → 默认 reset → postcondition(二次 status + recipe 退出 workspace + srctreebase vs expected)。
# 回传 7 outvar(_reset_*); moved 时 destination_parent=<workspace_effective>/attic/sources, 其余空。
# stderr_file 传调用者(不 rm, cmd_dev cat+rm); stage_file/stdout_file 内部 rm。返回 rc(不 exit)。
devtool_reset_run() {
    local machine="$1" build_dir="$2" recipe="$3"
    local srctree_outvar="$4" srctreebase_outvar="$5" disposition_outvar="$6"
    local destination_parent_outvar="$7" phase_outvar="$8" stage_outvar="$9" stderr_file_outvar="${10}"
    local stage_file stdout_file stderr_file
    local _resolved_workspace_raw="" _resolved_workspace_effective="" _resolved_phase=""
    local _located_srctreebase_raw="" _located_phase=""
    local _classified_expected="" _classified_phase=""
    local srctree="" srctreebase="" disposition="" destination_parent=""
    local phase="" stage="" rc=0 _post_srctree=""

    stage_file="$(mktemp 2>/dev/null)"
    stdout_file="$(mktemp 2>/dev/null)"
    stderr_file="$(mktemp 2>/dev/null)"

    # 1. effective workspace(严格解析; outvar 用 _resolved_* 不碰撞 helper 内 local phase)
    _devtool_reset_resolve_workspace "$build_dir" _resolved_workspace_raw _resolved_workspace_effective _resolved_phase || rc=$?
    [[ -n "$_resolved_phase" ]] && phase="$_resolved_phase"
    rc=0

    # 2. status → srctree(phase=status on fail)
    if [[ -z "$phase" ]]; then
        : > "$stdout_file"
        _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            phase="status"; stage="$(cat "$stage_file" 2>/dev/null || true)"
        else
            srctree="$(_devtool_parse_srctree "$recipe" "$stdout_file")"
        fi
        rc=0
    fi

    # 3. status 无 recipe 行 → noop(未 modified)
    if [[ -z "$phase" && -z "$srctree" ]]; then
        disposition="noop"
        rc=0
    fi

    # 4. locate bbappend(鲁棒; 仅非 noop; outvar _located_*)
    if [[ -z "$phase" && -z "$disposition" ]]; then
        _devtool_reset_locate_bbappend "$_resolved_workspace_effective" "$recipe" "$srctree" _located_srctreebase_raw _located_phase || rc=$?
        [[ -n "$_located_phase" ]] && phase="$_located_phase"
        srctreebase="$_located_srctreebase_raw"
        rc=0
    fi

    # 5. classify expected(reset 前; 仅非 noop; outvar _classified_*)
    if [[ -z "$phase" && -z "$disposition" ]]; then
        _devtool_reset_classify "$build_dir" "$_resolved_workspace_raw" "$_resolved_workspace_effective" "$srctreebase" _classified_expected _classified_phase || rc=$?
        [[ -n "$_classified_phase" ]] && phase="$_classified_phase"
        rc=0
    fi

    # 6. 默认 reset(无 --remove-work)
    if [[ -z "$phase" && -z "$disposition" ]]; then
        : > "$stdout_file"
        _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool reset "$recipe" || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            phase="reset"; stage="$(cat "$stage_file" 2>/dev/null || true)"
        fi
        rc=0
    fi

    # 7. postcondition: 二次 status + recipe 退出 workspace
    if [[ -z "$phase" && -z "$disposition" ]]; then
        : > "$stdout_file"
        _devtool_env_exec "$machine" "$build_dir" "$stage_file" "$stdout_file" "$stderr_file" -- devtool status || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            phase="postcondition"; stage="$(cat "$stage_file" 2>/dev/null || true)"
        else
            _post_srctree="$(_devtool_parse_srctree "$recipe" "$stdout_file")"
            [[ -n "$_post_srctree" ]] && phase="postcondition"   # recipe 仍在 workspace(未退出)
        fi
        rc=0
    fi

    # 7b. postcheck: srctreebase 原路径状态 vs expected(canonical 与 classify 一致)
    if [[ -z "$phase" && -z "$disposition" ]]; then
        python3 - "$build_dir" "$srctreebase" "$_classified_expected" >/dev/null 2>&1 <<'PY'
import os
import sys

build_dir, srctreebase, expected = sys.argv[1], sys.argv[2], sys.argv[3]
p = srctreebase if os.path.isabs(srctreebase) else os.path.join(build_dir, srctreebase)
p = os.path.abspath(p)   # lexical(与 classify pre_state 一致, 不 follow symlink)
exists = os.path.lexists(p)
ok = exists if expected == 'retained' else (not exists)   # moved/removed/absent → 必须不存在
sys.exit(0 if ok else 1)
PY
        rc=$?
        [[ "$rc" -ne 0 ]] && phase="postcondition"
    fi

    # 成功: 设 disposition + destination_parent
    if [[ -z "$phase" && -z "$disposition" ]]; then
        disposition="$_classified_expected"
        if [[ "$disposition" == "moved" ]]; then
            destination_parent="$_resolved_workspace_effective/attic/sources"
        fi
        rc=0
    fi

    # 末尾统一回传 7 outvar + 清内部 tempfile(stderr_file 传调用者)
    printf -v "$srctree_outvar" '%s' "$srctree"
    printf -v "$srctreebase_outvar" '%s' "$srctreebase"
    printf -v "$disposition_outvar" '%s' "$disposition"
    printf -v "$destination_parent_outvar" '%s' "$destination_parent"
    printf -v "$phase_outvar" '%s' "$phase"
    printf -v "$stage_outvar" '%s' "$stage"
    printf -v "$stderr_file_outvar" '%s' "$stderr_file"
    rm -f -- "$stage_file" "$stdout_file"
    if [[ -n "$phase" ]]; then
        return 1
    fi
    return 0
}
