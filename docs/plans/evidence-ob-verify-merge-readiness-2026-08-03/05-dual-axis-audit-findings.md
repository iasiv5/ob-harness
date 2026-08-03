# Dual-axis audit findings — ob-verify merge-readiness (2026-08-03)

## Scope (per criterion 5)

Dual-axis (over-eng × cov-gap) enumeration over:
- **Original test framework**: `tests/*` (protocol/unit/orchestration/integration `.sh`+`.exp`) + `tools/<gate>` (ob_check.sh, exit_contract.py, extract_funcs.py, coverage_radar.py, smoke_diff.py, smoke_regression.sh, etc.).
- **NEW smoke tests on this branch** (15 files, 1745 LOC): `tests/{protocol,unit,orchestration,integration}/smoke_*.sh`, `tests/unit/smoke_diff*.sh`, `tests/unit/smoke_regression_alpha_safety.sh`, `tests/orchestration/smoke_regression.sh`, `tests/lib/smoke_help_judge.sh`, `tests/fixtures/smoke_help_cases.sh`, `tools/smoke_diff.py`, `tools/smoke_regression.sh`.

Methodology reused + adapted from `docs/plans/evidence-test-audit-2026-08-02/reviewer-prompt-verbatim.txt`: each finding carries 5 non-empty fields (type | file:line | status quo | proposed change | risk | cited evidence) + a reproducible command. Verdict rubric: KEEP (real evidence-backed cost/gap + sound proportionate fix) vs DROP (evidence doesn't support, or distinct contract facet, or out-of-scope).

## Inventory baseline (reproducible)

```
tests/ files (.sh+.exp):  find tests -type f \( -name '*.sh' -o -name '*.exp' \) | wc -l   → 90
tools/<gate>:             ls tools/*.py tools/*.sh                                          → 11
NEW smoke-test LOC:       wc -l <15 new files>                                              → 1745
NEW prod LOC (smoke):     cmd_smoke + 5 probes + 5 judges + ob help + exit_contract line   → ~270
smoke prod functions:     grep -nE '^(cmd_smoke|_smoke_|smoke_judge_)...' lib/*.sh           → 12 fns
```

Coverage reality (radar shows structure-only "✗ uncovered" for all 12 smoke fns — same xtrace limitation as the prior audit; the REAL coverage picture is below):

| smoke fn | real coverage (fast layer, no real QEMU) | file |
|---|---|---|
| smoke_judge_redfish_root | stubbed signals, pass/fail boundaries, modern+legacy markers, conn-fail 000 | tests/protocol/smoke_assertions_judgment.sh |
| smoke_judge_redfish_managers | stubbed, 3 marker variants, no-marker, 404, 000 | smoke_assertions_judgment.sh |
| smoke_judge_redfish_swversion | stubbed, FirmwareVersion+SoftwareVersion alias, prettified JSON, empty-value guard, missing, empty-body | smoke_assertions_judgment.sh |
| smoke_judge_ipmi_lan | stubbed rc 0/1, excerpt, RMCP+ hint | smoke_assertions_judgment.sh |
| smoke_judge_system_ready | stubbed rc 0/1 | smoke_assertions_judgment.sh |
| _smoke_probe_redfish | PATH-stub curl, nameref outvars, 200/500/conn-fail 000 | tests/orchestration/smoke_orchestration.sh |
| _smoke_probe_redfish_managers | PATH-stub curl URL-branching, nameref, 200/500 | smoke_orchestration.sh |
| _smoke_probe_ipmi | PATH-stub ipmitool rc 0/1, nameref | smoke_orchestration.sh |
| _smoke_probe_ssh_tcp / _smoke_tcp_probe | python TCP listener open/closed port, nameref | smoke_orchestration.sh |
| cmd_smoke (exit 0) | faked live instance (exec -a + python listener + stub curl/ipmitool), 5 ✓ | tests/protocol/smoke_exit_contract.sh |
| cmd_smoke (exit 1) | faked live instance + IPMI rc 1, α truth-reporter line + RMCP+ hint | smoke_exit_contract.sh |
| cmd_smoke (exit 3) | no-machine / no-PID / stale-PID (3 routes) | smoke_exit_contract.sh + smoke_surface.sh |
| cmd_smoke (probe-only invariants) | body grep: no prepare/execute/trap, calls is_alive/load, reads PIDFILE_SSH_PORT | tests/protocol/smoke_surface.sh |
| cmd_smoke (substep isolation) | grep: only ob dispatcher calls cmd_smoke; no peer nudge | tests/protocol/smoke_substep_isolation.sh |

## Findings

### F1 — cov-gap: bundled `cmd_start_qemu` non-TTY confirmation skip lacks an isolated fast test
- **type**: cov-gap (production-behavior contract)
- **file:line**: `lib/qemu_commands.sh` cmd_start_qemu confirmation block (the `if [[ -t 0 ]]` guard at the "Safety confirmation（仅交互 TTY）" section, and its `else` non-TTY skip branch)
- **status quo**: This branch bundles a real behavior change to `cmd_start_qemu` (a production command used by everyone, not just smoke): the safety confirmation (`confirm_action` + 3-2-1 escape window) is now wrapped in `if [[ -t 0 ]]`. Non-TTY callers (CI, agent, run_all with redirected stdin) skip confirmation and proceed. BEFORE this guard, `confirm_action`'s `read` hit EOF on non-TTY → return 1 → `cmd_start_qemu exit 1` (blocked). The change is required so `start-qemu → smoke → stop-qemu` runs non-interactively (smoke_e2e.sh Step 1 depends on it). It is exercised end-to-end by the integration layer (smoke_e2e) but had NO isolated fast-layer test locking the branch.
- **proposed change**: add a focused protocol test with (A) a structural section asserting the confirmation block is gated by `[[ -t 0 ]]` (confirm_action call on a later line than the guard) + a non-TTY else-branch exists, and (B) a runtime section that runs cmd_start_qemu with stdin from /dev/null (NOT a TTY) and the launch pipeline stubbed, asserting it proceeds (reaches qemu_execute_launch), prints "Non-interactive start", and prints NO confirmation banner / NO escape window.
- **risk**: LOW — the bundled change is sound (start-qemu is non-destructive; aligns with the documented "正常起 QEMU 一律跳过" principle; confirmation banner is retained for the destructive kill-existing-instance conflict block which still requires `--force` on non-TTY). A revert of the guard would previously only be caught by the slow integration opt-in layer; the new fast test catches it at the protocol layer.
- **cited evidence / reproducible**:
  - `sed -n '/^cmd_start_qemu()/,/^}$/p' lib/qemu_commands.sh | grep -nE '\[\[ -t 0 \]\]|confirm_action|Launching QEMU in 3|Non-interactive start'`
  - `grep -rln '\-t 0\|Non-interactive start' tests/` → before fix: only smoke_ob.sh/exit_codes.sh/etc. mention TTY generically; none lock the cmd_start_qemu branch.
- **verdict**: **KEEP** — real cov-gap on a bundled production-behavior change; fix is sound + proportionate (test-layer only, structural + runtime, no prod change).
- **status**: **FIX LANDED** — `tests/protocol/start_qemu_noninteractive.sh` added; verified PASS=10 rc=0 in isolation; structural (confirm_action line 120 inside guard at line 77) + runtime (non-TTY proceeds, no banner) both green. Awaiting ob_check re-verification.

### F2 — over-eng candidate: exit-3 paths asserted in both smoke_surface.sh §6 and smoke_exit_contract.sh §1-§2
- **type**: over-eng (candidate duplicate coverage)
- **file:line**: `tests/protocol/smoke_surface.sh` §6 (exit-3 no-machine/no-PID/stale-PID + remedy + clean_stale deletion) vs `tests/protocol/smoke_exit_contract.sh` §1-§2 (exit-3 no-machine/no-PID, rc-only)
- **status quo**: the exit-3 (no machine arg, no PID file) paths are asserted in both files. smoke_surface §6 also asserts the remedy line content ("ob smoke <machine>", "ob start-qemu") AND the stale-PID clean_stale file-deletion side effect. smoke_exit_contract §1-§2 asserts only the exit code but with the faked-live-instance machinery (exec -a + python TCP listener + PATH-stub curl/ipmitool) that its §3-§4 (exit 0 all-pass / exit 1 IPMI-fail) require.
- **proposed change**: none.
- **risk**: N/A.
- **cited evidence / reproducible**:
  - `grep -nE 'exit 3|→ exit 3|_run_smoke' tests/protocol/smoke_surface.sh tests/protocol/smoke_exit_contract.sh`
- **verdict**: **DROP** — each file owns a distinct primary contract facet. smoke_surface = UI registration + probe-only invariants + remedy + clean_stale side-effect (its §6 is one of 6 sections, all about the surface contract). smoke_exit_contract = exit-code SEMANTICS including the exit-0/exit-1 paths that smoke_surface does NOT test (those require the faked-live-instance machinery). The exit-3 overlap is the shared contract both files stake on; each adds unique assertions (surface: remedy+deletion; contract: exit-0/exit-1). Not pure duplication. Trimming one would weaken a distinct facet for ~zero LOC savings.

### F3 — over-eng candidate: help-clarity suite (258 LOC across 3 files, agent-driven)
- **type**: over-eng (candidate excessive qualitative coverage)
- **file:line**: `tests/integration/smoke_help_clarity.sh` (136) + `tests/lib/smoke_help_judge.sh` (49) + `tests/fixtures/smoke_help_cases.sh` (73)
- **status quo**: a 12-case (P1-P5 positive, N1-N6 negative) agent-driven qualitative suite that proves a zero-context fresh agent given ONLY `ob --help` does not misuse `ob smoke`. Default SKIP (exit 77) unless `OB_HELP_CLARITY_RUN=1`; recorded run 2026-08-02 = 12/12 PASS (3/3 samples per case).
- **proposed change**: none.
- **risk**: N/A.
- **cited evidence / reproducible**:
  - `grep -n 'OB_HELP_CLARITY_RUN' tests/integration/smoke_help_clarity.sh` → default SKIP gate confirmed.
  - `sed -n '/RECORDED RUN/,/═══/p' tests/integration/smoke_help_clarity.sh` → 12/12 PASS recorded.
- **verdict**: **DROP** — directly mitigates the contract-tension misuse risk that is the PRIMARY FOCUS of the blind review (criterion 4): cases P2 (exit-1 = α truth-reporter) and N2 (refuses "smoke broken"; α pushback) prove the help's OVERRIDE banner communicates α semantics to fresh agents. Opt-in (default SKIP) so it imposes no CI cost. Proportionate to the risk it addresses; not over-eng.

### F4 — over-eng candidate: test:prod LOC ratio ~6.5:1
- **type**: over-eng (candidate blanket over-coverage)
- **file:line**: 1745 new test LOC vs ~270 new prod LOC
- **status quo**: high test:prod ratio across 4 layers (protocol/unit/orchestration/integration).
- **proposed change**: none.
- **risk**: N/A.
- **cited evidence**: per-file inventory shows each test owns a distinct contract facet (judges / probes / exit-codes / surface-invariants / substep-isolation / diff-semantics / α-safety / help-clarity / e2e), with stub-based isolation (no redundant real-QEMU runs). The α-semantics + global-contract tension justifies layered coverage.
- **verdict**: **DROP** — coverage is layered and facet-distinct, not redundant. The ratio reflects the contract-tension risk surface, not blanket duplication.

## Summary

| id | type | verdict | status |
|----|------|---------|--------|
| F1 | cov-gap | KEEP | **fix landed** (tests/protocol/start_qemu_noninteractive.sh) — awaiting ob_check re-green |
| F2 | over-eng | DROP | distinct contract facets (surface vs exit-semantics) |
| F3 | over-eng | DROP | opt-in qualitative suite, mitigates contract-tension misuse risk |
| F4 | over-eng | DROP | layered facet-distinct coverage |

**PASS-criterion self-check**: 1 KEEP (F1), fix LANDED; pending re-green of `bash tools/ob_check.sh` after the new test file was added (verification captured below in this evidence pack). No unprocessed KEEP-level finding remains.

---

## Deferred non-blocking 🟡 (independent reviewer convergence — NOT landed, recorded honestly)

Both blind reviewers (A and B, zero-context, independent) INDEPENDENTLY converged on the
same 🟡 non-blocking hardening opportunity. Per the driver's prod-change boundary
("ONLY mechanical fixes when ALL THREE hold: clear bug + test covers it + ob_check green")
and to preserve the integrity of criterion 4 (the reviewed diff == final diff), this 🟡
is recorded as a deferred follow-up rather than landed in this verification cycle. It is
NON-BLOCKING: criterion 4 is unaffected (both reviewers gave it NO-BLOCKER explicitly).

**The converged 🟡**: the global "Exit Codes" section in `ob --help` appears BELOW the
smoke Options section. An agent that grep-only jumps to the global "1 = Failure — broken"
line could miss smoke's per-command OVERRIDE (which sits above it). A one-line back-
reference from the global Exit Codes table to "see smoke Options for an exception" would
harden against that grep-only misread.

**Reviewer A (verbatim, from 06-reviewer-A-verdict.txt)**:
> I would consider adding a back-reference footnote in the global `Exit Codes` section
> (an agent that grep-only jumps to that section would miss the smoke caveat), but this
> is a non-blocking improvement. "I would design it differently" is not within the
> blocker bar.

**Reviewer B (verbatim, from 07-reviewer-B-verdict.txt)**:
> Non-blocking concerns I'll NOTE: (a) the global "Exit Codes" section appears BELOW the
> smoke section in `--help`, so a hasty reader could anchor on the global "1 = Failure —
> broken" line without scrolling up to smoke's override — a cross-reference from the
> global table to "see smoke Options for an exception" would harden it; ... These are 🟡
> hardening opportunities, not 🔴 blockers — the contract violation is documented,
> deliberated, and three-times mitigated.

**Disposition**: DEFERRED to a follow-up. Rationale: (1) it touches `ob` help-text (prod),
and the 🟡 is a clarity hardening, not a "clear bug" — does not meet the prod-change
3-condition bar; (2) landing it post-review would make the final diff diverge from the
reviewed diff, weakening criterion 4's evidence (re-running 2 opus reviewers for a
help-text tweak is disproportionate); (3) the current mitigation stack (override banner
positioned ABOVE the global section + in-band stderr line at exit time + ADR-0020) already
addresses the misuse path for any agent that reads ob's output per bestpractice_06 step 4.
The back-reference is a clean, low-risk follow-up item.

---

## Integration-revealed test-layer fix (NOT a prod cov-gap; recorded for honesty)

### F6-debounce — smoke_e2e Redfish gate proceeded too early (boot-flap race)
- **type**: test-robustness (test-layer only; discovered during criterion-2 integration verification)
- **file:line**: `tests/integration/smoke_e2e.sh` Step 1b Redfish readiness gate
- **status quo**: the F6 fix (already on branch) added a bounded Redfish root readiness gate that
  proceeded on the FIRST HTTP 200. Integration verification on this heavily-loaded shared host
  revealed a residual race: bmcweb briefly returns 200 during boot, then flaps back to HTTP 500
  for a narrow window, then stabilizes at 200. The gate's single-200 check caught the transient
  200, proceeded to smoke, and smoke then hit the 500 → smoke_e2e FAIL (Redfish ✗×3, not the
  expected α breakdown). Controlled diagnosis (clean start + curl every 10s for 70s) confirmed
  bmcweb is stably 200 once past the boot flap (7 consecutive 200s) — image is sound, race is
  the narrow boot flap.
- **proposed change (LANDED)**: debounce the gate — require N consecutive 200s (default 2, via
  `OB_INTEG_REDFISH_DEBOUNCE`, 5s apart) before declaring Redfish ready. A genuine Redfish
  outage (bmcweb never stabilizes) never reaches N consecutive 200s → still times out and FAILs
  (does not mask real outages).
- **risk**: LOW — test-layer only; the debounce only delays proceeding until bmcweb is stably up;
  a broken bmcweb still surfaces as a FAIL.
- **cited evidence / reproducible**:
  - `sed -n '/Step 1b: bounded Redfish/,/Step 2/p' tests/integration/smoke_e2e.sh` (debounce logic)
  - Diagnosis (this run): clean `ob start-qemu` + curl Redfish root every 10s → 200 stable from
    t=10s through t=70s (7 consecutive) — bmcweb sound, boot flap is the only issue.
- **verdict**: N/A (test-layer robustness fix, not an audit KEEP finding) — **LANDED** during
  integration verification. This is the F6 fix's logical completion (F6 closed the SSH-up-but-
  bmcweb-init window; the debounce closes the transient-200-then-flap window).

**Note on reviewed-diff integrity (criterion 4)**: this fix + F1 are both TEST-layer
(`tests/integration/smoke_e2e.sh`, `tests/protocol/start_qemu_noninteractive.sh`). Neither
touches the 4 production files that criterion-4 reviewers evaluated, so the reviewers' verdicts
(blockers=0) still apply to the final prod diff. No re-review needed.
