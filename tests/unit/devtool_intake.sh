#!/usr/bin/env bash
# tests/unit/devtool_intake.sh — dev_intake_argv 单测(unit 层)。
# 覆盖 argv 解析: 合法四元组(--machine/subcmd/pattern/recipe) + 等号形式 + -d 设全局 DRY_RUN +
#   usage-error(unknown option / missing value / 非法 --machine / too-many pattern·recipe) + 空入参。
# outvar 回填: 经 nameref 写 caller 作用域, 必须当前 shell 跑; stderr 用 2>"$_err" 捕(不用 $() 子 shell)。
# leaf-pure: 函数 return 0/1(不 exit); exit_contract Y 静态守卫。
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
_err="$TMP/err"

m=""; s=""; p=""; r=""; rc=0

# ① 合法: --machine romulus list ipmi → 0 + 四元组
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine romulus list ipmi 2>"$_err" || rc=$?
assert_eq "① 合法 rc=0" "$rc" "0"
assert_eq "① machine=romulus" "$m" "romulus"
assert_eq "① subcmd=list" "$s" "list"
assert_eq "① pattern=ipmi" "$p" "ipmi"
assert_eq "① recipe 空(list 不收 recipe)" "$r" ""

# ② 等号形式: --machine=romulus modify phosphor-ipmi-host → 0
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine=romulus modify phosphor-ipmi-host 2>"$_err" || rc=$?
assert_eq "② 等号 rc=0" "$rc" "0"
assert_eq "② machine=romulus" "$m" "romulus"
assert_eq "② subcmd=modify" "$s" "modify"
assert_eq "② recipe=phosphor-ipmi-host" "$r" "phosphor-ipmi-host"

# ③ -d 设全局 DRY_RUN=1
DRY_RUN=0
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r -d --machine romulus status 2>"$_err" || rc=$?
assert_eq "③ -d rc=0" "$rc" "0"
assert_eq "③ DRY_RUN=1(全局副作用)" "$DRY_RUN" "1"

# ④ unknown option --bogus → 1 + stderr 含 "unknown option"
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --bogus 2>"$_err" || rc=$?
assert_eq "④ unknown option rc=1" "$rc" "1"
assert_contains "④ stderr 含 unknown option" "$(cat "$_err")" "unknown option"

# ⑤ --machine 缺值 → 1
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine 2>"$_err" || rc=$?
assert_eq "⑤ --machine 缺值 rc=1" "$rc" "1"

# ⑥a --machine 空值 → 1
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine "" 2>"$_err" || rc=$?
assert_eq "⑥a --machine 空值 rc=1" "$rc" "1"

# ⑥b --machine=-x 非法值(以 - 开头) → 1
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r --machine=-x list 2>"$_err" || rc=$?
assert_eq "⑥b --machine=-x rc=1" "$rc" "1"

# ⑦ list 两 pattern → 1 (too-many)
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r list ipmi foo 2>"$_err" || rc=$?
assert_eq "⑦ list too-many rc=1" "$rc" "1"
assert_contains "⑦ stderr too many patterns" "$(cat "$_err")" "too many patterns"

# ⑧ modify 两 recipe → 1 (too-many)
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r modify a b 2>"$_err" || rc=$?
assert_eq "⑧ modify too-many rc=1" "$rc" "1"

# ⑨ 无 subcmd 无位置参 → 0 (subcmd 空, 留 TTY/dispatch 处理)
m=""; s=""; p=""; r=""; rc=0
dev_intake_argv m s p r 2>"$_err" || rc=$?
assert_eq "⑨ 空入参 rc=0" "$rc" "0"
assert_eq "⑨ subcmd 空(留 TTY/dispatch)" "$s" ""

assert_summary
