# Execution Plan

<!-- authored: in-session -->

## Plan step 1: Restate governance and domain model

- **Covers:** T1.1, T1.2, T1.3
- **Pre-conditions:**
  - `intent.md`, `proposal.md`, and delta spec are committed in the integration checkout.
  - `intent.md` remains frozen and is not edited.
- **Action:**
  1. Update `openspec/constitution.md` so prompt acceptance is defined as two-phase readiness + transcript-record acceptance and no liveness timeout is permitted.
  2. Update `openspec/domain.md` so prompt submission invariants describe readiness sentinel, bracketed-paste delivery, transcript user-record acceptance, replay immunity, and no elapsed-time failure decision.
  3. Keep live spec wording consistent with the delta spec when OpenSpec validation requires restatement.
  4. Run OpenSpec validation and fix only consistency errors.
  5. Commit governance/spec updates path-scoped.
- **Verification:**
  - `openspec validate deterministic-prompt-submission --strict`
  - `openspec validate --specs --strict`
- **Rollback:**
  - `git restore openspec/constitution.md openspec/domain.md openspec/specs/prompt-echo-confirmation/spec.md` before commit; after commit revert the governance/spec commit.

## Plan step 2: Implement event-gated delivery

- **Covers:** T2.1, T2.2, T2.5, T3.1, T3.4
- **Pre-conditions:**
  - Governance/spec validation is green for the authored requirements.
  - No wall-clock liveness timeout is introduced.
- **Action:**
  1. Add or expose a testable helper for bracketed-paste byte framing and submit-Enter separation.
  2. Add detection/state for the `ESC[?2004h` readiness sentinel in the PTY read path.
  3. Wait for the readiness event before writing prompt bytes; do not use elapsed time as a failure condition.
  4. Deliver prompts as `ESC[200~` + bytes + `ESC[201~`, hold submit Enter on `--mcp-ready-file` as before, then write `\r` separately.
  5. Add tests proving byte order and the absence of elapsed-time/missing-echo failure semantics.
- **Verification:**
  - `zig build test`
  - Targeted unit tests in `src/driver.zig`
- **Rollback:**
  - `git restore src/driver.zig` before commit; after commit revert the implementation commit.

## Plan step 3: Implement transcript-record acceptance

- **Covers:** T2.3, T2.4, T3.2, T3.3
- **Pre-conditions:**
  - Event-gated delivery tests pass.
  - Transcript path/session metadata already available to the driver are identified; no new dependency is introduced.
- **Action:**
  1. Add a transcript user-record baseline helper for the active session.
  2. Add a transcript acceptance helper that detects a new post-baseline user-message record.
  3. Replace authoritative echo/paste-pill acceptance in the submit state machine with transcript-record acceptance.
  4. Preserve echo/paste helpers only as non-authoritative/transitional helpers if needed by tests, not as the submitted gate.
  5. Add regressions proving replayed literal/paste history does not accept without a new transcript user record, while a new post-baseline user record does accept.
- **Verification:**
  - `zig build test`
  - Regression tests tied to `prompt-echo-confirmation.transcript-user-record-confirms-submission` and `prompt-echo-confirmation.replayed-history-does-not-confirm-submission`
- **Rollback:**
  - `git restore src/driver.zig` before commit; after commit revert the implementation commit.

## Plan step 4: Full validation and follow-up capture

- **Covers:** T4.1, T4.2
- **Pre-conditions:**
  - Implementation tasks are complete and checked off in the worktree branch.
  - No `intent.md` edits occurred.
- **Action:**
  1. Run `zig build test`.
  2. Run `zig build -Doptimize=ReleaseSafe`.
  3. Run `openspec validate deterministic-prompt-submission --strict`.
  4. Run `openspec validate --specs --strict`.
  5. Record results in `verify.md` and capture the downstream `pi-claude-bridge` pin/guard/scenario follow-up.
- **Verification:**
  - All commands above pass or a pre-existing failure is proven against unchanged baseline.
  - `opsx gate deterministic-prompt-submission --worktree <path>` advances past validation/verify checks.
- **Rollback:**
  - Revert validation artifact commit if results are stale or incorrect.

## Completion Verification

- `zig build test` — expected PASS.
- `zig build -Doptimize=ReleaseSafe` — expected PASS.
- `openspec validate deterministic-prompt-submission --strict` — expected PASS.
- `openspec validate --specs --strict` — expected PASS.
- `opsx gate deterministic-prompt-submission --worktree <path>` — expected PASS after blind code-review/doneness verdicts seal green.

## Manual Adjustments

- Execution mode is standard, not TDD-required, but the plan still orders regression tests close to the implementation steps because the Reliability bar is the core intent.
- No liveness-timeout fallback is permitted; any implementation strategy that requires elapsed-time failure detection must stop and be redesigned inside the change artifacts.
