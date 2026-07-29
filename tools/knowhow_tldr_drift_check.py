#!/usr/bin/env python3
"""know-how TL;DR 漂移预警 —— advisory 只读工具（不阻断）。

v1 用 git diff 结构检测：rules/knowhow/*.md 长文件（>100 行且有 ## TL;DR）若
正文段改动而 ## TL;DR 段未动 → flag「疑似漂移」，请人工复查。ADR-0015 把
「长 know-how 必须配 TL;DR」定为生产者硬义务；本工具守住它的下游风险——
作者改了正文忘改 TL;DR，让两份维护债不至于静默走样。

LLM 语义判断（正文换措辞、TL;DR 仍引旧措辞，字面段未动则无信号）为 v2 可选增强，
不在本范围；本仓库无任何调 LLM 的工具先例（cache_hit_rate / coverage_radar /
exit_contract 全是纯 python3 只读），v1 先零依赖覆盖最高发漂移。

【什么时候用】
  - 改了 know-how 正文后，想确认 TL;DR 是否也需要跟着更新
  - ob_check 第 5 项自动触发它（防 orphan）；也可单独跑

【怎么用】
  $ python3 tools/knowhow_tldr_drift_check.py        # 默认 git diff HEAD
  $ python3 tools/knowhow_tldr_drift_check.py --help  # 打印本 docstring

【定位】独立、只读、不阻断。退出码恒 0（advisory 不进 ob_check FAIL 计数）；
flag 只 echo 到 stdout，由人决定是否更新 TL;DR。
【边界】v1 是字面结构检测（hunk 落点），不做语义比对——能抓「正文改 TL;DR 没改」，
抓不到「都改了但语义不一致」（后者靠人工 review / v2 LLM）。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
THRESHOLD = 100
TLDR_RE = re.compile(r'^## TL;DR')   # 与 ob_check 1e 门禁 grep '^## TL;DR' 同口径: TL;DR 后可有后缀(如 bp_12 的 "## TL;DR · 30 秒决策...")
H2_RE = re.compile(r'^## ')
HUNK_RE = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')


def run_git_diff():
    """返回 {rel_path: diff_text}，只含改动的 rules/knowhow/*.md。"""
    names = subprocess.run(
        ['git', '-C', ROOT, 'diff', '--name-only', 'HEAD'],
        capture_output=True, text=True,
    ).stdout.splitlines()
    out = {}
    for rel in names:
        if rel.startswith('rules/knowhow/') and rel.endswith('.md'):
            diff = subprocess.run(
                ['git', '-C', ROOT, 'diff', 'HEAD', '--', rel],
                capture_output=True, text=True,
            ).stdout
            if diff:
                out[rel] = diff
    return out


def tldr_span(lines):
    """工作树文件的 TL;DR 段 1-based 行号区间 [start, end)；无 TL;DR 返回 None。

    start = `## TL;DR` 标题行；end = 下一个 `## ` 标题行（不含）。
    """
    start = None
    for i, ln in enumerate(lines, 1):
        if start is None:
            if TLDR_RE.match(ln):
                start = i
        elif H2_RE.match(ln):
            return (start, i)
    return (start, len(lines) + 1) if start else None


def hunk_overlap(diff, span):
    """解析 diff 的 hunk，返回 (has_tldr_hunk, has_body_hunk)。

    hunk 的 new 范围 [new_start, new_start+new_count) 与 TL;DR 段 span 相交 → tldr；
    否则 → body。横跨（罕见）保守计为 tldr。
    """
    s, e = span
    has_tldr = has_body = False
    for line in diff.splitlines():
        m = HUNK_RE.match(line)
        if not m:
            continue
        new_start = int(m.group(1))
        new_count = int(m.group(2)) if m.group(2) else 1
        new_end = new_start + new_count
        if new_start < e and new_end > s:
            has_tldr = True
        else:
            has_body = True
    return has_tldr, has_body


def main():
    if '--help' in sys.argv or '-h' in sys.argv:
        print(__doc__)
        return 0
    flags = []
    for rel, diff in run_git_diff().items():
        path = os.path.join(ROOT, rel)
        try:
            with open(path, encoding='utf-8') as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        if len(lines) <= THRESHOLD:
            continue
        span = tldr_span(lines)
        if not span:
            continue  # 无 TL;DR 的长文件归 1e hard gate 管，drift 不重复报
        has_tldr, has_body = hunk_overlap(diff, span)
        if has_body and not has_tldr:
            flags.append(
                f"疑似漂移：{rel} 正文改动但 ## TL;DR 段未更新，请人工复查"
            )
    for fl in flags:
        print(fl)
    return 0


if __name__ == '__main__':
    sys.exit(main())
