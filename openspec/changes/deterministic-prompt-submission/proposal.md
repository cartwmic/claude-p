## Why

`claude-p` can silently hang on warm resume because its PTY echo-scan can treat replayed-history text or a collapsed-paste marker as live prompt acceptance after the actual keystrokes were dropped. This violates Constitution III's false-positive prohibition and the frozen intent's no-liveness-timeouts rule: correctness must come from event-confirmed delivery and authoritative transcript acceptance, not from wall-clock failure reaping.

## What Changes

- **BREAKING (internal confirmation semantics):** Replace PTY echo / Enter-detection as the authoritative submission gate with a new transcript user-record acceptance gate: a prompt is accepted only when Claude Code appends a new post-baseline user record to its session transcript.
- Gate prompt delivery on the host TUI's `ESC[?2004h` bracketed-paste-enable sentinel so typing begins only after the input surface is live.
- Deliver prompt bytes as an explicit bracketed paste (`ESC[200~` + prompt + `ESC[201~`) and send submit `\r` as a separate PTY event after the paste closes.
- Preserve the no-liveness-timeouts architecture: readiness and acceptance waits are event waits with no wall-clock cap; `PromptNotAccepted` is raised only from a positive non-acceptance/terminal observation, not elapsed time.
- Restate the affected constitution/domain/spec language so transcript-record acceptance is the approved authoritative evidence and the old echo-scan/paste-pill evidence is transitional or removed, not silently retained.
- Add regression coverage proving the Reliability bar: (1) replayed-history echo/paste evidence does not falsely accept without a new transcript user record, and (2) a real submitted prompt is accepted by the new transcript user record.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `prompt-echo-confirmation`: Replace echo-based prompt acceptance with deterministic prompt submission acceptance: readiness-gated bracketed-paste delivery plus transcript user-record acceptance, no wall-clock liveness timeout, and fail-closed behavior on positive terminal/non-acceptance signals.

## Impact

### Affected files

- `src/driver.zig` — submit state machine, prompt delivery framing, readiness sentinel detection, transcript user-record baseline/acceptance helper, and tests.
- `openspec/constitution.md` — reconcile pre-Enter echo-confirm wording with the two-phase readiness + transcript-record acceptance model.
- `openspec/domain.md` — restate prompt submission invariants away from PTY echo as authoritative truth and toward transcript-record acceptance.
- `openspec/specs/prompt-echo-confirmation/spec.md` and delta spec under this change — restate requirements and scenarios for transcript-record acceptance.

### Affects which projects

- `claude-p` directly.
- `pi-claude-bridge` indirectly after implementation, via a separate downstream follow-up to pin/guard the updated fork. No bridge changes are in scope for this OpenSpec change.

### Non-goal impact exclusions

- No `claude -p`, `--print`, stream-json input, `--remote-control`, cloud-relay control path, bridge-side liveness timer, model/quota/auth change, or MCP protocol change.
