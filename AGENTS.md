# Agent Tooling

This repository contains the public macOS app and its Raycast companion.
`CLAUDE.md` imports these instructions.

## Public content

- Keep personal catalogs, workstation profiles, employer integrations, account
  details, private URLs, credentials, and machine-specific paths out of source,
  fixtures, documentation, screenshots, and release artifacts.
- Use synthetic fixtures and public client interfaces. Capture screenshots in
  an isolated home and workspace.
- Run `./scripts/validate-static` and review the diff before committing. Scan
  for secrets separately with Gitleaks; the public-content check is not a
  credential detector.
- Do not commit, push, publish releases, or rewrite history without the user's
  authorization. Changes to existing Git history need explicit approval.

## macOS app

- Swift sources live in `apps/agent-tooling-macos`. Targets are
  `AgentToolingCore`, `AgentToolingApp`, `AgentToolingMCP`, and `AgentToolingCLI`.
- Build with `swift build --disable-sandbox`; test with
  `swift test --disable-sandbox`. CI also checks release builds with
  `-Xswiftc -warnings-as-errors` and tests with Thread Sanitizer.
- Reuse `Tests/AgentToolingTestSupport` for shared fixtures and helpers.
- Keep declarations internal unless another target needs them.
- Use `DesignTokens.swift` for view dimensions and `.wrapsLines()` for text
  that wraps; avoid `fixedSize(horizontal: false, vertical: true)`.
- Client writes must use reviewed plans through `OperationEngine` and
  `OperationCommandPolicy`.
- Keep secrets out of portable documents and redact MCP responses through
  `ResponseRedaction`.
- Write comments to explain constraints and non-obvious decisions. Prefer
  clear names over comments that narrate the code.

## Distribution

- Validate the finished app's resources and the mounted DMG.
- Public binaries must pass Developer ID verification, notarization, and
  Gatekeeper assessment. Keep release approval and signing checks intact.
- Keep documentation consistent with the currently available downloads.
