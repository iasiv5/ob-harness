#!/usr/bin/env python3
"""smoke suite baseline-diff —— 两份 `ob test-qemu --suite smoke --report` JSON
的回归闸门(只读)。

给定 baseline 与 current 两次 smoke suite 的 JSON report(report.py 实测契约:
顶层 {verdict, counts, records}, 配对键 records[].ar, 判定字段 records[].status
∈ pass/fail/skip/xfail/xpass/error), 按 AR 配对, 把两类判为回归(退化):
**pass→fail**(同名退化) 与 **baseline 无此 AR + current fail**(新出现的失败 AR)。
fail→pass 改善仍作 info; skip/error 行不参与(error 属 infra 非真相)。

【设计: 为何按 AR 配对】
  report 每条 record 含 code/body/reason 等运行态信息, baseline 与 current 几乎
  总不同。按 records[].ar(AR ID, 如 SMOKE-04)配对, 判定只看 status 语义, 细节
  变化不构成假回归。

【什么算回归】  两类 → exit 1:
    (1) baseline=pass 且 current=fail(同名 pass→fail 退化);
    (2) baseline 无此 AR + current=fail(新出现的失败 AR — 全新的 fail 理应拦截)。
  不算回归(作 info): fail→pass 改善、新出现的非 fail AR、消失的 AR。
  skip/error 记录整体不参与配对判定(infra/skip 非 α 真相)。

【什么时候用】
  CI 把 smoke suite 当回归闸门: 改前/改后两次
  `ob test-qemu <machine> --suite smoke --report <tmp>` → smoke_diff →
  exit 0 = 无退化、exit 1 = 有退化(temporal gate 归 caller, ADR-0020/0028)。

【怎么用】
  $ python3 tools/smoke_diff.py <baseline.json> <current.json>
  $ python3 tools/smoke_diff.py --help
  退出码: 0 = 无回归; 1 = 检出回归(pass→fail 退化 或 新出现的 fail); 2 = 参数/文件错误。

【边界】只读, 不修改输入文件。重复 AR 按首次出现保留(report 生成侧已保证唯一)。
"""
import json
import sys


def parse(path):
    """解析 report JSON -> 有序 dict {ar: status}。

  skip/error 记录整体丢弃(infra/skip 非 α 真相, 不参与回归判定)。
  Schema 漂移 fail-closed(评审 🔴): 任一 record 非 dict / ar 非非空 str /
  status 不在白名单 / AR 重复 → ValueError(exit 2)——静默丢弃会把 schema
  漂移(如 status 误写成 verdict)折叠成"消失 AR"假放行。
    """
    with open(path, encoding='utf-8') as f:
        doc = json.load(f)
    if not isinstance(doc, dict) or not isinstance(doc.get('records'), list):
        raise ValueError('not a test-qemu report (want top-level {verdict, counts, records})')
    seen = {}
    for rec in doc['records']:
        if not isinstance(rec, dict):
            raise ValueError('record is not a mapping: {!r}'.format(rec))
        ar = rec.get('ar')
        st = rec.get('status')
        if not isinstance(ar, str) or not ar:
            raise ValueError('record has bad "ar": {!r}'.format(rec))
        if st not in ('pass', 'fail', 'skip', 'xfail', 'xpass', 'error'):
            raise ValueError('record {!r} has bad "status": {!r}'.format(ar, st))
        if ar in seen:
            raise ValueError('duplicate record for AR {!r}'.format(ar))
        if st in ('skip', 'error'):
            continue  # infra/skip 非 α 真相
        seen[ar] = st
    return seen


def main(argv):
    args = [a for a in argv[1:] if a not in ('-h', '--help')]
    if '-h' in argv or '--help' in argv or len(args) != 2:
        print(__doc__)
        return 0 if ('-h' in argv or '--help' in argv) else 2

    base_path, cur_path = args[0], args[1]
    try:
        base = parse(base_path)
    except (OSError, ValueError) as e:
        print(f"error: cannot parse {base_path}: {e}", file=sys.stderr)
        return 2
    try:
        cur = parse(cur_path)
    except (OSError, ValueError) as e:
        print(f"error: cannot parse {cur_path}: {e}", file=sys.stderr)
        return 2

    regressions = []        # pass→fail (退化, fail)
    improvements = []       # fail→pass (改善, info)
    added = []              # 仅 current 出现的非 fail (info)
    removed = []            # 仅 baseline 出现 (info)

    for ar, cst in cur.items():
        if ar in base:
            bst = base[ar]
            if bst == 'pass' and cst == 'fail':
                regressions.append(ar)
            elif bst == 'fail' and cst == 'pass':
                improvements.append(ar)
        elif cst == 'fail':
            # baseline 无此 AR + current fail 也算回归: 全新 fail 理应拦截。
            regressions.append(ar)
        else:
            added.append(ar)

    for ar in base:
        if ar not in cur:
            removed.append(ar)

    # ── 报告 ──
    print(f"smoke baseline-diff: {base_path} vs {cur_path}")
    print(f"  baseline AR: {len(base)} 条 / current AR: {len(cur)} 条")

    if regressions:
        print("")
        print(f"REGRESSION — 检出 {len(regressions)} 条退化(pass→fail 或 baseline 无此 AR 的新 fail):")
        for ar in regressions:
            if ar in base:
                print(f"  ✗ {ar}  baseline: pass → current: fail")
            else:
                print(f"  ✗ {ar}  baseline: (absent — new AR, not present in baseline) → current: fail")

    if improvements:
        print("")
        print(f"info — {len(improvements)} 条 fail→pass 改善(不算回归):")
        for ar in improvements:
            print(f"  ✓ {ar}")

    if added:
        print("")
        print(f"info — {len(added)} 条新出现的非 fail AR(不算回归):")
        for ar in added:
            print(f"  + {ar}")

    if removed:
        print("")
        print(f"info — {len(removed)} 条消失 AR(不算回归):")
        for ar in removed:
            print(f"  - {ar}")

    print("")
    if regressions:
        print(f"FAIL: {len(regressions)} 条回归(pass→fail 或 新 fail) — 闸门拦截")
        return 1
    print("OK: 无回归(pass→fail 或 新 fail) — 闸门放行")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
