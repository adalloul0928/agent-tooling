import Foundation

/// A variable a person's login shell exports that changes what a client does
/// in a terminal session.
///
/// The app runs every client with an environment of its own, so what a
/// command run from here reports is what a terminal reports only when the
/// shell exports none of these. Each case is documented by its vendor:
/// https://code.claude.com/docs/en/mcp ("Connectors from claude.ai are fetched
/// only when your active authentication method is a claude.ai subscription
/// login"), https://code.claude.com/docs/en/skills ("Where synced skills
/// load"), and https://learn.chatgpt.com/docs/config-file/environment-variables.
public enum AccountShellOverride: String, Codable, CaseIterable, Hashable, Sendable {
    case anthropicAPIKey = "ANTHROPIC_API_KEY"
    case anthropicAuthToken = "ANTHROPIC_AUTH_TOKEN"
    case claudeOAuthToken = "CLAUDE_CODE_OAUTH_TOKEN"
    case anthropicProfile = "ANTHROPIC_PROFILE"
    case claudeBedrock = "CLAUDE_CODE_USE_BEDROCK"
    case claudeVertex = "CLAUDE_CODE_USE_VERTEX"
    case claudeFoundry = "CLAUDE_CODE_USE_FOUNDRY"
    case claudeNoNonessentialTraffic = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    /// Reported only when the shell sets it to `false` or `0`.
    case claudeConnectorsOff = "ENABLE_CLAUDEAI_MCP_SERVERS"
    case claudeConfigDirectory = "CLAUDE_CONFIG_DIR"
    case codexHome = "CODEX_HOME"
    case codexAccessToken = "CODEX_ACCESS_TOKEN"

    public var variable: String { rawValue }

    public var provider: AccountProvider {
        switch self {
        case .codexHome, .codexAccessToken: .chatGPT
        default: .claude
        }
    }

    /// True when the variable takes a terminal session off the subscription,
    /// so the account's contents do not reach it there at all.
    public var replacesSubscription: Bool {
        switch self {
        case .anthropicAPIKey, .anthropicAuthToken, .claudeOAuthToken, .anthropicProfile,
            .claudeBedrock, .claudeVertex, .claudeFoundry:
            true
        case .claudeNoNonessentialTraffic, .claudeConnectorsOff, .claudeConfigDirectory, .codexHome, .codexAccessToken:
            false
        }
    }

    /// What the variable does, in a sentence a row can show.
    public var consequence: String {
        switch self {
        case .anthropicAPIKey:
            "Claude Code in a terminal uses this API key instead of your claude.ai sign-in, so none of your account's connectors, skills or plugins reach it there."
        case .anthropicAuthToken:
            "Claude Code in a terminal sends this token instead of your claude.ai sign-in, so your account's connectors, skills and plugins do not reach it there."
        case .claudeOAuthToken:
            "Claude Code in a terminal uses this long-lived token, which can only make model requests, so your account's connectors, skills and plugins do not reach it there."
        case .anthropicProfile:
            "An Anthropic profile supplies Claude Code's credential in a terminal, so your claude.ai account's connectors do not load there."
        case .claudeBedrock, .claudeVertex, .claudeFoundry:
            "Claude Code in a terminal runs on a third-party provider, so nothing from your claude.ai account reaches it there."
        case .claudeNoNonessentialTraffic:
            "Claude Code in a terminal skips fetching feature flags, and without them it does not sync your account's skills or plugins."
        case .claudeConnectorsOff:
            "claude.ai connectors are turned off for every terminal session started from this shell."
        case .claudeConfigDirectory:
            "Claude Code in a terminal may read a different configuration folder from the ~/.claude this app reads and edits."
        case .codexHome:
            "Codex in a terminal may read a different folder from the ~/.codex this app reads and edits."
        case .codexAccessToken:
            "Codex in a terminal is handed an access token directly, which can name a different account from the one Codex keeps signed in."
        }
    }
}

/// Asks the login shell which of the variables above it exports, by name.
///
/// The script is a fixed string with no interpolation; it prints a marked
/// line for each variable that is set, and never prints a value. The shell is
/// started as Terminal starts one (`-l -i`), because a key is as often in
/// `.zshrc` as in `.zprofile`. Anything else the profile prints is ignored.
enum AccountShellEnvironmentProbe {
    static let marker = "agent-tooling-shell-override:"

    static let script: String = {
        let presence = AccountShellOverride.allCases.filter { $0 != .claudeConnectorsOff }.map(\.variable)
        return "for n in \(presence.joined(separator: " ")); do [[ -n ${(P)n} ]] && print -r -- \"\(marker)$n\"; done; "
            + "[[ ${ENABLE_CLAUDEAI_MCP_SERVERS:-} == (false|0) ]] && print -r -- \"\(marker)ENABLE_CLAUDEAI_MCP_SERVERS\"; true"
    }()

    static let arguments: [String] = ["-l", "-i", "-c", script]

    static func read(runner: any CommandRunning) async -> [AccountShellOverride]? {
        guard let output = try? await runner.run(executable: "/bin/zsh", arguments: arguments, currentDirectory: nil),
            output.status == 0
        else { return nil }
        return parse(output.standardOutput)
    }

    static func parse(_ text: String) -> [AccountShellOverride] {
        let names = Set(
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix(marker) }
                .map { String($0.dropFirst(marker.count)) })
        return AccountShellOverride.allCases.filter { names.contains($0.variable) }
    }
}
