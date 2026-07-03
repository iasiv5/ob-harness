#!/usr/bin/env bash
# .claude/hooks/ob-check-stop.sh — Claude Code Stop hook:
# 本轮 working tree 若改 ob 或 lib/*.sh,则跑 ob_check 静态子集;失败则 decision:block 让 Claude 继续修。
#
# working tree 级门禁(非严格 per-turn): git diff 看整个 working tree(含 cached/untracked),
# 若仓库已有存量未提交的 ob/lib 改动,每轮 Stop 都会触发——已知行为,接受(评审 F3-2)。
# 静态子集(D2=B): SKIP_TESTS 跳 run_all(省 ~14s,run_all 由 CI 兜底) + READONLY 不改 baseline(hook 不应改文件)。
# 失败反馈(D3=A): python3 json.dumps 生成 decision:block,防 summary 含引号/反斜杠破坏 JSON(评审 F3-2)。
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" || exit 0

# 本轮 working tree 改动(committed 已在 CI 跑过,不重复)
changed=$(git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard 2>/dev/null)
if ! grep -qE '(^|/)lib/[^/]+\.sh$|^ob$' <<<"$changed"; then
  exit 0   # 未触及 ob/lib,放行
fi

out=$(mktemp)
if OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash tools/ob_check.sh >"$out" 2>&1; then
  rm -f "$out"; exit 0
else
  summary=$(grep -E '✗|FAIL=' "$out" | head -5 | tr '\n' '; ')
  rm -f "$out"
  python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":f"ob_check 失败(改了 ob/lib 须先过自检): {sys.argv[1]}"}, ensure_ascii=False))' "$summary"
  exit 0
fi
