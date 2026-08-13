#!/usr/bin/env python3
"""romulus baseline report: read JSONL results, emit VERDICT + per-AR rows.

Input: JSONL (one record per line) where each record carries at least
  {"ar", "status" in {pass,fail,skip,xfail,xpass,error}, "reason", ...}
Output (stdout):
  VERDICT: PASS|FAIL|ERROR (N pass / N fail / N skip / N xfail / N xpass / N error)
  + per-AR rows (default: every AR with id + status; fail/error + reason + code;
    skip/xfail/xpass + reason + source) — review 🟡7 (default fail rows, not appendix-only).
Optional --report PATH: dump full JSON report (atomic write).

exit: 0 no applicable fail; 1 alpha-truth fail (BMC misses baseline);
     3 infra/config error (probe crash / non-JSON / unknown status / I/O — NOT BMC failure).
"""
import argparse
import json
import sys

STATUSES = ("pass", "fail", "skip", "xfail", "xpass", "error")


def load_records(path):
    records = []
    try:
        stream = sys.stdin if path == "-" else open(path)
        for line in stream:
            line = line.strip()
            if line:
                records.append(json.loads(line))
        if stream is not sys.stdin:
            stream.close()
    except (json.JSONDecodeError, OSError) as e:
        sys.stderr.write("report: cannot read results: {}\n".format(e))
        sys.exit(3)
    return records


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--results", required=True,
                   help="JSONL results file (use '-' for stdin)")
    p.add_argument("--report", default=None,
                   help="optional path to dump full JSON report")
    args = p.parse_args()

    records = load_records(args.results)

    counts = {s: 0 for s in STATUSES}
    for r in records:
        st = r.get("status")
        if st in counts:
            counts[st] += 1
        else:
            # 未知 status = 数据错 → error(评审 🟡2: 不静默, 否则 {"status":"typo"} 假 PASS)
            sys.stderr.write("report: AR {} unknown status {!r} -> error\n".format(r.get("ar", "?"), st))
            counts["error"] += 1

    if counts["error"] > 0:
        verdict = "ERROR"
    elif counts["fail"] > 0:
        verdict = "FAIL"
    else:
        verdict = "PASS"
    print("VERDICT: {} ({} pass / {} fail / {} skip / {} xfail / {} xpass / {} error)".format(
        verdict, counts["pass"], counts["fail"], counts["skip"],
        counts["xfail"], counts["xpass"], counts["error"]))

    # 逐条五态(评审 🟡7): 默认打印每条 AR(含 pass/fail), fail/error 带 code + reason;
    # skip/xfail/xpass 带 reason + source。help "read the fail rows" 才名副其实。
    for r in records:
        st = r.get("status", "?")
        ar = r.get("ar", "?")
        reason = (r.get("reason", "") or "").replace("\n", " ")[:120]
        if st in ("fail", "error"):
            print("  {:<14} {} | code={} | {}".format(ar, st, r.get("code"), reason))
        elif st in ("skip", "xfail", "xpass"):
            print("  {:<14} {} | {} [{}]".format(ar, st, reason, r.get("source", "") or ""))
        else:
            print("  {:<14} {}".format(ar, st))

    if args.report:
        # 原子写(评审 🟡2): 临时文件 + os.replace; I/O 失败 → return 3(不冒充 BMC fail rc=1)
        import os, tempfile
        blob = {"verdict": verdict, "counts": counts, "records": records}
        try:
            d = os.path.dirname(os.path.abspath(args.report)) or "."
            fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
            with os.fdopen(fd, "w") as f:
                json.dump(blob, f, ensure_ascii=False, indent=2)
            os.replace(tmp, args.report)
        except OSError as e:
            sys.stderr.write("report: cannot write --report {}: {}\n".format(args.report, e))
            return 3

    if counts["error"] > 0:
        return 3
    if counts["fail"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
