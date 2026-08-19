#!/usr/bin/env python3
"""romulus baseline record 装配层: probe 输出 → 统一 record dict。

从 run.sh 抽出(B3 结构化; 逻辑与内嵌时期逐行等价, 防御原样保留):
  ① probe 协议校验(评审 🔴1): probe 输出必须 dict + rc/pass/error/code
     字段一致; 不一致({}+rc0 / []+rc0 / rc 越界 / 类型错) → error record,
     不假 PASS、不冒充 BMC fail。
  ② status 判定: rc3→error(infra); xfail→xpass/xfail; else pass/fail。
  ③ skip record 组装(skip/cascade_skip AR 不调 probe, 评审配套⑤)。

runner.py in-process import 消费(旧 argv 三形态 CLI 已随 bash 主循环消亡,
现为函数签名; CLI 形态已删——无外部消费方):

  assemble_record(ar, appl_status, source, appl_reason, rc, probe_stdout) -> dict
      校验 + 判定 + 装配 record(probe_stdout 为 probe stdout 字符串)
  skip_record(ar, reason, source) -> dict
      skip record(reason/source 为 plan() 产出的原字符串, 直接透传)
  fallback_record(ar) -> dict
      装配层自身失败的 error record(防御: 兜底不让装配异常冒充 exit 1
      假 α truth)
"""
import json


def assemble_record(ar, appl, source, appl_reason, rc, probe_stdout):
    """① 协议校验 ② status 判定 ③ record 装配(默认形态)。"""
    rc = int(rc)
    raw = probe_stdout

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
    return d


def skip_record(ar, reason, source):
    return {"ar": ar, "status": "skip", "reason": reason,
            "source": source, "code": None, "actual": None}


def fallback_record(ar):
    return {"ar": ar, "status": "error",
            "reason": "record assembly failed (infra): runner inline python aborted",
            "code": None, "actual": None}
