## 1. Spec and governance alignment

- [x] 1.1 Restate `openspec/constitution.md` for two-phase prompt acceptance and no liveness timeouts.
  - intent: feature
  - files_allowed:
      - openspec/constitution.md
  - allow_new_files: false
- [x] 1.2 Restate `openspec/domain.md` prompt-submission invariants for readiness-gated bracketed-paste delivery and transcript user-record acceptance.
  - intent: feature
  - files_allowed:
      - openspec/domain.md
  - allow_new_files: false
- [x] 1.3 Keep the live `prompt-echo-confirmation` spec consistent with the delta requirements during archive/apply validation.
  - intent: feature
  - files_allowed:
      - openspec/specs/prompt-echo-confirmation/spec.md
  - allow_new_files: false

## 2. Driver submission implementation

- [x] 2.1 Add an event-based readiness gate that waits for the child PTY to emit `ESC[?2004h` before prompt delivery.
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [x] 2.2 Replace raw prompt typing with explicit bracketed-paste delivery while preserving submit Enter as a separate PTY write after `ESC[201~` and after the existing MCP ready-file hold.
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [x] 2.3 Add transcript user-record baseline and acceptance detection for the active Claude Code session, using the transcript path already available to the driver.
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [ ] 2.4 Retire PTY echo / paste-pill acceptance as the authoritative submission gate once transcript-record acceptance satisfies the Reliability bar.
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [ ] 2.5 Preserve no-liveness-timeouts behavior: no submission/acceptance wall-clock cap, no retry clock, no `--timeout` reintroduction, and no elapsed-time-based `PromptNotAccepted`.
  - intent: fix
  - files_allowed:
      - src/driver.zig
      - README.md
  - allow_new_files: false

## 3. Regression coverage

- [ ] 3.1 Add unit coverage for readiness-gated bracketed-paste byte order (`ESC[200~` prompt `ESC[201~` then separate `\r`).
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [ ] 3.2 Add regression coverage proving replayed-history literal/paste evidence does not confirm acceptance without a new post-baseline transcript user record.
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [ ] 3.3 Add regression coverage proving a real new post-baseline transcript user record confirms submission.
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - allow_new_files: false
- [ ] 3.4 Add no-liveness-timeout regression/static coverage proving submission failure is not decided by elapsed time or missing echo alone.
  - intent: fix
  - files_allowed:
      - src/driver.zig
      - README.md
  - allow_new_files: false

## 4. Validation and bridge follow-up

- [ ] 4.1 Run `zig build test`, `zig build -Doptimize=ReleaseSafe`, `openspec validate deterministic-prompt-submission --strict`, and `openspec validate --specs --strict`; record results in `verify.md`.
  - intent: infra
  - files_allowed:
      - openspec/changes/deterministic-prompt-submission/verify.md
  - allow_new_files: true
- [ ] 4.2 Record the downstream `pi-claude-bridge` pin/guard/scenario follow-up without implementing it in this change.
  - intent: infra
  - files_allowed:
      - openspec/changes/deterministic-prompt-submission/follow-ups.md
      - openspec/changes/deterministic-prompt-submission/review.md
  - allow_new_files: true
