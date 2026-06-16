# claude-p Domain

**Version:** 1.0.0
**Last updated:** 2026-06-16

## Entities

- **Prompt** — User-supplied bytes that `claude-p` types into the interactive Claude Code input box.
- **Host TUI** — The Claude Code Ink terminal UI that renders input, chrome, hints, and hooks inside the PTY.
- **PTY recent buffer** — Rolling window of raw bytes emitted by the host TUI and read by the driver during startup and prompt submission.
- **Echo confirmation** — Driver decision that typed prompt bytes were accepted by the host TUI and it is safe to send Enter.
- **Collapsed paste placeholder** — Host TUI display form for long pasted input, observed as `[Pasted ESC[11G text ESC[16G #1]` plus `paste again to expand` instead of literal prompt text.

## Invariants

1. `claude-p` types prompts into an interactive Claude Code TUI, not into Claude Code native print mode.
2. The driver sends the prompt and submit Enter as separate PTY events.
3. Echo confirmation occurs before Enter is sent.
4. Short prompts can be displayed literally in the input box and are confirmed by a prompt-derived alphanumeric needle.
5. Long prompts at the observed threshold can be accepted by the host TUI while being displayed only as a collapsed paste placeholder.
6. Terminal-control sequences in the PTY buffer are display controls, not prompt content.
7. After CSI stripping, the observed collapsed placeholder can project as `Pastedtext#1` without a space.
8. The host hint phrase `paste again to expand` is evidence of the collapsed paste rendering.
9. Unrelated TUI output cannot prove prompt acceptance.
10. If confirmation evidence never appears after the bounded retry budget, the driver exits with `PromptNotAccepted`.

## Units and conventions

- **Prompt size**: bytes.
- **Terminal escapes**: raw byte sequences in the PTY stream; CSI begins with `ESC [`.
- **Zig version**: 0.15.2.
- **Validation**: release build uses `zig build -Doptimize=ReleaseSafe`; unit tests use `zig build test`.
- **Acceptance criterion IDs**: `<capability>.<requirement-slug>` and must appear in tests.

## Out-of-scope domains

- Claude Code authentication, quota, model selection, or API behavior.
- Bridge scheduling or concurrency changes outside this CLI.
- Replacing the interactive TUI driver with Claude Code native print mode.
- Changing transcript parsing, output formats, or MCP readiness behavior.

## See also

- Constitution: `openspec/constitution.md`
