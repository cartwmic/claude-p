# Capability: api-error-turns

## ADDED Requirements

### Requirement: Transcript API Error Ends Turn

`claude-p` SHALL treat a new API-error assistant record followed by a turn-duration system record as completion of the live turn, independent of the Stop hook.

#### Scenario: API error assistant and turn duration appear after baseline
- **WHEN** the live transcript grows past the resume baseline with an assistant record whose `isApiErrorMessage` is `true`
- **THEN** the driver SHALL capture the assistant error text

#### Scenario: Turn duration confirms API error flush
- **WHEN** a `system` record with subtype `turn_duration` follows the new API-error assistant record
- **THEN** the driver SHALL treat the API-error turn as terminal without waiting for the Stop hook

### Requirement: Retryable API Errors Are Resubmitted Boundedly

`claude-p` SHALL retry transient upstream API-error turns by resubmitting the same live prompt to the still-running interactive session, bounded by `CLAUDE_P_API_ERROR_RETRIES`.

#### Scenario: Transient API error is detected
- **WHEN** the captured API-error text contains overload, capacity, service-unavailable, HTTP 529, HTTP 503, or rate-limit/HTTP 429 wording case-insensitively
- **THEN** the driver SHALL classify the API error as retryable

#### Scenario: Retry budget remains
- **WHILE** the retry budget remains, **WHEN** a retryable API-error turn is confirmed
- **THEN** the driver SHALL sleep for a small bounded inter-attempt backoff, re-baseline the transcript, resubmit the same prompt, and resume waiting for the next turn-end

### Requirement: Non Retryable API Errors Fail Fast

`claude-p` SHALL fail the invocation promptly for API-error turns that are not classified as transient.

#### Scenario: Permanent API error is detected
- **IF** the captured API-error text does not match a retryable transient pattern
- **THEN** the driver SHALL return `RunError.ApiError` with a diagnostic containing the captured upstream error text

### Requirement: Exhausted API Error Retries Fail Fast

`claude-p` SHALL fail the invocation promptly when retryable API-error turns exceed the configured retry budget.

#### Scenario: Retry budget exhausted
- **IF** a retryable API-error turn is confirmed after `CLAUDE_P_API_ERROR_RETRIES` retries have already been attempted
- **THEN** the driver SHALL return `RunError.ApiError` with a diagnostic containing the captured upstream error text and total attempts

### Requirement: Normal Assistant Turns Are Not API Errors

`claude-p` SHALL preserve normal successful turn completion semantics.

#### Scenario: Normal assistant turn appears
- **WHEN** a new assistant record does not carry `isApiErrorMessage:true`
- **THEN** the transcript API-error detector SHALL NOT classify the turn as an API error

---

## Acceptance criterion quality checklist

| AC ID | Testable | Solution-free | Unambiguous | Consistent | Complete |
|---|---|---|---|---|---|
| api-error-turns.transcript-api-error-ends-turn | [x] | [x] | [x] | [x] | [x] |
| api-error-turns.retryable-api-errors-are-resubmitted-boundedly | [x] | [x] | [x] | [x] | [x] |
| api-error-turns.non-retryable-api-errors-fail-fast | [x] | [x] | [x] | [x] | [x] |
| api-error-turns.exhausted-api-error-retries-fail-fast | [x] | [x] | [x] | [x] | [x] |
| api-error-turns.normal-assistant-turns-are-not-api-errors | [x] | [x] | [x] | [x] | [x] |
