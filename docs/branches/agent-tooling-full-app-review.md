# Agent Tooling full app review

- Status: Ready for review
- Branch: `origin/codex/agent-tooling-full-app-review`
- Base: `origin/main` at `483b330`
- Updated: 2026-09-03

## Purpose

Harden and polish the Agent Tooling control plane after a full application review, with an emphasis on safer external requests, faster navigation, and smoother macOS interactions.

## Changes

- Added a review-first request boundary, safer installation checks, skill source editing, and richer collection workflows.
- Refined client-scoped navigation, Settings motion, Marketplace search and filters, accessibility, and responsive layout behavior.
- Hardened process execution, scanning and redaction, release packaging, and Raycast installation handling.
- Improved iOS session-lane tooling and the Life OS runtime with expanded regression coverage.

## Verification

- `swift test --disable-sandbox` passed: 452 tests, with one credential-dependent test skipped.
- `./scripts/validate-static` passed: 53 tests across 48 skills and 5 profiles.
- Strict formatting lint passed for every changed Swift file.
- Signed app packaging and `codesign --verify --deep --strict` passed.
- Rendered Settings and Marketplace visual QA passed.
- `git diff --check` passed.

## Open items

- Hosted GitHub Actions, Developer ID signing, notarization, and release publication remain external gates.

## Revisions

| Date | Revision |
| --- | --- |
| 2026-09-03 | Implemented the full app review, UI motion and Marketplace polish, and hardening changes. |
