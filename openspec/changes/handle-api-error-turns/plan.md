# Execution Plan

## Plan step 1: Pure API-error transcript logic

- **Covers:** T1.1, T1.2, T3.1
- **Pre-conditions:**
  - Read `src/driver.zig` existing test style and wait-loop baseline semantics.
- **Action:**
  1. Add tests citing `api-error-turns.transcript-api-error-ends-turn`, `api-error-turns.retryable-api-errors-are-resubmitted-boundedly`, `api-error-turns.non-retryable-api-errors-fail-fast`, `api-error-turns.normal-assistant-turns-are-not-api-errors`, and `api-error-turns.exhausted-api-error-retries-fail-fast`.
  2. Run targeted `zig build test` and observe failures for missing helpers.
  3. Implement pure detection/classification/retry-boundary helpers in `src/driver.zig`.
  4. Run tests and ensure new pure-function tests pass.
  5. Defer commit until full change validation is complete.
- **Verification:**
  - `zig build test`
- **Rollback:**
  - Revert helper/test additions in `src/driver.zig`.
- **Observed Failure:**
    Error verbatim: Claude Code wrote `isApiErrorMessage:true` + `turn_duration` but emitted no Stop hook.
    Repro steps: Anthropic 529 Overloaded during live `claude-p` session with `timeout_ms = 0`.
- **Debugging Trail:**
    Live evidence ruled out parent-session inactivity and showed `claude-p` idle on FIFO wait for 18h+.

## Plan step 2: Wait-loop retry integration

- **Covers:** T2.1, T2.2, T2.3
- **Pre-conditions:**
  - Step 1 helpers exist.
  - Existing Stop hook, echo-confirm, MCP gate, and baseline code remain intact.
- **Action:**
  1. Learn `transcript_path` on SessionStart regardless of streaming mode.
  2. During `awaiting_stop`, poll transcript with lazy FileNotFound tolerance and use the pure detector.
  3. On retryable API errors within budget, sleep bounded backoff, re-baseline, resubmit same prompt with echo confirmation, and continue waiting.
  4. On non-retryable or exhausted retry errors, set captured diagnostic and return `RunError.ApiError`.
  5. Update CLI catch path to print captured diagnostic for `ApiError`.
- **Verification:**
  - `zig build`
  - `zig build test`
- **Rollback:**
  - Revert wait-loop and CLI changes.

## Plan step 3: Final validation and verify artifact

- **Covers:** T3.2
- **Pre-conditions:**
  - All code tasks complete.
- **Action:**
  1. Run `zig build`.
  2. Run `zig build test`.
  3. Run `openspec validate --strict`.
  4. Write `verify.md` with structural/task/spec/test/constitution checks.
  5. Mark tasks complete and commit with subject ≤72 chars.
- **Verification:**
  - `zig build` exit 0
  - `zig build test` exit 0
  - `openspec validate --strict` valid
- **Rollback:**
  - Revert final commit.

## Completion Verification

- `zig build` → exit 0
- `zig build test` → exit 0
- `openspec validate --strict` → valid
- `git status --short` → only intended files before commit, clean after commit

## Manual Adjustments

- Plan keeps one final commit instead of per-step commits because user explicitly requested commit at the end.
