## 1. OpenSpec setup

- [ ] 1.1 Commit opsx-superpowers project context and change artifacts
  - intent: infra
  - files_allowed:
      - openspec/**
      - .claude/commands/opsx/**
      - .pi/prompts/opsx-*.md
  - files_forbidden:
      - src/**
      - tests/**
  - allow_new_files: true

## 2. Echo-confirm bug fix

- [ ] 2.1 Add regression coverage for literal echo, captured collapsed paste, and unrelated output
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - files_forbidden:
      - "**/*.bak"
      - "**/secrets/**"
  - allow_new_files: false

- [ ] 2.2 Implement normalized paste-collapse marker detection without weakening failure detection
  - intent: fix
  - files_allowed:
      - src/driver.zig
  - files_forbidden:
      - "**/*.bak"
      - "**/secrets/**"
  - allow_new_files: false

## 3. Validation and verify artifact

- [ ] 3.1 Run final build and test validators and record results in verify.md
  - intent: fix
  - files_allowed:
      - openspec/changes/echo-confirm-paste-collapse/tasks.md
      - openspec/changes/echo-confirm-paste-collapse/verify.md
      - src/driver.zig
  - files_forbidden:
      - "**/*.bak"
      - "**/secrets/**"
  - allow_new_files: true
