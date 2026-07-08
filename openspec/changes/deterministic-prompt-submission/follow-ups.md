# Follow-ups

<!-- authored: in-session -->

**Change:** deterministic-prompt-submission
**Created:** 2026-07-07 (downstream integration routing)

## Queue

| # | Finding | Severity | Origin (review type, round) | Routing reason | Status |
|---|---|---|---|---|---|
| 1 | Update `pi-claude-bridge` to pin/guard the claude-p commit that contains transcript-backed prompt acceptance, and add bridge-side scenario coverage for no silent warm-resume hang. | P2 | frozen intent / proposal impact | Downstream bridge integration is explicitly out of scope for this `claude-p` change; not required to satisfy this repo's driver implementation ACs. | open |

## Waivers

- None.

## Promotion

- #1 — recommended successor change in `pi-claude-bridge` after this claude-p change is merged/tagged.
