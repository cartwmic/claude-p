# claude-p Domain

**Version:** 2.0.0
**Last updated:** 2026-07-07

## Entities

- **Prompt** — User-supplied bytes that `claude-p` delivers into the interactive Claude Code input box.
- **Host TUI** — The Claude Code Ink terminal UI that renders input, chrome, hints, and hooks inside the PTY.
- **Input readiness event** — PTY evidence that the Host TUI input surface is live and ready to receive pasted input; the approved event for this change is `ESC[?2004h` (bracketed-paste enable).
- **Bracketed paste delivery** — Prompt write framed as `ESC[200~` + exact prompt bytes + `ESC[201~`, followed by a separate submit Enter (`\r`).
- **Session transcript** — Claude Code's active on-disk JSONL session record used as authoritative post-submit evidence.
- **Transcript user-record acceptance** — Driver decision that the active session transcript contains a new user-message record after the pre-submit baseline, proving the current prompt was accepted.
- **PTY recent buffer** — Rolling window of raw bytes emitted by the host TUI and read by the driver during startup and prompt submission; useful for readiness and diagnostics, not authoritative prompt acceptance.
- **Collapsed paste placeholder** — Host TUI display form for long pasted input, observed as `[Pasted ESC[11G text ESC[16G #1]` plus `paste again to expand` instead of literal prompt text.

## Invariants

1. `claude-p` delivers prompts into an interactive Claude Code TUI, not into Claude Code native print mode.
2. The driver sends prompt bytes and submit Enter as separate PTY events.
3. Prompt delivery waits for an input readiness event before writing prompt bytes.
4. Prompt bytes are delivered as bracketed paste: `ESC[200~`, exact prompt bytes, `ESC[201~`.
5. Submit Enter is written only after bracketed paste closes and, when configured, after the MCP ready-file sentinel exists.
6. Prompt acceptance is confirmed by a new post-baseline user-message record in the active session transcript.
7. PTY echo, literal prompt text, collapsed-paste placeholders, and host hints are display evidence only; they cannot authoritatively confirm the current prompt submission.
8. Replayed resume history in the PTY recent buffer cannot prove acceptance of the current prompt.
9. Terminal-control sequences in the PTY buffer are display controls, not prompt content.
10. Long prompts can be accepted by the host TUI while being displayed only as a collapsed paste placeholder.
11. Missing echo evidence or elapsed time alone cannot produce `PromptNotAccepted`.
12. `PromptNotAccepted` is produced only from positive terminal or non-acceptance evidence for the active submission.
13. Readiness and transcript acceptance waits are event waits with no wall-clock liveness timeout.

## Units and conventions

- **Prompt size**: bytes.
- **Terminal escapes**: raw byte sequences in the PTY stream; CSI begins with `ESC [`.
- **Bracketed paste sequences**: paste start is `ESC[200~`; paste end is `ESC[201~`; readiness enable is `ESC[?2004h`.
- **Transcript baseline**: the active session transcript state recorded immediately before submitting the prompt.
- **Zig version**: 0.15.2.
- **Validation**: release build uses `zig build -Doptimize=ReleaseSafe`; unit tests use `zig build test`.
- **Acceptance criterion IDs**: `<capability>.<requirement-slug>` and must appear in tests.

## Out-of-scope domains

- Claude Code authentication, quota, model selection, or API behavior.
- Bridge scheduling or concurrency changes outside this CLI.
- Replacing the interactive TUI driver with Claude Code native print mode.
- Switching to Claude Code remote-control or any cloud-relayed control channel.
- Changing transcript output formats or MCP readiness behavior.
- Introducing liveness timeouts, watchdogs, or wall-clock caps.

## See also

- Constitution: `openspec/constitution.md`
