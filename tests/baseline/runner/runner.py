#!/usr/bin/env python3
"""共享 baseline runner: 遍历 ar_probes.yaml × applicability → 逐条 probe →
收 pass/fail/skip/xfail/xpass → report → exit 0/1。
runner 单副本共享(ADR-0027, machine 差异只在数据 YAML); 数据路径经 OB_TQ_AR_PROBES/OB_TQ_APPL
env 注入(缺省 script_dir/../ 兜底), host/port/auth 由调用方注入, 不硬编码。

从 run.sh bash 编排全量下沉(逻辑逐行等价, 防御与文案原样保留):
  ① 前置检查     — 参数/凭据(argv 或 env 至少一源)/PyYAML
  ② plan.plan()  — YAML × applicability → schema 校验 + 过滤 + cascade-skip
                    → list[dict](数据错 → SystemExit 3, 不进 α truth)
  ③ 主循环       — 计划行逐条: skip(不调 probe)/xfail/applicable(调 probe);
                    probe 输出经 assemble 协议校验 + 五态判定 → record
  ④ report       — 汇总 VERDICT + 逐条行 + 可选 JSON report; exit 0/1/3

旧 bash↔python 记录边界(\x1f 帧 / assemble argv 形态 / mktemp+trap /
两段内联 live 行 python)全部消亡: record 以 list[dict] 内存流转,
live 行经 report.live_line(与逐条行同源 oneline, 一致性靠代码)。
probe_redfish.py 仍走 subprocess(rc 0/1/3 契约是 probe seam)。
报错文案保留 "run.sh:" 前缀(入口仍是 run.sh, 契约冻结)。
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import assemble  # noqa: E402
import plan as plan_mod  # noqa: E402
import report as report_mod  # noqa: E402

USAGE = """Usage: run.sh --host H --port P [--user U] [--password W] [options]
  Credentials: --user/--password argv OR OB_TQ_USER / OB_TQ_PASSWORD env.
  Env is preferred for real passwords (argv is ps-visible; environ is
  owner-only) — probe_redfish.py _resolve_auth consumes the env fallback.
  --ar ID         only run AR with this id
  --suite NAME    only run ARs in this suite
  --report PATH   dump JSON report to PATH
  -v, --verbose   per-AR live fail/error lines also carry code= when
                  available (reason is always shown; skip lines always
                  carry reason [source])
  -d, --dry-run   list ARs + applicability, no probe, exit 0
  --timeout SE    per-probe HTTP timeout (default 10; env OB_TQ_TIMEOUT)
  -h, --help      show this help
"""


def die(msg, code):
    sys.stderr.write("run.sh: {}\n".format(msg))
    sys.exit(code)


def parse_argv(argv):
    """返回 dict; 未知参数/缺值 → exit 2(文案与旧 run.sh 逐字一致)。"""
    opts = {"host": "", "port": "", "user": "", "password": "", "ar": "",
            "suite": "", "report": "", "timeout": os.environ.get("OB_TQ_TIMEOUT", "10"),
            "verbose": 0, "dry_run": 0}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            sys.stdout.write(USAGE)
            sys.exit(0)
        flag_map = {"--host": "host", "--port": "port", "--user": "user",
                    "--password": "password", "--ar": "ar", "--suite": "suite",
                    "--report": "report", "--timeout": "timeout"}
        if a in flag_map:
            if i + 1 >= len(argv):
                die("unknown argument: {}".format(a), 2)
            opts[flag_map[a]] = argv[i + 1]
            i += 2
        elif a in ("-v", "--verbose"):
            opts["verbose"] = 1
            i += 1
        elif a in ("-d", "--dry-run"):
            opts["dry_run"] = 1
            i += 1
        else:
            sys.stderr.write("run.sh: unknown argument: {}\n".format(a))
            sys.stderr.write(USAGE)
            sys.exit(2)
    return opts


def check_preconditions(o):
    if o["dry_run"]:
        return
    # 凭据各满足 argv 或 env 至少一源(评审 🟡2); 缺口指名, 不笼统一句。
    if not o["host"] or not o["port"]:
        die("--host/--port required (or use --dry-run)", 2)
    missing = ""
    if not o["user"] and not os.environ.get("OB_TQ_USER"):
        missing += " --user (or OB_TQ_USER env)"
    if not o["password"] and not os.environ.get("OB_TQ_PASSWORD"):
        missing += " --password (or OB_TQ_PASSWORD env)"
    if missing:
        die("missing credentials:{}".format(missing), 2)


def check_pyyaml():
    # PyYAML 前置(计划全局约束): 缺失 → exit 3 + remedy, 不让 planner traceback
    # 污染 α truth(评审 🔴2)
    probe = subprocess.run(
        [sys.executable, "-c", "import yaml"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if probe.returncode != 0:
        sys.stderr.write("run.sh: PyYAML not installed (runner needs 'import yaml').\n")
        sys.stderr.write("  Install: pip install pyyaml  (or your distro's python3-yaml)\n")
        sys.exit(3)


def build_plan_rows(script_dir, o):
    """调 plan.plan(); 数据错(SystemExit 3)补 remedy 后转发 exit 3。"""
    ar_probes = os.environ.get("OB_TQ_AR_PROBES",
                               os.path.join(script_dir, "..", "ar_probes.yaml"))
    appl = os.environ.get("OB_TQ_APPL",
                          os.path.join(script_dir, "..", "applicability.yaml"))
    try:
        return plan_mod.plan(ar_probes, appl, o["ar"], o["suite"])
    except SystemExit as e:
        if e.code == 3:
            sys.stderr.write(
                "run.sh: baseline parse/validate failed (see stderr above: YAML syntax / "
                "unknown assert type / bad applicability status / unknown depends_on).\n")
        raise


def main():
    argv = sys.argv[1:]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    o = parse_argv(argv)
    check_preconditions(o)
    check_pyyaml()

    rows = build_plan_rows(script_dir, o)

    # 0 条 AR = 筛选/配置前置错误(非"全通过", 评审 🔴1): exit 3 + remedy
    if not rows:
        sys.stderr.write("run.sh: no AR selected.\n")
        ar_probes = os.environ.get("OB_TQ_AR_PROBES",
                                   os.path.join(script_dir, "..", "ar_probes.yaml"))
        if o["ar"]:
            sys.stderr.write("  No AR matched --ar '{}' in {}.\n".format(o["ar"], ar_probes))
        elif o["suite"]:
            sys.stderr.write("  No AR matched --suite '{}' in {}.\n".format(o["suite"], ar_probes))
        else:
            sys.stderr.write("  baseline '{}' has no AR (empty 'ars:' list?).\n".format(ar_probes))
        sys.exit(3)

    if o["dry_run"] == 1:
        print("dry-run: AR list + applicability (no probe)")
        for r in rows:
            print("  {:<14} {}".format(r["ar"], r["status"]))
        return 0

    probe_bin = os.environ.get("OB_TQ_PROBE",
                               os.path.join(script_dir, "probe_redfish.py"))
    print("probing {} ARs (timeout {}s per probe) — results stream below".format(
        len(rows), o["timeout"]), file=sys.stderr, flush=True)

    records = []
    for r in rows:
        st = r["status"]
        if st in ("skip", "cascade_skip"):
            # live 行恒打 '  <AR> skip | reason'(每条 AR 只出现一次: reason 在
            # live 行给全, report --compact-rows 相应跳过 skip 行, 不再双打)。
            # -v 只影响 fail/error 行。reason 是 plan() 产出的原字符串,
            # 无 \x1f 帧转义形态, 无需解码。
            rec = assemble.skip_record(r["ar"], r["reason"], r["source"])
            records.append(rec)
            print(report_mod.live_line(rec, o["verbose"]),
                  file=sys.stderr, flush=True)
        elif st in ("xfail", "applicable"):
            # 凭据条件传(评审 🟡2): argv 缺者不传, probe _resolve_auth 从
            # OB_TQ_* env 补 — 密码全程不落 argv(ps world-readable →
            # environ owner-only)。body present iff plan dict 的 body is not
            # None(YAML 显式 {}/"" 是合法 body, 禁止 truthy 判断)。
            probe_args = [sys.executable, probe_bin,
                          "--host", o["host"], "--port", o["port"],
                          "--method", r["method"], "--path", r["path"],
                          "--asserts", json.dumps(r["asserts"]),
                          "--timeout", o["timeout"]]
            if o["user"]:
                probe_args += ["--user", o["user"]]
            if o["password"]:
                probe_args += ["--password", o["password"]]
            if r["body"] is not None:
                probe_args += ["--body", json.dumps(r["body"])]
            # 只捕获 stdout(与 bash out=$(...) 语义一致), probe stderr 自然
            # 继承到 runner stderr 不吞诊断; text+utf-8 钉死解码。
            proc = subprocess.run(
                probe_args, stdout=subprocess.PIPE, stderr=None,
                text=True, encoding="utf-8", errors="replace", check=False)
            out = proc.stdout or ""
            rc = proc.returncode
            try:
                rec = assemble.assemble_record(
                    r["ar"], st, r["source"], r["reason"], rc, out)
            except Exception:
                # 装配自身失败兜底: error record(infra), 不让异常冒充 exit 1
                # 假 α truth。
                rec = assemble.fallback_record(r["ar"])
            records.append(rec)
            # live 行经 report.live_line(record 走内存, 无 argv/stdin 过界,
            # E2BIG 类问题整体消失)。
            print(report_mod.live_line(rec, o["verbose"]),
                  file=sys.stderr, flush=True)
        else:
            die("unknown applicability status '{}' for {}".format(st, r["ar"]), 3)

    # report 恒跳过 pass/skip 行防双打(A4); 非 pass 行(code/reason/source)
    # 仍全量保留。
    return report_mod.run_report(records, o["report"] or None, True)


if __name__ == "__main__":
    sys.exit(main())
