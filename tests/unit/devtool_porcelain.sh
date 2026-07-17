#!/usr/bin/env bash
# tests/unit/devtool_porcelain.sh — devtool_porcelain leaf-pure emit 原语单测(unit 层)。
# 覆盖 devtool_emit_json(单行 JSON 校验+发布+删) + devtool_emit_jsonl(JSONL 行数/key/json.loads 校验+发布+删)。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stub.sh"
assert_reset

TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT

JFILE="$TMP/emit_json.tmp"
LFILE="$TMP/emit_jsonl.tmp"

# jtest <label> <expect_rc> <printf_fmt> [printf_args...]: 写 JFILE → 调 emit_json → 捕获 rc + stdout
jtest() {
    local label="$1" expect_rc="$2"; shift 2
    printf "$@" > "$JFILE"
    _out="$(devtool_emit_json "$JFILE" 2>/dev/null)"; _rc=$?
    assert_eq "$label: rc" "$_rc" "$expect_rc"
}

# jltest <label> <expect_rc> <expected_lines> <keys_json> <printf_fmt> [printf_args...]
jltest() {
    local label="$1" expect_rc="$2" explines="$3" keys="$4"; shift 4
    printf "$@" > "$LFILE"
    _out="$(devtool_emit_jsonl "$LFILE" "$explines" "$keys" 2>/dev/null)"; _rc=$?
    assert_eq "$label: rc" "$_rc" "$expect_rc"
}

# ============================================================================
# devtool_emit_json <tmpfile>
#   合法(恰好一物理行 + 尾换行 + json.loads) → cat + rm + rc=0;
#   多行/无尾换行/非法/空/缺文件 → rm(若存在) + rc=1。不 trap。
# ============================================================================

# 合法单行+尾换行 → rc=0 + stdout==内容 + tmpfile 删
printf '%s\n' '{"recipe":"foo","srctree":"/x"}' > "$JFILE"
_out="$(devtool_emit_json "$JFILE" 2>/dev/null)"; _rc=$?
assert_eq "json合法: rc=0" "$_rc" "0"
assert_eq "json合法: stdout==内容(无尾换行被$()剥)" "$_out" '{"recipe":"foo","srctree":"/x"}'
assert_false "json合法: tmpfile删" test -e "$JFILE"

# 合法含空格值(真实链 srctree 含空格) → rc=0 + stdout 完整
printf '%s\n' '{"srctree":"/path with space","r":"v"}' > "$JFILE"
_out="$(devtool_emit_json "$JFILE" 2>/dev/null)"; _rc=$?
assert_eq "json含空格: rc=0" "$_rc" "0"
assert_eq "json含空格: stdout完整(空格不截断)" "$_out" '{"srctree":"/path with space","r":"v"}'

# json.dumps 真实生成(含空格分隔/转义) → rc=0 + round-trip 相等(不强匹配字面, 防格式漂移)
python3 -c 'import json; print(json.dumps({"recipe":"a b","srctree":"/x y"}))' > "$JFILE"
_out="$(devtool_emit_json "$JFILE" 2>/dev/null)"; _rc=$?
assert_eq "json.dumps生成: rc=0" "$_rc" "0"
_rt=0; python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d=={"recipe":"a b","srctree":"/x y"}' "$_out" || _rt=$?
assert_eq "json.dumps生成: round-trip解析相等" "$_rt" "0"
assert_false "json.dumps生成: tmpfile删" test -e "$JFILE"

# 多行(两行 JSON) → rc=1 + 删
jtest "json多行" 1 '%s\n%s\n' '{"a":1}' '{"b":2}'
assert_false "json多行: tmpfile删" test -e "$JFILE"

# 无尾换行 → rc=1 + 删
jtest "json无尾换行" 1 '%s' '{"a":1}'
assert_false "json无尾换行: tmpfile删" test -e "$JFILE"

# 非法 JSON → rc=1 + 删
jtest "json非法" 1 '%s\n' '{a:1}'
assert_false "json非法: tmpfile删" test -e "$JFILE"

# 空文件 → rc=1 + 删
jtest "json空" 1 ''
assert_false "json空: tmpfile删" test -e "$JFILE"

# 缺文件 → rc=1(不创建 JFILE, 用不存在路径)
_out="$(devtool_emit_json "$TMP/no-such-file.json" 2>/dev/null)"; _rc=$?
assert_false "json缺文件: rc非0" test "$_rc" -eq 0

# 合法但含 NUL 物理行边界(单行 JSON 不应含 NUL; 含 NUL → splitlines 视为同行/解析失败)
# 构造: 单行 + 尾换行但中间插 NUL → json.loads 失败 → rc=1
printf '{"a":"x\0y"}\n' > "$JFILE"
_out="$(devtool_emit_json "$JFILE" 2>/dev/null)"; _rc=$?
assert_false "json含NUL: rc非0(NUL破坏json.loads)" test "$_rc" -eq 0
assert_false "json含NUL: tmpfile删" test -e "$JFILE"

# ============================================================================
# devtool_emit_jsonl <tmpfile> <expected_lines> <keys_json>
#   合法(尾\n + splitlines 行数==expected + 每行 strip 非空 + 每行 json.loads +
#        每行 set(keys)==set(json.loads(keys_json))) → cat + rm + rc=0;
#   任一不符/缺文件 → rm(若存在) + rc=1。不 trap。不用 grep -c .。
# ============================================================================

KEYS_RS='["recipe","srctree"]'

# 合法两行 + 尾换行, expected=2 → rc=0 + round-trip 两行 key 正确
printf '%s\n%s\n' '{"recipe":"a","srctree":"/x"}' '{"recipe":"b","srctree":"/y"}' > "$LFILE"
_out="$(devtool_emit_jsonl "$LFILE" 2 "$KEYS_RS" 2>/dev/null)"; _rc=$?
assert_eq "jsonl合法2行: rc=0" "$_rc" "0"
_rt=0; printf '%s\n' "$_out" | python3 -c 'import json,sys
lines=[l for l in sys.stdin if l.strip()]
assert len(lines)==2
for l in lines:
    d=json.loads(l); assert set(d.keys())=={"recipe","srctree"}' || _rt=$?
assert_eq "jsonl合法2行: round-trip两行key正确" "$_rt" "0"
assert_false "jsonl合法2行: tmpfile删" test -e "$LFILE"

# 合法单行 + 尾换行, expected=1 → rc=0
jltest "jsonl合法1行" 0 1 "$KEYS_RS" '%s\n' '{"recipe":"a","srctree":"/x"}'

# 含空格值(真实链) → rc=0
printf '%s\n%s\n' '{"recipe":"a b","srctree":"/path with space"}' '{"recipe":"c","srctree":"/z"}' > "$LFILE"
_out="$(devtool_emit_jsonl "$LFILE" 2 "$KEYS_RS" 2>/dev/null)"; _rc=$?
assert_eq "jsonl含空格值: rc=0" "$_rc" "0"
assert_false "jsonl含空格值: tmpfile删" test -e "$LFILE"

# 行数不等(expected=2 但实际1行) → rc=1
jltest "jsonl行数不等(期望2实际1)" 1 2 "$KEYS_RS" '%s\n' '{"recipe":"a","srctree":"/x"}'

# 含空行(expected=3 含一空行, 行数等但空行 strip 失败) → rc=1
jltest "jsonl含空行" 1 3 "$KEYS_RS" '%s\n%s\n%s\n' '{"recipe":"a","srctree":"/x"}' '' '{"recipe":"b","srctree":"/y"}'

# key 不符(行缺 srctree) → rc=1
jltest "jsonl key不符(缺srctree)" 1 1 "$KEYS_RS" '%s\n' '{"recipe":"a"}'

# key 多余(行多了 unknown) → rc=1
jltest "jsonl key多余" 1 1 "$KEYS_RS" '%s\n' '{"recipe":"a","srctree":"/x","unknown":1}'

# 某行非法 JSON → rc=1
jltest "jsonl某行非法" 1 2 "$KEYS_RS" '%s\n%s\n' '{"recipe":"a","srctree":"/x"}' '{bad}'

# 无尾换行 → rc=1(即使单行)
jltest "jsonl无尾换行" 1 1 "$KEYS_RS" '%s' '{"recipe":"a","srctree":"/x"}'

# 空文件(expected=0 + 空内容) → rc=1(无尾换行, emit 拒绝 expected=0 边界)
_out="$(devtool_emit_jsonl "$LFILE" 0 "$KEYS_RS" 2>/dev/null)"; _rc=$?
: > "$LFILE"
_out="$(devtool_emit_jsonl "$LFILE" 0 "$KEYS_RS" 2>/dev/null)"; _rc=$?
assert_false "jsonl空文件expected0: rc非0(无尾换行拒绝)" test "$_rc" -eq 0
assert_false "jsonl空文件: tmpfile删" test -e "$LFILE"

# 缺文件 → rc=1
_out="$(devtool_emit_jsonl "$TMP/no-such-jsonl.tmp" 1 "$KEYS_RS" 2>/dev/null)"; _rc=$?
assert_false "jsonl缺文件: rc非0" test "$_rc" -eq 0

# expected 非数字(防御 argv) → rc=1
printf '%s\n' '{"recipe":"a","srctree":"/x"}' > "$LFILE"
_out="$(devtool_emit_jsonl "$LFILE" "notanumber" "$KEYS_RS" 2>/dev/null)"; _rc=$?
assert_false "jsonl expected非数字: rc非0" test "$_rc" -eq 0
assert_false "jsonl expected非数字: tmpfile删" test -e "$LFILE"

# ============================================================================
# trap 不变(两个 emit 原语都不安装 EXIT trap)
# ============================================================================
trap 'echo TEST_TRAP' EXIT
printf '%s\n' '{"a":1}' > "$JFILE"
devtool_emit_json "$JFILE" >/dev/null 2>&1
_trap_state="$(trap -p EXIT)"
assert_contains "emit_json trap不变" "$_trap_state" "TEST_TRAP"

printf '%s\n%s\n' '{"recipe":"a","srctree":"/x"}' '{"recipe":"b","srctree":"/y"}' > "$LFILE"
devtool_emit_jsonl "$LFILE" 2 "$KEYS_RS" >/dev/null 2>&1
_trap_state="$(trap -p EXIT)"
assert_contains "emit_jsonl trap不变" "$_trap_state" "TEST_TRAP"

# emit 失败路径也不安装 trap
printf '%s\n%s\n' '{"a":1}' '{"b":2}' > "$JFILE"
devtool_emit_json "$JFILE" >/dev/null 2>&1
_trap_state="$(trap -p EXIT)"
assert_contains "emit_json失败trap不变" "$_trap_state" "TEST_TRAP"
trap - EXIT

assert_summary
