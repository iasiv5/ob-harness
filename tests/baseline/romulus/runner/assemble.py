#!/usr/bin/env python3
"""romulus baseline record 装配层: probe 输出 → 统一 JSONL record。

从 run.sh 抽出(B3 结构化; 逻辑与内嵌时期逐行等价, 防御原样保留):
  ① probe 协议校验(评审 🔴1): probe 输出必须 dict + rc/pass/error/code
     字段一致; 不一致({}+rc0 / []+rc0 / rc 越界 / 类型错) → error record,
     不假 PASS、不冒充 BMC fail。
  ② status 判定: rc3→error(infra); xfail→xpass/xfail; else pass/fail。
  ③ skip record 组装(skip/cascade_skip AR 不调 probe, 评审配套⑤)。

三种调用形态:
  assemble.py <ar> <appl_status> <source_json> <appl_reason_json> <rc>
      stdin = probe stdout(一行 JSON) → 校验 + 判定 + 装配 record
  assemble.py --skip <ar> <reason_json> <source_json>
      → skip record(reason/source 原样透传, 供 report 显示)
  assemble.py --fallback <ar>
      → 装配层自身失败的 error record(防御: 兜底不让 errexit 折叠成
        exit 1 假 α truth; argv 纯 ASCII + 默认 ensure_ascii, 自身不崩)

exit 0 恒(错误都装进 error record 输出, 由 report 汇总为 exit 3)。
"""
import json
import sys


def emit(record):
    print(json.dumps(record, ensure_ascii=False))


def skip_record(argv):
    ar, reason_raw, source_raw = argv[2], argv[3], argv[4]
    reason = json.loads(reason_raw) if reason_raw else ""
    source = json.loads(source_raw) if source_raw else ""
    emit({"ar": ar, "status": "skip", "reason": reason,
          "source": source, "code": None, "actual": None})


def fallback_record(argv):
    emit({"ar": argv[2], "status": "error",
          "reason": "record assembly failed (infra): runner inline python aborted",
          "code": None, "actual": None})


def assemble_record(argv):
    """① 协议校验 ② status 判定 ③ record 装配(默认形态)。"""
    ar, appl, source_raw, appl_reason_raw, rc_raw = argv[1:6]
    source = json.loads(source_raw) if source_raw else ""
    appl_reason = json.loads(appl_reason_raw) if appl_reason_raw else ""
    rc = int(rc_raw)
    raw = sys.stdin.read()

    try:
        d = json.loads(raw)
    except Exception:
        d = None
    proto = None
    if not isinstance(d, dict):
        proto = "probe output not dict (infra): " + str(raw)[:200]
    elif rc not in (0, 1, 3):
        proto = "probe rc {} outside 0/1/3 (infra)".format(rc)
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

    d["ar"] = ar
    d["status"] = st
    d["source"] = source
    d["probe_reason"] = d.get("reason", "") or proto or ""
    if st in ("xfail", "xpass") and appl_reason:
        d["reason"] = appl_reason
    elif proto:
        d["reason"] = proto
    emit(d)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--skip":
        skip_record(sys.argv)
    elif len(sys.argv) >= 2 and sys.argv[1] == "--fallback":
        fallback_record(sys.argv)
    else:
        assemble_record(sys.argv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
