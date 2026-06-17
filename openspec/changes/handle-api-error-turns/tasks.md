## 1. Transcript API-error detection

- [x] 1.1 Factor pure transcript detection for API-error assistant records followed by `turn_duration` past baseline
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [x] 1.2 Add retryable/non-retryable classifier and retry-boundary helper
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false

## 2. Driver integration

- [x] 2.1 Learn transcript path for non-streaming runs and poll it during `awaiting_stop`
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [x] 2.2 Add bounded retry loop with `CLAUDE_P_API_ERROR_RETRIES`, inter-attempt backoff, prompt resubmit, and re-baseline
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [x] 2.3 Add `RunError.ApiError` diagnostic surfacing through CLI
  - intent: fix
  - files_allowed:
      - src/driver.zig
      - src/main.zig
  - allow_new_files: false

## 3. Regression tests and validation

- [x] 3.1 Add unit tests for retryable API-error detection, non-retryable classification, normal-turn non-detection, and exhausted retry boundary
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [x] 3.2 Run `zig build`, `zig build test`, and `openspec validate --strict`
  - intent: infra
  - files_allowed:
      - openspec/changes/handle-api-error-turns/verify.md
      - openspec/changes/handle-api-error-turns/tasks.md
  - allow_new_files: true
