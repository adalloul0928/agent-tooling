import Foundation

// MARK: - Command shapes

/// How a skill is called by name inside each client's own chat, so a person
/// can try it the way they would at a prompt: the client is opened
/// interactively with the invocation as its first message.
///
/// Claude Code and Kiro CLI expose a skill as the slash command `/name`
/// (Claude's plugin-provided skills as `/plugin:name`); Codex invokes one
/// with `$name` in the prompt. Gemini CLI has no invocation this app has
/// verified, so it is not offered rather than guessed at.
public enum SkillTrialCommandShapes {
    /// The argument list that opens `client` interactively with `skillName`
    /// invoked first, or nil when the client is unsupported or the name is
    /// not one a client could have.
    public static func arguments(for client: ClientKind, skillName: String) -> [String]? {
        guard isValidSkillReference(skillName) else { return nil }
        switch client {
        case .claude: return ["/\(skillName)"]
        case .codex: return ["$\(unqualified(skillName))"]
        case .kiro: return ["chat", "/\(unqualified(skillName))"]
        case .gemini: return nil
        }
    }

    public static func isSupported(_ client: ClientKind) -> Bool {
        switch client {
        case .claude, .codex, .kiro: true
        case .gemini: false
        }
    }

    /// The invocation as the person would type it, for a label.
    public static func invocationText(for client: ClientKind, skillName: String) -> String? {
        arguments(for: client, skillName: skillName)?.last
    }

    /// Whether `arguments` is exactly the shape above for `client`, for the
    /// policy. The skill name is the only variable part and is re-checked.
    public static func isTrialShape(_ client: ClientKind, _ arguments: [String]) -> Bool {
        guard let last = arguments.last, let first = last.first, ["/", "$"].contains(first) else { return false }
        let name = String(last.dropFirst())
        return arguments == self.arguments(for: client, skillName: name)
    }

    /// A skill name as a client keeps it: one identifier of letters, digits,
    /// hyphens, underscores and dots, optionally prefixed by one plugin
    /// namespace and a colon. Nothing here is a flag, a path, or a shell word
    /// boundary.
    public static func isValidSkillReference(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), value.count <= 200 else { return false }
        return parts.allSatisfy(isIdentifier)
    }

    private static func isIdentifier(_ part: Substring) -> Bool {
        guard let first = part.first, first.isLetter || first.isNumber, first.isASCII else { return false }
        return part.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
        }
    }

    /// The name without a plugin namespace, for clients that never use one.
    private static func unqualified(_ skillName: String) -> String {
        skillName.split(separator: ":").last.map(String.init) ?? skillName
    }
}

// MARK: - The terminal script

/// A `.command` file Terminal.app runs in a new window.
///
/// This is the one place the app writes a shell script, and it is rendered
/// from checked parts only: every value is single-quoted, the executable is
/// the located tool, and the arguments have passed the operation policy. The
/// script starts the person's own login shell so the client sees the
/// environment it has at their prompt, then replaces that shell with the
/// client; when the client exits, Terminal reports the process as completed.
enum TerminalCommandScript {
    /// The script body. `interactiveShell` wraps the command in
    /// `$SHELL -l -i -c` so the person's profile applies; a test turns it off
    /// to run the rendered command directly.
    static func render(
        title: String,
        workingDirectory: URL,
        executable: String,
        arguments: [String],
        interactiveShell: Bool = true
    ) -> String {
        let command = ([executable] + arguments).map(shellQuoted).joined(separator: " ")
        let launch =
            interactiveShell
            ? "exec \"${SHELL:-/bin/zsh}\" -l -i -c \(shellQuoted("exec " + command))"
            : "exec " + command
        var directory = workingDirectory.standardizedFileURL.path(percentEncoded: false)
        while directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
        return """
            #!/bin/zsh
            # \(title.replacingOccurrences(of: "\n", with: " "))
            # Written by Agent Tooling. Safe to delete; it is rewritten on the next try.
            cd \(shellQuoted(directory)) || exit 1
            \(launch)

            """
    }

    /// `value` as one shell word: single quotes, with a literal single quote
    /// spelled as `'\''`. Composable, so a quoted command can itself be quoted.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes `body` as `name.command` inside `directory`, both readable by the
    /// owner only, replacing an earlier file of the same name. A directory
    /// that is a link, or a destination that is, is refused.
    static func write(
        _ body: String, named name: String, in directory: URL, fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw TerminalCommandScriptError.unsafeDirectory(directory.path(percentEncoded: false))
        }
        let destination = directory.appending(path: "\(name).command", directoryHint: .notDirectory)
        if let existing = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
            existing.isSymbolicLink == true || (fileManager.fileExists(atPath: destination.path) && existing.isRegularFile != true)
        {
            throw TerminalCommandScriptError.unsafeDirectory(destination.path(percentEncoded: false))
        }
        try Data(body.utf8).write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path(percentEncoded: false))
        return destination
    }
}

enum TerminalCommandScriptError: LocalizedError, Equatable, Sendable {
    case unsafeDirectory(String)

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory(let path): "Agent Tooling refused to write a launch script at \(path)."
        }
    }
}

// MARK: - Preparing a trial

/// Everything one try needs, ready to hand to Terminal.
public struct SkillTrialLaunch: Hashable, Sendable {
    public let client: ClientKind
    public let skillName: String
    /// The located tool, by the path the person's shell would use.
    public let executable: String
    public let arguments: [String]
    public let scriptURL: URL

    /// What Terminal will run, for a message.
    public var commandLine: String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
    }
}

enum SkillTrialLaunchError: LocalizedError, Equatable, Sendable {
    case unsupportedClient(ClientKind)
    case invalidSkillName(String)
    case toolNotFound(ClientKind)
    case commandRefused(ClientKind)

    var errorDescription: String? {
        switch self {
        case .unsupportedClient(let client): "Trying a skill in \(client.rawValue) from here is not supported yet."
        case .invalidSkillName(let name): "\"\(name)\" is not a name a client could call."
        case .toolNotFound(let client): "\(client.rawValue)'s command-line tool was not found on this Mac."
        case .commandRefused(let client):
            "Agent Tooling did not recognise the command it was about to run for \(client.rawValue) and refused to run it."
        }
    }
}

/// Prepares a `.command` file that opens a client with one skill invoked.
///
/// Nothing here runs the client: the file is written and returned, and the
/// caller hands it to Terminal. The executable is the one
/// `ClientExecutableLocator` finds, the argument list is checked by the
/// operation policy before it is written, and the script runs from the
/// person's home directory.
public struct SkillTrialLauncher {
    private let homeURL: URL
    private let scriptsDirectory: URL
    private let policy: OperationCommandPolicy
    private let fileManager: FileManager

    public init(homeURL: URL, scriptsDirectory: URL, fileManager: FileManager = .default) {
        self.homeURL = homeURL
        self.scriptsDirectory = scriptsDirectory
        self.fileManager = fileManager
        // Only the home directory matters for these shapes; the library and
        // backup roots guard git shapes this launcher never emits.
        self.policy = OperationCommandPolicy(
            libraryURL: homeURL.appending(path: ".agent-tooling/library", directoryHint: .isDirectory),
            gitBackupRoot: homeURL.appending(path: ".agent-tooling/git-backup", directoryHint: .isDirectory),
            homeURL: homeURL)
    }

    public func prepare(client: ClientKind, skillName: String) throws -> SkillTrialLaunch {
        guard SkillTrialCommandShapes.isSupported(client) else { throw SkillTrialLaunchError.unsupportedClient(client) }
        guard let arguments = SkillTrialCommandShapes.arguments(for: client, skillName: skillName) else {
            throw SkillTrialLaunchError.invalidSkillName(skillName)
        }
        guard let located = ClientExecutableLocator.locate(client, homeURL: homeURL, fileManager: fileManager) else {
            throw SkillTrialLaunchError.toolNotFound(client)
        }
        let executable = located.path(percentEncoded: false)
        do {
            try policy.validate(executable: executable, arguments: arguments)
        } catch {
            throw SkillTrialLaunchError.commandRefused(client)
        }
        let body = TerminalCommandScript.render(
            title: "Try the skill \(skillName) in \(client.rawValue)",
            workingDirectory: homeURL, executable: executable, arguments: arguments)
        let fileName = "try-\(slug(client.rawValue))-\(slug(skillName))"
        let scriptURL = try TerminalCommandScript.write(body, named: fileName, in: scriptsDirectory, fileManager: fileManager)
        return SkillTrialLaunch(
            client: client, skillName: skillName, executable: executable, arguments: arguments, scriptURL: scriptURL)
    }

    private func slug(_ value: String) -> String {
        String(
            value.lowercased().map { character in
                character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
            })
    }
}
