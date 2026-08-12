#!/usr/bin/env bash
# tests/unit/smoke_regression_alpha_safety.sh — α-safety 不变量 grep 守卫(unit 层)。
# 断言 tools/smoke_regression.sh 的实现:
#   (1) baseline/current 落运行时临时产物(mktemp / $TMPDIR), 不入版本管理;
#   (2) 绝不构造受版本管理、以具体 machine 命名的 baseline/profile 文件
#       —— 那是 ADR-0020 option-3 明确拒绝的「per-machine expected-profile」(spatial 期望),
#       违反 smoke 的「零 per-machine 知识」。本闸门须保持 temporal diff(机器无关)。
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/tools/smoke_regression.sh"
test -f "$GATE" || { echo "MISSING $GATE" >&2; exit 1; }

# 只看代码, 剥注释(注释里会正面讨论"避免 baseline/profile"这类设计, 不能误判为实现)
gate_code() { sed 's/[[:space:]]*#.*$//' "$GATE"; }
CODE="$(mktemp)"; trap 'rm -f "$CODE"' EXIT; gate_code > "$CODE"

# === (1) 必须: 用 mktemp 落盘 baseline/current(运行时临时产物) ===
assert_true  "实现用 mktemp 生成 baseline/current 临时文件" grep -q 'mktemp' "$CODE"
assert_true  "实现有 trap 清理临时文件(不残留)"           grep -qE 'trap .* EXIT' "$CODE"

# === (2) 禁止: 受版本管理 / machine 命名的 baseline/profile 文件(spatial 期望, 违 α) ===
# (a) 无 baselines/ 或 profiles/ 受版本目录引用
assert_false "无 baselines/ 受版本目录引用(spatial 期望)"  grep -qE '(^|[^[:alnum:]_/])baselines?/' "$CODE"
assert_false "无 profiles/ 受版本目录引用"                 grep -qE '(^|[^[:alnum:]_/])profiles?/' "$CODE"
# (b) 无 expected_profile / expected-profile / .baseline 等受版本 baseline 词汇
assert_false "无 expected_profile / expected-baseline 词汇" grep -qE 'expected[_-](profile|baseline|smoke)' "$CODE"
# (c) 无 git add baseline 类把临时产物提交版本库的动作
assert_false "无 git add/commit baseline 的动作"           grep -qE 'git (add|commit)' "$CODE"
# (d) 不把 $machine 拼进文件路径做持久落盘(唯一合法的 $machine 用法是 ob smoke 的命令参数 + echo 提示)
#     检测形如 > "$machine..." / >> "$machine..." / >"${machine}..." 的重定向落盘
assert_false "无 \$machine 派生文件路径落盘(重定向)"       grep -qE '>>? ?"?\$\{?machine\}?' "$CODE"

# === (3) 门禁: git diff(本分支 vs main)不含受版本管理的 baseline/profile 产物 ===
# 实证 α-safety: 本次改动不应新增 machine 命名 / baseline / profile 的 tracked 文件。
if git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1 \
   && git -C "$ROOT" rev-parse --verify main >/dev/null 2>&1; then
    tracked=$(git -C "$ROOT" diff --name-only main...HEAD || true)
    # 排除 test-qemu 合法 per-machine baseline(ADR-0025: tests/baseline/ 社区机随上游 +
    # contexts/baseline/ custom)——那是 test-qemu 命令的 AR 数据, 非 smoke 的 spatial 期望。
    violating=$(printf '%s\n' "$tracked" | grep -E '(^|/)(baselines?|profiles?|expected[_-])|\.baseline$|\.profile$' | grep -vE '^(tests|contexts)/baseline/' || true)
    assert_eq "git diff main...HEAD 无受版本 baseline/profile 产物(smoke α-safety; test-qemu tests/baseline 例外)" "$violating" ""
else
    # 无 main ref(孤立分支/浅克隆)→ 跳过 git 侧实证, 仅源码 grep 守(上方已覆盖)
    echo "ok   git diff 守卫(SKIP — 无 main ref, 仅源码 grep 守 α-safety)"
fi

assert_summary
