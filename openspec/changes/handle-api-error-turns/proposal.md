## Why

Claude Code v2.1.159 can end an API-error turn by flushing an `isApiErrorMessage:true` assistant record plus trailing `system` `turn_duration` transcript record without firing the Stop hook. With `timeout_ms = 0` this leaves `claude-p` waiting forever, violating Constitution IV's surgical reliability mandate while preserving the intentionally unlimited wall-clock default.

## What Changes

- Add transcript-based API-error turn-end detection after the resume-staleness baseline, independent of the Stop hook.
- Classify transient upstream API errors as retryable and resubmit the same live prompt into the running interactive session with bounded retries.
- Add `CLAUDE_P_API_ERROR_RETRIES` env knob, default `3`, for retries after the first failed attempt.
- Add `RunError.ApiError` fast-failure path that includes captured upstream error text for non-retryable errors or exhausted retries.
- Preserve normal Stop-hook completion, echo confirmation, MCP readiness gating, resume-staleness guard, and `timeout_ms = 0` unlimited default.

## Capabilities

### New Capabilities
- `api-error-turns`: Detect and recover from transcript-confirmed Claude API-error turns that do not emit Stop hooks.

### Modified Capabilities
- None.

## Impact

Affected code:
- `src/driver.zig`: wait loop, transcript polling/detection/classification, bounded retry/backoff, `RunError.ApiError`, tests.
- `src/main.zig`: CLI diagnostic for `ApiError`.

Affected APIs and systems:
- New environment knob: `CLAUDE_P_API_ERROR_RETRIES`.
- No dependency changes.
- Single-repo fork-only change in `claude-p`.
