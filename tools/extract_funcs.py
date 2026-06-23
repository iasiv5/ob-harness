#!/usr/bin/env python3
"""ob 函数边界提取器 —— 只读体检工具（不修改 ob/lib）。

列出给定文件全部函数的 [name, start_line, end_line]，并检查结构是否“干净”。
零副作用，随时可跑。

【什么时候用】
  - 动 ob/lib 前先跑一次，确认结构干净 —— 这是 reorder/搬迁能安全进行的前提
  - 给 ob/lib 加了新函数后，确认它被正确识别、边界无误
  - 怀疑函数之间/前后混进了顶层语句（会破坏纯函数定义结构）时定位
  - 只想快速看一眼某文件有哪些函数、各在第几行

【怎么用】
  $ python3 tools/extract_funcs.py ob           # 入口(豁免三段检查,只查函数间)
  $ python3 tools/extract_funcs.py lib/util.sh  # lib 文件(三段全查)
  $ python3 tools/extract_funcs.py <任意文件>    # 路径含 lib/ 即按 lib 规则
  输出：
    start-end  func_name    每个函数的起止行 + 名字
    TOTAL N                 函数总数
    GAPS 0                  函数之间夹杂的非注释顶层语句数(ob 入口也要求 0)
    [HEADER_TOPLEVEL ...]   lib 文件首个函数前有执行语句(shebang/注释除外)
    GAP ...                 lib 文件函数之间有执行语句
    [FOOTER_TOPLEVEL ...]   lib 文件最后函数后有执行语句(空行/注释除外)
  任一 HEADER_TOPLEVEL/GAP/FOOTER_TOPLEVEL → 退出码 1。

【GAPS=0 的含义】
  函数定义之间不得夹杂物。bash 函数顺序不影响执行（调用都在 main 里），所以只要
  GAPS=0，重排只是改顺序、行为等价；GAPS>0 说明有人在函数间塞了顶层语句，必须先清理。

【三段纯函数定义检查（仅 lib/ 路径文件,ob 入口豁免）】
  lib 文件必须是纯函数定义集（被 ob source），保证 source 顺序不承载执行语义:
  - header(首个函数前): 只允许 shebang、空行、注释。
  - 函数之间: GAPS=0(沿用)。
  - footer(最后函数后): 只允许空行、注释。
  ob 入口允许 source loop / main 调用等顶层语句,故豁免三段检查(只查 GAPS)。
  lib 路径判定: 路径某一级目录名为 'lib'(/tmp/x/lib/y.sh 或 lib/util.sh)。

【边界判定（维护参考）】
  - 单行函数（log/info/warn/error/verbose，} 在行尾）→ end = start
  - 多行函数 → end = 与下一函数起始行之间“最后一个顶格 }”
    （能穿过 python3 -c "..." 多行字符串里的顶格 }，如 generate_lockfile）

【由来】ob §1-§7 分层重构时写的体检工具。三段检查经 ob-modularize-lib-split
计划 v4 Task 3 加入（评审明确要求,不得只复用函数间 GAPS）。
"""
import os
import re
import sys

path = sys.argv[1]
lines = open(path).read().split('\n')
func_starts = []
brace_ends = []
for i, line in enumerate(lines, 1):
    mf = re.match(r'^([A-Za-z_]\w*)\s*\(\)', line)
    if mf:
        func_starts.append((i, mf.group(1)))
    if line == '}':
        brace_ends.append(i)
funcs = []
for k, (start, name) in enumerate(func_starts):
    defline = lines[start-1]
    if defline.rstrip().endswith('}'):   # single-line func
        end = start
    else:
        next_start = func_starts[k+1][0] if k+1 < len(func_starts) else len(lines)+1
        cands = [b for b in brace_ends if start < b < next_start]
        end = max(cands) if cands else None
    funcs.append((name, start, end))
for f in funcs:
    e = '?' if f[2] is None else f'{f[2]:5d}'
    print(f'{f[1]:5d}-{e}  {f[0]}')
print('TOTAL', len(funcs))
gaps = 0
for k in range(len(funcs)-1):
    end = funcs[k][2]; nxt = funcs[k+1][1]
    seg = lines[end:nxt-1]
    nontrivial = [s for s in seg if s.strip() and not s.strip().startswith('#')]
    if nontrivial:
        gaps += 1; print('GAP', funcs[k][0], '->', funcs[k+1][0], nontrivial[:3])
print('GAPS', gaps)

# 三段纯函数定义检查(仅 lib/ 路径文件;ob 入口豁免)
is_lib = 'lib' in path.replace('\\', '/').split('/')
violations = 0
if is_lib:
    if gaps:
        violations += gaps

    # header: 首个函数前只允许 shebang/空行/注释
    first_start = func_starts[0][0] if func_starts else len(lines) + 1
    for s in lines[:first_start - 1]:
        t = s.strip()
        if t and not t.startswith('#'):
            print('HEADER_TOPLEVEL', repr(s)); violations += 1
    # footer: 最后函数后只允许空行/注释
    if funcs and funcs[-1][2] is not None:
        last_end = funcs[-1][2]   # 最后函数 } 的行号(1-indexed)
        for s in lines[last_end:]:   # } 行之后
            t = s.strip()
            if t and not t.startswith('#'):
                print('FOOTER_TOPLEVEL', repr(s)); violations += 1
if violations:
    sys.exit(1)
