#!/usr/bin/env python3
"""ob smoke baseline-diff —— 两次 smoke 输出的回归闸门(只读)。

给定 baseline 与 current 两次 `ob smoke` 的输出文件, 解析其中的断言行
(`  ✓ <name> (...)` / `  ✗ <name> (...)`), 按断言名配对, 把两类判为回归(退化):
**✓→✗**(同名退化) 与 **baseline 无此名 + current ✗**(新出现的失败断言)。
✗→✓ 改善仍作 info; ✓→✓/✗→✗ 不变; 新出现的 ✓ 与消失的断言名只作 info 打印, 不据此 fail。

【设计: 为何按"断言名"而非整行配对】
  smoke 每条断言行 = `mark + 断言名 + (细节)`, 细节含 HTTP code / ipmitool rc /
  固件版本等运行态信息, baseline 与 current 几乎总不同。若按整行配对, 一条
  ✓→✗ 退化会被误读成"旧 ✓ 行消失 + 新 ✗ 行出现"(归入 info, 不 fail), 闸门失效。
  故配对 key 取断言名(行首 mark 后、首个 ` (` 前的稳定头部), 如
  "Redfish root reachable"、"IPMI over LAN works"、"System ready signal"。

【什么算回归】  两类 → exit 1:
    (1) baseline=✓ 且 current=✗(同名 ✓→✗ 退化);
    (2) baseline 无此名 + current=✗(新出现的失败断言 — 一个全新的 ✗ 理应拦截)。
  不算回归(作 info): ✗→✓ 改善、✓→✓/✗→✗ 不变、新出现的 ✓、消失的断言名。

【什么时候用】
  - CI 把 `ob smoke` 当回归闸门: 改前 smoke → baseline, 改后 smoke → current,
    `smoke_diff baseline current` exit 0 = 无退化、exit 1 = 有退化。
  - agent modify→verify 回路: 改前/改后两次 smoke 比对, 机器无关地判回归
    (ADR-0020: 回归判定归 caller, smoke 自身保持 α 纯报真相、零 per-machine 知识)。

【怎么用】
  $ python3 tools/smoke_diff.py <baseline> <current>
  $ python3 tools/smoke_diff.py --help
  退出码: 0 = 无回归; 1 = 检出回归(✓→✗ 退化 或 新出现的 ✗); 2 = 参数/文件错误。

【边界】只读, 不修改输入文件。重复断言行(如 smoke fail 时 breakdown 段重打
  `✗ <name>`)按首次出现保留(judge 行先打, 带 detail; breakdown 重打后打, 无 detail)。
"""
import re
import sys

ASSERT_RE = re.compile(r'^\s*([✓✗])\s+(.+)$')


def canonical_name(text):
    """断言行 mark 后的稳定头部: 首个 ' (' 前的文本; 无括号细节则整段。

    例: 'Redfish root reachable (HTTP 200, ...)' -> 'Redfish root reachable'
        'System ready signal (SSH port TCP-connectable)' -> 'System ready signal'
        'IPMI over LAN works' -> 'IPMI over LAN works'
    """
    idx = text.find(' (')
    head = text[:idx] if idx != -1 else text
    return head.strip()


def parse(path):
    """解析 smoke 输出文件 -> 有序 dict {canonical_name: (mark, raw_line)}。

    重复同名行(breakdown 段重打)按首次出现保留(judge 行带 detail, 先打)。
    """
    seen = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for raw in f:
            line = raw.rstrip('\n')
            m = ASSERT_RE.match(line)
            if not m:
                continue
            mark = m.group(1)
            name = canonical_name(m.group(2))
            if name not in seen:           # keep-first: judge 行先于 breakdown 重打
                seen[name] = (mark, line.strip())
    return seen


def main(argv):
    args = [a for a in argv[1:] if a not in ('-h', '--help')]
    if '-h' in argv or '--help' in argv or len(args) != 2:
        print(__doc__)
        return 0 if ('-h' in argv or '--help' in argv) else 2

    base_path, cur_path = args[0], args[1]
    for p in (base_path, cur_path):
        try:
            open(p, encoding='utf-8').close()
        except OSError as e:
            print(f"error: cannot read {p}: {e}", file=sys.stderr)
            return 2

    base = parse(base_path)
    cur = parse(cur_path)

    regressions = []        # ✓→✗ (退化, fail)
    improvements = []       # ✗→✓ (改善, info)
    added = []              # 仅 current 出现 (info)
    removed = []            # 仅 baseline 出现 (info)

    for name, (cmark, cline) in cur.items():
        if name in base:
            bmark, bline = base[name]
            if bmark == '✓' and cmark == '✗':
                regressions.append((name, bline, cline))
            elif bmark == '✗' and cmark == '✓':
                improvements.append((name, bline, cline))
        elif cmark == '✗':
            # 新出现的 ✗(baseline 无此名)也算回归: 一个全新的失败断言理应拦截。
            # bline 置 None, 渲染时打 (absent — new assertion)。
            regressions.append((name, None, cline))
        else:
            added.append((name, cline))

    for name, (bmark, bline) in base.items():
        if name not in cur:
            removed.append((name, bline))

    # ── 报告 ──
    print(f"smoke baseline-diff: {base_path} vs {cur_path}")
    print(f"  baseline 断言: {len(base)} 条 / current 断言: {len(cur)} 条")

    if regressions:
        print("")
        print(f"REGRESSION — 检出 {len(regressions)} 条退化(✓→✗ 或 baseline 无此名的新 ✗):")
        for name, bline, cline in regressions:
            print(f"  ✗ {name}")
            if bline is None:
                print(f"      baseline : (absent — new assertion, not present in baseline)")
            else:
                print(f"      baseline : {bline}")
            print(f"      current  : {cline}")

    if improvements:
        print("")
        print(f"info — {len(improvements)} 条 ✗→✓ 改善(不算回归):")
        for name, bline, cline in improvements:
            print(f"  ✓ {name}")

    if added:
        print("")
        print(f"info — {len(added)} 条新出现的 ✓ 断言(不算回归):")
        for name, cline in added:
            print(f"  + {name}")

    if removed:
        print("")
        print(f"info — {len(removed)} 条消失断言(不算回归):")
        for name, bline in removed:
            print(f"  - {name}")

    print("")
    if regressions:
        print(f"FAIL: {len(regressions)} 条回归(✓→✗ 或 新 ✗) — 闸门拦截")
        return 1
    print("OK: 无回归(✓→✗ 或 新 ✗) — 闸门放行")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
