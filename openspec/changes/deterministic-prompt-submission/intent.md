# Intent

Eliminate the silent warm-resume hang and the whole family of interactive-TUI
input races in `claude-p` by making prompt **submission acceptance authoritative
and deterministic in outcome**, rather than inferred from screen-scraped PTY
echo.

Today `claude-p` types the prompt into the Claude Code input box as raw PTY
keystrokes and decides "the prompt was accepted" by scanning the rolling PTY
`recent` buffer for the prompt's echo (`echoConfirms`/`promptEchoConfirmed`).
That inference is unreliable and produces two proven failure modes, worst on
large warm resumes:

1. **Keystrokes dropped** by a not-yet-ready host TUI while it is still rendering
   a large `--resume` replay (live-reproduced: under boot contention the first
   type attempt's echo never appears and a retype is required).
2. **False-positive acceptance**: `echoConfirms` matches the prompt (or a
   `[Pasted text]` collapse marker) that is present in the *replayed history*
   scrollback, not in live input — so the retype recovery is skipped, Enter is
   sent onto a box the keystrokes never reached, no live user turn is written,
   and the spawn hangs indefinitely (silent, no error, no output). This is the
   confirmed root cause of the hung session `87275da4` (pi `019f39bf`).

The intended behavior is a submission handshake whose **acceptance signal is the
model's own persisted transcript**, not the screen:

- **Deliver reliably (eliminate the drop, don't time it out).** Type only after
  the host TUI's input surface is provably live (the child has emitted the
  bracketed-paste-enable sequence `ESC[?2004h`), and deliver the prompt as an
  explicit bracketed paste (`ESC[200~` … `ESC[201~`) so it lands atomically
  regardless of size or render load, with the submit `\r` sent after the
  paste-close so it is an unambiguous Enter rather than buffer content. The
  readiness gate is an **event wait** (the sentinel byte sequence), exactly like
  the existing `--mcp-ready-file` hold — not a wall-clock cap. Because delivery
  targets a confirmed-live surface, the keystroke drop that caused the hang
  cannot occur; correctness comes from readiness, not from timing out a failure.
- **Confirm authoritatively.** Treat submission as accepted only when a **new
  user-message record appears in the session transcript past the pre-submit
  baseline** — Claude Code's own on-disk truth, immune to replayed history and
  paste-collapse rendering. This transcript-record acceptance is the **sole
  authoritative gate**; the PTY echo/Enter-detection path is **retired** once
  this change proves the transcript signal is strictly more reliable (see
  "Reliability bar" below). It is not maintained as a permanent parallel gate.

- **Confirm by event, recover by caller-driven abort — no timers.** Acceptance is
  the appearance of the new user record (an event), waited for without any
  wall-clock cap, mirroring the no-liveness-timeouts model. "No silent hang" is
  achieved by making delivery deterministic (readiness gate + atomic paste), not
  by a submission timeout that reaps a slow-but-alive turn. Any re-delivery is
  triggered by a **positive observation** (e.g. the input surface reports the box
  empty after a completed delivery cycle), never by elapsed time. A terminal
  failure surfaces only on a positive terminal signal (child exit/error) and is
  recovered by the bridge's existing caller-driven-abort + fresh-spawn retry
  gate. The outcome is *confirmed-submitted* or *observably/terminally failed* —
  never a false-positive submission, and never a wedge-reaping timer.

This change deliberately **evolves the confirmation model** from pre-Enter,
PTY-rendered echo evidence to a two-phase model: pre-Enter *delivery-readiness*
(the `ESC[?2004h` gate + bracketed paste) plus post-Enter *transcript-record
acceptance* as the authoritative gate. Because that shifts the authoritative
confirmation to *after* Enter and onto a non-PTY signal, it touches Constitution
principles I–III and Domain invariants 3–10; amending those artifacts to define
transcript-record acceptance as approved evidence is **in scope** for this change
(or a companion constitution change) and must not be done silently.

### Reliability bar (gates retiring the echo path)

Transcript-record acceptance replaces echo/Enter detection **only if this change
demonstrates it is strictly more reliable**, measured on two axes:

1. **No false-accept (must strictly win).** On inputs where the PTY echo-scan
   false-positives — the live prompt or a `[Pasted text]` pill present in the
   replayed-history `recent` buffer with the live keystrokes dropped — the
   transcript-record gate MUST NOT confirm (no new user record ⇒ no acceptance).
   A regression MUST show `echoConfirms`-style acceptance on such input while the
   transcript gate correctly withholds acceptance. This is the defect that hung
   `87275da4`.
2. **No false-reject / reliable detection (event-based, not timed).** A genuinely
   submitted prompt MUST be detected via a new post-baseline user record, waited
   for as an event with no wall-clock cap. Design MUST address the two known
   risks that could make the transcript signal unreliable: (a) asynchronous/late
   transcript flush after submit — handled by waiting for the event, not by a
   window; and (b) transcript rewrite/compaction on warm resume changing the
   baseline count without a live submit — handled by baseline/identity discipline
   (distinguishing a real new user record from a re-flushed replayed one), a
   correctness concern independent of timing. Detection reliability MUST come
   from the readiness-gated deterministic delivery, not from a timeout catching a
   drop.

If the bar is met, the echo path is removed (not left as dead weight); if it is
not met, the change fails closed to `PromptNotAccepted` and the decision returns
to the intent author rather than silently keeping a weaker gate.

## Constraints

- Preserve `claude-p` as an **interactive-TUI driver** on the Claude Code
  subscription quota. Do NOT switch to `claude -p` / `--print` /
  `--input-format stream-json` (separate API/SDK quota) or to `--remote-control`
  (cloud-relayed, device-enrolled — not a local API).
- Keep the confirmation **conservative** (Constitution III): unrelated TUI output
  MUST NOT confirm a submission, and a genuinely dropped/unaccepted prompt MUST
  still end in `PromptNotAccepted`, not a hang.
- Keep prompt and submit-Enter as **separate PTY events** (Domain invariant 2);
  bracketed paste closes before the `\r`.
- Preserve the existing MCP-readiness hold: when `--mcp-ready-file` is set, the
  submit Enter is still held until the sentinel exists.
- Preserve successful short-prompt and long-prompt (>800B collapsed-paste)
  submission; the display-only paste collapse must remain acceptable.
- Preserve the existing warm-resume staleness/baseline, API-error-turn, and usage
  baselining behavior; the new user-record acceptance check composes with the
  existing assistant-turn baseline, it does not replace the staleness guard.
- **No liveness timeouts anywhere** (standing `no-liveness-timeouts` principle):
  no `--timeout`, no submission/acceptance wall-clock cap, no retype budget clock,
  no per-attempt echo window that reaps. Every wait is an **event wait** (the
  `ESC[?2004h` readiness sentinel, the transcript user-record) with no time cap,
  mirroring the existing `--mcp-ready-file` hold. Recovery for a genuine wedge is
  caller-driven abort + the bridge's error/fresh-spawn retry gate on a positive
  terminal signal, never a timer. Boot serialization/scheduling (mutex/semaphore)
  remains acceptable as scheduling, not as a wedge timer.
- Surgical scope (Constitution IV): change the submit path and confirmation
  source in `src/driver.zig` (+ transcript helper) only; keep public flags,
  `--output-format`, dependencies, and env knobs stable.
- Reuse the transcript the driver already opens (`transcript_mod`,
  `turnCountFile`); add a user-record count rather than a new parser subsystem.

## Invariants honored

- Constitution IV: surgical fix; existing flags, output formats, deps, and
  short-prompt success preserved.
- Constitution III (strengthened): false-positive acceptance is eliminated, not
  weakened — the transcript-record signal cannot be forged by replayed history or
  chrome; unaccepted prompts still fail fast with `PromptNotAccepted`.
- Domain invariant 1: still drives the interactive Claude Code TUI, never print
  mode.
- Domain invariant 2: prompt bytes and submit Enter remain separate PTY events.
- Domain invariants 5/7/8: the collapsed-paste placeholder rendering for long
  prompts remains a valid, accepted host behavior (never treated as failure).
- Bridge contract: one `claude-p` spawn still spans one pi user-turn; MCP
  tool-call parking and `--mcp-ready-file` submit-hold semantics are unchanged.

## Constitution / domain evolution required (flagged, not silent)

- Constitution I ("confirm acceptance **before** sending Enter") and Domain
  invariant 3 ("echo confirmation occurs before Enter is sent") must be
  reconciled with the two-phase model, where the *authoritative* acceptance
  proof is the post-Enter transcript record. The design/spec phase MUST either
  restate these to admit transcript-record acceptance as approved evidence or
  justify retaining a pre-Enter echo gate in addition.
- Constitution III's fail-fast wording ("if no evidence appears **within the
  bounded retry budget**, fail fast") must be reconciled with no-liveness-timeouts:
  `PromptNotAccepted` is raised on a **positive** non-acceptance/terminal signal
  (an observed-empty input surface after a completed delivery cycle, or child
  exit/error) — NOT on expiry of a wall-clock budget or retry clock. The
  "bounded retry budget" phrasing MUST be restated in event/observation terms.
- Domain invariants 3–4 and 9–10 (echo-needle confirmation, `PromptNotAccepted`
  on missing echo) are superseded/augmented by transcript-record acceptance and
  MUST be restated in the `prompt-echo-confirmation` capability (full MODIFIED
  restatement discipline) rather than left contradictory.

## Non-goals

- Switching to `claude -p` / `--print` / stream-json input, or `--remote-control`
  / any cloud-relayed control channel.
- True token streaming, PTY screen-diff pseudo-streaming, or parsing the live Ink
  UI as model output.
- Bridge-side liveness timers, watchdogs, or wall-clock generation caps.
- Changing MCP readiness behavior, output formats, model/quota/auth handling, or
  bridge scheduling/concurrency.
- Permanently maintaining the PTY echo/Enter-detection gate in parallel with
  transcript-record acceptance. The echo path is transitional only and is removed
  once the Reliability bar is met (it is NOT a long-lived dual gate); if the bar
  is not met the change fails closed rather than shipping a weaker gate.
- The downstream `pi-claude-bridge` pin bump + guard/scenario coverage (a
  separate, mechanical follow-up change in that repo).
