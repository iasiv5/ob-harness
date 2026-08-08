#!/usr/bin/env bash
# .claude/hooks/ob-check-stop.sh — Claude Code Stop hook:
# 本轮 working tree 若改 ob 或 lib/*.sh,则跑 ob_check 静态子集;失败则 decision:block 让 Claude 继续修。
#
# working tree 级门禁(非严格 per-turn): git diff 看整个 working tree(含 cached/untracked),
# 若仓库已有存量未提交的 ob/lib 改动,每轮 Stop 都会触发——已知行为,接受(评审 F3-2)。
# 分层子集(round-4 intask-validation-wiring): ob/lib/*.sh 改动(高风险受检对象) → 完整 ob_check
# (含 run_all),让运行时回归在任务回合内交接前被发现而非逃逸到 CI;仅 tools/* 改动(checker/编排器)
# → 静态子集 SKIP_TESTS(省 ~14s,run_all 由 CI 兜底),保留 round-2 r2-stop-hook-trigger-tools-sh 扩展。
# 两路均 READONLY 不改 baseline(hook 不应改文件;AGENTS.md:36 配套自检要求的 run_all 现机械兜底)。
# 失败反馈(D3=A): python3 json.dumps 生成 decision:block,防 summary 含引号/反斜杠破坏 JSON(评审 F3-2)。
# fail-closed: 决策子进程(python3)失败/无输出时,纯 bash 兜底(最小转义 \ 和 ")仍产 decision:block——
#   ob_check 失败这个事实必须传达,不能因 JSON 生成器自身故障而放行(防 fail-open 反向失效)。
set -uo pipefail

# 依赖/cwd 前置守卫（防 fail-open 与『依赖缺失被误判成自检失败』）：关键依赖缺失或 cwd
# 不可定位时，显式 decision:block 报真因，绝不静默 exit 0 放行——ob_check 自检失败与
# 依赖/环境缺失必须可区分（lint: hook-portability-or-missing-dependency）。
emit_block() {  # $1 = reason
  python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.argv[1]}, ensure_ascii=False))' "$1" 2>/dev/null \
    || printf '{"decision": "block", "reason": "%s"}\n' "${1//\"/\\\"}"
}
# 早守卫：git 与 grep 必须先可用——相关性判定同时依赖 git diff 与 grep -qE，缺任一都会让相关性
# 门禁本身失灵（fail-open）。git/grep 缺失或 cwd 不可定位 → fail-closed，绝不静默放行。
# 其余依赖（python3/mktemp、ob_check.sh）只在相关性通过、真要跑 ob_check 时才检查，
# 避免无 ob/lib/tools 改动的无关轮次因依赖缺失被误阻塞成 stop-loop（r2 回归修复）。
for _dep in git grep; do
  command -v "$_dep" >/dev/null 2>&1 || { emit_block "ob-check-stop: 缺少依赖 $_dep（门禁 fail-closed，不静默放行）。"; exit 0; }
done
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" 2>/dev/null \
  || { emit_block "ob-check-stop: cwd 不可定位（CLAUDE_PROJECT_DIR 未注入且 git rev-parse 失败），门禁 fail-closed 不放行。"; exit 0; }

# 本轮 working tree 改动(committed 已在 CI 跑过,不重复)
changed=$(git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard 2>/dev/null)
# 触发范围: ob / lib/*.sh(受检对象) + tools/*.py(checker 实现) + tools/*.sh(编排器/采集器,
# 如 ob_check.sh 本体、trace_collect.sh、smoke_regression.sh)。改 checker 或编排器本身也要
# 本地自检,否则被改坏(注释掉一道 gate、放宽 surface 正则、exit_contract 静默假 PASS)会本地
# 零信号直放行;注意 CI 只在 main/refactor/** 与 PR 上跑,better-harness/* 等特性分支无 CI 兜底。
if ! grep -qE '(^|/)lib/[^/]+\.sh$|^ob$|(^|/)tools/[^/]+\.py$|(^|/)tools/[^/]+\.sh$' <<<"$changed"; then
  exit 0   # 未触及 ob/lib/tools 检查器,放行
fi

# 相关性通过、即将运行 ob_check：此时才检查 ob_check 需要的其余依赖（r2 回归修复——这些依赖缺失
# 只在真要跑 ob_check 时 fail-closed，不再阻塞无 ob/lib/tools 改动的无关轮次）。
for _dep in python3 mktemp; do
  command -v "$_dep" >/dev/null 2>&1 || { emit_block "ob-check-stop: 缺少依赖 $_dep（门禁 fail-closed，不静默放行）。"; exit 0; }
done
[[ -f tools/ob_check.sh ]] || { emit_block "ob-check-stop: 缺少 tools/ob_check.sh（门禁 fail-closed，不静默放行）。"; exit 0; }

out=$(mktemp)
# 分层路由: ob/lib/*.sh 改动 → 完整 ob_check(含 run_all, AGENTS.md:36 要求的配套自检在任务内交接前机械兜底);
# 仅 tools/* 改动 → 静态子集(SKIP_TESTS, run_all 由 CI 兜底)。两路 READONLY 不改 baseline。
if grep -qE '(^|/)lib/[^/]+\.sh$|^ob$' <<<"$changed"; then
  _oc_env=(OB_CHECK_READONLY=1)            # 完整: 不跳 run_all
else
  _oc_env=(OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1)
fi
if env "${_oc_env[@]}" bash tools/ob_check.sh >"$out" 2>&1; then
  rm -f "$out"; exit 0
else
  summary=$(grep -E '✗|FAIL=' "$out" | head -5 | tr '\n' '; ')
  rm -f "$out"
  # fail-closed(评审原 F3-2 升级): python3 只是 JSON 生成器,自身故障/无输出时绝不能让门禁放行。
  # 捕获子进程输出,失败或不含 decision:block 则纯 bash 兜底(最小转义 \ 和 ")再产 block。
  decision=$(python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":f"ob_check 失败(改了 ob/lib 须先过自检): {sys.argv[1]}"}, ensure_ascii=False))' "$summary" 2>/dev/null)
  rc=$?
  if [[ $rc -ne 0 || "$decision" != *'"decision"'* || "$decision" != *'"block"'* ]]; then
    esc="${summary//\\/\\\\}"          # \ -> \\ (JSON 字符串转义,先转义反斜杠)
    esc="${esc//\"/\\\"}"               # " -> \"
    printf '{"decision": "block", "reason": "ob_check 失败(改了 ob/lib 须先过自检,JSON 生成器故障 rc=%s,纯 bash 兜底): %s"}\n' "$rc" "$esc"
  else
    printf '%s\n' "$decision"
  fi
  exit 0
fi
