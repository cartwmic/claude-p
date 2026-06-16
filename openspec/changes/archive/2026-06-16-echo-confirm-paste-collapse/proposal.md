## Why

`claude-p` deterministically exits `PromptNotAccepted` for prompts at or above the observed 801-byte threshold because Claude Code/Ink accepts the prompt but displays a collapsed paste placeholder instead of the literal text. This violates Constitution I and III: prompt submission must be confirmed, but accepted paste-collapse evidence must not be missed.

## What Changes

- Teach prompt echo confirmation to accept normalized collapsed-paste evidence from the PTY buffer.
- Preserve the existing literal prompt-needle confirmation path for short prompts.
- Preserve conservative failure behavior: unrelated PTY output still fails confirmation and leads to `PromptNotAccepted` after retries.
- Add Zig unit coverage with the captured raw placeholder sequence `[Pasted\x1b[11Gtext\x1b[16G#1]` and hint line `paste again to expand`.
- **BREAKING**: none.

## Capabilities

### New Capabilities
- `prompt-echo-confirmation`: Driver confirms prompt acceptance from literal echo or approved collapsed-paste rendering while rejecting unrelated output.

### Modified Capabilities
- None; this repository has no existing OpenSpec capability specs yet.

## Impact

### Affected files
- `src/driver.zig`: echo-confirmation helper and unit tests.
- `openspec/constitution.md`, `openspec/domain.md`: initial project principles and invariants for opsx-superpowers.
- `openspec/changes/echo-confirm-paste-collapse/**`: change artifacts.

### Affected systems
- Runtime behavior of `claude-p` prompt submission for long prompts rendered by Claude Code/Ink as collapsed paste placeholders.
- No CLI flag, API, dependency, transcript, or output-format changes.
