#!/usr/bin/env bash
# tests/lib/smoke_help_judge.sh — deliverable-C verdict engine (PURE BASH, GREP-objective).
# Reproducible: given the SAME captured agent answers, any fresh agent / human re-running
# this gets the SAME pass/fail verdict. No subjective rating. (criterion 6)
#
# Usage:
#   source tests/fixtures/smoke_help_cases.sh   # defines CASE_* arrays
#   source tests/lib/smoke_help_judge.sh
#   judge_answer <polarity: pos|neg> <case_id> <<<"$agent_answer"   # → exit 0 PASS / 1 FAIL
#
# Verdict rules (mirror the contract in smoke_help_cases.sh):
#   pos: PASS iff answer matches CASE_REQ[case_id] (extended regex, -i).
#   neg: PASS ("no misuse") iff answer matches CASE_REQ[case_id] (the correction)
#        AND (CASE_FORB empty OR answer does NOT match CASE_FORB).

source "$(dirname "${BASH_SOURCE[0]}")/../fixtures/smoke_help_cases.sh"

# judge_answer <polarity> <case_id>   reads answer from stdin → 0 PASS / 1 FAIL.
judge_answer() {
    local polarity="$1" case_id="$2"
    local answer; answer=$(cat)
    local req="${CASE_REQ[$case_id]:-}"
    local forb="${CASE_FORB[$case_id]:-}"
    [[ -n "$req" ]] || return 1
    case "$polarity" in
        pos)
            printf '%s' "$answer" | grep -iqE "$req" && return 0 || return 1
            ;;
        neg)
            # correction must be present
            printf '%s' "$answer" | grep -iqE "$req" || return 1
            # forbidden misuse phrase (if any) must be absent
            if [[ -n "$forb" ]] && printf '%s' "$answer" | grep -iqE "$forb"; then
                return 1
            fi
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# CLI form for ad-hoc checking: smoke_help_judge.sh <polarity> <case_id> < answer_file
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ $# -eq 2 ]] || { echo "usage: $0 <pos|neg> <case_id> < answer" >&2; exit 2; }
    judge_answer "$1" "$2"
    exit $?
fi
