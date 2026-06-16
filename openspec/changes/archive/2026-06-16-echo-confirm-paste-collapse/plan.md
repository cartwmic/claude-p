# Execution Plan

## Plan step 1: Commit OpenSpec artifacts

- **Covers:** T1.1
- **Pre-conditions:**
  - Baseline `zig build -Doptimize=ReleaseSafe` passed with exit 0.
  - Baseline `zig build test` passed with exit 0.
  - `openspec status --change echo-confirm-paste-collapse --json` reports schema `opsx-superpowers`.
- **Observed Failure:**
    Error verbatim: `claude-p: PromptNotAccepted`
    Repro steps: run real `claude-p` with generated single-line prompt length >=801 bytes; matrix produced 0/5 pass for length 801 and 5/5 pass for length 800.
- **Debugging Trail:**
    Attempt 1 (2026-06-16): concurrency hypothesis ruled out because long opus concurrency-1 failed 5/5 and concurrency-4 failed 20/20 with same error.
    Attempt 2 (2026-06-16): model hypothesis ruled out because long haiku concurrency-1 failed 5/5 with same error.
    Attempt 3 (2026-06-16): auth/quota ruled out because short opus trials passed 5/5.
    Attempt 4 (2026-06-16): raw PTY capture proved Ink collapsed long prompt to `[Pasted ESC[11G text ESC[16G #1]` plus `paste again to expand`; current code searched for literal `Pasted text` and missed.
- **Action:**
  1. Verify all required artifacts exist: proposal, specs, clarify, design, analyze, review, tasks, plan.
  2. Run `openspec validate echo-confirm-paste-collapse --strict`.
  3. Stage OpenSpec initialization/context/change artifacts.
  4. Commit `chore(opsx): specify echo-confirm paste-collapse fix`.
- **Verification:**
  - `openspec status --change echo-confirm-paste-collapse`
  - `openspec validate echo-confirm-paste-collapse --strict`
- **Rollback:**
  - `git reset --soft HEAD~1` before code changes, or revert the OpenSpec commit.

## Plan step 2: Add regression and implementation

- **Covers:** T2.1, T2.2
- **Pre-conditions:**
  - OpenSpec artifacts committed.
  - `src/driver.zig` contains `echoConfirms`, `stripCsi`, and `alnumCopy` helper tests.
- **Action (tdd-preferred micro-tasks):**
  1. Add/adjust tests citing AC IDs:
     - `prompt-echo-confirmation.literal-prompt-echo-confirms-submission`
     - `prompt-echo-confirmation.collapsed-paste-placeholder-confirms-submission`
     - `prompt-echo-confirmation.unrelated-output-does-not-confirm-submission`
  2. Use captured raw bytes in test: `[Pasted\x1b[11Gtext\x1b[16G#1]` plus `paste again to expand`.
  3. Implement minimal helper change: match literal echo first; match normalized `Pastedtext`; match hint phrase.
  4. Run `zig build test` and fix only failures.
  5. Commit `fix(driver): accept Ink collapsed-paste echo marker`.
- **Verification:**
  - `zig build test`
- **Rollback:**
  - Revert the code commit; OpenSpec artifacts remain as design record.

## Plan step 3: Final validation and verify artifact

- **Covers:** T3.1
- **Pre-conditions:**
  - Code/test commit exists locally.
  - No unstaged changes except `tasks.md` checkbox updates and `verify.md` before final commit/amend if needed.
- **Action:**
  1. Mark tasks complete as each finishes.
  2. Run `zig build -Doptimize=ReleaseSafe` and capture final output.
  3. Run `zig build test` and capture final output.
  4. Run `openspec validate echo-confirm-paste-collapse --strict`.
  5. Author `verify.md` with hard checks and final outputs.
  6. If `verify.md` or task checkbox updates occur after the OpenSpec commit, include them in the code/test commit or amend the OpenSpec commit before final report.
- **Verification:**
  - `zig build -Doptimize=ReleaseSafe` exits 0.
  - `zig build test` exits 0.
  - `openspec validate echo-confirm-paste-collapse --strict` exits 0.
- **Rollback:**
  - Revert final code commit; reset task checkbox/verify changes if abandoning apply.

## Completion Verification

- `zig build -Doptimize=ReleaseSafe` → exit 0
- `zig build test` → exit 0
- `openspec validate echo-confirm-paste-collapse --strict` → exit 0
- `git status --short` → clean after commits, except ignored build cache/output

## Manual Adjustments

- TDD-preferred used instead of tdd-required because the pure helper already exists and can be modified with focused unit tests; no live Claude integration required.
