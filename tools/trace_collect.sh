#!/usr/bin/env bash
# tools/trace_collect.sh — 采集 ob 函数 xtrace 覆盖 trace(配合 coverage_radar.py)。
#
# 原理:对每个测试用 `BASH_XTRACEFD=3 bash -x` 显式开 xtrace,trace 写独立 fd3
# (绕过测试内的 >/dev/null 重定向),PS4='@@${FUNCNAME[0]}@@ ' 让每行含函数名。
#
# 覆盖范围:"直接调用"的 ob 函数(qemu_instance_is_alive/normalize_repo_url/read_kv_field/
#   write_source_manifest/derive_*/interact 的 select/confirm/prompt 等)。
# 采集波动(非确定):assert_rc/with_stub 的 bash -c 子进程测试的函数(check_ports_available/
#   parse_args/require_path/prompt_for_available_port 等)——其 xtrace 采集依赖
#   BASH_XTRACEFD 是否传到子进程 + 子进程 fd3 是否指向同一 log, 跨 bash/locale 不稳
#   (实测: 一环境捕 0 行→radar uncovered +1; 另一环境捕函数体→covered)。故 radar
#   uncovered 计数对这些函数 ±1 浮动, 不能当确定值; 语义覆盖靠 checklist 补偿。
#   根治(follow-up, 非本任务): 给 bash -c 子进程显式注入 BASH_XTRACEFD + set -x。
#
# 用法:
#   tools/trace_collect.sh | python3 tools/coverage_radar.py -   # 全 unit+protocol+orchestration
#   tools/trace_collect.sh tests/unit/url.sh | python3 tools/coverage_radar.py -   # 单个测试
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$DIR" || exit 1
LOG="$(mktemp)"; exec 3>"$LOG"
export PS4='@@${FUNCNAME[0]:-main}@@ '
if [[ $# -gt 0 ]]; then
    BASH_XTRACEFD=3 bash -x "$@" >/dev/null 2>&1 || true
else
    for f in tests/protocol/*.sh tests/unit/*.sh tests/orchestration/*.sh; do
        [[ -f "$f" ]] || continue
        BASH_XTRACEFD=3 bash -x "$f" >/dev/null 2>&1 || true
    done
fi
exec 3>&-
cat "$LOG"; rm -f "$LOG"
