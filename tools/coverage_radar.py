#!/usr/bin/env python3
"""tools/coverage_radar.py — xtrace 函数级覆盖雷达(两核心层之一:结构,自底向上运行时实测)。

复用 tools/extract_funcs.py 枚举 ob 92 函数(单一来源,不内联,边界判定与它同步);
读 xtrace(stdin 或文件),用 @@+(\\w+)@@ 提取唯一被调用函数集;与 92 函数求交,
输出 "函数 × 被测?" 矩阵 + 未覆盖清单 + 覆盖率%。

spike 已验证(2026-06-17):BASH_XTRACEFD + PS4='@@${FUNCNAME[0]:-main}@@ ' 能捕获
直接调用与子 shell/命令替换 transitive 调用;命令替换会产生 @@@func@@(重复首 @),
parser 用 @@+(\\w+)@@ 容错。设计未决事项 2 已解决。

已知采集局限(Task 5 收尾修):exit 函数(check_ports_available/parse_args/require_path/
prompt_for_available_port 等)经 assert_rc 的 bash -c 子进程测试,而 assert_rc 用
`>/dev/null 2>&1` 吞掉被测命令 stderr(xtrace 默认走 stderr),故这些函数 trace 不进
采集 log,COVERED 低估。实测:validate_pid(直接调)能命中,check_ports_available
(assert_rc 子进程)命中 0。修法:采集时用 BASH_XTRACEFD 导 trace 到独立 fd 绕过 >/dev/null,
或 assert.sh 加 trace 透传模式。当前 COVERED 仅反映"直接调用"函数的覆盖。

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
