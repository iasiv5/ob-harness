#!/usr/bin/env python3
"""Claude Code transcript 缓存命中率分析 —— 只读观测工具。

从 ~/.claude/projects/<proj>/*.jsonl 里逐 message 聚合 usage 字段，算 prompt
缓存命中率，验证「严格门禁 → 高缓存命中 → 低成本」飞轮是否在转
(axiom V6 概率乘 2.6 / bestpractice_08 eval 门禁模式库)。

【口径】只统计输入侧 (input-side) prompt cache:
  总输入 = 新鲜输入(fresh) + 缓存写入(cache_w) + 缓存命中(cache_r)
  命中率 = 缓存命中 ÷ 总输入
  总输出(output_tokens) 单列展示, 不参与命中率。
【本环境(GLM)特性: cache_w 恒 0 不代表无缓存】
  GLM 把缓存写入量并入新鲜输入(input_tokens), 未单列到 cache_creation,
  故 cache_w 列恒 0 —— 但缓存机制确实在工作(首轮整块首次输入全算 fresh、
  compact 重建时 fresh 暴涨 + hit 暴跌可证)。命中率 = cache_r/(fresh+cache_r)。
  推论: ①命中率数值仍准(写入并入 fresh 不改分母 hit/(fresh+creation+hit));
        ②"新鲜输入占比"被高估(混入写入量, 真·纯新鲜更小)。
单位: 摘要/合计/buckets 用中文紧凑单位(亿/万) + Tokens, 明细表千分位。

【什么时候用】
  - 想知道某项目/某阶段的缓存命中率(飞轮健康度)
  - 对比长短会话命中率差异(飞轮因果链可视化: 长会话应更高)
  - 命中率持续走低 = 门禁在松或 context 在碎(compact 是命中杀手)

【怎么用】
  $ python3 tools/cache_hit_rate.py                  # 默认扫 cwd 对应的 project dir
  $ python3 tools/cache_hit_rate.py <dir|file>       # 扫指定目录或单 jsonl
  $ python3 tools/cache_hit_rate.py <dir> --recent 10   # 只看最近 10 个 session
  $ python3 tools/cache_hit_rate.py --help
  退出码: 0 = 正常输出; 1 = 路径无效/无 usage 数据; 2 = 参数错误。

【边界】只读, 不修改 transcript。流式逐行读 jsonl(MB 级，不整体 load)。
【数据口径】客户端侧 cache token(Claude Code SDK 记录), 非后端计费层。
【由来】克谦方法论「多烧≠多花钱」飞轮的可观测化 —— V2 可验证性: 把信念变度量。
"""
import glob
import json
import os
import sys


def default_project_dir():
    """Claude Code project dir 命名: cwd 的 / 替换为 -, 前缀 -。
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
    """流式聚合单个 jsonl 的 usage。返回 (msgs, fresh, cache_w, cache_r, output)。"""
    ti = cc = cr = out = n = 0
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
                out += u.get("output_tokens", 0)
                n += 1
    except OSError:
        pass
    return n, ti, cc, cr, out


def _disp_w(s):
    """估算终端显示宽度: CJK 及以上字符算 2, 其余 1(粗略, 够本脚本用)。"""
    return sum(2 if ord(c) > 0x2E80 else 1 for c in s)


def rjust_w(s, width):
    """按显示宽度右对齐(中文占 2 列)。"""
    pad = width - _disp_w(s)
    return s if pad <= 0 else " " * pad + s


def ljust_w(s, width):
    """按显示宽度左对齐(中文占 2 列)。"""
    pad = width - _disp_w(s)
    return s if pad <= 0 else s + " " * pad


def fmt_cn(n):
    """中文紧凑单位: >=1亿→'X.XX 亿', >=1万→'X.X 万', 否则原数。0→'0'。"""
    if n == 0:
        return "0"
    if n >= 1e8:
        return f"{n/1e8:.2f} 亿"
    if n >= 1e4:
        return f"{n/1e4:.1f} 万"
    return f"{n}"


def pct(num, den):
    return (num / den * 100) if den else 0.0


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
        n, ti, cc, cr, out = agg_session(f)
        if n == 0:
            continue
        rows.append((os.path.basename(f), n, ti, cc, cr, out))

    if not rows:
        print(f"error: no usage data in {target}", file=sys.stderr)
        return 1

    # ── 聚合合计 ──
    g_n = g_ti = g_cc = g_cr = g_out = 0
    bk = {"cold": [0, 0, 0], "warm": [0, 0, 0], "hot": [0, 0, 0]}  # [count, total_in, cache_r]
    for name, n, ti, cc, cr, out in rows:
        total = ti + cc + cr
        g_n += n; g_ti += ti; g_cc += cc; g_cr += cr; g_out += out
        b = "cold" if n < 30 else ("warm" if n <= 100 else "hot")
        bk[b][0] += 1; bk[b][1] += total; bk[b][2] += cr

    g_total = g_ti + g_cc + g_cr
    g_rate = pct(g_cr, g_total)
    n_sessions = len(rows)
    BAR = "━" * 68

    # ── 摘要卡片 ──
    print("缓存命中率报告  ·  Claude Code 输入侧 prompt cache")
    print(f"项目  {target}")
    print(f"范围  {n_sessions} 会话 / {g_n:,} 消息(assistant turns)")
    print()
    print(BAR)
    print(f"  总输入      {rjust_w(fmt_cn(g_total),10)} Tokens    (= 新鲜 + 缓存写入 + 缓存命中)")
    print(f"    缓存命中  {rjust_w(fmt_cn(g_cr),10)} {g_rate:5.1f}%       ← 近乎免费, 同一段 context 反复复用")
    print(f"    新鲜输入  {rjust_w(fmt_cn(g_ti),10)} {pct(g_ti, g_total):5.1f}%       ← 真正计费/计配额")
    if g_cc == 0:
        cc_field, cc_note = "    ", "← GLM: 写入已并入上方新鲜输入"
    else:
        cc_field, cc_note = f"{pct(g_cc, g_total):5.1f}%", "← 首次计算+存储 KV cache (投资)"
    print(f"    缓存写入  {rjust_w(fmt_cn(g_cc),10)}    {cc_field}      {cc_note}")
    print(f"  总输出      {rjust_w(fmt_cn(g_out),10)} Tokens    (模型生成, 不计入命中率)")
    print(BAR)
    print()

    # ── 逐会话明细 ──
    print("逐会话明细  (命中率 = 缓存命中 ÷ 总输入; 输出独立, 单位 Tokens)")
    hdr = ("  " + "session".ljust(12) + "msgs".rjust(6)
           + rjust_w("总输入", 14) + rjust_w("缓存命中", 14)
           + rjust_w("新鲜输入", 14) + rjust_w("命中率", 9) + rjust_w("输出", 14))
    print(hdr)
    for name, n, ti, cc, cr, out in rows:
        total = ti + cc + cr
        print(f"  {name[:12]:<12}{n:>6}{total:>14,}{cr:>14,}{ti:>14,}"
              f"{pct(cr, total):>8.1f}%{out:>14,}")
    print("  " + "─" * 83)
    print(f"  {ljust_w('合计', 12)}{g_n:>6}"
          + rjust_w(fmt_cn(g_total), 14) + rjust_w(fmt_cn(g_cr), 14)
          + rjust_w(fmt_cn(g_ti), 14) + f"{g_rate:>8.1f}%"
          + rjust_w(fmt_cn(g_out), 14))
    print()

    # ── 飞轮证据 ──
    print("飞轮证据  (会话越长 → 固定 context 反复命中 → 命中率越高)")
    for label, (cnt, tot, cr) in bk.items():
        if cnt == 0:
            continue
        rng = {"cold": "<30 msgs", "warm": "30-100", "hot": ">100"}[label]
        print(f"  {label:<5} {rng:<9} {pct(cr, tot):5.1f}%   {cnt:>3} 会话    总输入 {fmt_cn(tot)} Tokens")
    print()
    print(f"缓存把重复输入的有效成本压缩到 {pct(g_ti, g_total):.1f}%"
          f" —— 仅 {fmt_cn(g_ti)} Tokens 按新鲜计费。")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
