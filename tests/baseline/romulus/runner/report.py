#!/usr/bin/env python3
"""romulus baseline report: read JSONL results, emit VERDICT + appendix.

Input: JSONL (one record per line) where each record carries at least
  {"ar", "status" in {pass,fail,skip,xfail,xpass}, "reason", "source", ...}
Output (stdout):
  VERDICT: PASS|FAIL (N pass / N fail / N skip / N xfail / N xpass)
  + appendix blocks for skip / xfail / xpass (reason + source)
Optional --report PATH: dump full JSON report.

exit: 0 no applicable fail; 1 alpha-truth fail (BMC misses baseline);
     3 infra/config error (probe crash / non-JSON, NOT a BMC failure — review 🔴2).
"""
import argparse
import json
import sys

STATUSES = ("pass", "fail", "skip", "xfail", "xpass", "error")


def load_records(path):
    if path == "-":
        stream = sys.stdin
        records = [json.loads(line) for line in stream if line.strip()]
    else:
        records = []
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    records.append(json.loads(line))
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
        st = r.get("status", "fail")
        if st in counts:
            counts[st] += 1

    # verdict 优先级: ERROR(infra) > FAIL(α truth) > PASS。infra 错误混淆同期 fail 的
    # α truth 语义, 故 error 优先(exit 3 先暴露 infra, 不混 exit 1 BMC fail)。评审 🔴2。
    if counts["error"] > 0:
        verdict = "ERROR"
    elif counts["fail"] > 0:
        verdict = "FAIL"
    else:
        verdict = "PASS"
    print("VERDICT: {} ({} pass / {} fail / {} skip / {} xfail / {} xpass / {} error)".format(
        verdict, counts["pass"], counts["fail"], counts["skip"],
        counts["xfail"], counts["xpass"], counts["error"]))

    for st in ("skip", "xfail", "xpass", "error"):
        subset = [r for r in records if r.get("status") == st]
        if subset:
            print("\n{}:".format(st.upper()))
            for r in subset:
                reason = r.get("reason", "") or ""
                source = r.get("source", "") or ""
                print("  - {}: {} [{}]".format(r.get("ar", "?"), reason, source))

    if args.report:
        blob = {"verdict": verdict, "counts": counts, "records": records}
        with open(args.report, "w") as f:
            json.dump(blob, f, ensure_ascii=False, indent=2)

    if counts["error"] > 0:
        return 3
    if counts["fail"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
