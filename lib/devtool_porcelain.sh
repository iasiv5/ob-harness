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


# dev_emit_reset_json <recipe> <srctree> <srctreebase> <disposition> <destination_parent> <cleaned_bbappend>
# python json.dumps 建 dict(7 字段序与 cmd_dev inline 逐字一致; destination_parent 空→null, destination 恒 null,
# cleaned_bbappend 空→null) → tempfile → devtool_emit_json 校验+原子发布。argv 值不插值源码串。
# 编码/校验失败 → 删 tempfile + return 1(调用者 exit 1, stdout 空)。被 cmd_dev reset 消费。
dev_emit_reset_json() {
    local recipe="$1" srctree="$2" srctreebase="$3" disposition="$4" destination_parent="$5" cleaned_bbappend="$6"
    local _json_tmp _json_rc=0
    _json_tmp="$(mktemp 2>/dev/null)"
    python3 -c 'import json,sys
print(json.dumps({"recipe":sys.argv[1],"srctree":sys.argv[2],"srctreebase":sys.argv[3],"disposition":sys.argv[4],"destination_parent":sys.argv[5] or None,"destination":None,"cleaned_bbappend":sys.argv[6] or None}))' \
        "$recipe" "$srctree" "$srctreebase" "$disposition" "$destination_parent" "$cleaned_bbappend" > "$_json_tmp" 2>/dev/null || _json_rc=$?
    if [[ "$_json_rc" -ne 0 || ! -s "$_json_tmp" ]]; then
        rm -f -- "$_json_tmp" 2>/dev/null
        return 1
    fi
    devtool_emit_json "$_json_tmp"
}


# dev_emit_finish_json <recipe> <srctree> <srctreebase> <disposition> <destination_parent> <cleaned_bbappend>
#                      <landing_mode> <landing_layer> <patches_json> <recipe_files_json> <srcrev>
# 12 字段序(reset 7 + landing 5); patches/recipe_files 经 argv JSON 串 json.loads 合入(空→[]); 其余空标量→null。
# 编码/校验失败 → 删 tempfile + return 1。被 cmd_dev finish 消费。
dev_emit_finish_json() {
    local recipe="$1" srctree="$2" srctreebase="$3" disposition="$4" destination_parent="$5" cleaned_bbappend="$6"
    local landing_mode="$7" landing_layer="$8" patches_json="$9" recipe_files_json="${10}" srcrev="${11}"
    local _json_tmp _json_rc=0
    _json_tmp="$(mktemp 2>/dev/null)"
    python3 -c 'import json,sys
patches=json.loads(sys.argv[9]) if sys.argv[9] else []
rf=json.loads(sys.argv[10]) if sys.argv[10] else []
print(json.dumps({"recipe":sys.argv[1],"srctree":sys.argv[2],"srctreebase":sys.argv[3],"disposition":sys.argv[4],"destination_parent":sys.argv[5] or None,"destination":None,"cleaned_bbappend":sys.argv[6] or None,"landing_mode":sys.argv[7] or None,"landing_layer":sys.argv[8] or None,"patches":patches,"recipe_files":rf,"srcrev":sys.argv[11] or None}))' \
        "$recipe" "$srctree" "$srctreebase" "$disposition" "$destination_parent" "$cleaned_bbappend" "$landing_mode" "$landing_layer" "$patches_json" "$recipe_files_json" "$srcrev" > "$_json_tmp" 2>/dev/null || _json_rc=$?
    if [[ "$_json_rc" -ne 0 || ! -s "$_json_tmp" ]]; then
        rm -f -- "$_json_tmp" 2>/dev/null
        return 1
    fi
    devtool_emit_json "$_json_tmp"
}


# dev_emit_status_jsonl <entries>(换行分隔 "recipe<TAB>srctree")
# 逐行 python json.dumps 建 {recipe,srctree} → tempfile → devtool_emit_jsonl 校验(行数==expected + key 集 + json.loads)+发布。
# expected 在 python3 调用前 +1, 故某行编码失败时 实际行数<expected → emit_jsonl 校验失败 → return 1(防 partial stdout 假成功)。
# 空 entries → expected=0 + 空文件(无尾换行) → emit_jsonl 拒绝 → return 1(调用方应先判空, cmd_dev status 空时 warn exit 0 不调本函数)。
# 编码/校验失败 → 删 tempfile + return 1。被 cmd_dev status 消费。
dev_emit_status_jsonl() {
    local entries="$1"
    local _jsonl _r _s _expected=0
    _jsonl="$(mktemp 2>/dev/null)"
    : > "$_jsonl"
    while IFS=$'\t' read -r _r _s; do
        [[ -z "$_r" ]] && continue
        _expected=$((_expected + 1))
        python3 -c 'import json,sys
print(json.dumps({"recipe":sys.argv[1],"srctree":sys.argv[2]}))' "$_r" "$_s" >> "$_jsonl" 2>/dev/null || true
    done <<< "$entries"
    devtool_emit_jsonl "$_jsonl" "$_expected" '["recipe","srctree"]'
}
