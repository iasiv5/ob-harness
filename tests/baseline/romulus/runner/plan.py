#!/usr/bin/env python3
"""romulus baseline planner: ar_probes.yaml × applicability.yaml → 执行计划。

从 run.sh 抽出(B3 结构化; 逻辑与内嵌时期逐行等价, 防御原样保留):
读两份 YAML → schema 校验 → --ar/--suite 过滤 → cascade-skip 传播。
runner.py in-process import 消费(旧 \x1f 分隔 stdout 帧已随 bash 主循环消亡,
现为 list[dict] 返回; plan() 是唯一入口, CLI 形态已删——无外部消费方)。

plan() 返回 list[dict], 元素字段:
  ar / status / method / path / body / asserts / reason / source
  status ∈ applicable / skip / xfail / cascade_skip(runner 把 cascade_skip
  归并读作 skip); method/path 为原字符串(schema 校验保证无控制字符);
  body/asserts 为已解析对象; reason/source 为原字符串。

plan() 内 sys.exit(3)(YAML 语法/schema 违规: default status 白名单 / AR ID 空
  或含控制字符或重复 / depends_on 未知 / orphan override / 未知 assert
  type / 缺 request 且非 skip / method 白名单外 / path 含控制字符) —
  baseline 数据错 ≠ BMC fail, 不进 α truth; runner 捕 SystemExit 补 remedy。
"""
import sys

import yaml

_ALLOWED_APPL = ("applicable", "skip", "xfail")
_ALLOWED_ASSERT = ("status_in", "json_path_exists", "json_path_match")
_ALLOWED_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD")


def has_control_chars(value):
    return any(ord(ch) < 0x20 or ord(ch) == 0x7f for ch in value)


def die(msg):
    sys.stderr.write("plan.py: {}\n".format(msg))
    sys.exit(3)


def load_inputs(ar_probes, appl_path):
    try:
        d = yaml.safe_load(open(ar_probes))
        appl = yaml.safe_load(open(appl_path))
    except Exception as e:  # yaml 语法/open 失败 → 数据错 exit 3, 不 traceback
        sys.stderr.write("plan.py: cannot parse baseline YAML: {}\n".format(e))
        sys.exit(3)
    return d, appl


def validate_ar_ids(ars):
    # AR ID 是 framing + report identity, 须非空且不含控制字符(评审 🟡3)。
    for a in ars:
        ar_id = a.get("ar") if isinstance(a, dict) else None
        if not isinstance(ar_id, str) or not ar_id or has_control_chars(ar_id):
            die("bad AR ID {!r} (want non-empty string without control chars)".format(ar_id))
    # AR ID 唯一(评审 🟡2): 重复 → 同 AR 跑两次。
    seen = set()
    for a in ars:
        if a["ar"] in seen:
            die("duplicate AR ID '{}'".format(a["ar"]))
        seen.add(a["ar"])


def resolve_status(ars, appl):
    """逐 AR 解析 applicability status + cascade-skip 传播。"""
    # schema 校验(评审 🟡3): default status 白名单(非法 → exit 3, 不 exit 2)
    default = appl.get("default", "applicable")
    if default not in _ALLOWED_APPL:
        die("applicability default '{}' not in {}".format(default, ", ".join(_ALLOWED_APPL)))
    overrides = appl.get("overrides", {})
    ar_ids = {a["ar"] for a in ars}
    # orphan override: 指向不存在 AR → exit 3(评审 🟡2)
    for o_id in overrides:
        if o_id not in ar_ids:
            die("applicability override '{}' references unknown AR".format(o_id))
    stat = {}
    for a in ars:
        o = overrides.get(a["ar"], {})
        st = o.get("status", default)
        if st not in _ALLOWED_APPL:
            die("AR '{}' applicability status '{}' not in {}".format(a["ar"], st, ", ".join(_ALLOWED_APPL)))
        stat[a["ar"]] = (st, o.get("reason", ""), o.get("source", ""))
    # depends_on 引用完整性(评审 🟡3): 未知 dependency 不默认 applicable
    for a in ars:
        for dep in (a.get("depends_on") or []):
            if dep not in ar_ids:
                die("AR '{}' depends_on unknown AR '{}'".format(a["ar"], dep))
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
    return stat


def build_plan(a, st):
    """单 AR 的 assert/request schema 校验 → 计划行 dict。"""
    # 未知 assert type = baseline 数据错(评审二轮 🟡), 不当 BMC fail
    for x in a.get("assert", []):
        if x.get("type") not in _ALLOWED_ASSERT:
            die("AR '{}' unknown assert type '{}'; allowed: {}".format(
                a["ar"], x.get("type"), ", ".join(_ALLOWED_ASSERT)))
    # request 缺省容忍(评审配套⑤): 仅实际将 skip 的 AR 可省略 request — 无可执行
    # 探测定义就不该编造占位请求(如 Web banner AR 挂 GET /redfish/v1 的语义错位);
    # request 存在则无条件过白名单校验(数据要合法, applicability 改回 applicable 后即跑)。
    req = a.get("request") or {}
    if not req:
        if st[0] not in ("skip", "cascade_skip"):
            die("AR '{}' missing request (required unless applicability is skip)".format(a["ar"]))
        method = ""
        path = ""
    else:
        # method 白名单 + path 拒控制字符: 两者直接进入 HTTP argv。
        method = req.get("method", "")
        path = req.get("path", "")
        if not isinstance(method, str) or method not in _ALLOWED_METHODS:
            die("AR '{}' bad HTTP method '{}'; allowed: {}".format(a["ar"], method, ", ".join(_ALLOWED_METHODS)))
        if not isinstance(path, str) or has_control_chars(path):
            die("AR '{}' request.path has control chars or non-str".format(a["ar"]))
    status, reason, source = st
    return {"ar": a["ar"], "status": status, "method": method, "path": path,
            "body": req.get("body"), "asserts": a.get("assert", []),
            "reason": reason, "source": source}


def plan(ar_probes, appl_path, ar_filter, suite_filter):
    """两份 YAML → list[dict] 执行计划(数据错 sys.exit(3), 不进 α truth)。"""
    d, appl = load_inputs(ar_probes, appl_path)
    ars = d["ars"]
    validate_ar_ids(ars)
    stat = resolve_status(ars, appl)
    rows = []
    for a in ars:
        if ar_filter and a["ar"] != ar_filter:
            continue
        if suite_filter and a.get("suite") != suite_filter:
            continue
        rows.append(build_plan(a, stat[a["ar"]]))
    return rows
