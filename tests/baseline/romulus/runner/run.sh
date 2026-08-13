#!/usr/bin/env bash
# romulus baseline runner: 遍历 ar_probes.yaml × applicability → 逐条 probe →
# 收 pass/fail/skip/xfail/xpass → report.py → exit 0/1。
# per-machine (ADR-0025); host/port/auth 由调用方注入, 不硬编码。
#
# rc 纪律 (评审三轮 🔴1): set -euo pipefail 下 probe fail (exit 1) 不能裸调,
# 否则 errexit 中止 runner、report.py 不执行。每条 probe 用 if/else 捕获 rc。
set -euo pipefail

HOST=""
PORT=""
USER_NAME=""
PASSWORD=""
AR_FILTER=""
SUITE_FILTER=""
REPORT_PATH=""
VERBOSE=0
DRY_RUN=0
TIMEOUT="${TIMEOUT:-10}"

usage() {
  cat <<EOF
Usage: run.sh --host H --port P --user U --password W [options]
  --ar ID         only run AR with this id
  --suite NAME    only run ARs in this suite
  --report PATH   dump JSON report to PATH
  -v, --verbose   print per-AR status to stderr
  -d, --dry-run   list ARs + applicability, no probe, exit 0
  --timeout SE    per-probe HTTP timeout (default 10)
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
  if [[ -z "$HOST" || -z "$PORT" || -z "$USER_NAME" || -z "$PASSWORD" ]]; then
    echo "run.sh: --host/--port/--user/--password required (or use --dry-run)" >&2
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
# schema 校验(评审 🟡3): default status 白名单(非法 → exit 3, 不 exit 2)
if default not in _ALLOWED_APPL:
    sys.stderr.write("run.sh: applicability default '%s' not in %s\n" % (default, ", ".join(_ALLOWED_APPL)))
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
    req = a["request"]
    # method 白名单 + path 拒控制字符(评审 🟡1: framing 不用换行承载, 校验保证 method/path 无 \n)
    _m = req.get("method", "")
    _p = req.get("path", "")
    if not isinstance(_m, str) or _m.upper() not in _ALLOWED_METHODS:
        sys.stderr.write("run.sh: AR '%s' bad HTTP method '%s'; allowed: %s\n" % (a["ar"], _m, ", ".join(_ALLOWED_METHODS)))
        sys.exit(3)
    if not isinstance(_p, str) or any(c in _p for c in ("\n", "\r", "\t")):
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
      probe_args=(python3 "$PROBE" --host "$HOST" --port "$PORT" \
                  --user "$USER_NAME" --password "$PASSWORD" \
                  --method "$method" --path "$path" \
                  --asserts "$asserts" --timeout "$TIMEOUT")
      [[ -n "$body" ]] && probe_args+=(--body "$body")
      if out=$("${probe_args[@]}"); then rc=0; else rc=$?; fi
      # probe 协议校验 + status(评审 🔴1): rc 限于 0/1/3; 输出必须 dict + pass/error/rc 一致;
      # 不一致({}+rc0/[]+rc0/rc2/rc3无error) → error record, 不假 PASS/冒充 BMC fail。
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
    d = {"pass": False, "code": None, "body": raw, "actual": None}
    proto = "probe output not dict (infra): " + str(raw)[:200]
elif rc not in (0, 1, 3):
    proto = "probe rc %d outside 0/1/3 (infra)" % rc
elif rc == 3 and not d.get("error"):
    proto = "probe rc=3 but no error flag (infra)"
elif rc in (0, 1) and d.get("error"):
    proto = "probe rc=%d but error flag set (infra)" % rc
elif rc == 0 and d.get("pass") is not True:
    proto = "probe rc=0 but pass is not True (infra)"
elif rc == 1 and d.get("pass") is not False:
    proto = "probe rc=1 but pass is not False (infra)"
if proto:
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
print(json.dumps(d, ensure_ascii=False))' "$ar" "$status" "$source" "$reason" "$rc")
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
