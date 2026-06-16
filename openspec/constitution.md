# claude-p Constitution

**Version:** 1.0.0
**Ratified:** 2026-06-16
**Last updated:** 2026-06-16

## Core Principles

### I. Prompt submission must be confirmed before generation
`claude-p` MUST confirm that the host Claude Code TUI accepted the prompt before sending Enter or waiting for a Stop hook. The confirmation gate may recognize equivalent host-rendered evidence, but it MUST NOT be removed or bypassed.

**Rationale:** A dropped prompt can otherwise wedge until timeout or run the wrong turn.
**Enforcement:** Specs define accepted evidence; analyze checks AC/design coverage; tests cover accepted and rejected evidence.

### II. Host TUI rendering is observable protocol
The PTY byte stream from Claude Code/Ink is treated as an observable protocol boundary. Driver logic MUST tolerate terminal-control sequences and display-only renderings that preserve input acceptance semantics.

**Rationale:** `claude-p` drives an interactive TUI rather than a stable print-mode API.
**Enforcement:** Domain invariants document known renderings; design and tests must use captured PTY bytes for regressions.

### III. False-positive prompt acceptance is forbidden
Echo confirmation MUST remain conservative: unrelated TUI output, chrome, or random text cannot confirm a prompt. If no literal echo or approved paste-collapse evidence appears within the bounded retry budget, the driver MUST fail fast with `PromptNotAccepted`.

**Rationale:** Submitting or trusting a prompt that was not accepted corrupts bridge correctness.
**Enforcement:** Specs include negative acceptance criteria; regression tests assert unrelated output is rejected.

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
