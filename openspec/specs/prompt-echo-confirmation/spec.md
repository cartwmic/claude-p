# Capability: prompt-echo-confirmation

## Purpose

Defines how `claude-p` confirms that the host TUI accepted prompt input before sending Enter, including literal prompt echoes and approved collapsed-paste evidence, while preserving bounded fail-fast behavior when confirmation evidence is absent.

## Requirements

### Requirement: Literal Prompt Echo Confirms Submission

Short prompts that are echoed literally by the host TUI SHALL continue to satisfy echo confirmation before `claude-p` sends Enter.

#### Scenario: Short literal echo appears in recent PTY output
- **WHEN** the PTY recent buffer contains the prompt-derived alphanumeric echo needle
- **THEN** the driver SHALL treat the prompt as accepted

### Requirement: Collapsed Paste Placeholder Confirms Submission

Long prompts that the host TUI accepted but rendered as a collapsed paste placeholder SHALL satisfy echo confirmation when approved paste-collapse evidence appears after terminal-control normalization.

#### Scenario: CSI-split collapsed paste marker appears
- **WHEN** the PTY recent buffer contains the host TUI collapsed paste marker split by terminal-control sequences, such as `[Pasted ESC[11G text ESC[16G #1]`
- **THEN** the driver SHALL treat the prompt as accepted after normalizing terminal controls and marker spacing

#### Scenario: Collapsed paste hint appears
- **WHEN** the PTY recent buffer contains the host TUI hint phrase `paste again to expand`
- **THEN** the driver SHALL treat the prompt as accepted

### Requirement: Unrelated Output Does Not Confirm Submission

Unrelated host TUI output SHALL NOT satisfy echo confirmation.

#### Scenario: No literal echo or paste-collapse evidence appears
- **IF** the PTY recent buffer contains neither the prompt-derived alphanumeric echo needle nor approved paste-collapse evidence
- **THEN** the driver SHALL keep the prompt unconfirmed

### Requirement: Prompt Not Accepted Remains Fail Fast

`claude-p` SHALL preserve bounded fail-fast behavior when the prompt is not confirmed.

#### Scenario: Confirmation evidence never appears after retries
- **IF** echo confirmation remains false after the configured retry attempts
- **THEN** the driver SHALL exit with `PromptNotAccepted`
