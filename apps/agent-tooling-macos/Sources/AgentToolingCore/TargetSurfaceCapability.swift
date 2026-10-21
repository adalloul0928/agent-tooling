import Foundation

/// Shared planner capability lookup. CLI surfaces with native skill folders
/// support copies. MCP and plugin installs additionally require verified
/// command shapes. Desktop, cloud and IDE surfaces have no local install route.
public enum TargetSurfaceCapability {
    /// A surface's client, but only when that surface is a command-line one
    /// this app installs into. The desktop, cloud and IDE surfaces share a
    /// `ClientKind` with their CLI sibling yet write nothing here, so they
    /// resolve to nothing rather than borrowing the CLI's routes.
    public static func cliClient(for surface: TargetSurface) -> ClientKind? {
        switch surface {
        case .claudeCode: .claude
        case .codexCLI: .codex
        case .geminiCLI: .gemini
        case .kiroCLI: .kiro
        case .claudeDesktop, .claudeCloud, .codexDesktop, .codexCloud,
            .geminiIDE, .geminiCloud:
            nil
        }
    }

    /// Placing a skill is a file copy into the client's own skill folder, which
    /// every CLI has a `NativeSkillDestination` route for. Any CLI surface
    /// qualifies; the copy itself still resolves its destination and the
    /// resolver still decides whether a placement is allowed.
    public static func skillClient(for surface: TargetSurface) -> ClientKind? {
        cliClient(for: surface)
    }

    /// A managed connection is a native command, so a surface qualifies only
    /// when `MCPClientCommand` has a verified command shape for its client.
    /// Every current CLI does — Claude, Codex, Gemini and Kiro all have shapes
    /// verified against a real release in `MCPClientCommand` — so this is the
    /// full set of CLI clients today; the switch is exhaustive over `ClientKind`
    /// so a future client with no shape must be classified here on purpose
    /// rather than inherited by accident.
    public static func managedMCPClient(for surface: TargetSurface) -> ClientKind? {
        guard let client = cliClient(for: surface) else { return nil }
        switch client {
        case .claude, .codex, .gemini, .kiro: return client
        }
    }

    /// A native package install is a command this Mac must have written down.
    /// Only a client whose install command the register holds qualifies, so
    /// Gemini and Kiro — present as clients but with no recorded command — are
    /// refused here even though they can carry skills.
    public static func nativePluginClient(for surface: TargetSurface) -> ClientKind? {
        guard let client = cliClient(for: surface),
            NativePluginInstallRegister.supportsClient(client)
        else { return nil }
        return client
    }
}
