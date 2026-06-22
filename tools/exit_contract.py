#!/usr/bin/env python3
"""ob exit-契约扫描器 —— 只读静态体检工具（多文件版）。

断言 ob + lib/*.sh 的 exit 纪律（ADR-0003 / exit-code 契约）：
  X: 每个真·bash 进程 exit 的字面值 ∈ {0,1,2,3}；唯一允许的非字面 exit
     是 require_path 的 exit "$code"。
  Y: basename 为 util.sh 的文件里,函数绝不 exit,除 EXIT_EXCEPTIONS（对偶式自维护）。
     无 util.sh 文件时 Y: n/a（lib 尚未拆出,窗口期预期）。
  Z: exit-3 remedy 覆盖——(a) require_path 精确（非空）；(b) direct exit 3
     弱守（仅防 totally-bare）+ 回溯诊断软告警。require_path 调用点与 direct
     exit 3 均**跨所有扫描文件**判定（Z 需全局视野,故工具走多文件全表,不 per-file）。

零副作用，随时可跑。

【什么时候用】
  - 改了 ob/lib 之后跑它，确认 exit 纪律没破（ob_check.sh 会自动调）
  - 怀疑某函数误加/误改 exit 时定位

【怎么用】
  $ python3 tools/exit_contract.py            # 默认扫 <ROOT>/ob + <ROOT>/lib/*.sh
  $ python3 tools/exit_contract.py <f1> <f2>.. # 扫指定文件(可多,debug 单文件用)
  $ python3 tools/exit_contract.py --seed-y   # 打印 util.sh 真exit集
  退出码：0 = 全绿；1 = 有违反；2 = 文件未找到。

【真·bash exit 判定】
  排除：注释行、sys.exit（python 子进程）、awk "exit !(…)"、
  echo/warn/info/error/printf/verbose 日志调用串内的散文 "exit"。
  只认命令词 exit（大小写敏感、带尾界，避免命中 exited/exits/$bb_exit）。

【由来】grilling + 两轮评审确立的 exit 纪律静态守护。函数边界复用
tools/extract_funcs.py（子进程），不内联第三份边界解析逻辑。多文件化
（Y-c basename）经 ob-modularize-lib-split 设计 v2.1 / 计划 v4 四审确立。
"""
import os
import re
import shlex
import subprocess
import sys
import glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTRACT_FUNCS = os.path.join(ROOT, 'tools', 'extract_funcs.py')
DEFAULT_OB = os.path.join(ROOT, 'ob')
DEFAULT_LIB = os.path.join(ROOT, 'lib')

LOG_FNS = {'echo', 'warn', 'info', 'error', 'printf', 'verbose'}
# 命令词 exit，大小写敏感，带尾界（exited/exits/$bb_exit 不命中）。
# 参数捕获停在 shell 元字符（;|&)）与空白，避免吃进 `exit 1;` 的分号。
EXIT_RE = re.compile(r'(?:^|[\s;`&|])exit(?=$|[\s;)&|])(?:\s+([^\s;|&)]+))?')
LEGAL_LITERAL = {'0', '1', '2', '3'}
# util 层允许 exit 的例外集。对偶式 Y：util.sh 函数绝不 exit，除此 3 个。
EXIT_EXCEPTIONS = {'fn_quit', 'resolve_npm_registry', 'require_path'}

# Z 的「向前看 vs 回溯诊断」软告警启发（尽力而为、非权威，供人工审核）。
_BACKWARD_PHRASES = ('previous step', 'may have failed', 'earlier', 'prior step', 'last step')
_BACKWARD_FIRST = {'invalid', 'neither', 'required', 'missing', 'unable',
                   'supported', 'error', 'failed', 'this'}
_FORWARD_WORDS = ("run '", 'provide', 'use ', 'ensure', 'define', 'specify',
                  'pass ', 'set ', 'configure', 'install', 'or use')


def _looks_backward(s):
    """启发：remedy 疑似回溯诊断（非向前看）。尽力而为，仅作 WARN 提示。"""
    low = re.sub(r'[^\w\s]', ' ', s).lower()
    low = re.sub(r'\s+', ' ', low).strip()
    if any(w in low for w in _FORWARD_WORDS):
        return False
    if any(p in low for p in _BACKWARD_PHRASES):
        return True
    first = low.split(' ', 1)[0] if low else ''
    return first in _BACKWARD_FIRST


def parse_funcs(path):
    """复用 extract_funcs.py 拿 [(name, start, end)]。end=None 表示边界不明。"""
    res = subprocess.run(
        ['python3', EXTRACT_FUNCS, path],
        capture_output=True, text=True,
    )
    funcs = []
    for line in res.stdout.splitlines():
        m = re.match(r'^\s*(\d+)-(\s*\d+|\?)\s+(\w+)\s*$', line)
        if not m:
            continue
        start = int(m.group(1))
        end = None if m.group(2).strip() == '?' else int(m.group(2))
        funcs.append((m.group(3), start, end))
    return funcs


def real_bash_exits(body_lines, start_lineno):
    """返回 [(abs_lineno, arg_token_or_None)]。arg_token=None 表示 bare exit。

    逐行判定，镜像 ob 行规：一行一语句。排除注释/sys.exit/awk-exit/日志调用串。
    """
    out = []
    for i, raw in enumerate(body_lines):
        s = raw.strip()
        if not s or s.startswith('#'):
            continue
        if 'sys.exit' in s:
            continue
        if 'awk' in s and 'exit' in s:
            continue
        first = s.split(None, 1)[0]
        if first in LOG_FNS:
            continue
        for m in EXIT_RE.finditer(raw):
            out.append((start_lineno + i, m.group(1)))
    return out


def collect_files(argv):
    """返回 (files, seed_y)。默认 <ROOT>/ob + sorted(<ROOT>/lib/*.sh);传参则用参数。"""
    seed_y = '--seed-y' in argv
    args = [a for a in argv if a not in ('--', '--seed-y')]
    if args:
        return args, seed_y
    files = [DEFAULT_OB] + sorted(glob.glob(os.path.join(DEFAULT_LIB, '*.sh')))
    return files, seed_y


def check_X(all_funcs, file_lines):
    """X: 字面 exit ∈ {0,1,2,3}；非字面/bare 仅允许在 require_path 体内。

    all_funcs: [(name, start, end, file)]。函数名级判定,不受多文件影响。
    """
    findings = []
    for name, start, end, f in all_funcs:
        if end is None:
            continue
        body = file_lines[f][start - 1:end]
        for lineno, tok in real_bash_exits(body, start):
            if tok is None:
                if name != 'require_path':
                    findings.append((lineno, name, 'bare exit (no code) outside require_path'))
                continue
            if re.fullmatch(r'\d+', tok):
                if tok not in LEGAL_LITERAL:
                    findings.append((lineno, name, f'illegal literal exit {tok}'))
            else:
                if name != 'require_path':
                    findings.append((lineno, name, f'dynamic exit {tok!r} outside require_path'))
    return findings


def util_sh_exiters(all_funcs, file_lines):
    """返回 {name: exits}：basename 为 util.sh 的文件中含真 bash exit 的函数。

    Y-c 文件归属:不靠 §2 注释锚点(会漂移),靠文件名。无 util.sh 返回 None。
    """
    util_files = [f for f in file_lines if os.path.basename(f) == 'util.sh']
    if not util_files:
        return None
    exiters = {}
    util_set = set(util_files)
    for name, start, end, f in all_funcs:
        if f not in util_set or end is None:
            continue
        ex = real_bash_exits(file_lines[f][start - 1:end], start)
        if ex:
            exiters[name] = ex
    return exiters


def check_Y(all_funcs, file_lines):
    """Y-c（对偶式）：{util.sh 真exit函数} == EXIT_EXCEPTIONS。无 util.sh 返回 None（n/a）。"""
    exiters = util_sh_exiters(all_funcs, file_lines)
    if exiters is None:
        return None
    func_start = {}
    for name, start, _, _ in all_funcs:
        func_start.setdefault(name, start)
    findings = []
    s2set = set(exiters)
    for name in sorted(s2set - EXIT_EXCEPTIONS):
        findings.append((exiters[name][0][0], name,
                         'util.sh function unexpectedly exits (add to EXIT_EXCEPTIONS, or remove the exit)'))
    for name in sorted(EXIT_EXCEPTIONS - s2set):
        findings.append((func_start.get(name), name,
                         'in EXIT_EXCEPTIONS but no longer exits in util.sh (stale exception)'))
    return findings


def check_Z(all_funcs, file_lines):
    """返回 (findings_FAIL, warnings_WARN)。跨所有扫描文件判定。

    (a) require_path 调用点（跨文件）:code==3 且 remedy 非空;非空但回溯诊断 → WARN。
    (b) direct exit 3（非 require_path 体内,跨文件）:同函数内 exit 前无 error/info/warn
        → FAIL;有但回溯诊断 → WARN。
    """
    findings = []
    warnings = []
    # (a) require_path 调用点:扫所有文件所有行(调用点散在 repo/qemu/init/commands)
    for f, lines in file_lines.items():
        for i, raw in enumerate(lines, 1):
            if not re.match(r'\s*require_path\s', raw):
                continue
            try:
                toks = shlex.split(raw, posix=True)
            except ValueError:
                continue
            if len(toks) < 5 or toks[0] != 'require_path':
                continue
            hint, code = toks[3], toks[4]
            if code != '3':
                findings.append((i, 'require_path', f'caller exit code {code!r} != 3'))
                continue
            if not hint:
                findings.append((i, 'require_path', 'empty remedy (3rd arg) — add a forward-looking next step'))
            elif _looks_backward(hint):
                warnings.append((i, 'require_path', f'remedy looks backward-looking: {hint!r}'))
    # (b) direct exit 3（非 require_path 体内）:扫所有函数
    for name, start, end, f in all_funcs:
        if end is None or name == 'require_path':
            continue
        body = file_lines[f][start - 1:end]
        for ln, tok in real_bash_exits(body, start):
            if tok != '3':
                continue
            msg = None
            for j in range(ln - 1, start - 1, -1):
                mm = (re.search(r'(?:error|info|warn)\s+"([^"]*)"', file_lines[f][j - 1])
                      or re.search(r"(?:error|info|warn)\s+'([^']*)'", file_lines[f][j - 1]))
                if mm:
                    msg = mm.group(1)
                    break
            if msg is None:
                findings.append((ln, name, 'direct exit 3 with no preceding error/info/warn (totally-bare)'))
            elif _looks_backward(msg):
                warnings.append((ln, name, f'exit-3 preceding msg looks backward-looking: {msg!r}'))
    return findings, warnings


def main(argv):
    files, seed_y = collect_files(argv[1:])

    for f in files:
        if not os.path.isfile(f):
            print(f'error: file not found: {f}', file=sys.stderr)
            return 2

    all_funcs = []  # (name, start, end, file)
    file_lines = {}
    for f in files:
        for (n, s, e) in parse_funcs(f):
            all_funcs.append((n, s, e, f))
        file_lines[f] = open(f).read().split('\n')

    unknown = [n for n, _, e, _ in all_funcs if e is None]
    if unknown:
        print(f'note: {len(unknown)} function(s) with undetermined end, body scan skipped: {unknown}')

    if seed_y:
        exiters = util_sh_exiters(all_funcs, file_lines)
        if exiters is None:
            print('(no util.sh found)')
        else:
            print('util.sh functions containing a real bash exit (seed for EXIT_EXCEPTIONS):')
            for n in sorted(exiters):
                print(f'  {n}')
        return 0

    failed = False

    xf = check_X(all_funcs, file_lines)
    if xf:
        print('X: FAIL')
        for lineno, name, msg in xf:
            print(f'  {lineno}  {name}: {msg}')
        failed = True
    else:
        print('X: PASS')

    yf = check_Y(all_funcs, file_lines)
    if yf is None:
        print('Y: n/a (no util.sh)')
    elif yf:
        print('Y: FAIL')
        for lineno, name, msg in yf:
            print(f'  {lineno}  {name}: {msg}')
        failed = True
    else:
        print('Y: PASS')

    zf, zw = check_Z(all_funcs, file_lines)
    if zf:
        print('Z: FAIL')
        for lineno, name, msg in zf:
            print(f'  {lineno}  {name}: {msg}')
        failed = True
    else:
        print('Z: PASS')
    if zw:
        print(f'Z WARN ({len(zw)}, advisory — review for forward-looking remedy):')
        for lineno, name, msg in zw:
            print(f'  {lineno}  {name}: {msg}')

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
