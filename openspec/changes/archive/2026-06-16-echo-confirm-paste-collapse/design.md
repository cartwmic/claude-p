## Context

`src/driver.zig` confirms a typed prompt before sending Enter by checking the PTY recent buffer for either an alphanumeric literal echo needle or the literal paste marker `Pasted text`. Controlled reproduction proved that Claude Code/Ink accepts prompts at and above 801 bytes but renders a display-only collapsed paste placeholder instead of the literal prompt.

Captured raw placeholder bytes:

```text
[Pasted\x1b[11Gtext\x1b[16G#1]\x1b[7m \r\x1b[2C\x1b[2B\x1b[27m\x1b[38;5;246mpaste again to expand
```

After CSI stripping, the visible projection is `Pastedtext#1`, not `Pasted text`. The existing literal paste marker therefore misses accepted prompts. This design respects Constitution I by preserving confirmation before Enter, Constitution II by treating TUI rendering as protocol, Constitution III by keeping unrelated output rejected, and Domain invariants 5–9 about collapsed paste evidence.

## Goals / Non-Goals

**Goals:**
- Confirm short prompts via the existing literal echo path.
- Confirm long prompts when recent PTY output contains normalized collapsed paste evidence: `Pastedtext` after terminal-control and whitespace normalization, or `paste again to expand`.
- Reject unrelated output so genuinely dropped prompts still fail with `PromptNotAccepted` after retries.
- Cover behavior with Zig unit tests that cite canonical AC IDs.

**Non-Goals:**
- No bridge scheduling or concurrency change.
- No change to retry count, timeout, MCP readiness, transcript parsing, CLI flags, or dependencies.
- No integration test requiring live Claude Code auth or paid model turns.

## Decisions

### D1: Normalize paste-collapse marker matching instead of removing echo confirmation

**Choice:** Keep `echoConfirms` as the confirmation gate and add normalized paste-marker matching to it. The helper will continue accepting literal echo needles and will additionally accept `Pastedtext` in an alphanumeric projection plus the stripped hint phrase `paste again to expand`.

**Alternatives considered:**
- **Remove echo confirmation for long prompts**: avoids the false negative but violates Constitution I and III because dropped prompts would be submitted or trusted.
- **Increase retries or wait time**: does not fix deterministic marker mismatch; root cause is the rendered placeholder string, not timing.
- **Search only for literal `Pasted text`**: current behavior; fails because Ink splits words with CSI cursor moves and no space remains after stripping.

**Rationale:** The fix targets the proven mechanism and only expands accepted evidence to host-rendered proof that the prompt was accepted.

**4-point test:** multiple approaches yes; lasting consequences low; disagreement low; future constraint low → ADR candidate no.

### D2: Match two approved paste-collapse signals

**Choice:** Accept either the alphanumeric-normalized marker projection `Pastedtext` or the stripped hint phrase `paste again to expand`.

**Alternatives considered:**
- **Require both marker and hint**: too brittle because a future frame may contain only one signal in the rolling recent buffer.
- **Accept any `Pasted` substring**: too broad; unrelated UI text could false-confirm.
- **Parse the whole Ink layout**: unnecessary and larger than the bug fix.

**Rationale:** The two signals are specific to collapsed paste rendering and come from captured PTY evidence. Alphanumeric normalization handles CSI splits and whitespace drift while avoiding broad substring acceptance.

**4-point test:** multiple approaches yes; lasting consequences low; disagreement low; future constraint low → ADR candidate no.

### D3: Keep tests at pure helper level

**Choice:** Add unit tests around `echoConfirms` with the captured raw sequence normalized through `stripCsi` and `alnumCopy`.

**Alternatives considered:**
- **Live PTY integration test**: higher fidelity but requires Claude Code availability and can consume auth/model resources.
- **No regression test**: unacceptable because this is a deterministic parser bug.

**Rationale:** The helper is pure, already unit-tested, and captures the exact acceptance decision without external process flake.

**4-point test:** multiple approaches yes; lasting consequences low; disagreement low; future constraint low → ADR candidate no.

## Risks / Trade-offs

| # | Risk | Likelihood | Severity | Mitigation |
|---|---|---|---|---|
| R1 | False-positive confirmation from unrelated output containing paste words | Low | High | Match specific normalized `Pastedtext` or full hint phrase; retain negative test. |
| R2 | Short prompt literal echo path regresses | Low | High | Leave literal needle logic first; retain literal echo test. |
| R3 | Captured placeholder changes in future Claude Code | Medium | Medium | Matching allows whitespace/control variation and recognizes the hint phrase. |
| R4 | Unit test overfits to one frame | Low | Medium | Test exact captured sequence plus existing generic placeholder and negative cases. |

## Migration Plan

1. Commit OpenSpec artifacts.
2. Update `src/driver.zig` helper and tests.
3. Run `zig build -Doptimize=ReleaseSafe` and `zig build test`.
4. Commit code and tests.
5. Do not push; orchestrator verifies and pushes.

Rollback: revert the code commit to restore prior literal-only paste marker behavior; no data migration exists.

## Open Questions

- None. Owner pre-approved Scale M, spec-anchored mode, exact fix, validation, and no-push constraint.
