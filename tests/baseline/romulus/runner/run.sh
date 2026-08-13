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
PROBE="$SCRIPT_DIR/probe_redfish.py"
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
    body = req.get("body")
    body_json = json.dumps(body) if body is not None else ""
    asserts_json = json.dumps(a.get("assert", []))
    s, r, src = stat[a["ar"]]
    # framing(评审 🟡3): r/src/path json.dumps 转义 \n(多行字段), 防 bash read 行拆成伪 AR;
    # run.sh record 构造时 json.loads 还原(reason/source); probe --path 用时还原。
    print("\x1f".join([a["ar"], s, json.dumps(req.get("method", "")), json.dumps(req.get("path", "")),
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
      # method/path json.loads 还原(framing: planner json.dumps 转义多行字段, 评审 🟡2/🟡5)
      _restored=$(python3 -c 'import json,sys
print(json.loads(sys.argv[1]))
print(json.loads(sys.argv[2]))' "$method" "$path")
      _method="${_restored%%$'\n'*}"; _path="${_restored#*$'\n'}"
      # probe rc 捕获 (绝不裸调): set -e 下 probe fail 在 if 条件里被吸收
      probe_args=(python3 "$PROBE" --host "$HOST" --port "$PORT" \
                  --user "$USER_NAME" --password "$PASSWORD" \
                  --method "$_method" --path "$_path" \
                  --asserts "$asserts" --timeout "$TIMEOUT")
      [[ -n "$body" ]] && probe_args+=(--body "$body")
      if out=$("${probe_args[@]}"); then rc=0; else rc=$?; fi
      # probe rc=3 = schema/infra error(unknown assert type 等, 评审二轮 🟡) → error, 不进 fail/xfail;
      # 合法 JSON + rc 0/1 → 按 applicability 判 pass/fail/xfail/xpass; 非 JSON → error(评审 🔴2)
      if [[ $rc -eq 3 ]]; then
          _st="error"
      elif [[ -n "$out" ]] && printf '%s' "$out" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
          if [[ "$status" == "xfail" ]]; then
              if [[ $rc -eq 0 ]]; then _st="xpass"; else _st="xfail"; fi
          else
              if [[ $rc -eq 0 ]]; then _st="pass"; else _st="fail"; fi
          fi
      else
          _st="error"
      fi
      printf '%s' "$out" | python3 -c 'import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    d = {"pass": False, "code": None, "body": raw, "actual": None,
         "reason": "probe output not JSON (infra): " + raw[:200]}
src = json.loads(sys.argv[3]) if sys.argv[3] else ""
appl_reason = json.loads(sys.argv[4]) if sys.argv[4] else ""
d["ar"] = sys.argv[1]
d["status"] = sys.argv[2]
d["source"] = src
# xfail/xpass: keep probe actual reason in probe_reason for debugging, but show
# the applicability reason ("why expected to fail") in the report appendix.
d["probe_reason"] = d.get("reason", "")
if sys.argv[2] in ("xfail", "xpass") and appl_reason:
    d["reason"] = appl_reason
print(json.dumps(d, ensure_ascii=False))' "$ar" "$_st" "$source" "$reason" >> "$results_file"
      [[ $VERBOSE -eq 1 ]] && printf '  %-14s %s\n' "$ar" "$_st" >&2
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
