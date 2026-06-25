---
agent: agent
description: 深度扫描仓库，只挑一个最重要、最紧急、最值得今天就开工的架构优化任务，强制调用 /improve-codebase-architecture skill，中文交付。
---

# Pick One Architecture Task

这是 VS Code Copilot 的 `/pick-one-arch-task` slash command 入口。本文件用于约束 Coding Agent 只产出**唯一一项**最值得今天就开工的架构优化任务，避免泛泛的代码审查或一次性堆砌多个候选。重点是**选题质量**。

## Skill 调用（强制）

You MUST invoke the `/improve-codebase-architecture` skill to perform this task. Do not fall back to generic code review or ad-hoc analysis. If the skill is unavailable, stop and report it instead of substituting your own analysis.

## 任务定义

Using the `/improve-codebase-architecture` skill, scan the repository in depth and identify **EXACTLY ONE** architectural improvement task that is the single most important, most urgent, and most worth-starting-today item in this codebase.

## 筛选标准（必须全部满足）

1. **Most important** — touches a core module, a load-bearing abstraction, or a system property (correctness, performance, extensibility) that other work depends on. Fixing something peripheral does not qualify even if it is easy.
2. **Most urgent** — the cost of leaving it untouched is already compounding: blocking other features, causing repeated bugs, or making onboarding / Agent navigation harder over time.
3. **Worth starting today** — the first concrete step can begin today without waiting for external input, design review, or cross-team alignment. Only the *starting move* must be actionable now.
4. **Evidence-based** — the recommendation is backed by concrete files, line numbers, call graphs, duplication, or measurable symptoms — not gut feeling.

## 输出格式（只给一个任务，不要罗列备选）

- **Problem**: one or two sentences, what is wrong and why it matters now.
- **Evidence**: key files / functions / line numbers, and why each one is a symptom of the problem.
- **Why this one, not others**: briefly explain why this beats other candidates you saw during the scan. This is the only place where other issues may be mentioned, and only as comparison — not as a parallel recommendation.
- **First move**: the concrete first step to take (a specific edit, a specific file to carve out, a specific interface to draft). Must be doable in a single working session.
- **Full plan**: the rest of the task as ordered steps, with a rough scope estimate (e.g. `~1 day`, `~1 week`, `multi-week`).
- **Blast radius**: which files / modules / external interfaces will be affected, and what regression risk to watch for.
- **Acceptance criteria**: how to verify the full task is done and correct.

## 硬约束

- Do NOT append "other candidate issues you could also consider" as a parallel list. Comparison belongs only inside the **Why this one, not others** section.
- Do NOT use vague phrases like "improve maintainability" or "enhance robustness"; every claim must map to specific code.
- Do NOT hedge with "maybe", "consider", "you might want to" — either commit to the recommendation, or leave it out.
- Do NOT skip the skill invocation; if the skill is unavailable, stop and report it instead of substituting your own analysis.

## 回复语言

Reason and analyze internally in English to preserve instruction fidelity, but write the FINAL response in **Simplified Chinese**.

保留英文不翻译的项：

- File paths, function names, line numbers, code snippets.
- Untranslatable technical terms (e.g. `harness`, `PR review`, `blast radius`).
- Section headers (**Problem / Evidence / Why this one, not others / First move / Full plan / Blast radius / Acceptance criteria**) — keep them as-is for downstream parsing.