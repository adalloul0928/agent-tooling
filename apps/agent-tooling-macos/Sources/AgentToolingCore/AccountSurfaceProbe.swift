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
    /// client this Mac does not manage is not asked, and with no provider
    /// nothing runs at all: the login shell runs `~/.zshrc`, and an answer
    /// nothing would use is not a reason to start it.
    public func read(_ providers: [AccountProvider], depth: Depth, now: Date = .now) async -> [AccountObservation] {
        let wanted = Set(providers).sorted()
        guard !wanted.isEmpty else { return [] }
        let overrides = await readShellOverrides()
        var observations: [AccountObservation] = []
        for provider in wanted {
            observations.append(await read(provider, depth: depth, shellOverrides: overrides, now: now))
        }
        return observations
    }

    /// Asks the login shell, once, which overriding variables it exports.
    /// Nil when this probe has no shell runner or the shell did not answer.
    /// A caller reading providers one at a time asks this first and hands the
    /// answer to each, so the shell starts once however many are read.
    public func readShellOverrides() async -> [AccountShellOverride]? {
        guard let shellRunner else { return nil }
        return await AccountShellEnvironmentProbe.read(runner: shellRunner)
    }

    /// Reads one provider, told what the login shell exports. It starts no
    /// shell of its own, so a read that is cancelled or skipped costs only
    /// its own client's commands.
    public func read(
        _ provider: AccountProvider, depth: Depth, shellOverrides: [AccountShellOverride]?, now: Date = .now
    ) async -> AccountObservation {
        let contents = depth == .contents
        switch provider {
        case .claude: return await claude.read(contents: contents, shellOverrides: shellOverrides ?? [], now: now)
        case .chatGPT: return await codex.read(contents: contents, shellOverrides: shellOverrides ?? [], now: now)
        }
    }
}
