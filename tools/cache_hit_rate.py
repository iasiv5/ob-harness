#!/usr/bin/env python3
"""Claude Code transcript 缓存命中率分析 —— 只读观测工具。

从 ~/.claude/projects/<proj>/*.jsonl 里逐 message 聚合 usage 字段，算 prompt
缓存命中率，验证「严格门禁 → 高缓存命中 → 低成本」飞轮是否在转
(axiom V6 概率乘 2.6 / bestpractice_08 eval 门禁模式库)。

口径: hit_rate = cache_read / (input + cache_creation + cache_read)
本环境(GLM 后端) cache_creation 恒 0, 故 = cache_read/(input+cache_read)。

【什么时候用】
  - 想知道某项目/某阶段的缓存命中率(飞轮健康度)
  - 对比长短会话命中率差异(飞轮因果链的可视化证据: 长会话应更高)
  - 命中率持续走低 = 门禁在松或 context 在碎, 需排查

【怎么用】
  $ python3 tools/cache_hit_rate.py                  # 默认扫 cwd 对应的 project dir
  $ python3 tools/cache_hit_rate.py <dir|file>       # 扫指定目录或单 jsonl
  $ python3 tools/cache_hit_rate.py <dir> --recent 10   # 只看最近 10 个 session
  $ python3 tools/cache_hit_rate.py --help
  退出码: 0 = 正常输出; 1 = 路径无效/无 usage 数据; 2 = 参数错误。

【边界】只读, 不修改任何 transcript。逐行流式读 jsonl(文件可达 MB 级, 不整体 load)。
【数据口径】客户端侧 cache token(Claude Code SDK 记录), 非后端计费层。对「验证飞轮
  是否工作」这一目的足够且正确: 直接反映同一段 context 有没有被反复高效复用。
【由来】克谦方法论「多烧≠多花钱」飞轮的可观测化 —— V2 可验证性: 把信念变度量。
"""
import glob
import json
import os
import sys


def default_project_dir():
    """Claude Code project dir 命名规则: cwd 的 / 替换为 -, 前缀 -。
    /bmc/iasi/ob-harness -> ~/.claude/projects/-bmc-iasi-ob-harness"""
    slug = os.getcwd().replace("/", "-")
    return os.path.join(os.path.expanduser("~"), ".claude", "projects", slug)


def collect_files(target):
    if os.path.isdir(target):
        return sorted(glob.glob(os.path.join(target, "*.jsonl")))
    if os.path.isfile(target):
        return [target]
    return []


def agg_session(path):
    """流式聚合单个 jsonl 的 usage。返回 (msgs, fresh_in, cache_w, cache_r)。"""
    ti = cc = cr = n = 0
    try:
        with open(path) as f:
            for line in f:
                if '"usage"' not in line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                u = (ev.get("message") or {}).get("usage")
                if not u:
                    continue
                ti += u.get("input_tokens", 0)
                cc += u.get("cache_creation_input_tokens", 0)
                cr += u.get("cache_read_input_tokens", 0)
                n += 1
    except OSError:
        pass
    return n, ti, cc, cr


def main(argv):
    recent = None
    args = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--recent":
            i += 1
            if i >= len(argv):
                print("error: --recent needs an integer", file=sys.stderr)
                return 2
            try:
                recent = int(argv[i])
            except ValueError:
                print("error: --recent needs an integer", file=sys.stderr)
                return 2
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            args.append(a)
        i += 1

    target = args[0] if args else default_project_dir()
    files = collect_files(target)
    if not files:
        print(f"error: no .jsonl under {target}", file=sys.stderr)
        return 1
    if recent:
        files = files[-recent:]

    rows = []
    for f in files:
        n, ti, cc, cr = agg_session(f)
        if n == 0:
            continue
        rows.append((os.path.basename(f), n, ti, cc, cr))

    if not rows:
        print(f"error: no usage data in {target}", file=sys.stderr)
        return 1

    print(f"cache hit-rate report  (project: {target})")
    print(f"{'session':<12}{'msgs':>6}{'fresh_in':>12}{'cache_w':>10}{'cache_r':>12}{'hit_rate':>10}")
    g_n = g_ti = g_cc = g_cr = 0
    # buckets: [count, total_tokens, cache_tokens], 按 msgs 分档可视化飞轮
    bk = {"cold": [0, 0, 0], "warm": [0, 0, 0], "hot": [0, 0, 0]}
    for name, n, ti, cc, cr in rows:
        total = ti + cc + cr
        rate = (cr / total * 100) if total else 0.0
        print(f"{name[:12]:<12}{n:>6}{ti:>12,}{cc:>10,}{cr:>12,}{rate:>9.1f}%")
        g_n += n; g_ti += ti; g_cc += cc; g_cr += cr
        b = "cold" if n < 30 else ("warm" if n <= 100 else "hot")
        bk[b][0] += 1; bk[b][1] += total; bk[b][2] += cr

    g_total = g_ti + g_cc + g_cr
    g_rate = (g_cr / g_total * 100) if g_total else 0.0
    print("-" * 62)
    print(f"{'TOTAL':<12}{g_n:>6}{g_ti:>12,}{g_cc:>10,}{g_cr:>12,}{g_rate:>9.1f}%")
    print(f"\nbuckets by session length (飞轮证据: 长会话命中率应更高):")
    for label, (cnt, tot, cr) in bk.items():
        if cnt == 0:
            continue
        r = (cr / tot * 100) if tot else 0.0
        rng = {"cold": "<30 msgs", "warm": "30-100", "hot": ">100"}[label]
        print(f"  {label:<5} ({rng:<8}): {r:>5.1f}%  ({cnt} sessions)")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
