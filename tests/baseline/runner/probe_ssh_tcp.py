#!/usr/bin/env python3
"""SSH TCP 就绪门 probe — smoke 可达性断言收编(ADR-0028)。

probe seam 契约与 probe_redfish 同构: stdout 恰好一行 JSON dict
{"pass","code","body","actual","reason"}(+error), rc ∈ {0,1,3}。

端口 env OB_TQ_SSH_PORT(缺 → error exit 3); 无凭据。TCP 连接按
attempts×interval 秒有界轮询(对齐旧 smoke 就绪门); 轮询超时不
中止——交给 tcp_connectable 断言判 fail(可达性是 BMC truth, 不是 infra)。

Assert primitives:
  tcp_connectable   TCP connect 成功即过(无 value 字段, plan.py 已校验)

CLI:
  probe_ssh_tcp.py --asserts '<JSON>' [--attempts N] [--interval S] [--selftest]
"""
import argparse
import json
import os
import socket
import sys
import time


def _run_asserts(asserts, connected):
    """返回 (all_pass, reason, actual)。"""
    for a in asserts:
        t = a.get("type")
        if t == "tcp_connectable":
            if not connected:
                return False, "tcp connect failed after all attempts", None
        else:
            return False, "unknown assert type {!r}".format(t), None
    return True, "ok", None


def _valid_port(value):
    """端口合法性(env 源自 PID file/env, 可能损坏; 评审 🟡): 正整数 1-65535。"""
    try:
        p = int(value)
    except (TypeError, ValueError):
        return False
    return 1 <= p <= 65535


def probe(port, attempts, interval):
    """有界轮询 TCP connect; 返回 (connected, code, body)。"""
    deadline_used = 0
    for i in range(attempts):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(max(interval, 1))
        try:
            s.connect(("localhost", int(port)))
            s.close()
            return True, 0, "connected on attempt {}/{}".format(i + 1, attempts)
        except OSError as e:
            deadline_used = i + 1
            body = "attempt {}/{}: {}".format(i + 1, attempts, e)
        finally:
            s.close()
        if i + 1 < attempts:
            time.sleep(interval)
    return False, 1, body if deadline_used else "no attempts"


def _emit(result, rc):
    print(json.dumps(result, ensure_ascii=False))
    return rc


def main(argv=None):
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--asserts", default=None)
    p.add_argument("--attempts", type=int, default=30)
    p.add_argument("--interval", type=int, default=5)
    args = p.parse_args(argv)

    if args.selftest:
        return run_selftest()

    asserts = json.loads(args.asserts) if args.asserts else []
    port = os.environ.get("OB_TQ_SSH_PORT")
    if not port:
        return _emit({"pass": False, "error": True, "code": None, "body": "",
                      "actual": None,
                      "reason": "missing env OB_TQ_SSH_PORT"}, 3)
    if not _valid_port(port):
        return _emit({"pass": False, "error": True, "code": None, "body": "",
                      "actual": None,
                      "reason": "invalid env OB_TQ_SSH_PORT: {!r} (want integer 1-65535)".format(port)}, 3)
    connected, code, body = probe(port, args.attempts, args.interval)
    all_pass, reason, actual = _run_asserts(asserts, connected)
    return _emit({"pass": all_pass, "code": code, "body": body,
                  "actual": actual, "reason": reason},
                 0 if all_pass else 1)


def run_selftest():
    import contextlib
    import io
    checks = []

    def chk(name, got, want):
        checks.append((name, got == want, got, want))

    # assert 原语纯函数
    chk("tcp hit", _run_asserts([{"type": "tcp_connectable"}], True), (True, "ok", None))
    chk("tcp miss", _run_asserts([{"type": "tcp_connectable"}], False),
        (False, "tcp connect failed after all attempts", None))
    chk("unknown assert", _run_asserts([{"type": "bogus"}], True),
        (False, "unknown assert type 'bogus'", None))
    # 端口合法性(评审 🟡): 坏端口 error 3 不 traceback(守 probe seam 一行 JSON 契约)
    chk("port valid", _valid_port("2222"), True)
    chk("port notaport", _valid_port("notaport"), False)
    chk("port oob", _valid_port("70000"), False)
    # 真连一个本地 listener(不依赖外部网络)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    free_port = srv.getsockname()[1]
    conn, code, body = probe(free_port, 2, 0)
    chk("probe connectable", (conn, code), (True, 0))
    srv.close()
    # 关闭后同端口(假定未复用)有限尝试 → fail 态而非 error
    conn2, code2, _ = probe(free_port, 2, 0)
    chk("probe refused", (conn2, code2), (False, 1))
    # 缺 env error 形态 + JSON 契约 shape
    buf = io.StringIO()
    env_bak = os.environ.get("OB_TQ_SSH_PORT")
    os.environ.pop("OB_TQ_SSH_PORT", None)
    try:
        with contextlib.redirect_stdout(buf):
            rc = main(["--asserts", "[{\"type\":\"tcp_connectable\"}]",
                       "--attempts", "1", "--interval", "0"])
    finally:
        if env_bak is not None:
            os.environ["OB_TQ_SSH_PORT"] = env_bak
    line = buf.getvalue()
    chk("error rc", rc, 3)
    try:
        rec = json.loads(line)
    except ValueError:
        rec = None
    chk("error line is one JSON dict", isinstance(rec, dict) and
        set(rec) == {"pass", "code", "body", "actual", "reason", "error"} and
        rec["error"] is True and "OB_TQ_SSH_PORT" in rec["reason"], True)
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
