import Foundation

/// The list command each client answers, and how its output is read.
///
/// Kept next to the probe rather than in `MCPClientCommand` because these are
/// read-only listings, not the mutating add/remove/login shapes that file
/// builds — but every argv here is still admitted by `OperationCommandPolicy`,
/// so a listing the policy would refuse is a refused probe, not a wrong command.
public enum ConnectionHealthListing {
    /// The list arguments for a client, or nil when the client has no listing
    /// this app knows how to read (Gemini today).
    public static func arguments(for client: ClientKind) -> [String]? {
        switch client {
        case .claude: ["mcp", "list"]
        case .codex: ["mcp", "list", "--json"]
        case .kiro: ["mcp", "list"]
        case .gemini: nil
        }
    }
}

/// What one client's probe produced: the entries it listed, or the reason it
/// could not be listed at all.
///
/// A client whose tool was not located, or whose command failed, carries an
/// `unavailableReason` and no entries, so the screen can show a per-client note
/// instead of pretending the client has no connections.
public struct ConnectionHealthClientResult: Equatable, Sendable {
    public let client: ClientKind
    public let entries: [ConnectionHealthEntry]
    public let unavailableReason: String?

    public init(client: ClientKind, entries: [ConnectionHealthEntry], unavailableReason: String?) {
        self.client = client
        self.entries = entries
        self.unavailableReason = unavailableReason
    }
}

/// Runs each managed client's list command and parses the result.
///
/// Nothing is probed for a client whose executable the locator cannot find:
/// the next thing this app would do with that tool is put its path into a
/// command a person approves, and there is no honest command to build without
/// a located path. The runner is injected so a test scripts the output and no
/// real client is ever touched.
public struct ConnectionHealthProbe: Sendable {
    private let runner: any CommandRunning
    private let homeURL: URL
    private let locate: @Sendable (ClientKind, URL) -> URL?

    /// The live probe bounds each client at 60 seconds through its own runner;
    /// a test hands in a scripted runner and, when it likes, a scripted
    /// locator so a client counts as found without a file on disk.
    public init(
        runner: any CommandRunning,
        homeURL: URL,
        locate: @escaping @Sendable (ClientKind, URL) -> URL? = { ClientExecutableLocator.locate($0, homeURL: $1) }
    ) {
        self.runner = runner
        self.homeURL = homeURL
        self.locate = locate
    }

    /// Probes one client. A client with no listing this app reads, or whose
    /// tool is not located, comes back unavailable with the reason; a command
    /// that exits nonzero carries its redacted error as the reason.
    public func probe(_ client: ClientKind) async -> ConnectionHealthClientResult {
        guard let arguments = ConnectionHealthListing.arguments(for: client) else {
            return .init(
                client: client, entries: [],
                unavailableReason: "\(client.rawValue) does not list connection health.")
        }
        guard let executable = locate(client, homeURL) else {
            return .init(
                client: client, entries: [],
                unavailableReason:
                    "\(client.rawValue)'s command-line tool was not found on this Mac, so its connections could not be listed.")
        }
        do {
            let output = try await runner.run(
                executable: executable.path, arguments: arguments, currentDirectory: nil)
            guard output.status == 0 else {
                let detail = SensitiveValueRedactor.redact(
                    firstMeaningfulLine(output.standardError) ?? firstMeaningfulLine(output.standardOutput)
                        ?? "exit status \(output.status)")
                return .init(
                    client: client, entries: [],
                    unavailableReason: "\(client.rawValue) could not list its connections: \(detail)")
            }
            let entries: [ConnectionHealthEntry] =
                client == .codex
                ? ConnectionHealthReport.parseCodex(jsonOrText: output.standardOutput)
                : ConnectionHealthReport.parse(client: client, text: output.standardOutput)
            return .init(client: client, entries: entries, unavailableReason: nil)
        } catch {
            return .init(
                client: client, entries: [],
                unavailableReason:
                    "\(client.rawValue) could not be checked: \(SensitiveValueRedactor.redact(error.localizedDescription))")
        }
    }

    /// Probes several clients, in the order given. Sequential rather than
    /// concurrent: these are cheap local reads, and one answer per client keeps
    /// the output bounded by the runner's own per-command limits.
    public func probe(_ clients: [ClientKind]) async -> [ConnectionHealthClientResult] {
        var results: [ConnectionHealthClientResult] = []
        for client in clients {
            results.append(await probe(client))
        }
        return results
    }

    private func firstMeaningfulLine(_ text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

/// How a sign-in ended, in words a person can act on. The message is the
/// redacted tail of what the tool printed, never a token.
public struct ConnectionHealthLoginResult: Equatable, Sendable {
    public var succeeded: Bool
    public var message: String

    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded
        self.message = message
    }
}

/// Runs the pseudo-terminal sign-in. Injected so tests can script the flow
/// without spawning a process.
public typealias InteractiveLoginRun = @Sendable (
    _ executable: String, _ arguments: [String], _ onAuthorizationURL: @escaping @Sendable (URL) -> Void
) async throws -> InteractiveLoginOutcome

/// Signs in to one MCP server through the client's own `mcp login` flow.
///
/// The tool does the OAuth dance itself: it prints an authorization URL,
/// listens on a localhost callback, and stores the credential where the
/// client keeps it. This type only decides which argv may run (checked
/// against the operation policy), gives the tool the terminal it insists on,
/// opens the URL it prints, and reports the redacted outcome. It never sees
/// a token.
public struct ConnectionHealthLoginRunner: Sendable {
    private let homeURL: URL
    private let policy: OperationCommandPolicy
    private let locate: @Sendable (ClientKind, URL) -> URL?
    private let run: InteractiveLoginRun

    public init(
        homeURL: URL,
        locate: @escaping @Sendable (ClientKind, URL) -> URL? = { ClientExecutableLocator.locate($0, homeURL: $1) },
        run: InteractiveLoginRun? = nil
    ) {
        self.homeURL = homeURL
        self.locate = locate
        self.run = run ?? { executable, arguments, onAuthorizationURL in
            try await InteractiveLoginProcess(homeURL: homeURL)
                .run(executable: executable, arguments: arguments, onAuthorizationURL: onAuthorizationURL)
        }
        // Only the home directory matters for admitting a located absolute
        // path; the library and backup roots guard the git shapes this type
        // never emits, so they are given placeholders under the same home.
        self.policy = OperationCommandPolicy(
            libraryURL: homeURL.appending(path: ".agent-tooling/library", directoryHint: .isDirectory),
            gitBackupRoot: homeURL.appending(path: ".agent-tooling/git-backup", directoryHint: .isDirectory),
            homeURL: homeURL)
    }

    /// The exact command a login would run for one server, for showing a person
    /// before it runs. Nil when the client has no login this app can run.
    public func commandText(client: ClientKind, serverID: String) -> String? {
        guard let arguments = MCPClientCommand.loginArguments(client: client, serverID: serverID) else {
            return nil
        }
        return ([MCPClientCommand.executable(for: client)] + arguments).joined(separator: " ")
    }

    /// Whether a login command even exists for this client, so a caller offers
    /// re-authentication only where it can run one.
    public func canLogIn(client: ClientKind) -> Bool {
        MCPClientCommand.loginArguments(client: client, serverID: "placeholder") != nil
    }

    /// Signs in to one server through the client's own flow. Builds the argv,
    /// checks it against the policy, locates the tool, runs it on a terminal,
    /// hands the authorization URL to `openURL` as soon as the tool prints it,
    /// waits for the tool to finish, and returns the redacted last lines. A
    /// shape the policy refuses never launches a process.
    public func logIn(
        client: ClientKind,
        serverID: String,
        openURL: @escaping @Sendable (URL) -> Void
    ) async -> ConnectionHealthLoginResult {
        guard let arguments = MCPClientCommand.loginArguments(client: client, serverID: serverID) else {
            return .init(
                succeeded: false,
                message: "\(client.rawValue) has no sign-in command Agent Tooling can run.")
        }
        guard let executable = locate(client, homeURL) else {
            return .init(
                succeeded: false,
                message: "\(client.rawValue)'s command-line tool was not found on this Mac.")
        }
        // The policy is the app's guarantee about the argv it will run. It is
        // checked under the tool's own name — the shape is what is being
        // guarded — while the located absolute path is what actually launches,
        // the way the executor accepts a located path at run time.
        do {
            try policy.validate(executable: MCPClientCommand.executable(for: client), arguments: arguments)
        } catch {
            return .init(
                succeeded: false,
                message: "Agent Tooling did not recognise that sign-in command and refused to run it.")
        }
        do {
            switch try await run(executable.path, arguments, openURL) {
            case .completed(let transcript):
                let tail = lastLines(transcript)
                return .init(succeeded: true, message: tail.isEmpty ? "Signed in." : tail)
            case .failed(let status, let transcript):
                let tail = lastLines(transcript)
                return .init(
                    succeeded: false,
                    message: tail.isEmpty ? "Sign-in exited with status \(status)." : tail)
            case .timedOut:
                return .init(
                    succeeded: false,
                    message: "The sign-in was not finished in the browser within five minutes, so it was stopped.")
            case .cancelled:
                return .init(succeeded: false, message: "Sign-in was cancelled.")
            }
        } catch {
            return .init(
                succeeded: false,
                message: SensitiveValueRedactor.redact(error.localizedDescription))
        }
    }

    private func lastLines(_ text: String, limit: Int = 3) -> String {
        // Terminal output carries colour and cursor escapes, carriage returns
        // and the tool's own prompts; keep the last few meaningful lines of
        // plain text so the row reads like a sentence.
        let lines = Self.plainLines(text)
            .filter { line in
                !line.hasPrefix("claude: info")
                    && !line.hasPrefix("Or paste the redirect URL")
                    && !line.hasPrefix("Waiting for authorization")
                    && !line.hasPrefix("Visit this URL")
                    && !line.hasPrefix("https://")
            }
        return lines.suffix(limit).joined(separator: "\n")
    }

    /// Terminal text reduced to printable lines: ANSI escape sequences (CSI
    /// and OSC) removed, carriage returns treated as line breaks, blank lines
    /// dropped. Exposed for tests because the shapes tools print are varied.
    static func plainLines(_ text: String) -> [String] {
        var output = ""
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard let kind = iterator.next() else { break }
                switch kind {
                case "[":
                    // CSI: parameter and intermediate bytes, then one final byte 0x40–0x7E.
                    while let byte = iterator.next() {
                        if (0x40...0x7E).contains(byte.value) { break }
                    }
                case "]":
                    // OSC: runs to BEL or ESC \ (string terminator).
                    var previous: Unicode.Scalar?
                    while let byte = iterator.next() {
                        if byte == "\u{07}" { break }
                        if previous == "\u{1B}" && byte == "\\" { break }
                        previous = byte
                    }
                default:
                    // Two-byte escapes (e.g. ESC 7) end here.
                    break
                }
                continue
            }
            if scalar == "\r" || scalar == "\n" {
                output.append("\n")
            } else if scalar.value >= 0x20 && scalar.value != 0x7F {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
