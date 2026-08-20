#!/usr/bin/env bash
# tests/protocol/smoke_substep_isolation.sh — cmd_smoke 子步隔离不变量协议测试。
# 锁定三个不变量(任一违反 → FAIL, 对应 criterion #2):
#   (1) cmd_smoke 在生产代码(ob + lib/*.sh)中, 仅被 ob dispatcher 调用;
#   (2) 无其它 cmd_* / lib 函数把 cmd_smoke 当子步调用(对照 smoke_surface.sh (3)
#       main smoke→cmd_smoke 的正向 dispatch 断言, 这里锁反向: 没人偷偷塞 smoke 进来);
#   (3) 无 peer-command remedy 行把用户引向 smoke (smoke→start-qemu 合法, 排除)。
# 裁决: assert_summary 退出码 = verdict (0 = 无违反; 非0 = 违反)。
# run_all 默认 .sh 子集 + ob_check.sh run_all 项都会跑到本测试。
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

# ── (1)+(2) cmd_smoke 生产调用方 = 仅 ob dispatcher ──
# 排除: 定义行 "cmd_smoke()" + 注释行。剩余 = 真调用, 必须全落在 ob。
_call_lines=$(grep -rn "cmd_smoke" ob lib/*.sh 2>/dev/null \
              | grep -v "cmd_smoke()" \
              | grep -vE ":[0-9]+:[[:space:]]*#")
_call_files=$(printf '%s\n' "$_call_lines" | cut -d: -f1 | sort -u)
assert_eq "(1) cmd_smoke 生产调用方文件集 = {ob}" "$_call_files" "ob"

# ob 内 cmd_smoke 出现次数 = 1(单一 dispatcher 分支; ob usage 用命令名 "smoke", 不用函数名)
assert_eq "(2) ob 引用 cmd_smoke 恰好 1 次(dispatcher)" "$(grep -c "cmd_smoke" ob)" "1"

# ── (3a) "ob smoke" 字面量在生产代码只能落在 smoke 自有边界 ──
#   ob (usage/dispatcher) / lib/qemu_commands.sh (cmd_smoke body+section header) /
#   lib/smoke_assertions.sh (module header)。任何 peer 文件加 "Run ob smoke" remedy → 退出该集 → FAIL。
_obsmoke_files=$(grep -rl "ob smoke" ob lib/*.sh 2>/dev/null | sort)
assert_eq "(3a) ob smoke 字面量文件集 = smoke 自有边界三件套" \
    "$_obsmoke_files" \
    "$(printf 'lib/qemu_commands.sh\nlib/smoke_assertions.sh' | sort)"

# ── (3b) 3 个 peer QEMU 命令同住 qemu_commands.sh, 文件集判定够不着 ──
# 逐个抽函数体(同 smoke_surface.sh:60 的 awk 范式), 断言 "ob smoke" 不出现 → 无 peer→smoke nudge。
QC=lib/qemu_commands.sh
for fn in cmd_start_qemu cmd_stop_qemu cmd_deploy_to_qemu; do
    _body=$(awk -v f="$fn" 'index($0, f "()")==1{g=1} g{print; if($0=="}") exit}' "$QC")
    if printf '%s' "$_body" | grep -q "ob smoke"; then
        assert_eq "(3b) $fn body 不引向 ob smoke" "FOUND-nudge" "clean"
    else
        assert_eq "(3b) $fn body 不引向 ob smoke" "clean" "clean"
    fi
done

# ── 裁决式总检: 单条命令, 退出码即 verdict (供报告 A.3 引用 + CI 直跑) ──
# 复刻 (1)(2)(3a)(3b) 进单个 `bash -c`, 任一违反 → 非0 退出。这是 criterion #2 的可复现裁决命令。
_substep_verdict() {
    bash -c '
set -euo pipefail
cd "$1"
# (1)(2) callers of cmd_smoke (excl definition + comments) must be only ob, exactly once.
call_files=$(grep -rn "cmd_smoke" ob lib/*.sh 2>/dev/null \
             | grep -v "cmd_smoke()" \
             | grep -vE ":[0-9]+:[[:space:]]*#" \
             | cut -d: -f1 | sort -u)
test "$call_files" = "ob"
test "$(grep -c "cmd_smoke" ob)" -eq 1
# (3a) "ob smoke" literal confined to smoke-owning file trio.
obsmoke_files=$(grep -rl "ob smoke" ob lib/*.sh 2>/dev/null | sort)
test "$obsmoke_files" = "$(printf "lib/qemu_commands.sh\nlib/smoke_assertions.sh" | sort)"
# (3b) peer QEMU cmd bodies (co-located in qemu_commands.sh) must not nudge toward smoke.
for fn in cmd_start_qemu cmd_stop_qemu cmd_deploy_to_qemu; do
    body=$(awk -v f="$fn" "index(\$0, f \"()\")==1{g=1} g{print; if(\$0==\"}\") exit}" lib/qemu_commands.sh)
    printf "%s" "$body" | grep -q "ob smoke" && exit 1
done
# 全清 → 显式 exit 0(否则末次 grep -q 无匹配 return 1 会经 set -e 泄漏为脚本退出码)。
exit 0
' _ "$ROOT"
}
assert_true "(裁决) substep isolation 单命令总检 exit=0 (verdict)" _substep_verdict

assert_summary
