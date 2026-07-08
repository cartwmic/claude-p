---
scale: M
full_rigor: false
execution_mode: standard
verification_mode: retained-required
debug_mode: standard
review_status: not-requested
delegation_mode: subagent-required
code_review_mode: gating-required
loop_max_iterations: 40
validation_source_mode: required
spec_level: spec-anchored
doneness_mode: required
review_max_rounds: 5
review_budget_mode: quiet-round
---

# Review

<!-- authored: in-session -->

## Modes

| Mode | Value | Notes |
|---|---|---|
| Scale | M | Cross-cutting driver behavior change with constitution/domain/spec evolution and implementation |
| full_rigor | false | Plain Scale M; design-fidelity still required by gate when design exists; doneness rides code-review per opsx-loop rules |
| Execution Mode | standard | Worktree execution only |
| Verification Mode | retained-required | Verify artifact required before archive because the change is behavioral and regression-sensitive |
| Debug Mode | standard | No systematic-debugging mode unless failures arise during implementation |
| Review Status | not-requested | No review dispatched yet |
| Delegation Mode | subagent-required | Blind reviewer verdicts required for gate-controlled review steps |
| Code Review Mode | gating-required | Explicit because the change modifies prompt-submission correctness |
| Loop Max Iterations | 40 | Scale-M default |
| Validation Source Mode | required | No waiver; tests and strict validation must be retained in verify.md |
| Doneness Mode | required | Semantic intent satisfaction must be judged |
| Spec Level | spec-anchored | Acceptance criteria are the source of implementation obligations |
| Model Config | (unset) | Use configured opsx role models |

## Diff Base + Worktree locator

**Diff Base SHA:** 3fdbcd3923f54b55f7e3a5f6dce7cb20224b686f
**Worktree Path:** /Volumes/Workshop/git/claude-p--opsx-deterministic-prompt-submission
**Integration Branch:** main

## Manual Adjustments

- Scale M selected because the frozen intent requires driver behavior changes plus constitution/domain/spec restatement; full_rigor remains false because the user requested autonomous drive-to-green and the gate can escalate if stricter rigor is required.
- `code_review_mode: gating-required` selected explicitly because false-positive prompt acceptance is a correctness defect with prior production impact.
- `verification_mode: retained-required` selected so the regression/proof bar remains auditable in `verify.md`.

## Execution Notes

- 2026-07-07 — Intent is frozen at commit `124926b902ba52c8e5a7e725ecc7d714d8689ef7`; do not edit `intent.md` without owner re-authorization.
- 2026-07-07 — Standing no-liveness-timeouts principle applies: no submission/acceptance wall-clock caps; waits are event waits only.
- 2026-07-07 — Worktree captured by `opsx worktree ensure deterministic-prompt-submission`: base `3fdbcd3923f54b55f7e3a5f6dce7cb20224b686f`, path `/Volumes/Workshop/git/claude-p--opsx-deterministic-prompt-submission`, integration branch `main`.

## Scope Expansions

- None yet.

## Fidelity Round Ledger

| Round | Fidelity | Per-judge verdicts | Attested HEAD |
|---|---|---|---|
