#!/usr/bin/env python3
"""ob exit-契约扫描器 —— 只读静态体检工具。

断言 ob 的 exit 纪律（ADR-0003 / exit-code 契约），目前实现 X：
  X: 每个真·bash 进程 exit 的字面值 ∈ {0,1,2,3}；唯一允许的非字面 exit
     是 require_path 的 exit "$code"。
  Y: （Task 2 增补）§2 函数绝不 exit，除 EXIT_EXCEPTIONS。
  Z: （Task 3 增补）exit-3 remedy 覆盖。

零副作用，随时可跑。

【什么时候用】
  - 改了 ob 之后跑它，确认 exit 纪律没破（ob_check.sh 会自动调）
  - 怀疑某函数误加/误改 exit 时定位

【怎么用】
  $ python3 tools/exit_contract.py            # 扫仓库根 ob
  $ python3 tools/exit_contract.py <path>     # 扫指定 bash 文件
  $ python3 tools/exit_contract.py --seed-y   # (Task 2) 打印 §2 真exit集
  退出码：0 = 全绿；1 = 有违反；2 = 文件未找到。

【真·bash exit 判定】
  排除：注释行、sys.exit（python 子进程）、awk "exit !(…)"、
  echo/warn/info/error/printf/verbose 日志调用串内的散文 "exit"。
  只认命令词 exit（大小写敏感、带尾界，避免命中 exited/exits/$bb_exit）。

【由来】grilling + 两轮评审确立的 exit 纪律静态守护。函数边界复用
  tools/extract_funcs.py（子进程），不内联第三份边界解析逻辑。
"""
import os
import re
import sys
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTRACT_FUNCS = os.path.join(ROOT, 'tools', 'extract_funcs.py')
DEFAULT_OB = os.path.join(ROOT, 'ob')

LOG_FNS = {'echo', 'warn', 'info', 'error', 'printf', 'verbose'}
# 命令词 exit，大小写敏感，带尾界（exited/exits/$bb_exit 不命中）。
# 参数捕获停在 shell 元字符（;|&)）与空白，避免吃进 `exit 1;` 的分号。
EXIT_RE = re.compile(r'(?:^|[\s;`&|])exit(?=$|[\s;)&|])(?:\s+([^\s;|&)]+))?')
LEGAL_LITERAL = {'0', '1', '2', '3'}


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


def check_X(funcs, lines):
    """X: 字面 exit ∈ {0,1,2,3}；非字面/bare 仅允许在 require_path 体内。"""
    findings = []
    for name, start, end in funcs:
        if end is None:
            continue
        body = lines[start - 1:end]
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


def main(argv):
    args = [a for a in argv[1:] if a != '--']
    seed_y = '--seed-y' in args
    args = [a for a in args if a != '--seed-y']
    path = args[0] if args else DEFAULT_OB

    if not os.path.isfile(path):
        print(f'error: file not found: {path}', file=sys.stderr)
        return 2

    funcs = parse_funcs(path)
    lines = open(path).read().split('\n')

    # 边界不明的函数（extract_funcs end=?）—— 体扫描跳过，提示一下
    unknown = [n for n, _, e in funcs if e is None]
    if unknown:
        print(f'note: {len(unknown)} function(s) with undetermined end, body scan skipped: {unknown}')

    if seed_y:
        print('(--seed-y: implemented in Task 2)')
        return 0

    xf = check_X(funcs, lines)
    if xf:
        print('X: FAIL')
        for lineno, name, msg in xf:
            print(f'  {lineno}  {name}: {msg}')
    else:
        print('X: PASS')

    return 1 if xf else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
