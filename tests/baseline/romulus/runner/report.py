#!/usr/bin/env python3
"""romulus baseline report: read JSONL results, emit per-AR rows + final VERDICT.

Input: JSONL (one record per line) where each record carries at least
  {"ar", "status" in {pass,fail,skip,xfail,xpass,error}, "reason", ...}
Output (stdout):
  + per-AR rows first (default: non-pass ARs with id + status + detail; pass rows
    are skipped under --compact-rows because run.sh streams live status lines —
    always on) — review 🟡7 (default fail rows, not appendix-only).
  VERDICT: PASS|FAIL|ERROR (N pass / N fail / N skip / N xfail / N xpass / N error)
  as the LAST line (summary reads after the rows it summarizes).
Optional --report PATH: dump full JSON report (atomic write).

exit: 0 no applicable fail; 1 alpha-truth fail (BMC misses baseline);
     3 infra/config error (probe crash / non-JSON / unknown status / I/O — NOT BMC failure).
"""
import argparse
import json
import sys

STATUSES = ("pass", "fail", "skip", "xfail", "xpass", "error")


def oneline(value):
    """reason 摘要一行化: 转字符串 + 换行替空格 + 截断 120。

    live 行(runner 流式)与逐条行(--compact-rows 保留的 fail/error 等)共用本函数,
    两条输出路径的 reason 形态永远一致(一致性靠代码, 不靠注释约定)。
    """
    return str(value or "").replace("\n", " ")[:120]


def live_line(record, verbose):
    """record → stderr 流式 live 行(每条 AR 完成即打一行)。

    与旧 run.sh 两段内联 python 输出逐字节一致:
      skip 行    '  <AR 留空补齐 14> skip | <reason 摘要>'(+ ' [source]' 有则拼接;
                 -v 不影响 skip 行, reason 恒给全)
      probe 行   '  <AR> <status>'; verbose=1 且 status ∈ fail/error 时行尾追加
                 ' ' + reason 摘要
    """
    ar = str(record.get("ar", "?"))
    st = record.get("status", "?")
    if st == "skip":
        reason = oneline(record.get("reason", ""))
        src = str(record.get("source", "") or "")
        return "  {:<14} skip | {}".format(ar, reason + " [" + src + "]" if src else reason)
    if verbose and st in ("fail", "error"):
        st += " " + oneline(record.get("reason", ""))
    return "  {:<14} {}".format(ar, st)


def load_records(path):
    records = []
    try:
        # encoding 钉死(评审 🟢4 双保险): results 文件恒为 UTF-8 字节(run.sh 双 export 钉死
        # 子进程 stdio); 本脚本作为独立 CLI 调用时环境不可控 → 显式 utf-8, 不随 locale 漂移。
        stream = sys.stdin if path == "-" else open(path, encoding="utf-8")
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


def run_report(records, report_path, compact_rows):
    """汇总 + 逐条行 + 可选 JSON report; 返回 exit code(0/1/3)。

    runner.py in-process 直调(内存 list[dict] 流转); CLI main() 经 load_records
    读 JSONL 后同样收口到这里 — 两条入口的输出与 exit 语义恒一致。
    """
    counts = {s: 0 for s in STATUSES}
    if not records:
        sys.stderr.write("report: empty results -> error\n")
        counts["error"] += 1
    seen_ars = set()
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
        elif ar in seen_ars:
            sys.stderr.write("report: duplicate AR id {!r} -> error\n".format(ar))
            counts["error"] += 1
        else:
            seen_ars.add(ar)
            counts[st] += 1

    if counts["error"] > 0:
        verdict = "ERROR"
    elif counts["fail"] > 0:
        verdict = "FAIL"
    else:
        verdict = "PASS"

    # 逐条五态(评审 🟡7): 逐条行在前、VERDICT 最后(行序 UX: 用户先看明细, 汇总结论收尾)。
    # 默认打印非 pass AR 详情; fail/error 带 code + reason; skip/xfail/xpass 带 reason +
    # source。help "read the fail rows" 才名副其实。
    # --compact-rows: runner 恒已向 stderr 实时流过每条 AR 状态(pass 裸状态, skip 带
    # reason), report 再打一遍是双打 — 跳过 pass 与 skip 行(信息无损失; skip 的 source
    # 也随 live 行给出), fail/error/xfail/xpass 行保留 code/reason/source 详情。
    for r in records:
        if not isinstance(r, dict):
            print("  <non-dict>    error | {!r}".format(r))
            continue
        st = r.get("status", "?")
        if compact_rows and st in ("pass", "skip"):
            continue
        ar = str(r.get("ar", "?"))   # coerce(评审 🟡2: ar 非 str 不 format 崩)
        # 字段 coerce 到 str(评审 🟡4: reason/source 非 str 不 AttributeError; 仅显示用)
        reason = oneline(r.get("reason", ""))
        src = str(r.get("source", "") or "")
        if st in ("fail", "error"):
            print("  {:<14} {} | code={} | {}".format(ar, st, r.get("code"), reason))
        elif st in ("skip", "xfail", "xpass"):
            print("  {:<14} {} | {} [{}]".format(ar, st, reason, src))
        else:
            print("  {:<14} {}".format(ar, st))

    # 401 hint (B1): 全部 fail 都是 401 而 BMC 在正常应答(其余 AR 有 pass)时, 最大嫌疑是
    # 凭据配错(infra)而非 BMC 不满足 baseline — exit 语义仍是 α truth(fail 是 BMC 对这些
    # 凭据的真实回答, 拒绝错误凭据恰是正确行为), 但把"先查凭据"指出来, 防止用户按 fail
    # 行方向去 debug BMC 接口。probe 无法自证所给凭据是否正确, 故只 hint 不重分类。
    if counts["fail"] > 0 and counts["pass"] > 0:
        fails = [r for r in records
                 if isinstance(r, dict) and r.get("status") == "fail"]
        if fails and all(r.get("code") == 401 for r in fails):
            print("HINT: all {} failing ARs returned HTTP 401 while {} other AR(s) passed —".format(
                len(fails), counts["pass"]))
            print("      likely wrong credentials (OB_TQ_USER / OB_TQ_PASSWORD env or ar_probes.yaml")
            print("      auth), not a baseline miss. Verify creds and re-run before debugging the BMC.")

    # VERDICT 收尾(行序 UX): 逐条行 + 401 HINT 之后, 汇总结论作 stdout 最后一行。
    print("VERDICT: {} ({} pass / {} fail / {} skip / {} xfail / {} xpass / {} error)".format(
        verdict, counts["pass"], counts["fail"], counts["skip"],
        counts["xfail"], counts["xpass"], counts["error"]))

    if report_path:
        # 原子写(评审 🟡2): 临时文件 + os.replace; I/O 失败 → return 3(不冒充 BMC fail rc=1);
        # finally 删未 rename 的临时文件(评审 🟡1: 不残留)
        import os, tempfile
        blob = {"verdict": verdict, "counts": counts, "records": records}
        fd = tmp = None
        try:
            d = os.path.dirname(os.path.abspath(report_path)) or "."
            fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(blob, f, ensure_ascii=False, indent=2)
            os.replace(tmp, report_path)
            tmp = None  # 已 rename, 不删
        except OSError as e:
            sys.stderr.write("report: cannot write --report {}: {}\n".format(report_path, e))
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


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--results", required=True,
                   help="JSONL results file (use '-' for stdin)")
    p.add_argument("--report", default=None,
                   help="optional path to dump full JSON report")
    p.add_argument("--compact-rows", action="store_true",
                   help="print only non-pass/non-skip AR rows (pass and skip "
                        "rows are already streamed live with reason by the "
                        "runner — always on; avoids double printing)")
    args = p.parse_args()
    return run_report(load_records(args.results), args.report, args.compact_rows)


if __name__ == "__main__":
    sys.exit(main())
