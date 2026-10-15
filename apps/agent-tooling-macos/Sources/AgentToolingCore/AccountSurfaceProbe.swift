import Foundation

/// Anything that can say what the hosted accounts put in front of this Mac's
/// clients. The live probe runs the clients; a test hands in a script.
public protocol AccountSurfaceReading: Sendable {
    func read(_ providers: [AccountProvider], depth: AccountSurfaceProbe.Depth, now: Date) async -> [AccountObservation]
}

/// Reads both hosted accounts as this Mac's clients see them.
///
/// The login shell is asked once which overriding variables it exports, and
/// both readers are told, so a terminal that uses an API key is reported the
/// same way whichever account it affects.
public struct AccountSurfaceProbe: AccountSurfaceReading {
    public enum Depth: Sendable {
        /// How each client signs in and what its switches say. Fast, local.
        case signInOnly
        /// Also what each account holds. Asks Claude Code to health-check its
        /// servers and Codex to load its app list, which can take a while.
        case contents
    }

    private let claude: ClaudeAccountReader
    private let codex: CodexAccountReader
    private let shellRunner: (any CommandRunning)?

    public init(claude: ClaudeAccountReader, codex: CodexAccountReader, shellRunner: (any CommandRunning)?) {
        self.claude = claude
        self.codex = codex
        self.shellRunner = shellRunner
    }

    /// The live probe: each client's own tool through a bounded runner, and
    /// a short-lived login shell for the override check.
    public static func live(homeURL: URL, appVersion: String = "1") -> AccountSurfaceProbe {
        let runner = ProcessCommandRunner(timeout: .seconds(90), homeURL: homeURL)
        return AccountSurfaceProbe(
            claude: ClaudeAccountReader(runner: runner, homeURL: homeURL),
            codex: CodexAccountReader(homeURL: homeURL, clientVersion: appVersion),
            shellRunner: ProcessCommandRunner(timeout: .seconds(20), homeURL: homeURL))
    }

    /// Reads the providers asked for, in provider order. A provider whose
    /// client this Mac does not manage is not asked.
    public func read(_ providers: [AccountProvider], depth: Depth, now: Date = .now) async -> [AccountObservation] {
        var overrides: [AccountShellOverride]?
        if let shellRunner { overrides = await AccountShellEnvironmentProbe.read(runner: shellRunner) }
        let contents = depth == .contents
        var observations: [AccountObservation] = []
        for provider in Set(providers).sorted() {
            switch provider {
            case .claude:
                observations.append(await claude.read(contents: contents, shellOverrides: overrides ?? [], now: now))
            case .chatGPT:
                observations.append(await codex.read(contents: contents, shellOverrides: overrides ?? [], now: now))
            }
        }
        return observations
    }
}
