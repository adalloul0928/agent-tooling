# Agent Tooling Control Center — product brief

## Recommendation

Build the product as a native SwiftUI macOS application. The control center is intentionally local and Mac-specific, and authentic Liquid Glass, native window behavior, SF Symbols, keyboard support, accessibility, sheets, and system file panels matter more here than sharing a renderer with another platform. The repository now includes the native implementation under `apps/agent-tooling-macos`.

SwiftUI is also the quickest route to the requested visual quality. macOS provides the native window material, traffic-light controls, focus behavior, buttons, sheets, and adaptive contrast directly. The design reserves translucency for the single native window; controls, rows, and operational groups use calm, solid system surfaces so the app never becomes a stack of glass cards.

The privileged boundary should remain small and typed. Do not expose a general terminal to the view layer: every action should map to a named operation with validated arguments, a preview, a cancellable process, and a structured receipt. Existing client CLIs remain the execution engine behind that registry; a repository is an optional import/export source, not the operational database or a prerequisite for using the product.

## Product promise

Create once, review every target operation, then verify the observed result.

The app should answer four questions immediately:

1. What tooling is installed on this Mac?
2. Do Codex, Claude Code, Gemini CLI, and the selected scoped profile agree?
3. What needs attention, and what exact action will fix it?
4. What changed after the app ran an action?

## Core surfaces

- **Overview:** machine health, local workspace, active profile, drift, required attention, recent activity, and doctor/sync actions.
- **Skills:** owned and vendor skill inventory, bundle/source/scope, trigger phrases, files, client availability, collision checks, validation, and reveal-in-library actions.
- **Create skill:** guided purpose and trigger interview, negative trigger, collision detection, bundled files, target selection, and a reviewable local install plan. Git backup is optional.
- **MCP servers:** configured versus usable state, client and scope, transport, authentication, approval, launch-wrapper health, secrets by name only, test, login, restart, and exact repair commands.
- **Plugins:** installed and available bundles, marketplace source, scope, revision parity, included skills/MCPs, updates, enablement, and profile membership.
- **Profiles:** user/project/workspace desired-state editor, inheritance, resolved composition, machine drift, and manual checks.
- **Marketplace:** imported local/checked-out Agent Plugins packages, native Claude/Codex catalog discovery, and target-specific native install routes. Gemini remains its native gallery/CLI flow.
- **Accounts & connectors:** explicit cloud/account surfaces and a metadata-only connection inventory that never stores credentials.
- **Sync center:** local source → target plan → independent client result → fresh local scan, with partial success retained.
- **Activity and receipts:** command preview, duration, exit state, affected files, redacted output, and rollback guidance.
- **Settings:** local workspace, optional source import, detected CLIs, local Git backup/restore review, log redaction, and advanced paths.

## Safety contract

- Run local packaged code only; never load remote UI with privileged access.
- Keep command execution behind a dedicated, allowlisted operation service.
- Use an allowlisted operation registry and argument arrays, not arbitrary shell strings.
- Show the command and affected scope before writes.
- Redact environment values and secrets; display secret names only.
- Keep destructive operations behind explicit confirmation and a diff/target preview.
- Treat each client independently so one failure does not erase the other client's success.
- Re-scan local configuration after a sync instead of trusting exit status alone.

## Delivery sequence

1. **Complete:** native macOS window shell plus Overview, Skills, MCPs, Plugins, Profiles, Marketplace, Accounts, Sync Center, Activity, and Settings.
2. **Complete:** persistent SQLite workspace, managed local package library, scoped profile composition, read-only local scanner, allowlisted operation plans/receipts, native MCP commands, optional local Git export/restore review, native Claude/Codex catalog discovery, opt-in AES-GCM encrypted folder sync with a Keychain recovery key, and imported data-only managed-policy manifests that distribute managed profiles and block named plugins.
3. **Next product increment:** add full client adapters for project-level Codex placement, streaming/cancellable command execution, and post-restart canaries where the client exposes a safe probe.
4. **Invariant:** neither encrypted sync nor a managed policy source becomes a hidden requirement for local use.

## Primary references

- [Apple Human Interface Guidelines: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple Human Interface Guidelines: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [SwiftUI](https://developer.apple.com/xcode/swiftui/)
- [Bringing Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
