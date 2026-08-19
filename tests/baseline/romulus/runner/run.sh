#!/usr/bin/env bash
# romulus baseline runner: 遍历 ar_probes.yaml × applicability → 逐条 probe →
# 收 pass/fail/skip/xfail/xpass → report.py → exit 0/1。
# per-machine (ADR-0025); host/port/auth 由调用方注入, 不硬编码。
#
# 结构地图(B3; 4 段, 每 python 件独立可单测):
#   ① 前置检查     — 参数/凭据(argv 或 env 至少一源)/PyYAML
#   ② plan.py      — YAML × applicability → schema 校验 + 过滤 + cascade-skip
#                    → \x1f 分隔计划行(数据错 → exit 3, 不进 α truth)
#   ③ 主循环       — 计划行逐条: skip(不调 probe)/xfail/applicable(调 probe);
#                    probe 输出经 assemble.py 协议校验 + 五态判定 → JSONL
#   ④ report.py    — 汇总 VERDICT + 逐条行 + 可选 JSON report; exit 0/1/3
#
# rc 纪律 (评审三轮 🔴1): set -euo pipefail 下 probe fail (exit 1) 不能裸调,
# 否则 errexit 中止 runner、report.py 不执行。每条 probe 用 if/else 捕获 rc。
set -euo pipefail

# 编码钉死(评审 🟢4, 四轮对撞定稿): 两个 export 各管一个敌意变体、互不可替 —
#   PYTHONIOENCODING=utf-8 覆盖"stdio 被压成 ascii"的预设(变体 B: xfail/xpass 的中文 reason
#     在装配层 print(ensure_ascii=False) 撞 ascii stdio 崩 → errexit → exit 1 假 α truth);
#   PYTHONUTF8=1 覆盖"UTF-8 mode 被关"的预设(变体 A: 内嵌 python -c 的中文注释经 argv
#     surrogateescape 解码崩 / open() 非 UTF-8)。PYTHONIOENCODING 优先级高于 UTF-8 mode
#   的 stdio 面, 故双 export 缺一即留一个洞。子进程(planner/probe/装配层/report)全继承。
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

HOST=""
PORT=""
USER_NAME=""
PASSWORD=""
AR_FILTER=""
SUITE_FILTER=""
REPORT_PATH=""
VERBOSE=0
DRY_RUN=0
TIMEOUT="${OB_TQ_TIMEOUT:-10}"

usage() {
  cat <<EOF
Usage: run.sh --host H --port P [--user U] [--password W] [options]
  Credentials: --user/--password argv OR OB_TQ_USER / OB_TQ_PASSWORD env.
  Env is preferred for real passwords (argv is ps-visible; environ is
  owner-only) — probe_redfish.py _resolve_auth consumes the env fallback.
  --ar ID         only run AR with this id
  --suite NAME    only run ARs in this suite
  --report PATH   dump JSON report to PATH
  -v, --verbose   per-AR lines also carry fail/error reason (live status
                  lines are always on)
  -d, --dry-run   list ARs + applicability, no probe, exit 0
  --timeout SE    per-probe HTTP timeout (default 10; env OB_TQ_TIMEOUT)
  -h, --help      show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --ar) AR_FILTER="$2"; shift 2 ;;
    --suite) SUITE_FILTER="$2"; shift 2 ;;
    --report) REPORT_PATH="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -d|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AR_PROBES="${OB_TQ_AR_PROBES:-$SCRIPT_DIR/../ar_probes.yaml}"
APPL="${OB_TQ_APPL:-$SCRIPT_DIR/../applicability.yaml}"
PROBE="${OB_TQ_PROBE:-$SCRIPT_DIR/probe_redfish.py}"
PLAN="$SCRIPT_DIR/plan.py"
ASSEMBLE="$SCRIPT_DIR/assemble.py"
REPORT="$SCRIPT_DIR/report.py"

if [[ $DRY_RUN -eq 0 ]]; then
  # 凭据各满足 argv 或 env 至少一源(评审 🟡2); 缺口指名, 不笼统一句。
  [[ -z "$HOST" || -z "$PORT" ]] && { echo "run.sh: --host/--port required (or use --dry-run)" >&2; exit 2; }
  _cred_missing=""
  [[ -z "$USER_NAME" && -z "${OB_TQ_USER:-}" ]] && _cred_missing="--user (or OB_TQ_USER env)"
  [[ -z "$PASSWORD" && -z "${OB_TQ_PASSWORD:-}" ]] && _cred_missing="$_cred_missing --password (or OB_TQ_PASSWORD env)"
  if [[ -n "$_cred_missing" ]]; then
    echo "run.sh: missing credentials:$_cred_missing" >&2
    exit 2
  fi
fi

# PyYAML 前置(计划全局约束): 缺失 → exit 3 + remedy, 不让 planner traceback 污染 α truth(评审 🔴2)
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "run.sh: PyYAML not installed (runner needs 'import yaml')." >&2
    echo "  Install: pip install pyyaml  (or your distro's python3-yaml)" >&2
    exit 3
fi

# ── ② planner: 读 yaml × applicability, 应用 --ar/--suite 过滤 + cascade-skip 传播。
# 产 \x1f 分隔行; YAML/schema 违规 → exit 3 + remedy(不 traceback, 不污染 α truth, 评审 🔴2)
if ! plan=$(AR_FILTER="$AR_FILTER" SUITE_FILTER="$SUITE_FILTER" \
       AR_PROBES="$AR_PROBES" APPL="$APPL" python3 "$PLAN"); then
    echo "run.sh: baseline parse/validate failed (see stderr above: YAML syntax / unknown assert type / bad applicability status / unknown depends_on)." >&2
    exit 3
fi

# 0 条 AR = 筛选/配置前置错误(非"全通过", 评审 🔴1): exit 3 + remedy
_ar_count=$(printf '%s\n' "$plan" | grep -c . 2>/dev/null || true)
if [[ "$_ar_count" -eq 0 ]]; then
    echo "run.sh: no AR selected." >&2
    if [[ -n "$AR_FILTER" ]]; then
        echo "  No AR matched --ar '$AR_FILTER' in $AR_PROBES." >&2
    elif [[ -n "$SUITE_FILTER" ]]; then
        echo "  No AR matched --suite '$SUITE_FILTER' in $AR_PROBES." >&2
    else
        echo "  baseline '$AR_PROBES' has no AR (empty 'ars:' list?)." >&2
    fi
    exit 3
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "dry-run: AR list + applicability (no probe)"
  while IFS=$'\x1f' read -r ar status method path body asserts reason source; do
    [[ -z "$ar" ]] && continue
    printf '  %-14s %s\n' "$ar" "$status"
  done <<< "$plan"
  exit 0
fi

results_file="$(mktemp)"
trap 'rm -f "$results_file"' EXIT

# ── ③ 主循环: 计划行逐条分派。skip/cascade_skip 不调 probe; xfail/applicable 调 probe,
# 输出经 assemble.py 协议校验 + 五态判定装成 JSONL record。
# 流式 UX(默认开): 每条 AR 完成即向 stderr 打一行 '  <AR> <status>' — 探测全程可见,
# 不再等 report 一次性吐出; -v 时 fail/error 行尾追加 reason 摘要(一行化规则与
# report.py 逐条行一致: 转字符串 + 换行替空格 + 截断 120, 保证每条 AR 恒一行)。
echo "probing $_ar_count ARs (timeout ${TIMEOUT}s per probe) — results stream below" >&2
while IFS=$'\x1f' read -r ar status method path body asserts reason source; do
  [[ -z "$ar" ]] && continue
  case "$status" in
    skip|cascade_skip)
      python3 "$ASSEMBLE" --skip "$ar" "$reason" "$source" >> "$results_file"
      printf '  %-14s %s\n' "$ar" "skip" >&2
      ;;
    xfail|applicable)
      # method/path 原字符串(planner 白名单/控制字符校验保证无 \n, 评审 🟡1)
      # 凭据条件传(评审 🟡2): argv 缺者不传, probe _resolve_auth 从 OB_TQ_* env 补 —
      # 密码全程不落 argv(ps world-readable → environ owner-only)。
      probe_args=(python3 "$PROBE" --host "$HOST" --port "$PORT" \
                  --method "$method" --path "$path" \
                  --asserts "$asserts" --timeout "$TIMEOUT")
      [[ -n "$USER_NAME" ]] && probe_args+=(--user "$USER_NAME")
      [[ -n "$PASSWORD" ]] && probe_args+=(--password "$PASSWORD")
      [[ -n "$body" ]] && probe_args+=(--body "$body")
      if out=$("${probe_args[@]}"); then rc=0; else rc=$?; fi
      # probe 协议校验 + 五态判定经 assemble.py(评审 🔴1: 不一致 → error record,
      # 不假 PASS/冒充 BMC fail)。装配层 rc 兜底(评审 🟡1): 内联 python 异常不允许经
      # errexit 折叠成 exit 1 假 α truth — 失败改记 error record(infra)。已知触发器
      # (编码崩溃)已被头部双 export 消灭, 本分支属防御性: 敌意 env 回归用例走的是
      # 预防层, 不断言此分支, 勿再为它造测(四轮对撞结论)。
      _rec=""
      _rec=$(printf '%s' "$out" | python3 "$ASSEMBLE" "$ar" "$status" "$source" "$reason" "$rc") || _rec=""
      if [[ -z "$_rec" ]]; then
          # 若真崩则 errexit 可见, 好过静默丢 AR 记录(report 读空行会被 skip,
          # AR 既不 pass 也不 fail)。
          _rec=$(python3 "$ASSEMBLE" --fallback "$ar")
      fi
      echo "$_rec" >> "$results_file"
      printf '  %-14s %s\n' "$ar" "$(python3 -c '
import json, sys
r = json.loads(sys.argv[1])
st = r.get("status", "?")
if sys.argv[2] == "1" and st in ("fail", "error"):
    # reason 摘要同 report.py 逐条行: 转字符串 + 换行替空格 + 截断 120
    st += " " + str(r.get("reason", "") or "").replace("\n", " ")[:120]
print(st)
' "$_rec" "$VERBOSE")" >&2
      ;;
    *)
      echo "run.sh: unknown applicability status '$status' for $ar" >&2
      exit 3
      ;;
  esac
done <<< "$plan"

# ── ④ report: 逐条行 + 可选 JSON + 末行 VERDICT; exit 0(无 applicable fail)/1(α truth)/3(infra)。
report_args=(python3 "$REPORT" --results "$results_file")
if [[ -n "$REPORT_PATH" ]]; then
  report_args+=(--report "$REPORT_PATH")
fi
# 流式行已默认实时流过 stderr(见 ③ 段), report 恒跳过 pass 行防双打(A4);
# 非 pass 行(code/reason/source)仍全量保留。
report_args+=(--compact-rows)
if "${report_args[@]}"; then rc=0; else rc=$?; fi
exit "$rc"
