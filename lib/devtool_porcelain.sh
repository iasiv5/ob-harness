#!/usr/bin/env bash
# lib/devtool_porcelain.sh — devtool porcelain emit 原语(leaf-pure module)。
#   devtool_emit_json(校验单行 JSON + cat 发布 + 删) + devtool_emit_jsonl(校验 JSONL 行数/key/json.loads + cat 发布 + 删)。
#   被 cmd_dev(reset/status/finish)消费: 调用者已把 JSON/JSONL 写入 tempfile(argv 传路径, 值不插值源码串),
#   emit 只管"校验 + 原子发布(cat stdout) + 删"。校验/编码失败 → 删 + return 1(调用者 exit 1, stdout 空)。
#   ob loader(ob:73-76 for f in lib/*.sh)source 全部 lib; bash 函数运行时按名解析, 不依赖 source 顺序。
#   术语见 CONTEXT.md ob dev porcelain stdout / function semantic layer。
# Exit: leaf-pure module(函数绝不 exit; 允许文件/进程副作用); 调用者(cmd_dev)负责 exit-code/remedy/诊断。


# devtool_emit_json <tmpfile>
# 校验 tmpfile 恰好一物理行 + 尾换行 + 合法 JSON(json.loads) → cat 发布 + rm → return 0;
# 多行/无尾换行/非法/空/缺文件 → rm(若存在) + return 1。不安装 trap。
devtool_emit_json() {
    local tmpfile="$1" rc=0
    python3 - "$tmpfile" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = f.read()
except Exception:
    sys.exit(1)

ok = len(data.splitlines()) == 1 and data.endswith("\n")
if ok:
    try:
        json.loads(data)
    except Exception:
        ok = False
sys.exit(0 if ok else 1)
PY
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        rm -f -- "$tmpfile" 2>/dev/null
        return 1
    fi
    cat -- "$tmpfile"
    rc=$?
    rm -f -- "$tmpfile"
    return "$rc"
}


# devtool_emit_jsonl <tmpfile> <expected_lines> <keys_json>
# 全 python 校验: 尾换行 + splitlines 行数==expected + 每行 strip 非空 + 每行 json.loads +
#   每行 set(d.keys())==set(json.loads(keys_json)) → cat 发布 + rm → return 0;
# 任一不符/expected 非数字/缺文件 → rm(若存在) + return 1。不安装 trap。不用 grep -c .(全 python 算行数)。
devtool_emit_jsonl() {
    local tmpfile="$1" expected="$2" keys_json="$3" rc=0
    python3 - "$tmpfile" "$expected" "$keys_json" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = f.read()
    expected_n = int(sys.argv[2])
    want_keys = set(json.loads(sys.argv[3]))
except Exception:
    sys.exit(1)

if not data.endswith("\n"):
    sys.exit(1)
lines = data.splitlines()
if len(lines) != expected_n:
    sys.exit(1)
for line in lines:
    s = line.strip()
    if not s:
        sys.exit(1)
    try:
        d = json.loads(s)
    except Exception:
        sys.exit(1)
    if set(d.keys()) != want_keys:
        sys.exit(1)
sys.exit(0)
PY
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        rm -f -- "$tmpfile" 2>/dev/null
        return 1
    fi
    cat -- "$tmpfile"
    rc=$?
    rm -f -- "$tmpfile"
    return "$rc"
}
