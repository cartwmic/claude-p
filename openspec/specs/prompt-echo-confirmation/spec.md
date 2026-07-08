# Capability: prompt-echo-confirmation

## Purpose

Defines how `claude-p` delivers a prompt to the interactive Claude Code TUI and confirms submission acceptance without relying on PTY echo as authoritative evidence. Prompt delivery is gated by an input-readiness event, prompt bytes are sent as bracketed paste, and acceptance is confirmed by a new post-baseline user-message record in the active Claude Code session transcript. Submission waits are event-based and do not use liveness timeouts.

## Requirements

### Requirement: Prompt Delivery Readiness Is Event-Gated

`claude-p` SHALL NOT write prompt bytes to the host TUI until the host input surface has emitted an approved readiness event.

#### Scenario: Bracketed-paste enable sentinel appears
- **WHEN** the PTY stream emits `ESC[?2004h`
- **THEN** the driver SHALL treat the host input surface as ready for prompt delivery

#### Scenario: Readiness sentinel has not appeared
- **IF** the PTY stream has not emitted `ESC[?2004h`
- **THEN** the driver SHALL continue waiting for the readiness event without writing prompt bytes
- **AND** the driver SHALL NOT fail the submission due solely to elapsed time

### Requirement: Prompt Delivery Uses Bracketed Paste

`claude-p` SHALL deliver prompt bytes as an explicit bracketed paste and SHALL keep the submit Enter as a separate PTY event.

#### Scenario: Prompt is delivered after readiness
- **GIVEN** the host input surface is ready
- **WHEN** `claude-p` delivers a prompt
- **THEN** the driver SHALL write `ESC[200~`, the exact prompt bytes, and `ESC[201~` in that order
- **AND** the driver SHALL write the submit `\r` only after `ESC[201~` has been written

#### Scenario: MCP readiness hold is configured
- **GIVEN** `--mcp-ready-file` is configured
- **AND** the prompt paste has completed
- **WHEN** the MCP ready sentinel file does not exist
- **THEN** the driver SHALL hold the submit `\r` until the sentinel file exists

### Requirement: Transcript User Record Confirms Submission

`claude-p` SHALL treat a prompt submission as accepted only when Claude Code's session transcript contains a new user-message record for the active session after the pre-submit baseline.

#### Scenario: New post-baseline user record appears
- **GIVEN** the driver recorded the active session transcript baseline before submitting the prompt
- **WHEN** the transcript contains a new user-message record after that baseline
- **THEN** the driver SHALL treat the submitted prompt as accepted

#### Scenario: No new post-baseline user record appears
- **GIVEN** the driver recorded the active session transcript baseline before submitting the prompt
- **WHEN** the PTY stream contains prompt-like text but the transcript contains no new user-message record after that baseline
- **THEN** the driver SHALL keep the submitted prompt unaccepted

### Requirement: Replayed History Does Not Confirm Submission

Text rendered from resume history, prior turns, prompt echoes, or collapsed-paste placeholders SHALL NOT confirm the current prompt submission unless a new post-baseline transcript user record also appears.

#### Scenario: Prior prompt appears in replayed PTY output
- **GIVEN** the PTY recent buffer contains the current prompt text from replayed history before live delivery
- **AND** no new post-baseline transcript user record appears
- **WHEN** the driver evaluates submission acceptance
- **THEN** the driver SHALL keep the submitted prompt unaccepted

#### Scenario: Prior collapsed-paste marker appears in replayed PTY output
- **GIVEN** the PTY recent buffer contains a collapsed-paste marker such as `[Pasted ESC[11G text ESC[16G #1]` from replayed history
- **AND** no new post-baseline transcript user record appears
- **WHEN** the driver evaluates submission acceptance
- **THEN** the driver SHALL keep the submitted prompt unaccepted

### Requirement: Submission Handshake Has No Liveness Timeout

`claude-p` SHALL NOT use wall-clock elapsed time, fixed attempt windows, or retry clocks to decide that a prompt submission failed or should be re-delivered.

#### Scenario: Readiness or transcript acceptance is delayed
- **WHEN** the readiness event or transcript user-record event has not appeared yet
- **THEN** the driver SHALL continue waiting for the event
- **AND** the driver SHALL NOT exit with `PromptNotAccepted` due solely to elapsed time

#### Scenario: Child exits before acceptance
- **WHEN** the child process exits or reports a terminal error before a post-baseline transcript user record appears
- **THEN** the driver SHALL surface the terminal failure instead of treating replayed PTY output as submission acceptance

### Requirement: Prompt Not Accepted Is Positive-Signal Only

`claude-p` SHALL report `PromptNotAccepted` only from positive evidence that the current submission cannot have been accepted, never from missing echo evidence or elapsed time alone.

#### Scenario: Positive non-acceptance observation occurs
- **WHEN** the driver observes a positive terminal non-acceptance signal for the active submission
- **AND** no new post-baseline transcript user record appears
- **THEN** the driver SHALL exit with `PromptNotAccepted`

#### Scenario: Echo evidence is absent
- **WHEN** literal echo, paste-collapse marker, and paste-collapse hint evidence are absent from the PTY recent buffer
- **THEN** the driver SHALL NOT exit with `PromptNotAccepted` due solely to absent echo evidence
