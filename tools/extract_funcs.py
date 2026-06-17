#!/usr/bin/env python3
"""ob 函数边界提取器 —— 只读体检工具（不修改 ob）。

列出 ob 全部函数的 [name, start_line, end_line]，并检查 ob 结构是否“干净”。
零副作用，随时可跑。

【什么时候用】
  - 动 ob 前先跑一次，确认 GAPS=0 —— 这是 reorder.py 能安全重排的前提
  - 给 ob 加了新函数后，确认它被正确识别、边界无误
  - 怀疑函数之间混进了顶层语句（会破坏可重排结构）时，用它定位
  - 只想快速看一眼 ob 有哪些函数、各在第几行时

【怎么用】
  $ python3 tools/extract_funcs.py ob
  输出：
    start-end  func_name    每个函数的起止行 + 名字
    TOTAL 92                函数总数
    GAPS 0                  函数之间夹杂的非注释顶层语句数（必须为 0）

【GAPS=0 的含义】
  ob 的顶层可执行语句只允许在头部（§1 变量）和尾部（main 调用），函数定义之间不得
  夹杂物。bash 函数顺序不影响执行（调用都在 main 里），所以只要 GAPS=0，重排只是改
  顺序、行为等价；GAPS>0 说明有人在函数间塞了顶层语句，必须先清理。

【边界判定（维护参考）】
  - 单行函数（log/info/warn/error/verbose，} 在行尾）→ end = start
  - 多行函数 → end = 与下一函数起始行之间“最后一个顶格 }”
    （能穿过 python3 -c "..." 多行字符串里的顶格 }，如 generate_lockfile）

【由来】ob §1-§7 分层重构时写的体检工具。reorder.py 内联了同一套边界逻辑，
改判定规则需两处同步。
"""
import re, sys
lines = open(sys.argv[1]).read().split('\n')
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
