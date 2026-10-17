import Foundation

/// Where a single test connection is allowed to go.
public enum MCPTestTarget: Equatable, Sendable {
    /// A local program the person explicitly asked Agent Tooling to start.
    case stdio(executableURL: URL, arguments: [String])
    /// A remote or loopback MCP endpoint spoken over HTTP.
    case http(url: URL)

    /// The exact text shown before anything runs. This is the promise the
    /// policy keeps: nothing outside this line is started or contacted.
    public var displayCommand: String {
        switch self {
        case .stdio(let executableURL, let arguments):
            let parts = [executableURL.path(percentEncoded: false)] + arguments
            return SensitiveValueRedactor.redact(parts.map(Self.escaped).joined(separator: " "))
        case .http(let url):
            return SensitiveValueRedactor.redact("POST \(url.absoluteString)")
        }
    }

    public var isProcessLaunch: Bool {
        if case .stdio = self { return true }
        return false
    }

    private static func escaped(_ value: String) -> String {
        value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            ? value : "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// The complete, self-contained boundary for a *live test connection*.
///
/// This is deliberately **not** ``OperationCommandPolicy``. That policy is an
/// allowlist for reviewed operations: a fixed set of client CLIs whose exact
/// argument shapes Agent Tooling authored. A test connection is a different
/// thing — it starts a program the person's own MCP definition names, which is
/// third-party code — so widening the operation allowlist to let it through
/// would have quietly turned a closed allowlist into an open one.
///
/// The boundary this type enforces instead:
///
/// 1. **Only on an explicit, per-server action.** Nothing here runs on
///    appearance, on selection, on refresh, or as part of a sync. The caller
///    must have shown ``MCPTestTarget/displayCommand`` and taken a confirmation
///    for that exact server first.
/// 2. **Only a definition Agent Tooling manages.** A server merely *discovered*
///    in a client's configuration records where it was seen, not how to start
///    it, so it is refused rather than guessed at.
/// 3. **A named program, never a wrapper.** The executable must resolve to a
///    real, non-setuid file on this Mac using the fixed `PATH` every child
///    this app starts gets, never the app's inherited one. Shells,
///    privilege elevators, and run-another-program wrappers are refused,
///    because the console's safety story is that the displayed line is the
///    program that runs. There is no `/usr/bin/env` fallback.
/// 4. **No secrets, ever.** A stdio child gets a freshly built environment —
///    `PATH`, `HOME`, `TMPDIR`, `LANG`, `USER`, `LOGNAME` and a marker — and
///    never the app's inherited environment. An HTTP request carries no
///    `Authorization` header, no cookies, and no stored credentials.
/// 5. **Plaintext only to this Mac.** `http://` is accepted for loopback hosts
///    and refused for anything else; a real remote endpoint must be `https`.
/// 6. **Bounded and stoppable.** Every stage has a timeout, every message and
///    result has a byte cap, the session has a hard lifetime, and cancelling
///    terminates the child process group.
/// 7. **An observation, not a verdict.** Nothing this produces is written into
///    a server's recorded state.
public enum MCPTestConnectionPolicy {
    // MARK: Bounds

    public static let handshakeTimeout: Duration = .seconds(20)
    public static let inventoryTimeout: Duration = .seconds(20)
    public static let toolCallTimeout: Duration = .seconds(30)
    /// A live connection is never open-ended. The console stops itself here
    /// even if the person walks away with the pane open.
    public static let sessionLifetime: Duration = .seconds(300)
    /// The same wall in whole seconds, for interface copy and countdowns.
    public static var sessionLifetimeSeconds: Int { Int(sessionLifetime.components.seconds) }
    public static let maximumMessageBytes = 1_048_576
    /// How much complete, unread output the console will hold. Bounds a server
    /// that writes valid lines faster than the console reads them, which the
    /// per-message cap does not catch.
    public static let maximumBufferedBytes = 8 * 1_048_576
    public static let maximumToolCount = 500
    public static let maximumListPages = 10
    public static let maximumDiagnosticCharacters = 2_048
    public static let maximumToolResultCharacters = 8_192
    public static let maximumArgumentBytes = 64 * 1_024

    public static let clientName = "agent-tooling-test-console"
    public static let protocolVersion = "2025-06-18"

    /// Programs whose entire purpose is to run some *other* program, plus the
    /// privilege elevators. Allowing one would mean the line shown before the
    /// run is not the program that runs.
    public static let refusedExecutableNames: Set<String> = [
        "arch", "bash", "busybox", "caffeinate", "csh", "dash", "doas", "env", "eval", "exec", "expect", "fish", "ksh",
        "launchctl", "login", "mksh", "nice", "nohup", "open", "osascript", "rc", "script", "setsid", "sh", "ssh",
        "sshpass", "stdbuf", "su", "sudo", "tcsh", "time", "timeout", "xargs", "zsh",
    ]

    /// The complete environment handed to a test child. It is the app's own
    /// child environment built from an empty parent — so no exported key,
    /// token, or session variable in the app's environment can reach a server
    /// being tested — plus the marker that tells a server it is being probed.
    /// Building on the shared builder also means a tested server gets the same
    /// `PATH`, `TERM`, and `LC_CTYPE` a real client command gets.
    public static func childEnvironment(
        homeURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        var environment = ProcessCommandRunner.childEnvironment(
            inheriting: [:],
            homeURL: homeURL,
            temporaryDirectory: temporaryDirectory
        )
        environment["MCP_TEST_CONNECTION"] = "agent-tooling"
        return environment
    }

    // MARK: Resolution

    /// Turns a recorded MCP definition into a target this policy is willing to
    /// contact, or explains precisely why it will not.
    public static func resolve(
        server: MCPServer,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> MCPTestTarget {
        guard server.isManagedDefinition else {
            throw MCPLiveTestError.definitionNotConnectable(
                "Agent Tooling only recorded where \(server.name) was discovered, not how to start it. "
                    + "A live test needs the server's own command or URL, so add it as a managed definition first."
            )
        }
        let destination = try MCPDefinitionValidator.validate(server.endpoint, transport: server.transport)
        switch server.transport {
        case .http:
            return try resolveHTTP(destination.endpoint)
        case .stdio:
            return try resolveStdio(destination.command, homeURL: homeURL, fileManager: fileManager)
        }
    }

    static func resolveHTTP(_ endpoint: String) throws -> MCPTestTarget {
        guard let components = URLComponents(string: endpoint),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            let url = components.url
        else {
            throw MCPLiveTestError.insecureEndpoint("\(endpoint) is not a complete http or https URL.")
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw MCPLiveTestError.insecureEndpoint("An MCP endpoint with credentials, a query, or a fragment is never contacted.")
        }
        if scheme == "https" { return .http(url: url) }
        guard scheme == "http", isLoopbackHost(host) else {
            throw MCPLiveTestError.insecureEndpoint(
                "A test connection sends the MCP handshake in the clear over http, so it is allowed only to this Mac. "
                    + "Use https for \(host)."
            )
        }
        return .http(url: url)
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "0:0:0:0:0:0:0:1"
            || normalized.hasSuffix(".localhost")
    }

    static func resolveStdio(
        _ command: [String],
        homeURL: URL,
        fileManager: FileManager = .default
    ) throws -> MCPTestTarget {
        guard let executable = command.first, !executable.isEmpty else {
            throw MCPLiveTestError.definitionNotConnectable("This stdio server has no command to run.")
        }
        let arguments = Array(command.dropFirst())
        let argumentBytes = arguments.reduce(0) { $0 + $1.utf8.count }
        guard argumentBytes <= maximumArgumentBytes else {
            throw MCPLiveTestError.definitionNotConnectable("This stdio command's arguments exceed the test connection's size limit.")
        }
        let requestedName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        guard !refusedExecutableNames.contains(requestedName) else {
            throw MCPLiveTestError.executableNotPermitted(requestedName)
        }
        let environment = childEnvironment(homeURL: homeURL)
        // The program starts from the path it was found at, not the file a link
        // there leads to, the way every other child this app starts does: a
        // shim dispatches on the name it was started by, and every tool in
        // Amazon Toolbox's `~/.toolbox/bin` is a link to one shared dispatcher.
        guard
            let installed = ProcessCommandRunner.launchExecutableURL(
                for: executable,
                environment: environment,
                currentDirectory: nil,
                fileManager: fileManager
            )
        else {
            throw MCPLiveTestError.executableNotFound(executable)
        }
        // The file the link leads to is the code that runs and can differ from
        // the written name, so the refusal list is applied again to it, and it
        // is the file checked for setuid.
        let resolved = installed.resolvingSymlinksInPath().standardizedFileURL
        guard !refusedExecutableNames.contains(resolved.lastPathComponent.lowercased()) else {
            throw MCPLiveTestError.executableNotPermitted(resolved.lastPathComponent)
        }
        guard !isSetIdentifier(resolved, fileManager: fileManager) else {
            throw MCPLiveTestError.executableNotPermitted(
                "\(resolved.lastPathComponent) runs as another user (setuid or setgid)"
            )
        }
        return .stdio(executableURL: installed, arguments: arguments)
    }

    private static func isSetIdentifier(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false)),
            let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.uint16Value & 0o6000 != 0
    }

    // MARK: Presentation

    /// One sentence stating what the person is agreeing to, used verbatim by
    /// the confirmation before a connection opens.
    public static func consentSummary(for target: MCPTestTarget, serverName: String) -> String {
        switch target {
        case .stdio:
            return "Agent Tooling will start this program on your Mac. It is \(serverName)'s own code, not Agent Tooling's. "
                + "It runs with a minimal environment that excludes your shell's exported secrets, and stops when you stop the test."
        case .http(let url):
            let host = url.host() ?? url.absoluteString
            return "Agent Tooling will open an MCP session with \(host). No credentials, cookies, or tokens are sent, "
                + "so a server that needs a sign-in will report an authentication error."
        }
    }
}
