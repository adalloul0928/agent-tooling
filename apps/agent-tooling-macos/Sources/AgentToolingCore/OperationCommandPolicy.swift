import Foundation

/// The complete executable and argument allowlist for reviewed operations.
/// Keeping this policy separate from process execution makes it impossible for
/// UI or marketplace code to smuggle an arbitrary shell recipe into a plan.
struct OperationCommandPolicy: Sendable {
    let libraryURL: URL
    let gitBackupRoot: URL
    /// Where a client's own tool is looked for. An absolute path is accepted
    /// only when it is exactly what that lookup returns.
    let homeURL: URL

    init(
        libraryURL: URL, gitBackupRoot: URL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.libraryURL = libraryURL
        self.gitBackupRoot = gitBackupRoot
        self.homeURL = homeURL
    }

    func validate(executable: String, arguments: [String]) throws {
        let command = try commandName(for: executable)
        guard arguments.count <= 64,
            arguments.allSatisfy({
                $0.count <= 8_192 && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r")
            })
        else {
            throw OperationEngineError.commandArgumentsNotAllowed(executable)
        }

        switch command {
        case "git":
            let target = gitBackupRoot.path(percentEncoded: false)
            guard arguments == ["-C", target, "init"] || arguments == ["-C", target, "status", "--short"] else {
                throw OperationEngineError.commandArgumentsNotAllowed(executable)
            }
        case "claude": try validateClaude(arguments)
        case "codex": try validateCodex(arguments)
        case "gemini": try validateGemini(arguments)
        case "kiro-cli": try validateKiro(arguments)
        default: throw OperationEngineError.commandNotAllowed(executable)
        }
    }

    /// The name a command is checked under.
    ///
    /// A bare name is one of the four this app runs. An absolute path is a
    /// client's own tool at the one place `ClientExecutableLocator` found it,
    /// and nothing else: plans carry the located path so that an app launched
    /// outside a login shell still reaches the tool, and a path that is not the
    /// locator's answer is somebody else's file with a familiar name. `git` has
    /// no locator and is only ever named.
    private func commandName(for executable: String) throws -> String {
        if Self.allowedCommands.contains(executable) { return executable }
        guard executable.hasPrefix("/") else { throw OperationEngineError.commandNotAllowed(executable) }
        let url = URL(fileURLWithPath: executable).standardizedFileURL
        guard
            let client = ClientKind.allCases.first(where: {
                ClientExecutableLocator.executableName(for: $0) == url.lastPathComponent
            }),
            let located = ClientExecutableLocator.locate(client, homeURL: homeURL),
            located.standardizedFileURL.path == url.path
        else {
            throw OperationEngineError.commandNotAllowed(executable)
        }
        return url.lastPathComponent
    }

    static func isSafeMCPIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 512
            && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)
            }
    }

    private func validateClaude(_ arguments: [String]) throws {
        // The skill creator: Claude Code in print mode, answering one prompt
        // from standard input inside a staged request folder. The whole
        // shape is fixed except the session identifier.
        if SkillCreatorCommandShapes.isClaudeCreatorShape(arguments) { return }
        // Adding the official marketplace, which the skill-creator plugin
        // install needs first. One literal, nothing variable.
        if arguments == SkillCreatorCommandShapes.claudeOfficialMarketplaceAddArguments { return }
        // Trying a skill: the interactive client, with `/name` as its first
        // message. The name is one checked identifier.
        if SkillTrialCommandShapes.isTrialShape(.claude, arguments) { return }
        // The insights deep dive: print mode, no tools, one fixed schema.
        if InsightsDeepDiveCommandShapes.isClaudeShape(arguments) { return }
        // The setup review: print mode, reading only the tooling folders under
        // home (and, for a client review, the web); never a shell or a write.
        if SetupReviewCommandShapes.isClaudeShape(arguments, homeURL: homeURL) { return }
        // Read-only listing and per-server lookup, plus the OAuth login flow.
        // The login opens the browser itself; the app never handles a token.
        if arguments == ["mcp", "list"] { return }
        // The account reader's read-only questions: how Claude Code signs in,
        // and which plugins it loads (the `@synced` rows are the account's).
        if arguments == ClaudeAccountCommands.authStatus || arguments == ClaudeAccountCommands.pluginList { return }
        if arguments.count == 3,
            arguments[0] == "mcp",
            ["get", "login"].contains(arguments[1]),
            Self.isSafeMCPIdentifier(arguments[2])
        {
            return
        }
        if arguments.count == 4,
            arguments[0] == "mcp",
            arguments[1] == "login",
            Self.isSafeMCPIdentifier(arguments[2]),
            arguments[3] == "--no-browser"
        {
            return
        }
        if arguments.count == 5,
            ["install", "uninstall", "update"].contains(arguments[1]),
            arguments[0] == "plugin",
            arguments[3] == "--scope",
            arguments[4] == "user",
            Self.isSafePluginIdentifier(arguments[2]),
            !ClaudeAccountSync.hasReservedOrigin(arguments[2])
        {
            return
        }
        if arguments.count == 5,
            arguments[0] == "mcp",
            arguments[1] == "remove",
            arguments[2] == "--scope",
            ["user", "project", "local"].contains(arguments[3]),
            Self.isSafeMCPIdentifier(arguments[4])
        {
            return
        }
        if arguments.count == 8,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--transport",
            arguments[3] == "http",
            arguments[4] == "--scope",
            ["user", "project", "local"].contains(arguments[5]),
            Self.isSafeMCPIdentifier(arguments[6]),
            Self.isSafeHTTPDestination(arguments[7])
        {
            return
        }
        if arguments.count >= 9,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--transport",
            arguments[3] == "stdio",
            arguments[4] == "--scope",
            ["user", "project", "local"].contains(arguments[5]),
            Self.isSafeMCPIdentifier(arguments[6]),
            arguments[7] == "--",
            Self.isSafeStdioCommand(Array(arguments.dropFirst(8)))
        {
            return
        }
        throw OperationEngineError.commandArgumentsNotAllowed("claude")
    }

    private func validateCodex(_ arguments: [String]) throws {
        // Read-only listing (text or JSON) and per-server lookup, plus the
        // OAuth login flow for HTTP servers. The login opens the browser
        // itself; no token passes through this app.
        // The skill creator: Codex exec, starting a thread in a staged request
        // folder under the home directory, or resuming one by identifier.
        if SkillCreatorCommandShapes.isCodexCreatorShape(arguments, homeURL: homeURL) { return }
        // Trying a skill: the interactive client, with `$name` as its first
        // message. The name is one checked identifier.
        if SkillTrialCommandShapes.isTrialShape(.codex, arguments) { return }
        // The insights deep dive: read-only exec in a staged folder under the
        // home directory, answering to the schema file inside it.
        if InsightsDeepDiveCommandShapes.isCodexShape(arguments, homeURL: homeURL) { return }
        // The setup review: read-only exec rooted at home so the tooling
        // folders are in reach, answering to a schema file in a staged folder.
        if SetupReviewCommandShapes.isCodexShape(arguments, homeURL: homeURL) { return }
        if arguments == ["mcp", "list"] || arguments == ["mcp", "list", "--json"] { return }
        if arguments.count == 3,
            arguments[0] == "mcp",
            ["get", "login"].contains(arguments[1]),
            Self.isSafeMCPIdentifier(arguments[2])
        {
            return
        }
        if arguments.count == 4,
            arguments[0] == "mcp",
            arguments[1] == "login",
            Self.isSafeMCPIdentifier(arguments[2]),
            arguments[3] == "--no-browser"
        {
            return
        }
        if arguments.count == 3,
            arguments[0] == "plugin",
            ["add", "remove"].contains(arguments[1]),
            Self.isSafePluginIdentifier(arguments[2])
        {
            return
        }
        if arguments.count == 3,
            arguments[0] == "mcp",
            arguments[1] == "remove",
            Self.isSafeMCPIdentifier(arguments[2])
        {
            return
        }
        if arguments.count == 5,
            arguments[0] == "mcp",
            arguments[1] == "add",
            Self.isSafeMCPIdentifier(arguments[2]),
            arguments[3] == "--url",
            Self.isSafeHTTPDestination(arguments[4])
        {
            return
        }
        if arguments.count >= 5,
            arguments[0] == "mcp",
            arguments[1] == "add",
            Self.isSafeMCPIdentifier(arguments[2]),
            arguments[3] == "--",
            Self.isSafeStdioCommand(Array(arguments.dropFirst(4)))
        {
            return
        }
        throw OperationEngineError.commandArgumentsNotAllowed("codex")
    }

    private func validateGemini(_ arguments: [String]) throws {
        if arguments.count == 5,
            arguments[0] == "mcp",
            arguments[1] == "remove",
            arguments[2] == "--scope",
            ["user", "project"].contains(arguments[3]),
            Self.isSafeMCPIdentifier(arguments[4])
        {
            return
        }
        if arguments.count == 8,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--scope",
            ["user", "project"].contains(arguments[3]),
            arguments[4] == "--transport",
            arguments[5] == "http",
            Self.isSafeMCPIdentifier(arguments[6]),
            Self.isSafeHTTPDestination(arguments[7])
        {
            return
        }
        if arguments.count >= 9,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--scope",
            ["user", "project"].contains(arguments[3]),
            arguments[4] == "--transport",
            arguments[5] == "stdio",
            Self.isSafeMCPIdentifier(arguments[6]),
            arguments[7] == "--",
            Self.isSafeStdioCommand(Array(arguments.dropFirst(8)))
        {
            return
        }
        if arguments.count == 3,
            arguments[0] == "extensions",
            arguments[1] == "link"
        {
            let source = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            guard Self.contains(source, in: libraryURL) else {
                throw OperationEngineError.commandArgumentsNotAllowed("gemini")
            }
            return
        }
        throw OperationEngineError.commandArgumentsNotAllowed("gemini")
    }

    /// Exactly the shapes `MCPClientCommand` emits for Kiro, verified against
    /// kiro-cli 2.23.0: named flags, `global`/`workspace` scopes, and repeated
    /// `--args` pairs after the fixed prefix for a stdio server.
    private func validateKiro(_ arguments: [String]) throws {
        let scopes = ["global", "workspace"]
        // Trying a skill: an interactive chat with `/name` as its first
        // message. The name is one checked identifier.
        if SkillTrialCommandShapes.isTrialShape(.kiro, arguments) { return }
        // Read-only listing. Kiro CLI 2.23.0 has no verified login command, so
        // this is list-only; no login shape is admitted for it.
        if arguments == ["mcp", "list"] { return }
        if arguments.count == 6,
            arguments[0] == "mcp",
            arguments[1] == "remove",
            arguments[2] == "--name",
            Self.isSafeMCPIdentifier(arguments[3]),
            arguments[4] == "--scope",
            scopes.contains(arguments[5])
        {
            return
        }
        if arguments.count == 9,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--name",
            Self.isSafeMCPIdentifier(arguments[3]),
            arguments[4] == "--url",
            Self.isSafeHTTPDestination(arguments[5]),
            arguments[6] == "--scope",
            scopes.contains(arguments[7]),
            arguments[8] == "--force"
        {
            return
        }
        if arguments.count >= 9,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--name",
            Self.isSafeMCPIdentifier(arguments[3]),
            arguments[4] == "--command",
            arguments[6] == "--scope",
            scopes.contains(arguments[7]),
            arguments[8] == "--force"
        {
            // The tail is pairs of `--args <value>`; the launched command is
            // checked whole, the way the stdio validators already do.
            let tail = Array(arguments.dropFirst(9))
            var values: [String] = []
            var index = 0
            while index + 1 < tail.count, tail[index] == "--args" {
                values.append(tail[index + 1])
                index += 2
            }
            if index == tail.count, Self.isSafeStdioCommand([arguments[5]] + values) {
                return
            }
        }
        throw OperationEngineError.commandArgumentsNotAllowed("kiro-cli")
    }

    private static let allowedCommands: Set<String> = ["claude", "codex", "gemini", "kiro-cli", "git"]

    static func isSafePluginIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 512
            && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || "._-@".unicodeScalars.contains(scalar)
            }
    }

    private static func isSafeHTTPDestination(_ value: String) -> Bool {
        guard SensitiveValueRedactor.redact(value) == value,
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false
        else { return false }
        return components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    private static func isSafeStdioCommand(_ values: [String]) -> Bool {
        guard let executable = values.first,
            !executable.isEmpty,
            !executable.hasPrefix("-"),
            SensitiveValueRedactor.redact(values.joined(separator: " ")) == values.joined(separator: " ")
        else { return false }
        return values.allSatisfy { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    }

    private static func contains(_ child: URL, in root: URL) -> Bool {
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }
}
