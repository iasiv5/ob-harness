#!/usr/bin/env python3
"""Web (HTTP static resource) probe — Web UI 可达性与内容断言。

probe seam 契约与 probe_redfish 同构: stdout 恰好一行 JSON dict
{"pass","code","body","actual","reason"}(+error), rc ∈ {0,1,3}。

host/port 走 argv(与 redfish 同); 无凭据(Web UI 静态资源通常公开)。

Assert primitives:
  status_in{value: [code,...]}       HTTP 状态码命中任一
  content_type_match{value: prefix}  Content-Type header 前缀匹配(如 "text/html")
  body_contains_any{value: [s,...]}  body 子串任一命中

CLI:
  probe_web.py --host H --port P --path PATH --asserts '<JSON>' [--timeout N] [--selftest]
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


def probe(host, port, path, timeout, scheme=None):
    """HTTP/HTTPS GET; 返回 (code, headers, body) 或 (None, {}, error_msg)。

    scheme 优先级: argv scheme > env OB_TQ_WEB_SCHEME > 默认 https。
    HTTPS 自签证书场景禁用验证(urllib 默认验签会拒自签)。
    """
    import ssl
    scheme = scheme or os.environ.get("OB_TQ_WEB_SCHEME", "https")
    url = "{}://{}:{}{}".format(scheme, host, port, path)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ob-test-qemu/1.0"})
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            headers = dict(resp.headers)
            return resp.status, headers, body
    except urllib.error.HTTPError as e:
        # HTTPError 也是 valid response(如 404), 带 status/headers/body
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        headers = dict(e.headers) if e.headers else {}
        return e.code, headers, body
    except Exception as e:
        return None, {}, "request failed: {}".format(e)


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
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--scheme", choices=["http", "https"], default=None)
    args = p.parse_args(argv)

    if args.selftest:
        return run_selftest()

    # selftest 之后的必填校验(避免 selftest 被 --host/--port/--path 阻断)
    if not args.host or not args.port or not args.path:
        p.error("--host, --port, --path required (unless --selftest)")

    asserts = json.loads(args.asserts) if args.asserts else []
    code, headers, body = probe(args.host, args.port, args.path, args.timeout, args.scheme)
    if code is None:
        return _emit({"pass": False, "error": True, "code": None, "body": body,
                      "actual": None, "reason": body}, 3)
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

    suite = unittest.TestLoader().loadTestsFromTestCase(TestWebProbe)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
