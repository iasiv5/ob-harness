#!/usr/bin/env python3
"""Web (HTTP static resource) probe — Web UI 可达性/登录与内容断言。

probe seam 契约与 probe_redfish 同构: stdout 恰好一行 JSON dict
{"pass","code","body","actual","reason"}(+error), rc ∈ {0,1,3}。

host/port 走 argv(与 redfish 同); 静态资源无凭据; 配置 login 块时走
"登录 → 带 cookie GET 目标路径" 两段式(SMOKE-08, 数据驱动 per ADR-0028):
  login: {path, method=POST, content_type, body({user}/{password} 占位符),
          csrf, ok_statuses, logout_path, logout_method}
凭据解析: argv > OB_TQ_WEB_USER/OB_TQ_WEB_PASSWORD > OB_TQ_USER/OB_TQ_PASSWORD
(密码优先 env, argv ps 可见 — 与 probe_redfish _resolve_auth 同惯例)。

Assert primitives:
  status_in{value: [code,...]}       HTTP 状态码命中任一
  content_type_match{value: prefix}  Content-Type header 前缀匹配(如 "text/html")
  body_contains_any{value: [s,...]}  body 子串任一命中

CLI:
  probe_web.py --host H --port P --path PATH --asserts '<JSON>'
               [--login '<JSON>' --user U --password W]
               [--timeout N] [--selftest]
"""
import argparse
import json
import os
import sys
import urllib.request
import urllib.error


def _run_asserts(asserts, code, headers, body):
    """返回 (all_pass, reason, actual)。"""
    for a in asserts:
        t = a.get("type")
        if t == "status_in":
            want = a.get("value", [])
            if code not in want:
                return False, "status {} not in {}".format(code, want), code
        elif t == "content_type_match":
            want = a.get("value", "")
            ct = headers.get("Content-Type", "")
            if not ct.startswith(want):
                return False, "Content-Type {!r} does not start with {!r}".format(ct, want), ct
        elif t == "body_contains_any":
            want = a.get("value", [])
            if not any(s in body for s in want):
                return False, "body does not contain any of {!r}".format(want), None
        else:
            return False, "unknown assert type {!r}".format(t), None
    return True, "ok", None


def _build_opener(ctx):
    """带 CookieJar 的 opener + jar — login 会话(SESSION/XSRF-TOKEN)跨请求保持。"""
    import http.cookiejar
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx),
        urllib.request.HTTPCookieProcessor(jar))
    return opener, jar


def _open(opener, req, timeout):
    """opener.open 包装; HTTPError 也是 valid response(如 401/404)。
    返回 (code, headers, body) 或 (None, {}, error_msg)。"""
    try:
        with opener.open(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return resp.status, dict(resp.headers), body
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        headers = dict(e.headers) if e.headers else {}
        return e.code, headers, body
    except Exception as e:
        return None, {}, "request failed: {}".format(e)


def _resolve_creds(argv_user, argv_password):
    """凭据解析: argv > OB_TQ_WEB_* > OB_TQ_*。返回 (user, password) 可为空。"""
    user = argv_user or os.environ.get("OB_TQ_WEB_USER") or os.environ.get("OB_TQ_USER") or ""
    password = (argv_password or os.environ.get("OB_TQ_WEB_PASSWORD")
                or os.environ.get("OB_TQ_PASSWORD") or "")
    return user, password


def _do_login(opener, host, port, scheme, cfg, user, password, timeout):
    """两段式登录(数据驱动): 可选 GET 拿 CSRF → POST 凭据。
    返回 (ok, status, reason); 请求层异常 reason 带 error 前缀由调用方转 error 3。"""
    url = "{}://{}:{}{}".format(scheme, host, port, cfg["path"])
    token = None
    if cfg.get("csrf", True):
        _, headers, err = _open(opener, urllib.request.Request(url), timeout)
        if err is not None and headers == {} and _is_transport_error(err):
            return False, None, err
        token = (headers or {}).get("X-CSRFTOKEN")
    body = (cfg.get("body") or "").replace("{user}", user).replace("{password}", password)
    headers = {"User-Agent": "ob-test-qemu/1.0",
               "Content-Type": cfg.get("content_type", "application/x-www-form-urlencoded")}
    if token:
        headers["X-CSRFTOKEN"] = token
    req = urllib.request.Request(url, data=body.encode("utf-8"), headers=headers, method="POST")
    code, _, err = _open(opener, req, timeout)
    if code is None:
        return False, None, err
    if code not in cfg.get("ok_statuses", [200, 201]):
        return False, code, "login failed with status {}".format(code)
    return True, code, "ok"


def _is_transport_error(msg):
    """_open 的 error 返回(str)是否 transport 层异常(非 HTTPError)。"""
    return msg is not None and msg.startswith("request failed:")


def _do_logout(opener, host, port, scheme, cfg, jar, timeout):
    """best-effort 登出: 失败/未配置都只返回 note, 不影响 verdict。"""
    lp = cfg.get("logout_path")
    if not lp:
        return None
    url = "{}://{}:{}{}".format(scheme, host, port, lp)
    headers = {"User-Agent": "ob-test-qemu/1.0"}
    # XSRF-TOKEN cookie → X-XSRF-TOKEN header(部分 bmcweb 血统实测需要; 无此 cookie 无害省略)
    for c in jar:
        if c.name == "XSRF-TOKEN":
            headers["X-XSRF-TOKEN"] = c.value
    req = urllib.request.Request(url, data=b"", headers=headers,
                                 method=cfg.get("logout_method", "POST"))
    code, _, err = _open(opener, req, timeout)
    if code is None or code >= 400:
        return "logout best-effort failed (status={!r}, err={!r})".format(code, err)
    return None


def probe(host, port, path, timeout, scheme=None, login=None, user="", password="",
          _opener=None):
    """HTTP/HTTPS GET; 返回 (code, headers, body, login_fail)。
    (None, {}, error, None) = transport/前置 error(rc 3); login_fail 非 None =
    登录阶段失败(rc 1, reason 保留 "login failed with status N" 根因, 不进入
    最终 GET/assert — 防凭据/端点问题被 status assert 的泛化 reason 覆盖)。
    login 配置时先走 _do_login 建会话(同一 opener 共享 cookie)。
    _opener=(opener, jar) 仅测试注入用, 生产路径走 _build_opener。

    scheme 优先级: argv scheme > env OB_TQ_WEB_SCHEME > 默认 https。
    HTTPS 自签证书场景禁用验证(urllib 默认验签会拒自签)。
    """
    import ssl
    scheme = scheme or os.environ.get("OB_TQ_WEB_SCHEME", "https")
    url = "{}://{}:{}{}".format(scheme, host, port, path)
    if _opener is None:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        opener, jar = _build_opener(ctx)
    else:
        opener, jar = _opener
    if login:
        if not user or not password:
            return None, {}, ("login configured but credentials missing "
                              "(--user/--password or OB_TQ_WEB_*/OB_TQ_* env)"), None
        ok, status, reason = _do_login(opener, host, port, scheme, login, user, password, timeout)
        if not ok:
            if status is None:
                return None, {}, reason, None
            return status, {}, reason, reason
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ob-test-qemu/1.0"})
        with opener.open(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            headers = dict(resp.headers)
            code = resp.status
    except urllib.error.HTTPError as e:
        # HTTPError 也是 valid response(如 404), 带 status/headers/body
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        headers = dict(e.headers) if e.headers else {}
        code = e.code
    except Exception as e:
        return None, {}, "request failed: {}".format(e), None
    if login:
        note = _do_logout(opener, host, port, scheme, login, jar, timeout)
        if note:
            # best-effort: 只附加 note 不改 verdict; 借 body 拼接传递
            body = body + "\n[" + note + "]"
    return code, headers, body, None


def _emit(result, rc):
    print(json.dumps(result, ensure_ascii=False))
    return rc


def main(argv=None):
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--host")
    p.add_argument("--port", type=int)
    p.add_argument("--path")
    p.add_argument("--asserts", default=None)
    p.add_argument("--login", default=None,
                   help="login block JSON (SMOKE-08: login then GET with session)")
    p.add_argument("--user", default=None)
    p.add_argument("--password", default=None)
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--scheme", choices=["http", "https"], default=None)
    args = p.parse_args(argv)

    if args.selftest:
        return run_selftest()

    # selftest 之后的必填校验(避免 selftest 被 --host/--port/--path 阻断)
    if not args.host or not args.port or not args.path:
        p.error("--host, --port, --path required (unless --selftest)")

    asserts = json.loads(args.asserts) if args.asserts else []
    login = json.loads(args.login) if args.login else None
    user, password = _resolve_creds(args.user, args.password)
    code, headers, body, login_fail = probe(args.host, args.port, args.path, args.timeout,
                                            args.scheme, login, user, password)
    if code is None:
        return _emit({"pass": False, "error": True, "code": None, "body": body,
                      "actual": None, "reason": body}, 3)
    if login_fail:
        # 登录阶段失败 = 真实 fail(α truth), 保留根因 reason 不进入最终 assert
        return _emit({"pass": False, "code": code, "body": body,
                      "actual": code, "reason": login_fail}, 1)
    all_pass, reason, actual = _run_asserts(asserts, code, headers, body)
    return _emit({"pass": all_pass, "code": code, "body": body,
                  "actual": actual, "reason": reason},
                 0 if all_pass else 1)


def run_selftest():
    """自测: 断言逻辑 + probe 函数 mock 验证。"""
    import unittest
    from unittest.mock import patch, MagicMock

    class TestWebProbe(unittest.TestCase):
        def test_status_in_pass(self):
            asserts = [{"type": "status_in", "value": [200, 301]}]
            all_pass, reason, _ = _run_asserts(asserts, 200, {}, "")
            self.assertTrue(all_pass)

        def test_status_in_fail(self):
            asserts = [{"type": "status_in", "value": [200]}]
            all_pass, reason, actual = _run_asserts(asserts, 404, {}, "")
            self.assertFalse(all_pass)
            self.assertEqual(actual, 404)

        def test_content_type_match_pass(self):
            asserts = [{"type": "content_type_match", "value": "text/html"}]
            headers = {"Content-Type": "text/html; charset=utf-8"}
            all_pass, reason, _ = _run_asserts(asserts, 200, headers, "")
            self.assertTrue(all_pass)

        def test_content_type_match_fail(self):
            asserts = [{"type": "content_type_match", "value": "text/html"}]
            headers = {"Content-Type": "application/json"}
            all_pass, reason, actual = _run_asserts(asserts, 200, headers, "")
            self.assertFalse(all_pass)
            self.assertEqual(actual, "application/json")

        def test_body_contains_any_pass(self):
            asserts = [{"type": "body_contains_any", "value": ["OpenBMC", "login"]}]
            all_pass, reason, _ = _run_asserts(asserts, 200, {}, "<html>OpenBMC Login</html>")
            self.assertTrue(all_pass)

        def test_body_contains_any_fail(self):
            asserts = [{"type": "body_contains_any", "value": ["OpenBMC"]}]
            all_pass, reason, _ = _run_asserts(asserts, 200, {}, "<html>Other</html>")
            self.assertFalse(all_pass)

        def test_unknown_assert(self):
            asserts = [{"type": "bogus"}]
            all_pass, reason, _ = _run_asserts(asserts, 200, {}, "")
            self.assertFalse(all_pass)
            self.assertIn("unknown assert", reason)

        def _fake_opener(self, get_responses):
            """按调用序返回预设 (code, headers, body) 的 mock opener + jar。"""
            import http.cookiejar
            calls = []

            class _Resp:
                def __init__(self, code, headers, body):
                    self.status, self.headers, self._body = code, headers, body

                def read(self):
                    return self._body.encode()

                def __enter__(self):
                    return self

                def __exit__(self, *a):
                    return False

            class _Opener:
                def open(self, req, timeout=None):
                    calls.append(req)
                    return _Resp(*get_responses[len(calls) - 1])

            class _Jar(list):
                pass

            return _Opener(), _Jar(), calls

        BASE_LOGIN = {"path": "/login", "content_type": "application/json",
                      "body": '{"username":"{user}","password":"{password}"}',
                      "csrf": False}

        def test_login_success(self):
            opener, jar, _ = self._fake_opener([
                (200, {"Content-Type": "application/json"}, '{"a":1}'),   # POST login
                (200, {"Content-Type": "application/json"}, '{"s":[]}'),  # GET target
            ])
            ok, status, reason = _do_login(opener, "h", 1, "https",
                                           dict(self.BASE_LOGIN), "u", "p", 5)
            self.assertTrue(ok)
            self.assertEqual(status, 200)

        def test_login_created_status_default_pass(self):
            # 部分 bmcweb 血统登录返 201(Created); 默认 ok_statuses=[200,201] 须收录(防退回只认 200)
            opener, jar, _ = self._fake_opener([(201, {}, "")])
            ok, status, reason = _do_login(opener, "h", 1, "https",
                                           dict(self.BASE_LOGIN), "u", "p", 5)
            self.assertTrue(ok)
            self.assertEqual(status, 201)

        def test_login_bad_status(self):
            opener, jar, _ = self._fake_opener([(401, {}, "")])
            ok, status, reason = _do_login(opener, "h", 1, "https",
                                           dict(self.BASE_LOGIN), "u", "p", 5)
            self.assertFalse(ok)
            self.assertEqual(status, 401)
            self.assertIn("login failed with status 401", reason)

        def test_login_missing_creds(self):
            code, headers, err, lf = probe("h", 1, "/x", 5, login=dict(self.BASE_LOGIN))
            self.assertIsNone(code)
            self.assertIn("credentials missing", err)

        def test_login_placeholder_substitution(self):
            opener, jar, calls = self._fake_opener([(200, {}, "")])
            _do_login(opener, "h", 1, "https", dict(self.BASE_LOGIN), "alice", "s:cret", 5)
            sent = calls[0].data.decode()
            self.assertEqual(sent, '{"username":"alice","password":"s:cret"}')
            self.assertNotIn("{user}", sent)
            self.assertNotIn("{password}", sent)

        def test_login_logout_best_effort(self):
            import http.cookiejar
            # login 200 → final GET 200 → logout 500: pass verdict 不变, 附加 note
            opener, jar, _ = self._fake_opener([
                (200, {}, ""), (200, {"Content-Type": "application/json"}, "ok"),
                (500, {}, ""),
            ])
            jar.append(http.cookiejar.Cookie(
                version=0, name="XSRF-TOKEN", value="tok", port=None, port_specified=False,
                domain="127.0.0.1", domain_specified=False, domain_initial_dot=False,
                path="/", path_specified=True, secure=True, expires=None,
                discard=True, comment=None, comment_url=None, rest={}, rfc2109=False))
            cfg = dict(self.BASE_LOGIN)
            cfg["logout_path"] = "/logout"
            code, headers, body, lf = probe("h", 1, "/x", 5, login=cfg,
                                        user="u", password="p", _opener=(opener, jar))
            self.assertEqual(code, 200)
            self.assertIn("logout best-effort failed", body)

        def test_no_login_unchanged(self):
            # 无 login 块: 走原有单 GET 路径, 不做登录/登出
            code, headers, body, lf = probe("127.0.0.1", 1, "/definitely-unreachable", 1)
            self.assertIsNone(code)   # transport error → (None, {}, err) 与旧行为一致

        def test_main_login_fail_reason_preserved(self):
            # 登录 401 → 最终 JSON reason 保留 "login failed with status 401"
            # 根因(main 级, 非 _do_login 级 — 防被 status assert 的泛化 reason 覆盖)
            import io
            import unittest.mock
            cfg = dict(self.BASE_LOGIN)
            opener, jar, _ = self._fake_opener([(401, {}, "")])
            with unittest.mock.patch.object(
                    sys.modules[__name__], "probe",
                    return_value=(401, {}, "login failed with status 401",
                                  "login failed with status 401")):
                buf = io.StringIO()
                with unittest.mock.patch.object(sys, "stdout", buf):
                    rc = main(["--host", "h", "--port", "1", "--path", "/x",
                               "--asserts", '[{"type":"status_in","value":[200]}]',
                               "--login", json.dumps(cfg),
                               "--user", "u", "--password", "p"])
            out = json.loads(buf.getvalue())
            self.assertEqual(rc, 1)
            self.assertFalse(out["pass"])
            self.assertEqual(out["reason"], "login failed with status 401")

    suite = unittest.TestLoader().loadTestsFromTestCase(TestWebProbe)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
