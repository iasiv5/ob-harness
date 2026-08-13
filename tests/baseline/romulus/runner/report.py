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
        if not isinstance(r, dict):
            # 非 dict record = infra/数据错 → error(评审 🟡1: 不 AttributeError 冒充 rc=1)
            sys.stderr.write("report: non-dict record {!r} -> error\n".format(r))
            counts["error"] += 1
            continue
        st = r.get("status")
        ar = r.get("ar")
        # status/ar 类型校验(评审 🟡2/🟡4: 非 str → error rc3, 不 TypeError 冒充 rc=1)
        if not isinstance(st, str) or st not in counts:
            sys.stderr.write("report: AR {} bad status {!r} -> error\n".format(ar, st))
            counts["error"] += 1
        elif not isinstance(ar, str) or not ar:
            sys.stderr.write("report: bad AR id {!r} (status {}) -> error\n".format(ar, st))
            counts["error"] += 1
        else:
            counts[st] += 1

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
        if not isinstance(r, dict):
            print("  <non-dict>    error | {!r}".format(r))
            continue
        st = r.get("status", "?")
        ar = str(r.get("ar", "?"))   # coerce(评审 🟡2: ar 非 str 不 format 崩)
        # 字段 coerce 到 str(评审 🟡4: reason/source 非 str 不 AttributeError; 仅显示用)
        reason = str(r.get("reason", "") or "").replace("\n", " ")[:120]
        src = str(r.get("source", "") or "")
        if st in ("fail", "error"):
            print("  {:<14} {} | code={} | {}".format(ar, st, r.get("code"), reason))
        elif st in ("skip", "xfail", "xpass"):
            print("  {:<14} {} | {} [{}]".format(ar, st, reason, src))
        else:
            print("  {:<14} {}".format(ar, st))

    if args.report:
        # 原子写(评审 🟡2): 临时文件 + os.replace; I/O 失败 → return 3(不冒充 BMC fail rc=1);
        # finally 删未 rename 的临时文件(评审 🟡1: 不残留)
        import os, tempfile
        blob = {"verdict": verdict, "counts": counts, "records": records}
        fd = tmp = None
        try:
            d = os.path.dirname(os.path.abspath(args.report)) or "."
            fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
            with os.fdopen(fd, "w") as f:
                json.dump(blob, f, ensure_ascii=False, indent=2)
            os.replace(tmp, args.report)
            tmp = None  # 已 rename, 不删
        except OSError as e:
            sys.stderr.write("report: cannot write --report {}: {}\n".format(args.report, e))
            return 3
        finally:
            if tmp is not None:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass

    if counts["error"] > 0:
        return 3
    if counts["fail"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
