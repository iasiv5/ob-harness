#!/usr/bin/env bash
# tests/protocol/stop_hook_behavior.sh — Stop hook 行为回归锁。
# 覆盖 .claude/hooks/ob-check-stop.sh：触发正则、相关性短路、fail-closed（cd/依赖），
# 以及 round-2 回归（无 ob/lib/tools 改动 + 依赖缺失不误阻塞成 stop-loop）。
# 所有 working-tree 相关用例都在临时 git repo 里跑，不依赖真实仓库 working tree；
# 缺依赖用例通过受限 PATH 子 shell 隔离，结束后清理。
set -uo pipefail
OB_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

HOOK="$OB_DIR/.claude/hooks/ob-check-stop.sh"

# --- 1. 触发正则静态断言（hook 文件含四类触发子句；用 -F 字面匹配，因子句含 [^/] 等元字符）---
for clause in 'lib/[^/]+\.sh$' '^ob$' 'tools/[^/]+\.py$' 'tools/[^/]+\.sh$'; do
  assert_true "trigger regex covers: $clause" grep -qF -- "$clause" "$HOOK"
done

# --- 临时 git repo（带 stub ob_check.sh，使 hook 能跑到「执行 ob_check」段）---
TMP=$(mktemp -d); NOP_DIR=""
trap 'rm -rf "$TMP" "$NOP_DIR"' EXIT
git init -q "$TMP"
mkdir -p "$TMP/tools" "$TMP/lib"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/tools/ob_check.sh"   # stub：ob_check 永远通过
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/ob"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/lib/x.sh"
git -C "$TMP" add -A && git -C "$TMP" -c user.email=t@t -c user.name=t commit -qm base

# 受限 PATH 构造器：返回一个只含【除 $1 外】真实二进制的目录，用 realpath 取真实路径
# （脚本非交互运行，command -v 在本进程内返回真实二进制路径）。
minipath_without() {  # $1 = 要排除的依赖
  local exclude="$1" d c p
  d=$(mktemp -d)
  for c in bash git grep mktemp python3; do
    [[ "$c" == "$exclude" ]] && continue
    p=$(command -v "$c" 2>/dev/null) || continue
    [[ -n "$p" && -x "$p" ]] && ln -sf "$p" "$d/$c"
  done
  printf '%s' "$d"
}

# --- 2. 无 working-tree 改动 → exit 0、不 emit block ---
out=$(cd "$TMP" && env CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1); rc=$?
assert_eq "S2 no-change exits 0" "$rc" "0"
assert_false "S2 no-change emits no block" grep -q '"decision"' <<<"$out"

# --- 3. tools/*.sh 改动 + 依赖齐全 → 跑 stub ob_check（exit 0、不 block）---
echo "# noop" >> "$TMP/tools/probe.sh"
out=$(cd "$TMP" && env CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1); rc=$?
assert_eq "S3 tools-sh change runs ob_check (exit 0)" "$rc" "0"
assert_false "S3 tools-sh change emits no block (stub passes)" grep -q '"decision"' <<<"$out"
rm -f "$TMP/tools/probe.sh"

# --- 4. cd 失败（CLAUDE_PROJECT_DIR=/nonexistent）→ decision:block（fail-closed）---
out=$(env CLAUDE_PROJECT_DIR=/nonexistent bash "$HOOK" 2>&1); rc=$?
assert_eq "S4 cd-fail exits 0 (block via JSON)" "$rc" "0"
assert_contains "S4 cd-fail emits decision block" "$out" '"decision"'

# --- 5. r2 回归锁：无改动 + python3 缺失 → exit 0（不再误阻塞无关轮次）---
NOP_DIR=$(minipath_without python3)
out=$(cd "$TMP" && env CLAUDE_PROJECT_DIR="$TMP" PATH="$NOP_DIR" bash "$HOOK" 2>&1); rc=$?
assert_eq "S5 r2: no-change + python3-missing exits 0" "$rc" "0"
assert_false "S5 r2: no-change + python3-missing emits no block" grep -q '"decision"' <<<"$out"

# --- 6. 相关改动 + python3 缺失 → decision:block naming python3（fail-closed 保留）---
echo "# noop" >> "$TMP/tools/probe.sh"
out=$(cd "$TMP" && env CLAUDE_PROJECT_DIR="$TMP" PATH="$NOP_DIR" bash "$HOOK" 2>&1); rc=$?
assert_eq "S6 tools-sh + python3-missing exits 0 (block via JSON)" "$rc" "0"
assert_contains "S6 emits block naming python3" "$out" 'python3'
rm -f "$TMP/tools/probe.sh"

# --- 7. r4 intask-validation-wiring: lib/*.sh 改动 → 完整 ob_check(含 run_all, 不 SKIP_TESTS) ---
# 用记录型 stub：把传入的 OB_CHECK_SKIP_TESTS 写 marker，仍 exit 0。验证 hook 对 ob/lib 改动
# 走完整路径（不设 SKIP_TESTS），AGENTS.md:36 的配套自检在交接前机械兜底。
printf '#!/usr/bin/env bash\necho "SKIP=${OB_CHECK_SKIP_TESTS:-unset}" > "%s"\nexit 0\n' "$TMP/marker_lib" > "$TMP/tools/ob_check.sh"
echo "# r4" >> "$TMP/lib/x.sh"
rm -f "$TMP/marker_lib"
out=$(cd "$TMP" && env CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1); rc=$?
assert_eq "S7 lib change exits 0 (stub passes)" "$rc" "0"
assert_contains "S7 lib change → full ob_check (no SKIP_TESTS)" "$(cat "$TMP/marker_lib" 2>/dev/null)" "SKIP=unset"
git -C "$TMP" checkout -q -- lib/x.sh 2>/dev/null || true
rm -f "$TMP/marker_lib"

# --- 8. r4: 仅 tools/* 改动 → 静态子集(SKIP_TESTS=1, run_all 由 CI 兜底) ---
printf '#!/usr/bin/env bash\necho "SKIP=${OB_CHECK_SKIP_TESTS:-unset}" > "%s"\nexit 0\n' "$TMP/marker_tools" > "$TMP/tools/ob_check.sh"
echo "# r4" >> "$TMP/tools/probe.sh"
rm -f "$TMP/marker_tools"
out=$(cd "$TMP" && env CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1); rc=$?
assert_eq "S8 tools-only exits 0 (stub passes)" "$rc" "0"
assert_contains "S8 tools-only → static subset (SKIP_TESTS=1)" "$(cat "$TMP/marker_tools" 2>/dev/null)" "SKIP=1"
rm -f "$TMP/tools/probe.sh" "$TMP/marker_tools"

assert_summary
