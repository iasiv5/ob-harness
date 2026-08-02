#!/usr/bin/env bash
# tests/fixtures/smoke_help_cases.sh — deliverable-C case DEFINITIONS (data only).
# Consumed by: tests/lib/smoke_help_judge.sh (verdict engine) AND by the orchestrating
# agent that spawns fresh "被测" agents (criteria 3/4). Pure data: source it, read arrays.
#
# Each case = { id, polarity(pos|neg), question, req(regex), forb(regex, neg-only) }.
#   pos: answer PASSES iff it matches `req` (extended regex, case-insensitive).
#   neg: answer PASSES ("no misuse") iff it matches `req` (the correct correction)
#        AND does NOT match `forb` (an endorsed-misuse phrase; empty = skip forbid check).
# All judgments are GREP-objective (criterion 6): any fresh agent re-spawning samples
# and re-running the judge reproduces the same verdict class.
#
# Case set intent (zero-context agent given ONLY `ob --help`):
#   POSITIVE — must hit the key cognition:
#     P1  readiness probe          → proposes `ob smoke`
#     P2  exit-1 interpretation    → α truth / actual-state / "not broken"
#     P3  probe Redfish/IPMI       → proposes `ob smoke`
#     P4  prerequisite             → `start-qemu`
#     P5  exit-3 interpretation    → `start-qemu` / exit-3 / no-instance
#   NEGATIVE — must NOT fall into the trap (answer contains the correction):
#     N1  smoke to boot            → redirect to `start-qemu`
#     N2  "exit 1 = broken, fix smoke" → α pushback
#     N3  auto-boot on no instance → no/exit-3/start-qemu
#     N4  --ssh-port override      → smoke ignores ports / reads PID file
#     N5  -d / --dry-run           → smoke ignores --dry-run
#     N6  smoke to tear down       → redirect to `stop-qemu`

CASE_IDS=(P1 P2 P3 P4 P5 N1 N2 N3 N4 N4b N5 N6)

declare -A CASE_POLARITY=(
    [P1]=pos  [P2]=pos  [P3]=pos  [P4]=pos  [P5]=pos
    [N1]=neg  [N2]=neg  [N3]=neg  [N4]=neg  [N4b]=neg  [N5]=neg  [N6]=neg
)

declare -A CASE_QUESTION=(
    [P1]="Verify whether the romulus BMC is up and its interfaces are ready. What ob command do I run?"
    [P2]="I ran 'ob smoke romulus' and it returned exit code 1. What does exit 1 mean for ob smoke? Is the smoke command itself broken?"
    [P3]="How do I probe a running BMC's Redfish and IPMI interfaces using ob?"
    [P4]="What must already be running before 'ob smoke' can probe a machine?"
    [P5]="ob smoke returned exit code 3. What does exit code 3 mean and how do I proceed?"
    [N1]="Use 'ob smoke romulus' to start / boot the BMC for me."
    [N2]="ob smoke exited 1, which means the smoke command is broken — debug and fix smoke."
    [N3]="If I run 'ob smoke romulus' with no QEMU instance running, will it auto-boot one for me?"
    [N4]="I want to probe on a different SSH port. Run 'ob smoke romulus --ssh-port 9999' for me."
    [N4b]="Probe on a different Redfish port: 'ob smoke romulus --redfish-port 8443'."
    [N5]="Dry-run the smoke first to preview: 'ob smoke romulus -d'."
    [N6]="Use 'ob smoke romulus' to tear down / stop the BMC."
)

# Required regex (extended, case-insensitive). pos: the key cognition the answer must
# contain. neg: the correct correction/refusal the answer must contain.
declare -A CASE_REQ=(
    [P1]='ob smoke'
    [P2]='truth-reporter|actual state|not.{0,6}broken|α|alpha|reports.{0,12}state|bmc.{0,12}interface'
    [P3]='ob smoke'
    [P4]='start-qemu'
    [P5]='start-qemu|exit 3|no.{0,12}instance|not running'
    [N1]='start-qemu'
    [N2]='truth-reporter|actual state|not.{0,6}broken|α|alpha|reports.{0,12}state|bmc.{0,12}interface'
    [N3]='start-qemu|exit 3|will not|won.t|does not|auto|no,? it|no it won'
    [N4]='ignor|no port|not.{0,6}honor|does not.{0,10}port|pid file|read.{0,10}pid|start-qemu.{0,20}--ssh-port|not.{0,6}accept'
    [N4b]='ignor|no port|not.{0,6}honor|does not.{0,10}port|pid file|read.{0,10}pid|not.{0,6}accept'
    [N5]='ignor|not.{0,6}honor|does not.{0,12}(dry|-d|dry-run)|honors?.{0,4}no.{0,20}(dry|-d|dry-run)|no.{0,20}dry|dry-run.{0,6}(not|reject|ignor)|not.{0,6}accept'
    [N6]='stop-qemu'
)

# Forbidden regex (neg-only; empty = skip). Reserved for cases where a specific
# endorsement phrase would be unambiguous misuse. Kept empty by default to avoid
# false-positives on answers that mention the trap only to refute it.
declare -A CASE_FORB=(
    [P1]=''  [P2]=''  [P3]=''  [P4]=''  [P5]=''
    [N1]=''  [N2]=''  [N3]=''  [N4]=''  [N4b]=''  [N5]=''  [N6]=''
)
