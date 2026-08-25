#!/usr/bin/env python3
"""IPMI (ipmitool lanplus) probe — smoke 可达性断言收编(ADR-0028)。

probe seam 契约与 probe_redfish 同构: stdout 恰好一行 JSON dict
{"pass","code","body","actual","reason"}(+error), rc ∈ {0,1,3}。

host 固定 localhost(与旧 ob smoke 一致); 端口/凭据全走 env:
  OB_TQ_IPMI_PORT             缺 → error record exit 3
  OB_TQ_IPMI_USER / OB_TQ_IPMI_PASSWORD   缺则 fallback
  OB_TQ_USER / OB_TQ_PASSWORD             两源全缺 → error exit 3

密码安全: 强制 ipmitool -E 形态——密码经子进程 env IPMI_PASSWORD 传递,
由 ipmitool 自行读取; 禁止 -P "$password"(argv 对 ps 全局可见)。

Assert primitives:
  exitcode_zero            ipmitool rc == 0 即过
  output_contains{value}   body 子串命中(value 非空 str, plan.py 已校验)

CLI:
  probe_ipmi.py --asserts '<JSON>' [--command '<ipmitool 子命令>'] [--selftest]
  --command: 空格形态 ipmitool 子命令(plan.py 白名单归一后经 runner 传入;
  缺省 "mc info")
"""
import argparse
import json
import os
import shutil
import subprocess
import sys


def _build_argv(port, user, command="mc info"):
    """构造 ipmitool argv(纯函数, 供直测): 含 -U user, 不含任何密码字面量
    (-E 形态, 密码经子进程 env IPMI_PASSWORD 传递)。"""
    return ["ipmitool", "-I", "lanplus", "-E", "-H", "localhost",
            "-p", str(port), "-U", user] + command.split()


def _valid_port(value):
    """端口合法性(env 源自 PID file/env, 可能损坏; 评审 🟡): 正整数 1-65535。
    ipmitool 对坏端口参数报 rc 1, 不拦会被 exitcode_zero 误判 BMC fail。"""
    try:
        p = int(value)
    except (TypeError, ValueError):
        return False
    return 1 <= p <= 65535


def _resolve_creds(env):
    """env 优先 OB_TQ_IPMI_*, fallback OB_TQ_*; 返回 (user, password) or None。"""
    user = env.get("OB_TQ_IPMI_USER") or env.get("OB_TQ_USER")
    password = env.get("OB_TQ_IPMI_PASSWORD") or env.get("OB_TQ_PASSWORD")
    if not user or not password:
        return None
    return user, password


def _run_asserts(asserts, code, body):
    """返回 (all_pass, reason, actual)。"""
    for a in asserts:
        t = a.get("type")
        if t == "exitcode_zero":
            if code != 0:
                return False, "ipmitool exit code {} != 0".format(code), code
        elif t == "output_contains":
            want = a.get("value", "")
            if want not in body:
                return False, "output does not contain {!r}".format(want), None
        else:
            return False, "unknown assert type {!r}".format(t), None
    return True, "ok", None


def _emit(result, rc):
    print(json.dumps(result, ensure_ascii=False))
    return rc


def main(argv=None):
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--asserts", default=None)
    # --command: ipmitool 子命令(空格形态, plan.py 白名单归一后经 runner 传入;
    # 缺省 "mc info" 向后兼容直跑/旧调用形态)。
    p.add_argument("--command", default="mc info")
    args = p.parse_args(argv)

    if args.selftest:
        return run_selftest()

    asserts = json.loads(args.asserts) if args.asserts else []
    port = os.environ.get("OB_TQ_IPMI_PORT")
    if not port:
        return _emit({"pass": False, "error": True, "code": None, "body": "",
                      "actual": None,
                      "reason": "missing env OB_TQ_IPMI_PORT"}, 3)
    if not _valid_port(port):
        return _emit({"pass": False, "error": True, "code": None, "body": "",
                      "actual": None,
                      "reason": "invalid env OB_TQ_IPMI_PORT: {!r} (want integer 1-65535)".format(port)}, 3)
    creds = _resolve_creds(os.environ)
    if creds is None:
        return _emit({"pass": False, "error": True, "code": None, "body": "",
                      "actual": None,
                      "reason": "missing IPMI credentials env "
                              "(OB_TQ_IPMI_USER/OB_TQ_IPMI_PASSWORD or "
                              "OB_TQ_USER/OB_TQ_PASSWORD)"}, 3)
    user, password = creds

    if shutil.which("ipmitool") is None:
        return _emit({"pass": False, "error": True, "code": None, "body": "",
                      "actual": None, "reason": "ipmitool not found"}, 3)

    proc = subprocess.run(
        _build_argv(port, user, args.command), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", check=False,
        env=dict(os.environ, IPMI_PASSWORD=password))
    body = proc.stdout or ""
    all_pass, reason, actual = _run_asserts(asserts, proc.returncode, body)
    return _emit({"pass": all_pass, "code": proc.returncode, "body": body,
                  "actual": actual, "reason": reason},
                 0 if all_pass else 1)


def run_selftest():
    checks = []

    def chk(name, got, want):
        checks.append((name, got == want, got, want))

    # assert 原语纯函数
    chk("exitcode_zero hit", _run_asserts([{"type": "exitcode_zero"}], 0, "x")[0], True)
    chk("exitcode_zero miss", _run_asserts([{"type": "exitcode_zero"}], 1, "x")[0], False)
    chk("output_contains hit", _run_asserts([{"type": "output_contains", "value": "BMC"}], 0, "Device Id: BMC")[0], True)
    chk("output_contains miss", _run_asserts([{"type": "output_contains", "value": "BMC"}], 0, "nope")[0], False)
    chk("unknown assert", _run_asserts([{"type": "bogus"}], 0, "x"),
        (False, "unknown assert type 'bogus'", None))
    # 端口合法性(评审 🟡): 坏端口 error 3 而非 ipmitool rc1 冒充 BMC fail
    chk("port valid", _valid_port("2623"), True)
    chk("port notaport", _valid_port("notaport"), False)
    chk("port zero", _valid_port("0"), False)
    chk("port oob", _valid_port("70000"), False)
    # argv 构造: 含 -U user, 不含密码字面量(-E 形态, 密码走子进程 env)
    av = _build_argv(2623, "ipmiuser")
    chk("argv shape", av, ["ipmitool", "-I", "lanplus", "-E", "-H", "localhost",
                           "-p", "2623", "-U", "ipmiuser", "mc", "info"])
    chk("argv no password", any("0penBmc" in x or "ipmiuser!@#" in x for x in av), False)
    # --command 透传(2026-08-25 V2.1 导入): 空格形态命令 split 进 argv 尾部
    av2 = _build_argv(2623, "ipmiuser", "chassis status")
    chk("argv custom command tail", av2[-2:], ["chassis", "status"])
    chk("argv no -P", any(x == "-P" for x in av), False)
    # 凭据 fallback 链
    chk("creds ipmi-specific", _resolve_creds({"OB_TQ_IPMI_USER": "a", "OB_TQ_IPMI_PASSWORD": "b"}), ("a", "b"))
    chk("creds fallback generic", _resolve_creds({"OB_TQ_USER": "u", "OB_TQ_PASSWORD": "w"}), ("u", "w"))
    chk("creds ipmi wins", _resolve_creds({"OB_TQ_IPMI_USER": "a", "OB_TQ_IPMI_PASSWORD": "b",
                                           "OB_TQ_USER": "u", "OB_TQ_PASSWORD": "w"}), ("a", "b"))
    chk("creds missing", _resolve_creds({}), None)
    # JSON 输出契约 shape(缺端口 error 形态)
    import io
    import contextlib
    buf = io.StringIO()
    env_bak = os.environ.get("OB_TQ_IPMI_PORT")
    os.environ.pop("OB_TQ_IPMI_PORT", None)
    try:
        with contextlib.redirect_stdout(buf):
            rc = main(["--asserts", "[{\"type\":\"exitcode_zero\"}]"])
    finally:
        if env_bak is not None:
            os.environ["OB_TQ_IPMI_PORT"] = env_bak
    line = buf.getvalue()
    chk("error rc", rc, 3)
    try:
        rec = json.loads(line)
    except ValueError:
        rec = None
    chk("error line is one JSON dict", isinstance(rec, dict) and
        set(rec) == {"pass", "code", "body", "actual", "reason", "error"} and
        rec["error"] is True and "OB_TQ_IPMI_PORT" in rec["reason"], True)
    chk("stdout exactly one line", line.endswith("\n") and line.count("\n"), 1)

    all_ok = True
    for name, ok, got, want in checks:
        if not ok:
            all_ok = False
            sys.stderr.write("FAIL {}: got {!r} want {!r}\n".format(name, got, want))
    if all_ok:
        print("selftest OK ({} checks)".format(len(checks)))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
