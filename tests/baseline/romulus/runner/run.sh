#!/usr/bin/env bash
# romulus baseline runner 薄 shim: 全部编排在 runner.py(结构地图与 rc 纪律
# 见 runner.py docstring)。本件只保留编码钉死 + exec 透传。
# per-machine (ADR-0025); host/port/auth 由调用方注入, 不硬编码。
#
# 编码钉死(评审 🟢4, 四轮对撞定稿): 两个 export 各管一个敌意变体、互不可替 —
#   PYTHONIOENCODING=utf-8 覆盖"stdio 被压成 ascii"的预设(变体 B: xfail/xpass 的中文 reason
#     在装配层 print(ensure_ascii=False) 撞 ascii stdio 崩 → errexit → exit 1 假 α truth);
#   PYTHONUTF8=1 覆盖"UTF-8 mode 被关"的预设(变体 A: 内嵌 python -c 的中文注释经 argv
#     surrogateescape 解码崩 / open() 非 UTF-8)。PYTHONIOENCODING 优先级高于 UTF-8 mode
#   的 stdio 面, 故双 export 缺一即留一个洞。子进程(runner.py 自身/planner/probe/装配/
#   report)全继承 — bash 编排下沉后防御面不减。

# 编码钉死(评审 🟢4): 见上方注释; 论据为 probe 子进程继承 + 敌意 env 防御不减。
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/runner.py" "$@"
