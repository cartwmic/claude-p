## Context

`claude-p` drives the interactive Claude Code TUI and currently treats the Stop hook as the only normal completion signal for a submitted turn. Live evidence shows Claude Code can flush an API-error assistant transcript record and a trailing `system` `turn_duration` record without firing Stop. Since `Options.timeout_ms` defaults to `0` by design, this wedges forever unless the transcript itself is treated as an observable completion channel.

This design respects Constitution IV by limiting behavior changes to `src/driver.zig` and CLI error reporting, and respects existing domain invariants for echo confirmation, prompt submission, and resume baselining by making the API-error path additive.

## Goals / Non-Goals

**Goals:**
- Detect transcript-confirmed API-error turn-end without Stop.
- Retry transient API errors a bounded number of times using the same prompt in the same interactive session.
- Fail fast with a clear `RunError.ApiError` diagnostic for permanent API errors or exhausted retries.
- Keep `timeout_ms = 0` unlimited and avoid any idle watchdog or fixed turn budget.

**Non-Goals:**
- Replace the Stop hook for normal successful turns.
- Change output formats, dependencies, transcript summary semantics for successful turns, or MCP readiness gating.
- Add a wall-clock cap or idle watchdog.

## Decisions

### D1: Detect API-error turn-end from transcript records

**Choice:** Add a pure transcript scanner that finds an assistant record past `baseline_turns` with `isApiErrorMessage:true`, captures text, and confirms turn completion only after a following `system` `turn_duration` record.

**Alternatives considered:**
- **Wait only for Stop:** preserves old behavior but causes the proven infinite hang.
- **Treat API-error assistant line alone as terminal:** faster but risks reading incomplete text before Claude flushes the turn.

**Rationale:** The trailing `turn_duration` record is the observed durable signal that the errored turn is fully flushed, and baseline filtering preserves the resume-staleness guard.

**4-point test:** multiple approaches yes; lasting yes; disagreement low; constrains future options no → ADR candidate N.

### D2: Retry only transient upstream errors with an env-bounded budget

**Choice:** Classify retryable errors by case-insensitive text patterns for overload/capacity, HTTP 529, HTTP 503/service unavailable, and rate-limit/HTTP 429. Use `CLAUDE_P_API_ERROR_RETRIES` default `3` as retries after the first failure.

**Alternatives considered:**
- **Retry all API errors:** can loop on auth or invalid-request failures.
- **Never retry API errors:** fails recoverable overloaded/rate-limit turns that the live session can resubmit.

**Rationale:** Text classification matches the only evidence available in the transcript and keeps retries bounded without adding a wall-clock turn budget.

**4-point test:** multiple approaches yes; lasting moderate; disagreement moderate; constrains future options no → ADR candidate N.

### D3: Re-baseline after each retryable failed turn

**Choice:** Before resubmitting after a retryable API-error turn, update `baseline_turns` and `baseline_usage` to the transcript state that includes the failed turn.

**Alternatives considered:**
- **Keep original baseline:** would repeatedly re-detect the same API-error turn and could misattribute final results.
- **Reset the session:** higher blast radius and loses the user's interactive session state.

**Rationale:** Re-baselining preserves existing live-turn freshness semantics while enabling the next attempt to be evaluated past the larger transcript.

**4-point test:** multiple approaches yes; lasting low; disagreement low; constrains future options no → ADR candidate N.

### D4: Surface `RunError.ApiError` with captured text

**Choice:** Add `RunError.ApiError` and a CLI diagnostic path that prints the captured upstream error text and total attempts.

**Alternatives considered:**
- **Return StopTimeout:** misleading and loses the actual upstream failure.
- **Return an error Result envelope:** inconsistent with current driver error variants for pre-result failures.

**Rationale:** A distinct error variant lets callers distinguish API-error failures from hook/timeouts while preserving non-zero CLI exit behavior.

**4-point test:** multiple approaches yes; lasting moderate; disagreement low; constrains future options no → ADR candidate N.

## Risks / Trade-offs

| # | Risk | Likelihood | Severity | Mitigation |
|---|---|---|---|---|
| R1 | Retryable text matching misses a new transient phrase. | Medium | Medium | Keep classifier pure and testable; include broad overload/capacity/service/rate-limit terms. |
| R2 | Transcript polling before file exists produces noise. | Medium | Low | Reuse lazy-open/read retry behavior and ignore FileNotFound. |
| R3 | Streaming callers may observe transcript lines from failed attempts before eventual success. | Low | Low | Preserve live transcript streaming semantics; final result remains authoritative. |

## Migration Plan

- Implement in-place in `src/driver.zig` and `src/main.zig`.
- Add unit/regression tests for transcript detection, classification, normal-turn non-detection, and retry exhaustion boundary.
- Validate with `zig build`, `zig build test`, and `openspec validate --strict`.
- Rollback by reverting the final commit.

## Open Questions

None.
