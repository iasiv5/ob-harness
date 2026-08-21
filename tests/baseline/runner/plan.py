#!/usr/bin/env python3
"""共享 baseline planner: ar_probes.yaml × applicability.yaml → 执行计划。

从 run.sh 抽出(B3 结构化; 逻辑与内嵌时期逐行等价, 防御原样保留):
读两份 YAML → schema 校验 → --ar/--suite 过滤 → cascade-skip 传播。
runner.py in-process import 消费(旧 \x1f 分隔 stdout 帧已随 bash 主循环消亡,
现为 list[dict] 返回; plan() 是唯一入口, CLI 形态已删——无外部消费方)。

plan() 返回 list[dict], 元素字段:
  ar / status / probe / method / path / body / asserts / attempts / interval
  / reason / source
  status ∈ applicable / skip / xfail / cascade_skip(runner 把 cascade_skip
  归并读作 skip); method/path 为原字符串(schema 校验保证无控制字符);
  body/asserts 为已解析对象; reason/source 为原字符串。

plan() 内 sys.exit(3)(YAML 语法/schema 违规: default status 白名单 / AR ID 空
  或含控制字符或重复 / depends_on 未知 / orphan override / 未知 assert
  type / 缺 request 且非 skip / method 白名单外 / path 含控制字符) —
  baseline 数据错 ≠ BMC fail, 不进 α truth; runner 捕 SystemExit 补 remedy。
"""
import os
import sys

import yaml

_ALLOWED_APPL = ("applicable", "skip", "xfail")
# probe-type 白名单(ADR-0028 smoke 收编): none 是 planner-only sentinel——
# 仅 skip/cascade_skip AR 合法(无可执行探测定义), 永不进入 runner probe 分派。
_ALLOWED_PROBE = ("redfish", "ipmi", "ssh_tcp", "console", "web", "none")
# assert 原语 × probe-type 兼容矩阵: 矩阵外组合 = 数据错 → die() exit 3。
_PROBE_ASSERTS = {
    "redfish": ("status_in", "json_path_exists", "json_path_match",
                "body_contains_any", "json_path_nonempty_any"),
    "ipmi": ("exitcode_zero", "output_contains"),
    "ssh_tcp": ("tcp_connectable",),
    "console": ("login_prompt_reached", "shell_prompt_reached"),
    "web": ("status_in", "content_type_match", "body_contains_any"),
    "none": (),
}
_ALLOWED_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD")
# 布局 v2(ADR-0025/0027 增补)起 ar_probes 与 applicability 方言分家:
# ar_probes = 2(include 驱动薄顶层), applicability = 1(布局未变)。
_AR_SCHEMA_VERSIONS = (2,)
_APPL_SCHEMA_VERSIONS = (1,)


def has_control_chars(value):
    return any(ord(ch) < 0x20 or ord(ch) == 0x7f for ch in value)


def die(msg):
    sys.stderr.write("plan.py: {}\n".format(msg))
    sys.exit(3)


def _gate_schema(doc, versions, name):
    # 两仓版本门禁(ADR-0027): runner(主仓)与数据(community tests/ 或 custom 子仓)分属
    # 不同 git 仓, YAML 顶层 schema_version 声明数据方言, 此处 fail-closed 校验。
    # type(v) is not int 而非 isinstance: bool 是 int 子类, YAML 的
    # schema_version: true 会因 True == 1 被当合法版本 1, 类型约束失真。
    _v = doc.get("schema_version") if isinstance(doc, dict) else None
    if type(_v) is not int or _v not in versions:
        die("bad schema_version {!r} in {} (want one of {})".format(
            _v, name, ", ".join(map(str, versions))))


def load_ar_probes(path):
    """布局 v2: 薄顶层(schema_version + auth + include) → merge 分片 ars。

    校验顺序: schema 门禁先于结构契约——旧 v1 单文件(schema_version: 1 + 顶层 ars)
    必须报 bad schema_version, 与 schema gate 测试矩阵一致。
    """
    try:
        top = yaml.safe_load(open(path))
    except Exception as e:  # yaml 语法/open 失败 → 数据错 exit 3, 不 traceback
        sys.stderr.write("plan.py: cannot parse baseline YAML: {}\n".format(e))
        sys.exit(3)
    _gate_schema(top, _AR_SCHEMA_VERSIONS, "ar_probes")
    if "ars" in top:
        die("top-level 'ars' not allowed in v2; ARs live in ar_probes.d/<suite>.yaml fragments")
    include = top.get("include")
    if not isinstance(include, list) or not include:
        die("ar_probes 'include' must be a non-empty list of fragment paths")
    base_real = os.path.realpath(os.path.dirname(os.path.abspath(path)))
    ars = []
    for item in include:
        # include 条目必须是相对路径: 绝对路径使数据目录不可 relocatable, 违反契约。
        if not isinstance(item, str) or not item or os.path.isabs(item):
            die("include entry must be a relative path, got {!r}".format(item))
        target = os.path.join(base_real, item)
        target_real = os.path.realpath(target)
        # commonpath 判界(禁止 startswith: sibling 目录共享字符串前缀会误放行)
        try:
            inside = os.path.commonpath([base_real, target_real]) == base_real
        except ValueError:  # 不同盘符等 → 必在界外
            inside = False
        if not inside:
            die("include path {!r} escapes baseline directory".format(item))
        if not os.path.isfile(target_real):
            die("include fragment {!r} not found".format(item))
        try:
            frag = yaml.safe_load(open(target_real))
        except Exception as e:
            sys.stderr.write("plan.py: cannot parse baseline YAML: {}\n".format(e))
            sys.exit(3)
        if not isinstance(frag, dict) or not isinstance(frag.get("ars"), list):
            die("include fragment {!r} missing 'ars' list".format(item))
        ars.extend(frag["ars"])
    return {"schema_version": top["schema_version"], "auth": top.get("auth"), "ars": ars}


def load_inputs(ar_probes, appl_path):
    d = load_ar_probes(ar_probes)
    try:
        appl = yaml.safe_load(open(appl_path))
    except Exception as e:  # yaml 语法/open 失败 → 数据错 exit 3, 不 traceback
        sys.stderr.write("plan.py: cannot parse baseline YAML: {}\n".format(e))
        sys.exit(3)
    _gate_schema(appl, _APPL_SCHEMA_VERSIONS, "applicability")
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
    if not isinstance(overrides, dict):
        die("applicability overrides must be a mapping (got {!r})".format(overrides))
    ar_ids = {a["ar"] for a in ars}
    # orphan override: 指向不存在 AR → exit 3(评审 🟡2)
    for o_id, o in overrides.items():
        if o_id not in ar_ids:
            die("applicability override '{}' references unknown AR".format(o_id))
        if not isinstance(o, dict):
            die("applicability override '{}' must be a mapping (got {!r})".format(o_id, o))
    # depends_on 容器也属 schema: 非 list/非字符串不能 traceback 成 exit 1。
    deps_by_ar = {}
    for a in ars:
        deps = a.get("depends_on", [])
        if not isinstance(deps, list) or not all(
                isinstance(dep, str) and dep for dep in deps):
            die("AR '{}' depends_on must be a list of non-empty strings (got {!r})".format(a["ar"], deps))
        deps_by_ar[a["ar"]] = deps
    stat = {}
    for a in ars:
        o = overrides.get(a["ar"], {})
        st = o.get("status", default)
        if st not in _ALLOWED_APPL:
            die("AR '{}' applicability status '{}' not in {}".format(a["ar"], st, ", ".join(_ALLOWED_APPL)))
        stat[a["ar"]] = (st, o.get("reason", ""), o.get("source", ""))
    # depends_on 引用完整性(评审 🟡3): 未知 dependency 不默认 applicable
    for a in ars:
        for dep in deps_by_ar[a["ar"]]:
            if dep not in ar_ids:
                die("AR '{}' depends_on unknown AR '{}'".format(a["ar"], dep))
    # cascade-skip: depends_on 命中 skip/cascade_skip 的 AR 级联为 skip
    changed = True
    while changed:
        changed = False
        for a in ars:
            if stat[a["ar"]][0] == "applicable":
                for dep in deps_by_ar[a["ar"]]:
                    ds = stat.get(dep, ("applicable", "", ""))[0]
                    if ds in ("skip", "cascade_skip"):
                        stat[a["ar"]] = ("cascade_skip", "depends_on " + dep + " skipped", "auto")
                        changed = True
    return stat


def _gate_login(ar, login):
    """web login 块 schema 校验(SMOKE-08, fail-closed 白名单与 probe_web 契约同构)。"""
    if not isinstance(login, dict):
        die("AR '{}' web request.login must be a mapping (got {!r})".format(ar, login))
    allowed = {"path", "method", "content_type", "body", "csrf",
               "ok_statuses", "logout_path", "logout_method"}
    if set(login) - allowed:
        die("AR '{}' login allows only {} (got keys {})".format(
            ar, ", ".join(sorted(allowed)), sorted(login)))
    lp = login.get("path")
    if not isinstance(lp, str) or not lp or has_control_chars(lp):
        die("AR '{}' login.path must be a non-empty str without control chars (got {!r})".format(ar, lp))
    m = login.get("method")
    if m is not None and m != "POST":
        die("AR '{}' login.method must be 'POST' (got {!r})".format(ar, m))
    ct = login.get("content_type")
    if ct is not None and not isinstance(ct, str):
        die("AR '{}' login.content_type must be a str (got {!r})".format(ar, ct))
    body = login.get("body")
    if not isinstance(body, str) or not body:
        die("AR '{}' login.body must be a non-empty str with {{user}}/{{password}} placeholders".format(ar))
    # 占位符显式校验(fail-closed): 漏写占位符 = 凭据不进登录请求 / 凭据硬编码进
    # YAML, 都该在 schema gate 拦下而不是 live 才失败。
    if "{user}" not in body or "{password}" not in body:
        die("AR '{}' login.body must contain both {{user}} and {{password}} placeholders (got {!r})".format(ar, body))
    if "csrf" in login and not isinstance(login["csrf"], bool):
        die("AR '{}' login.csrf must be a bool (got {!r})".format(ar, login["csrf"]))
    ok = login.get("ok_statuses")
    if ok is not None and (not isinstance(ok, list) or not all(type(x) is int for x in ok)):
        die("AR '{}' login.ok_statuses must be a list of ints (got {!r})".format(ar, ok))
    lop = login.get("logout_path")
    if lop is not None and (not isinstance(lop, str) or has_control_chars(lop)):
        die("AR '{}' login.logout_path must be a str without control chars (got {!r})".format(ar, lop))
    lom = login.get("logout_method")
    if lom is not None and lom not in ("POST", "DELETE"):
        die("AR '{}' login.logout_method must be 'POST' or 'DELETE' (got {!r})".format(ar, lom))


def build_plan(a, st):
    """单 AR 的 probe/assert/request schema 校验 → 计划行 dict。"""
    ar = a["ar"]
    # 类型防御(评审 🟡): AR 源自 YAML, 字段访问前先保证容器形态——
    # 畸形数据 traceback 到 runner 会冒充 exit 1 假 α truth。
    if not isinstance(a, dict):
        die("AR entry must be a mapping (got {!r})".format(a))
    raw_asserts = a.get("assert", [])
    if not isinstance(raw_asserts, list) or not all(
            isinstance(x, dict) for x in raw_asserts):
        die("AR '{}' assert must be a list of mappings (got {!r})".format(ar, raw_asserts))
    req_raw = a.get("request")
    if req_raw is not None and not isinstance(req_raw, dict):
        die("AR '{}' request must be a mapping (got {!r})".format(ar, req_raw))
    # probe 字段: 缺省 redfish(v1/早期数据不带 probe); 白名单外 = 数据错。
    p = a.get("probe", "redfish")
    if p not in _ALLOWED_PROBE:
        die("AR '{}' unknown probe type '{}'; allowed: {}".format(
            ar, p, ", ".join(_ALLOWED_PROBE)))
    # none sentinel: 无可执行探测定义, 仅 skip/cascade_skip 合法——
    # applicable/xfail 却无探测定义 = "要跑却没定义", 数据错。
    if p == "none" and st[0] not in ("skip", "cascade_skip"):
        die("AR '{}' probe 'none' only allowed when applicability is skip/cascade_skip (got '{}')".format(ar, st[0]))
    # executable AR(assert 将被消费)必须携带非空 assert(评审 🔴): assert 误删/漏写
    # 时 probe 的空 assert 循环恒 pass → 假绿, 比 fail 更危险(CI 放行)。
    if p != "none" and st[0] in ("applicable", "xfail") and not raw_asserts:
        die("AR '{}' (probe '{}', status '{}') has no assert — executable AR requires a non-empty assert list".format(ar, p, st[0]))
    # 未知 assert type / 矩阵外组合 = baseline 数据错(评审二轮 🟡), 不当 BMC fail
    allowed_asserts = _PROBE_ASSERTS[p]
    for x in raw_asserts:
        t = x.get("type")
        if t not in allowed_asserts:
            die("AR '{}' assert type '{}' not allowed for probe '{}' (allowed: {})".format(
                ar, t, p, ", ".join(allowed_asserts)))
        # status_in.value 必须非空 list: probe 读 a.get("value", []) — 字段写错
        # (如 values typo)或空列表会静默拿 [], 任何 HTTP code 都 fail, 冒充 BMC 缺陷。
        if t == "status_in":
            v = x.get("value")
            if not isinstance(v, list) or not v:
                die("AR '{}' status_in.value must be a non-empty list (got {!r})".format(ar, v))
        # body_contains_any.value: 非空 str 列表 — 空列表恒 false(必 fail 冒充缺陷),
        # 空串在 `"" in body` 下恒 true(假 pass), 双向堵。
        if t == "body_contains_any":
            v = x.get("value")
            if not isinstance(v, list) or not v or not all(
                    isinstance(s, str) and s for s in v):
                die("AR '{}' body_contains_any.value must be a non-empty list of non-empty strings (got {!r})".format(ar, v))
        # json_path_nonempty_any.path: 非空 dotted 路径列表(同上双向堵)。
        if t == "json_path_nonempty_any":
            v = x.get("path")
            if not isinstance(v, list) or not v or not all(
                    isinstance(s, str) and s for s in v):
                die("AR '{}' json_path_nonempty_any.path must be a non-empty list of non-empty strings (got {!r})".format(ar, v))
        # output_contains.value: 非空 str(空串子串恒命中 → 假 pass)。
        if t == "output_contains":
            v = x.get("value")
            if not isinstance(v, str) or not v:
                die("AR '{}' output_contains.value must be a non-empty string (got {!r})".format(ar, v))
        # 无参原语: 带 value 字段 = 字段写错(如 copy-paste status_in), 多余即拒。
        if t in ("exitcode_zero", "tcp_connectable") and "value" in x:
            die("AR '{}' assert '{}' takes no 'value' field".format(ar, t))
    # request 缺省容忍(评审配套⑤): 仅实际将 skip 的 AR 可省略 request — 无可执行
    # 探测定义就不该编造占位请求(如 Web banner AR 挂 GET /redfish/v1 的语义错位);
    # request 存在则无条件过白名单校验(数据要合法, applicability 改回 applicable 后即跑)。
    req = req_raw or {}
    attempts = None
    interval = None
    if not req:
        if st[0] not in ("skip", "cascade_skip"):
            die("AR '{}' missing request (required unless applicability is skip)".format(ar))
        method = ""
        path = ""
    elif p == "ipmi":
        # ipmi request 分叉(ADR-0028): 目前仅 mc_info; 未知键 = 字段写错。
        if set(req) - {"command"}:
            die("AR '{}' ipmi request allows only 'command' (got keys {})".format(ar, sorted(req)))
        if req.get("command") != "mc_info":
            die("AR '{}' ipmi request.command must be 'mc_info' (got {!r})".format(ar, req.get("command")))
        method = ""
        path = ""
    elif p == "ssh_tcp":
        # ssh_tcp request 分叉: 可选 attempts/interval 正整数(缺省 30/5, 对齐
        # 旧 smoke 就绪门 30×5); 无凭据无 method/path。
        if set(req) - {"attempts", "interval"}:
            die("AR '{}' ssh_tcp request allows only 'attempts'/'interval' (got keys {})".format(ar, sorted(req)))
        for k in ("attempts", "interval"):
            v = req.get(k)
            if v is not None and (type(v) is not int or v <= 0):
                die("AR '{}' ssh_tcp request.{} must be a positive integer (got {!r})".format(ar, k, v))
        attempts = req.get("attempts", 30)
        interval = req.get("interval", 5)
        method = ""
        path = ""
    elif p == "console":
        # console request 分叉: 可选 timeout 正整数(缺省 30, pexpect 三阶段交互总超时);
        # 无凭据无 method/path(socket/凭据走 env)。
        if set(req) - {"timeout"}:
            die("AR '{}' console request allows only 'timeout' (got keys {})".format(ar, sorted(req)))
        v = req.get("timeout")
        if v is not None and (type(v) is not int or v <= 0):
            die("AR '{}' console request.timeout must be a positive integer (got {!r})".format(ar, v))
        method = ""
        path = ""
    elif p == "web":
        # web request 分叉: path 必填 + scheme 可选(HTTP GET 静态资源, 无 method/body)
        # + login 可选块(SMOKE-08 两段式: 登录建会话 → 带 cookie GET 目标路径)。
        if set(req) - {"path", "scheme", "login"}:
            die("AR '{}' web request allows only 'path' and optional 'scheme'/'login' (got keys {})".format(ar, sorted(req)))
        path = req.get("path", "")
        if not isinstance(path, str) or has_control_chars(path):
            die("AR '{}' web request.path has control chars or non-str".format(ar))
        scheme = req.get("scheme")
        if scheme is not None and scheme not in ("http", "https"):
            die("AR '{}' web request.scheme must be 'http' or 'https' (got {!r})".format(ar, scheme))
        login = req.get("login")
        if login is not None:
            _gate_login(ar, login)
        method = "GET"  # web 语义隐含 GET, 但 runner 分派不消费 method 字段
    else:
        # method 白名单 + path 拒控制字符: 两者直接进入 HTTP argv。
        method = req.get("method", "")
        path = req.get("path", "")
        if not isinstance(method, str) or method not in _ALLOWED_METHODS:
            die("AR '{}' bad HTTP method '{}'; allowed: {}".format(ar, method, ", ".join(_ALLOWED_METHODS)))
        if not isinstance(path, str) or has_control_chars(path):
            die("AR '{}' request.path has control chars or non-str".format(ar))
    status, reason, source = st
    return {"ar": ar, "status": status, "probe": p, "method": method,
            "path": path, "body": req.get("body"), "asserts": a.get("assert", []),
            "attempts": attempts, "interval": interval, "timeout": req.get("timeout"),
            "scheme": req.get("scheme"), "reason": reason, "source": source,
            "login": req.get("login")}


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
