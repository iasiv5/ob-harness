#!/usr/bin/env python3
"""ob 函数边界提取器（阶段 3b 物理重排辅助工具）。

提取 ob 单文件脚本中所有函数的 [name, start_line, end_line]：
  - 单行函数（log/info/warn/error/verbose，} 在行尾）→ end = start
  - 多行函数 → end = 该函数与下一函数起始行之间"最后一个顶格 }"
    （正确处理 python3 -c "..." 多行字符串内的顶格 }，如 generate_lockfile）

用法：python3 tools/extract_funcs.py ob
输出：每函数 start-end + name；TOTAL 计数；GAPS（函数间非注释内容，应为 0）。

配合 tools/reorder.py（reorder 复用本提取器的边界逻辑判定函数结束）。
GAPS=0 是重排安全的前提：函数间无夹杂顶层语句 → 重排仅改顺序，行为等价。
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
