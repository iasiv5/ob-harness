#!/usr/bin/env python3
"""romulus Redfish probe engine + assert primitives.

Per-machine probe engine (ADR-0025: each machine's baseline dir ships its own
engine; this is NOT shared with `ob smoke`).  host/port/auth are injected by
the caller (cmd_test_qemu / run.sh); nothing is hardcoded.

Assert primitives (state assertions, not timing — zero flake by design):
  status_in(code, value_list)         HTTP code in list
  json_path_exists(body, jp)          dotted path resolves in parsed body
  json_path_match(body, jp, expected) value at dotted path equals expected

Dotted path `jp` is split on '.' and walked level by level; an integer segment
indexes into a list (e.g. "Managers.0.FirmwareVersion").  Dotted keys like
"@odata.count" are NOT supported (spike limitation) — spike ARs avoid them.

CLI (normal probe):
  probe_redfish.py --host H --port P --user U --password W \
                   --method M --path PATH [--body JSON] --asserts 'JSON'
  stdout: one-line JSON {"pass","code","body","actual","reason"}
  exit:   0=pass / 1=fail

CLI (selftest, no network):
  probe_redfish.py --selftest   -> exit 0 iff all primitive checks pass
"""

import argparse
import base64
import json
import ssl
import sys
import urllib.error
import urllib.request

# bmcweb ships a self-signed cert; mirror `ob smoke`'s `curl -sk` (no cert verify).
# Spike scope: test-qemu talks to a local QEMU BMC the operator trusts.
_SSL_CTX = ssl._create_unverified_context()


# --- assert primitives ------------------------------------------------------

def status_in(code, value_list):
    """HTTP status code is in value_list."""
    return code in value_list


def _walk_json_path(obj, jp):
    """Walk obj by dotted path jp. Returns (found, value)."""
    cur = obj
    for seg in jp.split("."):
        if isinstance(cur, list):
            try:
                idx = int(seg)
            except (ValueError, TypeError):
                return False, None
            if idx < 0 or idx >= len(cur):
                return False, None
            cur = cur[idx]
        elif isinstance(cur, dict):
            if seg not in cur:
                return False, None
            cur = cur[seg]
        else:
            return False, None
    return True, cur


def _parse_body(body):
    if isinstance(body, (dict, list)):
        return body
    try:
        return json.loads(body)
    except (ValueError, TypeError):
        return None


def json_path_exists(body, jp):
    """Dotted path jp exists in parsed body."""
    obj = _parse_body(body)
    if obj is None:
        return False
    found, _ = _walk_json_path(obj, jp)
    return found


def json_path_match(body, jp, expected):
    """Value at dotted path jp equals expected."""
    obj = _parse_body(body)
    if obj is None:
        return False
    found, val = _walk_json_path(obj, jp)
    return found and val == expected


def run_asserts(asserts, code, body):
    """Run each assert against (code, body).

    Returns (all_pass, reason, actual). On the first failing assert, reason
    explains the mismatch and actual carries the observed value for reporting.
    """
    for a in asserts:
        t = a.get("type")
        if t == "status_in":
            want = a.get("value", [])
            if not status_in(code, want):
                return False, "status {} not in {}".format(code, want), code
        elif t == "json_path_exists":
            jp = a.get("path", "")
            if not json_path_exists(body, jp):
                return False, "path '{}' not found".format(jp), None
        elif t == "json_path_match":
            jp = a.get("path", "")
            want = a.get("value")
            obj = _parse_body(body)
            found, val = _walk_json_path(obj, jp) if obj is not None else (False, None)
            if not found:
                return False, "path '{}' not found".format(jp), None
            if val != want:
                return False, "path '{}' expected {!r} got {!r}".format(jp, want, val), val
        else:
            return False, "unknown assert type {!r}".format(t), None
    return True, "ok", None


# --- probe ------------------------------------------------------------------

def _basic_auth(user, password):
    raw = "{}:{}".format(user, password).encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def _extract_created_uri(headers, body):
    """Location header first, then body @odata.id."""
    if headers is not None:
        loc = headers.get("Location")
        if loc:
            return loc
    obj = _parse_body(body)
    if isinstance(obj, dict):
        return obj.get("@odata.id")
    return None


def _cleanup_delete(host, port, user, password, headers, body, timeout):
    """Best-effort DELETE of a resource a mutating probe should not have created.

    Never raises; a failure is recorded as a note appended to reason and does
    NOT change the fail verdict (评审六轮 🟡2: residual account on a shared
    instance → later 409 / permission drift).
    """
    uri = _extract_created_uri(headers, body)
    if not uri:
        return None
    if uri.startswith("http://") or uri.startswith("https://"):
        url = uri
    else:
        url = "https://{}:{}{}".format(host, port, uri)
    req = urllib.request.Request(url, method="DELETE")
    req.add_header("Authorization", _basic_auth(user, password))
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CTX) as resp:
            return "cleanup DELETE {} -> {}".format(url, resp.getcode())
    except urllib.error.HTTPError as e:
        return "cleanup DELETE {} -> HTTP {}".format(url, e.code)
    except Exception as e:  # best-effort: swallow
        return "cleanup DELETE {} -> error: {}".format(url, e)


def probe(host, port, user, password, method, path, body, asserts, timeout=10.0):
    """Issue a Redfish request and run asserts. Returns result dict."""
    url = "https://{}:{}{}".format(host, port, path)
    data = body.encode("utf-8") if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", _basic_auth(user, password))

    code = None
    resp_body = ""
    resp_headers = None
    conn_error = None
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CTX) as resp:
            code = resp.getcode()
            resp_headers = resp.headers
            resp_body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        code = e.code
        resp_headers = e.headers
        try:
            resp_body = e.read().decode("utf-8", "replace")
        except Exception:
            resp_body = ""
    except urllib.error.URLError as e:
        conn_error = "connection error: {}".format(e.reason)
    except Exception as e:
        conn_error = "request error: {}".format(e)

    if conn_error is not None:
        return {"pass": False, "code": None, "body": "", "actual": None,
                "reason": conn_error}

    all_pass, reason, actual = run_asserts(asserts, code, resp_body)
    result = {"pass": all_pass, "code": code, "body": resp_body,
              "actual": actual, "reason": reason}

    # mutating cleanup fail-safe: POST returned 2xx while asserts failed → the
    # BMC accepted a request baseline says it must reject; try to remove the
    # side effect so re-runs against the shared instance stay clean.
    if method and method.upper() == "POST" and code in (200, 201) and not all_pass:
        note = _cleanup_delete(host, port, user, password, resp_headers, resp_body, timeout)
        if note:
            result["reason"] = "{}; {}".format(reason, note)
    return result


# --- selftest (no network) --------------------------------------------------

def run_selftest():
    checks = []

    def chk(name, got, want):
        checks.append((name, got == want, got, want))

    chk("status_in hit", status_in(200, [200, 401]), True)
    chk("status_in miss", status_in(200, [400]), False)
    chk("exists top", json_path_exists('{"FirmwareVersion":"x"}', "FirmwareVersion"), True)
    chk("exists missing", json_path_exists('{"FirmwareVersion":"x"}', "SerialNumber"), False)
    chk("exists non-json", json_path_exists("not json", "a"), False)
    chk("match hit", json_path_match('{"FirmwareVersion":"x"}', "FirmwareVersion", "x"), True)
    chk("match miss", json_path_match('{"FirmwareVersion":"x"}', "FirmwareVersion", "y"), False)
    chk("deep list idx", json_path_match('{"Managers":[{"FirmwareVersion":"x"}]}',
                                          "Managers.0.FirmwareVersion", "x"), True)
    chk("deep list oob", json_path_exists('{"Managers":[{"FirmwareVersion":"x"}]}',
                                          "Managers.5.FirmwareVersion"), False)

    all_ok = True
    for name, ok, got, want in checks:
        if not ok:
            all_ok = False
            sys.stderr.write("FAIL {}: got {!r} want {!r}\n".format(name, got, want))
    if all_ok:
        print("selftest OK ({} checks)".format(len(checks)))
        return 0
    return 1


def main(argv=None):
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--host")
    p.add_argument("--port", type=int)
    p.add_argument("--user")
    p.add_argument("--password")
    p.add_argument("--method")
    p.add_argument("--path")
    p.add_argument("--body", default=None)
    p.add_argument("--asserts", default=None)
    p.add_argument("--timeout", type=float, default=10.0)
    args = p.parse_args(argv)

    if args.selftest:
        return run_selftest()

    asserts = json.loads(args.asserts) if args.asserts else []
    # schema 校验(评审二轮 🟡): 未知 assert type = baseline 数据错, 输出 error + exit 3(不判 fail)。
    # 兜底 planner(方案 A): 直接调 probe 绕过 runner 时也防 unknown type 折叠成 BMC fail。
    _allowed = ("status_in", "json_path_exists", "json_path_match")
    for a in asserts:
        if a.get("type") not in _allowed:
            print(json.dumps({"pass": False, "error": True, "code": None, "body": "",
                              "actual": None,
                              "reason": "unknown assert type '%s'; allowed: %s" %
                              (a.get("type"), ", ".join(_allowed))}, ensure_ascii=False))
            return 3
    result = probe(args.host, args.port, args.user, args.password,
                   args.method, args.path, args.body, asserts, args.timeout)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("pass") else 1


if __name__ == "__main__":
    sys.exit(main())
