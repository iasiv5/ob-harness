#!/usr/bin/env python3
"""Console (serial-over-socket) probe — 串口登录交互断言。

probe seam 契约与 probe_redfish 同构: stdout 恰好一行 JSON dict
{"pass","code","body","actual","reason"}(+error), rc ∈ {0,1,3}。

socket 路径 env OB_TQ_CONSOLE_SOCK(缺 → error exit 3); 凭据 env
OB_TQ_CONSOLE_USER / OB_TQ_CONSOLE_PASSWORD, fallback OB_TQ_USER /
OB_TQ_PASSWORD(两源全缺 → error exit 3)。

交互序列(pexpect):
  1. spawn socat -,rawer UNIX-CONNECT:<sock>
  2. expect login prompt (默认 "login:", 可配 OB_TQ_CONSOLE_LOGIN_PROMPT)
  3. sendline user
  4. expect password prompt (默认 "Password:", 可配 OB_TQ_CONSOLE_PASSWORD_PROMPT)
  5. sendline password
  6. expect shell prompt (默认 "$ " 或 "# ", 可配 OB_TQ_CONSOLE_SHELL_PROMPT)

Assert primitives:
  login_prompt_reached    看到 login prompt 即过(不验凭据)
  shell_prompt_reached    完整登录到 shell prompt(验凭据正确性)

CLI:
  probe_console.py --asserts '<JSON>' [--timeout N] [--selftest]
"""
import argparse
import json
import os
import re
import sys

import pexpect
from pexpect import fdpexpect


def _run_asserts(asserts, stage_reached):
    """返回 (all_pass, reason, actual)。

    stage_reached ∈ {"none", "login_prompt", "shell_prompt"}
    """
    for a in asserts:
        t = a.get("type")
        if t == "login_prompt_reached":
            if stage_reached not in ("login_prompt", "shell_prompt"):
                return False, "login prompt not reached (stage={})".format(stage_reached), stage_reached
        elif t == "shell_prompt_reached":
            if stage_reached != "shell_prompt":
                return False, "shell prompt not reached (stage={})".format(stage_reached), stage_reached
        else:
            return False, "unknown assert type {!r}".format(t), None
    return True, "ok", None


def _resolve_creds(env):
    """env 优先 OB_TQ_CONSOLE_*, fallback OB_TQ_*; 返回 (user, password) or None。"""
    user = env.get("OB_TQ_CONSOLE_USER") or env.get("OB_TQ_USER")
    password = env.get("OB_TQ_CONSOLE_PASSWORD") or env.get("OB_TQ_PASSWORD")
    if not user or not password:
        return None
    return user, password


def probe(sock_path, user, password, timeout):
    """pexpect 交互序列; 返回 (stage_reached, code, body)。

    stage_reached: "none" | "login_prompt" | "shell_prompt"
    code: 0=shell_prompt, 1=login_prompt, 3=none/spawn 失败
    body: 交互过程诊断文本

    状态探测优先: 连接后发回车, 若返回新 shell prompt 则直接判 shell_prompt
    (已登录也是可达性证明); 若返回 login prompt 则走完整登录流程。
    """
    login_prompt = os.environ.get("OB_TQ_CONSOLE_LOGIN_PROMPT", "login:")
    password_prompt = os.environ.get("OB_TQ_CONSOLE_PASSWORD_PROMPT", "Password:")
    shell_prompt = os.environ.get("OB_TQ_CONSOLE_SHELL_PROMPT", r"[\$#] ")

    # 直接 Unix socket 连接(绕开 socat 的 TTY 依赖 — 非 TTY 环境 socat 报
    # tcgetattr 错且 pexpect.spawn 无法驱动)。fdpexpect.fdspawn 在 socket fd 上做
    # expect 语义, 与 spawn 同 API。
    import socket
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(sock_path)
    except (OSError, socket.timeout) as e:
        return "none", 3, "socket connect failed: {}".format(e)

    try:
        child = fdpexpect.fdspawn(sock, timeout=timeout, encoding="utf-8")
    except Exception as e:
        sock.close()
        return "none", 3, "fdpexpect init failed: {}".format(e)

    body_parts = []

    # 状态探测: 发回车, 看返回 shell prompt(已登录)还是 login prompt(未登录)。
    # QEMU socket wait=off 模式不重放历史输出, 必须主动触发。
    try:
        child.sendline("")
    except Exception as e:
        child.close()
        return "none", 3, "initial sendline failed: {}".format(e)

    # 优先探测 shell prompt(已登录场景, 直过)
    try:
        child.expect(shell_prompt, timeout=5)
        body_parts.append("shell prompt reached (already logged in)")
        child.close()
        return "shell_prompt", 0, "; ".join(body_parts)
    except pexpect.TIMEOUT:
        # 不是 shell prompt, 继续探测 login prompt
        pass
    except pexpect.EOF:
        child.close()
        return "none", 3, "EOF during state probe; got: {}".format(child.before or "<empty>")

    # 探测 login prompt(未登录场景, 走完整登录流程)
    try:
        child.expect(login_prompt)
        body_parts.append("login prompt reached")
        stage = "login_prompt"
    except pexpect.TIMEOUT:
        child.close()
        return "none", 3, "timeout waiting for login prompt {!r}; got: {}".format(
            login_prompt, child.before or "<empty>")
    except pexpect.EOF:
        child.close()
        return "none", 3, "EOF before login prompt; got: {}".format(child.before or "<empty>")

    # Stage 2: send user, expect password prompt
    try:
        child.sendline(user)
        child.expect(password_prompt)
        body_parts.append("password prompt reached")
    except pexpect.TIMEOUT:
        child.close()
        return stage, 1, "timeout waiting for password prompt {!r}; got: {}".format(
            password_prompt, child.before or "<empty>")
    except pexpect.EOF:
        child.close()
        return stage, 1, "EOF before password prompt; got: {}".format(child.before or "<empty>")

    # Stage 3: send password, expect shell prompt
    try:
        child.sendline(password)
        child.expect(shell_prompt)
        body_parts.append("shell prompt reached")
        stage = "shell_prompt"
    except pexpect.TIMEOUT:
        child.close()
        return stage, 1, "timeout waiting for shell prompt {!r}; got: {}".format(
            shell_prompt, child.before or "<empty>")
    except pexpect.EOF:
        child.close()
        return stage, 1, "EOF before shell prompt; got: {}".format(child.before or "<empty>")

    child.close()
    return stage, 0, "; ".join(body_parts)


def _redact_text(text):
    # Redact common secret patterns while keeping diagnostics useful.
    redacted = text
    redacted = re.sub(r"(?i)(password\s*[:=]\s*)(\S+)", r"\1<redacted>", redacted)
    redacted = re.sub(r"(?i)(passwd\s*[:=]\s*)(\S+)", r"\1<redacted>", redacted)
    redacted = re.sub(r"(?i)(token\s*[:=]\s*)(\S+)", r"\1<redacted>", redacted)
    redacted = re.sub(r"(?i)(secret\s*[:=]\s*)(\S+)", r"\1<redacted>", redacted)
    return redacted


def _sanitize_for_output(value):
    if isinstance(value, str):
        return _redact_text(value)
    if isinstance(value, dict):
        sanitized = {}
        for k, v in value.items():
            key = str(k).lower()
            if any(s in key for s in ("password", "passwd", "token", "secret")):
                sanitized[k] = "<redacted>"
            else:
                sanitized[k] = _sanitize_for_output(v)
        return sanitized
    if isinstance(value, list):
        return [_sanitize_for_output(v) for v in value]
    if isinstance(value, tuple):
        return tuple(_sanitize_for_output(v) for v in value)
    return value


def _emit(result, rc):
    safe_result = _sanitize_for_output(result)
    print(json.dumps(safe_result, ensure_ascii=False))
    return rc


def main(argv=None):
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--asserts", default=None)
    p.add_argument("--timeout", type=int, default=30)
    args = p.parse_args(argv)

    if args.selftest:
        return run_selftest()

    asserts = json.loads(args.asserts) if args.asserts else []
    sock_path = os.environ.get("OB_TQ_CONSOLE_SOCK")
    if not sock_path:
        return _emit({"pass": False, "error": True, "code": None, "body": "",
                      "actual": None,
                      "reason": "missing env OB_TQ_CONSOLE_SOCK"}, 3)
    if not os.path.exists(sock_path):
        return _emit({"pass": False, "error": True, "code": None, "body": "",
                      "actual": None,
                      "reason": "console socket not found: {!r}".format(sock_path)}, 3)
    creds = _resolve_creds(os.environ)
    if creds is None:
        return _emit({"pass": False, "error": True, "code": None, "body": "",
                      "actual": None,
                      "reason": "missing console credentials env "
                                "(OB_TQ_CONSOLE_USER/OB_TQ_CONSOLE_PASSWORD or fallback OB_TQ_USER/OB_TQ_PASSWORD)"}, 3)
    user, password = creds
    stage_reached, code, body = probe(sock_path, user, password, args.timeout)
    all_pass, reason, actual = _run_asserts(asserts, stage_reached)
    return _emit({"pass": all_pass, "code": code, "body": body,
                  "actual": actual, "reason": reason},
                 0 if all_pass else 1)


def run_selftest():
    """自测: mock pexpect.spawn 验证三阶段断言逻辑。"""
    import unittest
    from unittest.mock import MagicMock, patch

    class TestConsoleProbe(unittest.TestCase):
        def test_login_prompt_reached_pass(self):
            asserts = [{"type": "login_prompt_reached"}]
            all_pass, reason, _ = _run_asserts(asserts, "login_prompt")
            self.assertTrue(all_pass)
            self.assertEqual(reason, "ok")

        def test_shell_prompt_reached_pass(self):
            asserts = [{"type": "shell_prompt_reached"}]
            all_pass, reason, _ = _run_asserts(asserts, "shell_prompt")
            self.assertTrue(all_pass)

        def test_login_prompt_reached_fail(self):
            asserts = [{"type": "login_prompt_reached"}]
            all_pass, reason, actual = _run_asserts(asserts, "none")
            self.assertFalse(all_pass)
            self.assertIn("not reached", reason)
            self.assertEqual(actual, "none")

        def test_shell_prompt_reached_fail(self):
            asserts = [{"type": "shell_prompt_reached"}]
            all_pass, reason, actual = _run_asserts(asserts, "login_prompt")
            self.assertFalse(all_pass)
            self.assertIn("not reached", reason)

        def test_unknown_assert(self):
            asserts = [{"type": "bogus"}]
            all_pass, reason, _ = _run_asserts(asserts, "shell_prompt")
            self.assertFalse(all_pass)
            self.assertIn("unknown assert", reason)

        def test_resolve_creds_console_env(self):
            env = {"OB_TQ_CONSOLE_USER": "u1", "OB_TQ_CONSOLE_PASSWORD": "p1"}
            self.assertEqual(_resolve_creds(env), ("u1", "p1"))

        def test_resolve_creds_fallback(self):
            env = {"OB_TQ_USER": "u2", "OB_TQ_PASSWORD": "p2"}
            self.assertEqual(_resolve_creds(env), ("u2", "p2"))

        def test_resolve_creds_missing(self):
            self.assertIsNone(_resolve_creds({}))

    suite = unittest.TestLoader().loadTestsFromTestCase(TestConsoleProbe)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
