#!/usr/bin/env bash
# romulus baseline runner: 遍历 ar_probes.yaml × applicability → 逐条 probe →
# 收 pass/fail/skip/xfail/xpass → report.py → exit 0/1。
# per-machine (ADR-0025); host/port/auth 由调用方注入, 不硬编码。
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
  -v, --verbose   print per-AR status to stderr
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

# planner: 读 yaml × applicability, 应用 --ar/--suite 过滤 + cascade-skip 传播。
# 产 \x1f 分隔行; YAML 解析失败 → exit 3 + remedy(不 traceback, 不污染 α truth, 评审 🔴2)
if ! plan=$(AR_FILTER="$AR_FILTER" SUITE_FILTER="$SUITE_FILTER" \
       AR_PROBES="$AR_PROBES" APPL="$APPL" python3 -c '
import yaml, json, os, sys
af = os.environ.get("AR_FILTER", "")
sf = os.environ.get("SUITE_FILTER", "")
try:
    d = yaml.safe_load(open(os.environ["AR_PROBES"]))
    appl = yaml.safe_load(open(os.environ["APPL"]))
except Exception as e:
    sys.stderr.write("run.sh: cannot parse baseline YAML: %s\n" % e)
    sys.exit(3)
default = appl.get("default", "applicable")
overrides = appl.get("overrides", {})
ars = d["ars"]
_ALLOWED_APPL = ("applicable", "skip", "xfail")
def has_control_chars(value):
    return any(ord(ch) < 0x20 or ord(ch) == 0x7f for ch in value)
# schema 校验(评审 🟡3): default status 白名单(非法 → exit 3, 不 exit 2)
if default not in _ALLOWED_APPL:
    sys.stderr.write("run.sh: applicability default '%s' not in %s\n" % (default, ", ".join(_ALLOWED_APPL)))
    sys.exit(3)
# schema 校验: AR ID 是 framing + report identity, 须非空且不含控制字符。
for a in ars:
    ar_id = a.get("ar") if isinstance(a, dict) else None
    if not isinstance(ar_id, str) or not ar_id or has_control_chars(ar_id):
        sys.stderr.write("run.sh: bad AR ID %r (want non-empty string without control chars)\n" % ar_id)
        sys.exit(3)
# schema 校验(评审 🟡3): depends_on 引用完整性(未知 dependency 不默认 applicable)
ar_ids = {a["ar"] for a in ars}
for a in ars:
    for dep in (a.get("depends_on") or []):
        if dep not in ar_ids:
            sys.stderr.write("run.sh: AR '%s' depends_on unknown AR '%s'\n" % (a["ar"], dep))
            sys.exit(3)
# schema 校验(评审 🟡2): AR ID 唯一(重复 → exit 3, 否则同 AR 跑两次)
_seen = set()
for a in ars:
    if a["ar"] in _seen:
        sys.stderr.write("run.sh: duplicate AR ID '%s'\n" % a["ar"])
        sys.exit(3)
    _seen.add(a["ar"])
# schema 校验(评审 🟡2): orphan override(指向不存在 AR → exit 3)
for _o_id in overrides:
    if _o_id not in ar_ids:
        sys.stderr.write("run.sh: applicability override '%s' references unknown AR\n" % _o_id)
        sys.exit(3)
def meta(ar_id):
    o = overrides.get(ar_id, {})
    st = o.get("status", default)
    if st not in _ALLOWED_APPL:
        sys.stderr.write("run.sh: AR '%s' applicability status '%s' not in %s\n" % (ar_id, st, ", ".join(_ALLOWED_APPL)))
        sys.exit(3)
    return (st, o.get("reason", ""), o.get("source", ""))
stat = {a["ar"]: meta(a["ar"]) for a in ars}
# cascade-skip: depends_on 命中 skip/cascade_skip 的 AR 级联为 skip
changed = True
while changed:
    changed = False
    for a in ars:
        if stat[a["ar"]][0] == "applicable":
            for dep in (a.get("depends_on") or []):
                ds = stat.get(dep, ("applicable", "", ""))[0]
                if ds in ("skip", "cascade_skip"):
                    stat[a["ar"]] = ("cascade_skip", "depends_on " + dep + " skipped", "auto")
                    changed = True
_ALLOWED_ASSERT = ("status_in", "json_path_exists", "json_path_match")
_ALLOWED_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD")
for a in ars:
    if af and a["ar"] != af:
        continue
    if sf and a.get("suite") != sf:
        continue
    # schema 校验(评审二轮 🟡): 未知 assert type = baseline 数据错, exit 3(不当 BMC fail)
    for x in a.get("assert", []):
        if x.get("type") not in _ALLOWED_ASSERT:
            sys.stderr.write("run.sh: AR '%s' unknown assert type '%s'; allowed: %s\n" %
                             (a["ar"], x.get("type"), ", ".join(_ALLOWED_ASSERT)))
            sys.exit(3)
    # request 缺省容忍(评审配套⑤): 仅实际将 skip 的 AR 可省略 request — 无可执行
    # 探测定义就不该编造占位请求(如 Web banner AR 挂 GET /redfish/v1 的语义错位);
    # request 存在则无条件过白名单校验(数据要合法, applicability 改回 applicable 后即跑)。
    req = a.get("request") or {}
    if not req:
        if stat[a["ar"]][0] not in ("skip", "cascade_skip"):
            sys.stderr.write("run.sh: AR '%s' missing request (required unless applicability is skip)\n" % a["ar"])
            sys.exit(3)
        _m = ""
        _p = ""
    else:
        # method 白名单 + path 拒控制字符: 两者直接进入 framing/HTTP argv。
        _m = req.get("method", "")
        _p = req.get("path", "")
        if not isinstance(_m, str) or _m not in _ALLOWED_METHODS:
            sys.stderr.write("run.sh: AR '%s' bad HTTP method '%s'; allowed: %s\n" % (a["ar"], _m, ", ".join(_ALLOWED_METHODS)))
            sys.exit(3)
        if not isinstance(_p, str) or has_control_chars(_p):
            sys.stderr.write("run.sh: AR '%s' request.path has control chars or non-str\n" % a["ar"])
            sys.exit(3)
    body = req.get("body")
    body_json = json.dumps(body) if body is not None else ""
    asserts_json = json.dumps(a.get("assert", []))
    s, r, src = stat[a["ar"]]
    # framing: method/path 原字符串(白名单/控制字符校验保证无 \n); reason/src json.dumps(多行允许)
    print("\x1f".join([a["ar"], s, _m, _p,
                     body_json, asserts_json, json.dumps(r), json.dumps(src)]))
'); then
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

while IFS=$'\x1f' read -r ar status method path body asserts reason source; do
  [[ -z "$ar" ]] && continue
  case "$status" in
    skip|cascade_skip)
      python3 -c 'import json, sys
r = json.loads(sys.argv[2]) if sys.argv[2] else ""
src = json.loads(sys.argv[3]) if sys.argv[3] else ""
print(json.dumps({"ar": sys.argv[1], "status": "skip", "reason": r,
                  "source": src, "code": None, "actual": None}))' \
        "$ar" "$reason" "$source" >> "$results_file"
      [[ $VERBOSE -eq 1 ]] && printf '  %-14s skip\n' "$ar" >&2
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
      # probe 协议校验 + status(评审 🔴1): rc 限于 0/1/3; 输出必须 dict + pass/error/rc 一致;
      # 不一致({}+rc0/[]+rc0/rc2/rc3无error) → error record, 不假 PASS/冒充 BMC fail。
      # 装配层 rc 兜底(评审 🟡1): 内联 python 异常不允许经 errexit 折叠成 exit 1 假 α truth —
      # 失败改记 error record(infra)。已知触发器(编码崩溃)已被头部双 export 消灭, 本分支属
      # 防御性: 敌意 env 回归用例走的是预防层, 不断言此分支, 勿再为它造测(四轮对撞结论)。
      _rec=""
      _rec=$(printf '%s' "$out" | python3 -c 'import json, sys
raw = sys.stdin.read()
appl = sys.argv[2]
src = json.loads(sys.argv[3]) if sys.argv[3] else ""
appl_reason = json.loads(sys.argv[4]) if sys.argv[4] else ""
rc = int(sys.argv[5])
try:
    d = json.loads(raw)
except Exception:
    d = None
proto = None
if not isinstance(d, dict):
    proto = "probe output not dict (infra): " + str(raw)[:200]
elif rc not in (0, 1, 3):
    proto = "probe rc %d outside 0/1/3 (infra)" % rc
elif any(k not in d for k in ("pass", "code", "body", "actual", "reason")):
    proto = "probe output missing required field (infra)"
elif type(d.get("pass")) is not bool:
    proto = "probe pass is not bool (infra)"
elif "error" in d and type(d.get("error")) is not bool:
    proto = "probe error is not bool (infra)"
elif d.get("code") is not None and type(d.get("code")) is not int:
    proto = "probe code is not int/null (infra)"
elif not isinstance(d.get("body"), str) or not isinstance(d.get("reason"), str):
    proto = "probe body/reason is not string (infra)"
elif rc == 3 and not (d.get("pass") is False and d.get("error") is True):
    proto = "probe rc=3 requires pass=false,error=true (infra)"
elif rc == 0 and not (d.get("pass") is True and d.get("error", False) is False):
    proto = "probe rc=0 requires pass=true,error=false (infra)"
elif rc == 1 and not (d.get("pass") is False and d.get("error", False) is False):
    proto = "probe rc=1 requires pass=false,error=false (infra)"
if proto:
    d = {"pass": False, "error": True, "code": None, "body": raw,
         "actual": None, "reason": proto}
    st = "error"
elif rc == 3:
    st = "error"
elif appl == "xfail":
    st = "xpass" if rc == 0 else "xfail"
else:
    st = "pass" if rc == 0 else "fail"
d["ar"] = sys.argv[1]
d["status"] = st
d["source"] = src
d["probe_reason"] = d.get("reason", "") or proto or ""
if st in ("xfail", "xpass") and appl_reason:
    d["reason"] = appl_reason
elif proto:
    d["reason"] = proto
print(json.dumps(d, ensure_ascii=False))' "$ar" "$status" "$source" "$reason" "$rc") || _rec=""
      if [[ -z "$_rec" ]]; then
          # argv 纯 ASCII + print 默认 ensure_ascii → 此构造自身不会崩; 若真崩则 errexit 可见,
          # 好过静默丢 AR 记录(report 读空行会被 skip, AR 既不 pass 也不 fail)。
          _rec=$(python3 -c 'import json, sys
print(json.dumps({"ar": sys.argv[1], "status": "error",
                  "reason": "record assembly failed (infra): runner inline python aborted",
                  "code": None, "actual": None}, ensure_ascii=False))' "$ar")
      fi
      echo "$_rec" >> "$results_file"
      if [[ $VERBOSE -eq 1 ]]; then
          printf '  %-14s %s\n' "$ar" "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("status","?"))' "$_rec")" >&2
      fi
      ;;
    *)
      echo "run.sh: unknown applicability status '$status' for $ar" >&2
      exit 3
      ;;
  esac
done <<< "$plan"

report_args=(python3 "$REPORT" --results "$results_file")
if [[ -n "$REPORT_PATH" ]]; then
  report_args+=(--report "$REPORT_PATH")
fi
if "${report_args[@]}"; then rc=0; else rc=$?; fi
exit "$rc"
