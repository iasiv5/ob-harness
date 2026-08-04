#!/usr/bin/env bash
# tests/integration/smoke_help_clarity.sh — deliverable-C runner: criteria 3 (positive)
# and 4 (negative) behavior cases. Proves a zero-context fresh agent given ONLY
# `ob --help` does not misuse `ob smoke`.
#
# GREP-OBJECTIVE & REPRODUCIBLE (criterion 6): the verdict is computed by the pure-bash
# judge (tests/lib/smoke_help_judge.sh) over captured agent answers. Any fresh agent
# re-spawning the samples and re-running this runner reproduces the same verdict class.
#
# ─── Default gate behavior ───
# This runner SKIPs (exit 77) unless OB_HELP_CLARITY_RUN=1, so the CI gate
# (run_all.sh) does NOT spawn ~36 agents every run. An orchestrating agent opts in.
#
# ─── SPAWN PROCEDURE (a bash test cannot spawn Claude; the orchestrating agent does) ───
# 1. Capture ob --help verbatim ONCE:
#        HELP="$(./ob --help)"
# 2. source tests/fixtures/smoke_help_cases.sh   → CASE_IDS[], CASE_QUESTION[], CASE_POLARITY[]
# 3. For each id in "${CASE_IDS[@]}", spawn 3 FRESH general-purpose agents (Agent tool,
#    subagent_type general-purpose), CONCURRENTLY (3 Agent calls in one message):
#      Each 被测 agent prompt = verbatim `ob --help` output
#                       + the single CASE_QUESTION[id]
#                       + instruction (copy verbatim):
#         "Answer using ONLY the ob --help text above. You have NO other context about
#          this repo. State the exact `ob ...` command you would run (or whether you
#          would refuse / do nothing), then briefly explain (2-4 sentences)."
# 4. Save each answer to:  $ANSWERS/<id>.<sample>.txt   (sample = 1, 2, 3)
# 5. Run the verdict:
#        OB_HELP_CLARITY_RUN=1 OB_HELP_CLARITY_ANSWERS=$ANSWERS \
#          bash tests/integration/smoke_help_clarity.sh
#    Exit 0  = all cases PASS (≥2/3 samples PASS per case, ALL cases).
#    Exit 1  = ≥1 case failed its majority vote.
#    Exit 77 = SKIP (not opted in).
#
# ─── Recorded result (auditable evidence) ───
# Most recent agent-driven run tallies are recorded at the bottom of this file in the
# "RECORDED RUN" section (per-case PASS/FAIL + sample vote tally). Update after re-runs.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/ob_loader.sh"   # $OB + assert helpers context
source "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/smoke_help_judge.sh"
assert_reset

# ─── Gate: SKIP unless opted in (criterion 3/4 are agent-driven, not CI-default) ───
if [[ "${OB_HELP_CLARITY_RUN:-0}" != "1" ]]; then
    echo "SKIP: smoke help-clarity suite is agent-driven; set OB_HELP_CLARITY_RUN=1 and OB_HELP_CLARITY_ANSWERS=<dir> (see file header)"
    exit 77
fi

ANSWERS="${OB_HELP_CLARITY_ANSWERS:-}"
if [[ -z "$ANSWERS" || ! -d "$ANSWERS" ]]; then
    echo "FAIL: OB_HELP_CLARITY_ANSWERS must point at a directory of captured answers" >&2
    exit 1
fi

SAMPLES_PER_CASE=3
MAJORITY=$(( (SAMPLES_PER_CASE / 2) + 1 ))   # 3 samples → majority = 2
CASE_PASS_COUNT=0; CASE_TOTAL=0; FAILED_CASES=()

echo "=== smoke help-clarity verdict (answers dir: $ANSWERS) ==="
echo "polarity | case | question (short)                          | sample-votes (PASS/total) | verdict"
echo "--------|------|---------------------------------------------|---------------------------|--------"

for id in "${CASE_IDS[@]}"; do
    polarity="${CASE_POLARITY[$id]}"
    question="${CASE_QUESTION[$id]}"
    CASE_TOTAL=$((CASE_TOTAL + 1))
    pass=0; missing=0
    for s in $(seq 1 "$SAMPLES_PER_CASE"); do
        f="$ANSWERS/$id.$s.txt"
        if [[ ! -f "$f" ]]; then
            missing=$((missing + 1))
            continue
        fi
        if judge_answer "$polarity" "$id" < "$f"; then
            pass=$((pass + 1))
        fi
    done
    short_q="$(printf '%s' "$question" | head -c 43)"
    if [[ "$pass" -ge "$MAJORITY" ]]; then
        verdict="PASS"; CASE_PASS_COUNT=$((CASE_PASS_COUNT + 1))
    else
        verdict="FAIL"; FAILED_CASES+=("$id")
    fi
    printf '%-8s| %-4s | %-43s | %d/%d (missing:%d)        | %s\n' \
        "$polarity" "$id" "$short_q" "$pass" "$SAMPLES_PER_CASE" "$missing" "$verdict"
done

echo ""
echo "summary: $CASE_PASS_COUNT/$CASE_TOTAL cases PASS (majority vote ≥$MAJORITY of $SAMPLES_PER_CASE samples)"
if (( ${#FAILED_CASES[@]} > 0 )); then
    echo "FAILED cases: ${FAILED_CASES[*]}"
    exit 1
fi
echo "ALL CASES PASS"
exit 0

# ═══════════════════════════════════════════════════════════════════════════════
# RECORDED RUN (auditable evidence — update after each agent-driven re-run)
#
# Run date: 2026-08-02
# Branch  : feat/ob-verify
# 被测 agent: general-purpose, fresh per sample, fed ONLY verbatim `ob --help` + the
#            case question + the standard instruction (zero other repo context).
# Driver  : orchestrating Claude Code agent (this repo's operator).
# Verdict : 12/12 cases PASS, suite exit 0. Every case 3/3 samples PASS.
#
# Per-case sample-vote tallies (PASS = matched the case's grep-objective cognition):
#   pos | P1  | 3/3   proposes `ob smoke`
#   pos | P2  | 3/3   exit-1 = α truth-reporter / actual state / not broken
#   pos | P3  | 3/3   proposes `ob smoke`
#   pos | P4  | 3/3   prerequisite = `ob start-qemu`
#   pos | P5  | 3/3   exit-3 = no running instance; remedy `ob start-qemu`
#   neg | N1  | 3/3   refuses smoke-as-boot; redirects to `ob start-qemu`
#   neg | N2  | 3/3   refuses "smoke broken"; α pushback (debug BMC interface)
#   neg | N3  | 3/3   no auto-boot; exit 3; remedy `ob start-qemu`
#   neg | N4  | 3/3   smoke ignores --ssh-port; ports from PID file
#   neg | N4b | 3/3   smoke ignores --redfish-port; ports from PID file
#   neg | N5  | 3/3   smoke ignores --dry-run / -d (no preview mode)
#   neg | N6  | 3/3   refuses smoke-as-teardown; redirects to `ob stop-qemu`
#
# Regex adjustments made DURING this run (honesty note — both are genuine judge fixes,
# NOT case weakenings; both were validated against the real captured answers):
#   - P5 REQ: removed an empty subexpression `(running |)` that grep/ugrep rejects as a
#     syntax error (it made P5 falsely 0/3). Equivalent intended match set, valid syntax.
#   - N5 REQ: broadened to also match the help's own phrasing "honors NO ... --dry-run"
#     (was only matching "ignores"/"does not honor"/"no dry"). N5.1 was a judge
#     false-negative on a correct answer; the broadened alternative still requires the
#     negation token "NO" (so it cannot match an endorsement like "smoke honors -d").
#
# Reproduce: capture `ob --help`, spawn 3 fresh general-purpose agents per case id in
# tests/fixtures/smoke_help_cases.sh (concurrent batches), save answers to a dir as
# <id>.<1|2|3>.txt, then:
#   OB_HELP_CLARITY_RUN=1 OB_HELP_CLARITY_ANSWERS=<dir> bash tests/integration/smoke_help_clarity.sh
# ═══════════════════════════════════════════════════════════════════════════════
