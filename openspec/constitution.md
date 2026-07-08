# claude-p Constitution

**Version:** 2.0.0
**Ratified:** 2026-06-16
**Last updated:** 2026-07-07

## Core Principles

### I. Prompt submission must be authoritatively confirmed before generation is trusted
`claude-p` MUST confirm that the host Claude Code session accepted the prompt before treating a turn as submitted or waiting on generation results. The authoritative confirmation signal is a new post-baseline user-message record in Claude Code's active session transcript. Pre-submit readiness evidence (such as the host enabling bracketed paste) may gate delivery, but PTY echo, collapsed-paste rendering, chrome text, or replayed history MUST NOT be the authoritative acceptance gate.

**Rationale:** A dropped prompt can otherwise wedge or run the wrong turn, and a replayed-history echo can falsely confirm a prompt that never reached the live input box.
**Enforcement:** Specs define accepted readiness and transcript evidence; analyze checks AC/design coverage; tests cover accepted submissions, replayed-history false positives, and rejected evidence.

### II. Host TUI input readiness is observable protocol
The PTY byte stream from Claude Code/Ink is treated as an observable protocol boundary for input-readiness events and terminal-control behavior. Driver logic MUST tolerate terminal-control sequences and display-only renderings, but display rendering is not authoritative prompt-acceptance evidence once transcript-record confirmation is available.

**Rationale:** `claude-p` drives an interactive TUI rather than a stable print-mode API, so it must wait for a live input surface while avoiding screen-scrape false positives.
**Enforcement:** Domain invariants document known readiness events and display renderings; design and tests must use captured PTY bytes for readiness and replay regressions.

### III. False-positive prompt acceptance is forbidden
Prompt acceptance MUST remain conservative: unrelated TUI output, chrome, random text, literal prompt echoes, and approved paste-collapse markers cannot confirm a prompt unless a new post-baseline transcript user record also appears. Missing echo evidence or elapsed time alone MUST NOT cause `PromptNotAccepted`; non-acceptance is reported only from positive terminal or non-acceptance evidence.

**Rationale:** Submitting or trusting a prompt that was not accepted corrupts bridge correctness. Reaping slow or delayed submissions with liveness timers is also forbidden because long parked turns must survive.
**Enforcement:** Specs include negative acceptance criteria; regression tests assert replayed output is rejected, transcript user records are required, and submission waits are event-based rather than wall-clock-capped.

### IV. Surgical fixes over broad rewrites
Bug fixes MUST minimize file and behavior scope, preserving existing public flags, output formats, dependencies, and successful short-prompt behavior unless the change explicitly modifies them.

**Rationale:** This CLI is consumed by automation and bridge code that depends on stable behavior.
**Enforcement:** Tasks carry file contracts; validation runs `zig build -Doptimize=ReleaseSafe` and `zig build test`.

## Governance

- Amendments to this constitution require a dedicated OpenSpec change with review.
- The constitution is read before every artifact in the `opsx-superpowers` schema.
- Principles in this file override individual artifact prose when they conflict.

## Versioning

- Major: a principle is removed or reversed.
- Minor: a principle is added.
- Patch: clarification, no semantic change.

## See also

- Domain invariants: `openspec/domain.md`
