#!/usr/bin/env python3
"""tools/coverage_radar.py — xtrace 函数级覆盖雷达(两核心层之一:结构,自底向上运行时实测)。

复用 tools/extract_funcs.py 枚举 ob 92 函数(单一来源,不内联,边界判定与它同步);
读 xtrace(stdin 或文件),用 @@+(\\w+)@@ 提取唯一被调用函数集;与 92 函数求交,
输出 "函数 × 被测?" 矩阵 + 未覆盖清单 + 覆盖率%。

spike 已验证(2026-06-17):BASH_XTRACEFD + PS4='@@${FUNCNAME[0]:-main}@@ ' 能捕获
直接调用与子 shell/命令替换 transitive 调用;命令替换会产生 @@@func@@(重复首 @),
parser 用 @@+(\\w+)@@ 容错。设计未决事项 2 已解决。

采集局限与对策(2026-06-17 实测定论):"直接调用"的 ob 函数能被 xtrace 采集;但
assert_rc 的 bash -c 子进程测试的 exit 函数(check_ports_available/parse_args/
require_path/prompt_for_available_port)不采集——真因是嵌套 bash -c 不继承父的 -x
(bash 限制,非 assert_rc 吞 stderr;实测 BASH_XTRACEFD=3 下 validate_pid 直接调命中、
check_ports_available bash -c 子进程仍 0)。对策:tools/trace_collect.sh 采集直接调用
函数(COVERED 反映此);exit 函数靠 checklist(tools/coverage_matrix.md)补偿——两核心层
交叉的设计本意。用法:tools/trace_collect.sh | python3 tools/coverage_radar.py -

用法:
  python3 tools/coverage_radar.py trace.log      # 解析文件
  echo '@@g@@' | python3 tools/coverage_radar.py -    # 从 stdin
  bash -x tests/unit/url.sh 2>trace.log; python3 tools/coverage_radar.py trace.log
"""
import re, subprocess, sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parent
OB = REPO / "ob"


def list_funcs():
    """调 extract_funcs.py 拿 ob 全部函数名(单一来源;改边界判定需与 extract_funcs.py 同步)。"""
    out = subprocess.run(
        [sys.executable, str(TOOLS / "extract_funcs.py"), str(OB)],
        capture_output=True, text=True, check=True).stdout
    funcs = []
    for line in out.splitlines():
        m = re.match(r'\s*\d+\s*-\s*\d+\s+(\w+)', line)
        if m:
            funcs.append(m.group(1))
    return funcs


def parse_trace(text):
    """从 xtrace 文本提取唯一被调用函数集(@@func@@ 或命令替换的 @@@func@@)。"""
    return set(re.findall(r'@@+(\w+)@@', text))


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "-"
    text = sys.stdin.read() if src == "-" else Path(src).read_text()
    called = parse_trace(text)
    funcs = list_funcs()
    total = len(funcs)
    covered = [f for f in funcs if f in called]
    missing = [f for f in funcs if f not in called]
    for f in funcs:
        print(f"  {'✓' if f in called else '✗'} {f}")
    pct = 100 * len(covered) // total if total else 0
    print(f"\nTOTAL {total}  COVERED {len(covered)}  ({pct}%)")
    if missing:
        print(f"\n未覆盖 ({len(missing)}):")
        for f in missing:
            print(f"  - {f}")


if __name__ == "__main__":
    main()
