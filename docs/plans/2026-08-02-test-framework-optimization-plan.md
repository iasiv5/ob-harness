# Test Framework Optimization Plan — Dual-Axis Audit (over-engineering × coverage-gap)

- **Date:** 2026-08-02 (landed 2026-08-03)
- **Scope:** ob-harness test framework — `tests/*` (117 files) + `tools/<gate>` (10 gates) = 127 test-face items. Production code (`ob`, `lib/*.sh`) appears only as the test target.
- **Repo HEAD at audit:** `feat/ob-verify` (commit `2f467de`). Landing branch: `feat/test-audit-land-f1-wrapper-cov`.
- **Method:** exhaustive enumeration (criterion 3) + objective evidence per finding + dual independent reviewer consensus (criterion 4) + one landing with real validation (criterion 5). Refuses subjective assertions; every finding is falsifiable.

## TL;DR

- **Findings:** 5 total. **KEPT = 4** (F1, F2, F3, F4). **DROPPED = 1** (F5, reviewer disagreement).
- **Dual axis:** over-engineering = 2 KEPT (F3 duplicate assertion; F4 meta-test-of-test-gate). coverage-gap = 2 KEPT (F1 wrapper branches; F2 interactive-binary-setup branches).
- **Landed:** F1 (highest-value cov-gap, lowest-risk) on `feat/test-audit-land-f1-wrapper-cov`. `bash tools/ob_check.sh` → exit 0 (ALL GREEN PASS=14). `bash tests/run_all.sh --full --integration` → ALL GREEN (real bitbake rebuild of gb200nvl-obmc + QEMU + smoke α-truth + devtool modify→reset→finish). Zero residual QEMU.

---

## Findings (canonical table — 5 fields + verdict, all non-empty)

| ID | type | evidence (file:line) | status quo | proposed change | risk | verdict |
|----|------|----------------------|------------|-----------------|------|---------|
| F1 | cov-gap | lib/qemu_binary.sh:211 `download_and_replace_community_qemu` | wrapper owns 3 branches (acquire-fail L224-228 warn+rm+return1; flock-busy L231-236; commit L239-244); orchestration test stubs the two leaf helpers and never invokes the wrapper; matrix md:81 claims covered, radar cross-check lists uncovered, grep tests/ empty | add 3 wrapper-branch tests (stub leaves only) OR correct matrix L81 | low | KEPT 2/2 |
| F2 | cov-gap | lib/qemu_binary.sh:488 `ensure_qemu_binary_custom` | branches non-TTY→exit3 L495-499, cancel→exit1 L510-512, resolve-error loop L514-519, happy cp+chmod L521-522; only tests/ ref is a negative structural assertion qemu_launch_profile_structure.sh:78; matrix L82 mitigation claim is false (no .exp covers it) | add unit test (stub deps) for non-TTY exit3 + resolve-error loop OR document TTY-only boundary in matrix | low | KEPT 2/2 |
| F3 | over-eng | tests/protocol/exit_codes.sh:84 AND tests/protocol/smoke_ob.sh:38 | both assert identical contract ob build empty-workspace→exit3 via same parse_args build→cmd_build dispatch; smoke_ob.sh:36 self-labels it the baseline; exit_codes.sh is slowest file 19.54s of 57.7s (34%), ~1.5s per ob-sourcing | drop the exit_codes.sh:84 baseline case (keep its 4 non-TTY-guard + positional cases smoke_ob lacks) OR drop the build case from smoke_ob; assert once | low | KEPT 2/2 |
| F4 | over-eng | tests/protocol/ob_check_smoke.sh:12-13 | single assert_rc 0 wrapping `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash tools/ob_check.sh`; .github/workflows/ob-tests.yml:28 runs that exact command as a peer CI step while L20 runs run_all which includes this test → byte-identical redundancy in CI; 5.07s 2nd slowest (8.8%) | remove and rely on canonical ob_check.sh OR keep and document the intentional redundancy (zero-cost option b) | low-medium | KEPT 2/2 |
| F5 | over-eng | tools/coverage_matrix.md:113 | 5 names (machine_state_records etc.) absent from ob/lib (ob_check §1b enforces absence) yet cross-check emits them every run as typo/stale-name candidates with no allowlist | relocate gate-doc out of matrix OR add cross-check allowlist | low | DROPPED 1-keep/1-drop |

---

## Per-finding detail + falsifiable evidence

### F1 — cov-gap — KEPT (Reviewer A KEEP, Reviewer B KEEP)

- **file:line:** `lib/qemu_binary.sh:211` — `download_and_replace_community_qemu`.
- **status quo:** Wrapper owns three branches the leaf tests do not reach: (a) acquire failure (`_dlqbc_stage_binary` returns non-zero → `warn` + `rm -rf tmp_dir` + `return 1`, body L224-228); (b) flock contention (`flock -n 200` fails → `warn` + `return 1`, L231-236); (c) commit path (calls `_replace_community_binary`, propagates rc, cleans tmp + releases lock, L239-244). `tests/orchestration/qemu_binary_replace.sh` stubs `download_qemu_binary_core` and calls `_dlqbc_stage_binary` + `_replace_community_binary` directly in subshells (lines 28, 38, 55, 70) — never the wrapper. `tools/coverage_matrix.md:81` declares the wrapper covered by that test; the runtime radar cross-check lists it under "声明但 radar 未覆盖".
- **proposed change (LANDED):** append 3 wrapper-branch cases to `tests/orchestration/qemu_binary_replace.sh` (stub only the networked `_dlqbc_stage_binary` and FS-touching `_replace_community_binary`, exercise the wrapper's own mktemp/flock/rm): w1 acquire-fail → rc=1 + old binary untouched; w2 flock-busy (parent pre-holds fd9 lock; child `flock -n` fails) → rc=1; w3 happy → rc=0 + binary swapped.
- **risk:** low. Test-only; closed the gap, 15/15 green (was 9).
- **falsifiable evidence:**
  - `grep -rln download_and_replace_community_qemu tests/` → empty before landing. [evidence 06-radar-uncovered-grep.txt]
  - `bash tools/trace_collect.sh | python3 tools/coverage_radar.py - --cross-check` lists `download_and_replace_community_qemu` under "声明但 radar 未覆盖(3)". [evidence 05-coverage-crosscheck.txt]
  - function body read at lib/qemu_binary.sh:211-254; the three branches confirmed.
  - post-landing: `bash tests/orchestration/qemu_binary_replace.sh` → PASS=15 FAIL=0.

### F2 — cov-gap — KEPT (Reviewer A KEEP, Reviewer B KEEP)

- **file:line:** `lib/qemu_binary.sh:488` — `ensure_qemu_binary_custom`.
- **status quo:** branches non-TTY → `exit 3` (L495-499); `prompt_for_absolute_path` cancel → `exit 1` (L510-512); `resolve_custom_binary_candidate` error tokens `err_dir_no_arch`/`err_not_file` → loop continue (L514-519); happy → `cp` + `chmod +x` (L521-522). The only `tests/` reference is a NEGATIVE structural assertion `tests/protocol/qemu_launch_profile_structure.sh:78` (body must not match `QB_SYSTEM_NAME|\bSOC_TYPE\b`). No behavioral test. `tools/coverage_matrix.md:82` mitigation note "非 TTY exit 3 仍靠 .exp" is false (both reviewers grepped all 4 `.exp` files — no reference to the function or its error strings). Radar cross-check lists it uncovered.
- **proposed change:** add a unit test (stub `derive_qemu_paths`/`prompt_for_absolute_path`/`resolve_custom_binary_candidate`) covering ≥ non-TTY `exit 3` + resolve-error loop; OR correct the matrix L82 boundary note.
- **risk:** low.
- **falsifiable evidence:**
  - `grep -rn ensure_qemu_binary_custom tests/` → exactly 1 hit, the negative assertion. [evidence 06]
  - cross-check lists it uncovered. [evidence 05]
  - body read at lib/qemu_binary.sh:488-524.
  - scratch-validated a non-TTY exit-3 test (2/2 assertions pass); not landed this round (F1 chosen for landing).

### F3 — over-eng — KEPT (Reviewer A KEEP, Reviewer B KEEP)

- **file:line:** `tests/protocol/exit_codes.sh:84` and `tests/protocol/smoke_ob.sh:38`.
- **status quo:** Both assert the identical contract "ob build in an empty workspace → exit 3" via the same dispatch (`parse_args build` → `cmd_build` → empty-workspace guard → exit 3):
  - `exit_codes.sh:84` `assert_ob_rc 3 "build empty workspace" build`
  - `smoke_ob.sh:38-39` `assert_rc 3 "ob build in empty workspace" bash -c '...parse_args build; cmd_build'`
  Each spawns a subshell sourcing the full `ob` (32 `lib/*.sh` modules). `exit_codes.sh` is the slowest file at 19.54 s of 57.7 s total (34%); the duplicate costs ~one full ob-sourcing (~1.5 s). `smoke_ob.sh:36` self-labels its case as the baseline.
- **proposed change:** drop the `exit_codes.sh:84` baseline (keep its 4 non-TTY-guard + positional cases `smoke_ob.sh` lacks), or drop the build case from `smoke_ob.sh`. The 4 non-TTY-guard cases (build/start-qemu/stop-qemu/init candidates-but-non-TTY) are NOT in `smoke_ob.sh` and must be retained.
- **risk:** low.
- **falsifiable evidence:**
  - `grep -n 'build empty workspace' tests/protocol/exit_codes.sh` → `84:assert_ob_rc 3 "build empty workspace" build`. [evidence 09-overlap-exit-build.txt]
  - `grep -n 'build in empty workspace' tests/protocol/smoke_ob.sh` → lines 36 + 38. [evidence 09]
  - timing: exit_codes.sh = 19.54 s slowest; full fast run_all = 57.7 s. [evidence 07, 08]

### F4 — over-eng — KEPT (Reviewer A KEEP, Reviewer B KEEP)

- **file:line:** `tests/protocol/ob_check_smoke.sh:12-13`.
- **status quo:** Single `assert_rc 0` wrapping `env OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash tools/ob_check.sh`. Its own header (L2-6) states it only exercises extract_funcs/baseline/exit-contract (run_all skipped to avoid recursion). But `.github/workflows/ob-tests.yml:28` runs that EXACT command as a dedicated CI step while L20 runs `run_all.sh` (which includes `ob_check_smoke.sh`) — so CI executes the identical ob_check.sh invocation twice, and `ob_check_smoke.sh` adds no catching power there. 5.07 s, 2nd slowest (8.8% of 57.7 s).
- **proposed change:** (a) remove `ob_check_smoke.sh` and rely on the canonical `bash tools/ob_check.sh` mandated by AGENTS.md Working Mode; OR (b) keep but add a header note documenting the intentional redundancy. Option (b) is zero-cost.
- **risk:** low–medium (removing loses a ~5 s rot-canary; keeping + documenting costs nothing).
- **falsifiable evidence:**
  - file is a single `assert_rc 0 ... bash tools/ob_check.sh`. [file read in full]
  - `.github/workflows/ob-tests.yml:28` runs the exact command as a CI step. [both reviewers independently confirmed]
  - timing 5.07 s 2nd slowest. [evidence 08]

### F5 — over-eng — DROPPED (Reviewer A KEEP, Reviewer B DROP — disagreement)

- **file:line:** `tools/coverage_matrix.md:113`.
- **status quo:** matrix "横切" L113 lists 5 names (`machine_state_records`, `_commands_machine_record_field`, `_commands_record_has_discovery_source`, `_commands_collect_machine_state_records`, `_repo_machine_record_field`) as a "surface 门禁" entry. None exist in `ob`/`lib/*.sh` — `ob_check.sh` §1b (L46-54) enforces their ABSENCE. The matrix annotates "out-of-radar(surface gate 回归锁)". The cross-check tool (`coverage_radar.py` L86-89) has no allowlist and emits these 5 every run under "matrix 声明但不在 radar 全集(…typo/过期名待修)".
- **proposed change:** relocate the gate-doc out of the matrix into the ob_check §1b comment, OR add a cross-check allowlist.
- **risk:** low.
- **DISAGREEMENT (→ DROPPED):**
  - Reviewer A KEEP: `coverage_radar.py` L86-89 has no allowlist → the 5 names generate recurring false-positive noise on every cross-check, diluting the typo-detection signal.
  - Reviewer B DROP: the cross-check output [05:123] already self-explains these as "应为 surface gate 等刻意 out-of-radar" and matrix L113 annotates them "out-of-radar(surface gate 回归锁)" — the "noise" is 5 lines of self-documenting output, the entry is legitimate annotated documentation of an intentional gate, and the proposed allowlist/move remedies a non-issue at non-zero maintenance cost.
- **falsifiable evidence:**
  - `grep -nE '...' tools/coverage_matrix.md` → L113. [evidence 09]
  - `grep -rnE '...' lib/*.sh` → empty (truly absent). [evidence 09]
  - cross-check emits them as "typo/过期名待修" candidates. [evidence 05]

---

## Scan methodology (criterion 3 — exhaustive enumeration)

**Canonical commands** (master re-runs these to verify rc/count):

```
find tests -type f | sort                       # 117 files
ls tools/{ob_check.sh,exit_contract.py,extract_funcs.py,smoke_regression.sh,
         smoke_diff.py,coverage_radar.py,trace_collect.sh,
         knowhow_tldr_drift_check.py,cache_hit_rate.py,coverage_matrix.md}   # 10 gates
```

**Captured totals:** `tests/` = 117 files (fixtures 4, lib 6, protocol 32, unit 45, orchestration 21, integration 7, top-level 2 [run_all.sh + .shellcheck-baseline]). `tools/` gates = 10. **Grand total test-face = 127 items.** Raw output: `evidence-test-audit-2026-08-02/10-canon-enumeration.txt`.

**Per-item axis tag** (over-eng / cov-gap / N-A). "All found" = this exhaustive scan ∪ the two reviewers' independent re-runs. Tags reflect whether the item is implicated by a finding; N-A items are tagged with reason.

### tests/ (117)

**fixtures (4)**
- `bitbake-e.sample.txt` — N-A (static sample data referenced by 1 test)
- `deps.json.sample` — N-A (static sample data referenced by 2 tests)
- `smoke_help_cases.sh` — N-A (fixture cases for opt-in smoke_help_clarity runner; env-gated, not implicated)
- `source_manifest.sample` — N-A (static sample data referenced by 2 tests)

**lib (6) — test helpers**
- `assert.sh` — N-A (assertion primitive library, refs=96)
- `ob_loader.sh` — N-A (ob/lib loader for tests, refs=70)
- `qemu_stubs.sh` — N-A (stub library, refs=7)
- `smoke_help_judge.sh` — N-A (pure-bash judge for opt-in runner, refs=2)
- `status_fixtures.sh` — N-A (fixture data, refs=2)
- `stub.sh` — N-A (stub primitive library, refs=28)

**protocol (32)**
- `exit_codes.sh` — **over-eng** (F3 duplicate "build empty workspace" case)
- `ob_check_smoke.sh` — **over-eng** (F4 meta-test-of-test-gate redundant with CI L28)
- `qemu_launch_profile_structure.sh` — **cov-gap witness** (F2: its `assert_function_not_match ensure_qemu_binary_custom` is the SOLE tests/ ref for that function — negative structural only, no behavioral coverage)
- `manual_matrix.exp` — N-A (TTY interaction matrix; distinct from integration manual_matrix_qemu.exp; covers non-QEMU cancel/menu branches)
- `dev_interactive.exp` — N-A (ob dev TTY引导; covers cmd_dev non-TTY-unreachable branches)
- `status_golden.expected`, `status_golden.sh` — N-A (golden-byte regression for status)
- other 24 `.sh` — N-A (each covers a distinct contract; no overlap or gap surfaced by scan/reviewers)

**unit (45)**
- `smoke_regression_alpha_safety.sh` — N-A (α-safety invariant guard for the gate; not implicated)
- other 44 — N-A (per-function leaf-pure unit tests; scan surfaced no over-eng; coverage_matrix declares their targets and radar confirms)

**orchestration (21)**
- `qemu_binary_replace.sh` — **cov-gap (F1, now landed)** + landing site (wrapper branches added)
- other 20 — N-A (distinct orchestration concerns; no redundancy surfaced)

**integration (7)**
- `build_e2e.exp` — N-A (opt-in real-build driver, env-gated OB_RUN_BUILD_E2E=1; skipped by default, design)
- `ob_deploy_to_qemu.sh` — N-A (real bitbake + QEMU; PASSED in landing validation)
- `ob_dev.sh` — N-A (real devtool modify→reset→finish; PASSED in landing validation)
- `smoke_e2e.sh` — N-A (real QEMU smoke; accepts gb200nvl α-truth by design; PASSED)
- `manual_matrix_qemu.exp` — N-A (self-contained QEMU start/stop; PASSED)
- `init_dryrun_sanity.sh` — N-A (ob init -d sanity; PASSED)
- `smoke_help_clarity.sh` — N-A (agent-driven judge runner; env-gated OB_HELP_CLARITY_RUN=1; skipped by default, design)

**top-level (2)**
- `run_all.sh` — N-A (layered dispatcher; criterion-5 vehicle)
- `.shellcheck-baseline` — N-A (shellcheck multiset baseline consumed by ob_check §2)

### tools/ gates (10)

- `ob_check.sh` — N-A as audit target (the canonical stage gate; F4 concerns a TEST of it, not the gate itself)
- `exit_contract.py` — N-A (X/Y/Z exit discipline; not implicated)
- `extract_funcs.py` — N-A (GAPS + three-section check; reused by coverage_radar)
- `smoke_regression.sh` — N-A (α-safe temporal CI gate; its own test is tests/orchestration/smoke_regression.sh — distinct, not duplicate)
- `smoke_diff.py` — N-A (temporal diff engine for the gate)
- `coverage_radar.py` — referenced by F5 (no-allowlist emission), but F5 DROPPED → N-A in KEPT set
- `trace_collect.sh` — N-A (xtrace collector)
- `knowhow_tldr_drift_check.py` — N-A (advisory drift check)
- `cache_hit_rate.py` — N-A (cache hit-rate observer)
- `coverage_matrix.md` — referenced by F5 (stale-entry witness) and F1/F2 (false coverage claims at L81/L82). F1's matrix correction is the optional alt-fix (the landed fix is the test addition). N-A as over-eng in KEPT set.

---

## Dual independent review (criterion 4)

Two reviewers spawned independently (synchronous, `opus`, zero-shared-context). Each received ONLY the evidence pack + 5 findings + the rubric — never the orchestrator's recommendation, never the other's verdict. Verbatim prompt in appendix A. Verdicts captured in `evidence-test-audit-2026-08-02/11-reviewer-A-verdicts.txt` and `12-reviewer-B-verdicts.txt`.

### Consensus summary (self-consistent tally)

| finding | Reviewer A | Reviewer B | consensus |
|---------|-----------|-----------|-----------|
| F1 | KEEP | KEEP | **KEPT** |
| F2 | KEEP | KEEP | **KEPT** |
| F3 | KEEP | KEEP | **KEPT** |
| F4 | KEEP | KEEP | **KEPT** |
| F5 | KEEP | DROP | **DROPPED** (disagreement) |

**Counts:** KEPT = 4, DROPPED = 1, total = 5. Each finding has exactly 2 verdicts (one per canonical reviewer). Top summary tally matches per-finding tally. (Two additional async runs corroboration: both returned F1-F4 KEEP, F5 KEEP — logged for transparency; consensus is decided by the 2 canonical synchronous reviewers per the "双方" rule.)

---

## Landing validation (criterion 5)

- **Finding landed:** F1 (cov-gap, `download_and_replace_community_qemu` wrapper branches).
- **Branch:** `feat/test-audit-land-f1-wrapper-cov` (from `feat/ob-verify` HEAD `2f467de`). Commit `e362148`.
- **Change:** appended 3 wrapper-branch cases (acquire-fail / flock-busy / happy) to `tests/orchestration/qemu_binary_replace.sh`; stubs only the networked/FS-touching leaves, exercises the wrapper's own mktemp/flock/rm orchestration. Test went 9 → 15 assertions.
- **`bash tools/ob_check.sh`:** **exit 0** (ALL GREEN PASS=14).
- **`bash tests/run_all.sh --full --integration`:** **ALL GREEN** (exit 0). Real bitbake rebuild of `gb200nvl-obmc` (incremental, warm `tmp/work`) + QEMU restart + BMC SSH ready; `ob_dev.sh` modify→reset→finish; `smoke_e2e.sh` α-truth path (Redfish✓×3, IPMI✗ image lacks RMCP+, ready✓ → rc=1 by design, accepted); `manual_matrix_qemu.exp` self-contained QEMU; `init_dryrun_sanity.sh` dry-run. Two env-gated opt-in tests skipped by design (`build_e2e.exp` needs `OB_RUN_BUILD_E2E=1`; `smoke_help_clarity.sh` needs `OB_HELP_CLARITY_RUN=1`). Log: `evidence-test-audit-2026-08-02/13-runall-full-integration.log` (no FAIL markers; terminator = "ALL GREEN").
- **QEMU cleanup:** `ob stop-qemu --all` → "No QEMU instances to stop" (the integration tests are self-contained and cleaned up after themselves). Verified zero residual: no `qemu-system` processes, no `workspace/qemu-bin/.pids/*.pid`, ports 2222/2443/2623 free.
- **Note on rc observation:** the integration was run detached via `nohup` (1-4h budget); post-hoc `wait` on the reaped PID returned 127 (artifact of polling a reaped nohup child, not the run's exit). The run's true exit code is 0, proven by the "ALL GREEN" terminator (`run_all.sh` prints `exit 1` before ALL GREEN iff FAILED non-empty). A fresh synchronous `bash tests/run_all.sh --full --integration` reproduces rc=0.

---

## Evidence pack index (criterion 6)

Directory: `docs/plans/evidence-test-audit-2026-08-02/`. Any fresh agent can re-run the cited commands to reproduce.

- `00-INDEX.txt` — this index
- `01-enumeration-tests.txt` — first-pass tests/ list (superseded by 10)
- `02-enumeration-tools-gates.txt` — 9 tool gates + run_all.sh + .shellcheck-baseline existence
- `03-coverage-radar.txt` — `coverage_radar.py` raw (structure-only, 231 fn / 0 covered)
- `04-coverage-matrix.txt` — `coverage_matrix.md` head + bucket grep
- `05-coverage-crosscheck.txt` — **THE real coverage picture** (`trace_collect.sh | coverage_radar.py - --cross-check`)
- `06-radar-uncovered-grep.txt` — `grep tests/` for the 3 radar-uncovered functions
- `07-runall-timing.txt` — fast run_all = 57.7s; per-layer breakdown
- `08-slowest-tests.txt` — slowest protocol .sh: exit_codes.sh=19.54s, ob_check_smoke.sh=5.07s
- `09-overlap-exit-build.txt` — exit_codes.sh × smoke_ob.sh overlap + matrix stale-ref check
- `10-canon-enumeration.txt` — canonical `find tests -type f` = 117 + 10 tools gates
- `11-reviewer-A-verdicts.txt` — Reviewer A per-finding verdicts (verbatim)
- `12-reviewer-B-verdicts.txt` — Reviewer B per-finding verdicts (verbatim)
- `13-runall-full-integration.log` — full `run_all.sh --full --integration` output (ALL GREEN)

---

## Appendix A — reviewer prompt (verbatim, identical for both reviewers)

Each reviewer was spawned as a fresh `general-purpose` subagent with `opus`, zero-shared-context (separate spawn, no transcript sharing, no reference to the other reviewer). The full prompt text is reproduced in `evidence-test-audit-2026-08-02/reviewer-prompt-verbatim.txt` (written below). Summary of what each reviewer received: repository context (read-only, cwd `/home/iasi/ob-harness`, branch `feat/ob-verify`), the evidence-pack file list (01-10), the 5 findings with all 5 fields + falsifiable evidence citations, permission to re-run any cited grep/command, instruction NOT to edit files or spawn sub-agents, and the rubric (KEEP iff real evidence-backed cost/gap AND sound proportionate change; DROP iff evidence unsupported / out-of-scope / subjective). Each returned one `F<n>: KEEP|DROP — <reason>` line per finding + a `SUMMARY: kept=<n> dropped=<n>` tally.

---

## Reproducible grep (criterion 1)

A single command that exits 0 (rc=0) **iff** the canonical finding table has ≥2 findings AND no empty field in any finding row. Narrows to finding-table rows (those whose type cell is `cov-gap` or `over-eng`, distinguishing them from the consensus table which also begins `| F<n> |`) and checks only the 7 inner content cells (skipping the leading/trailing empty split artifacts from markdown `| ... |` framing):

```
awk -F'|' '
  /^\| F[0-9]+ \| (cov-gap|over-eng) \|/ {
    n++;
    for (i=2; i<NF; i++) { gsub(/^[ \t]+|[ \t]+$/,"",$i); if ($i=="") empty++ }
  }
  END { exit !(n>=2 && empty==0) }
' docs/plans/2026-08-02-test-framework-optimization-plan.md
```

- `n` = finding-row count in the canonical table (must be ≥2; this plan has 5).
- `empty` = count of empty inner cells across those rows (must be 0).
- Exits 0 iff both hold. (The `i<NF` bound skips the trailing empty split cell from the closing `|`; the `(cov-gap|over-eng)` anchor excludes the consensus table rows.)

**Quick count check:** `grep -cE '^\| F[0-9]+ \| (cov-gap|over-eng) \|' docs/plans/2026-08-02-test-framework-optimization-plan.md` → 5.

---

## Boundary & non-goals

- Audit target = the test framework. Production behavior (`ob`/`lib`) appears only as the test target; this audit changed NO production behavior. The F1 landing is a test-only addition.
- F2/F3/F4 are KEPT but not landed this round (one landing satisfies criterion 5; F1 was chosen as highest-value/lowest-risk). Their proposed changes are ready to land on follow-up branches.
- F5 DROPPED on disagreement; not landed.
- `docs/plans` is a frozen snapshot; this file will not be edited after the consensus + landing were captured.
