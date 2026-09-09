import Foundation

/// The complete executable and argument allowlist for reviewed operations.
/// Keeping this policy separate from process execution makes it impossible for
/// UI or marketplace code to smuggle an arbitrary shell recipe into a plan.
struct OperationCommandPolicy: Sendable {
    let libraryURL: URL
    let gitBackupRoot: URL

    func validate(executable: String, arguments: [String]) throws {
        guard Self.allowedCommands.contains(executable) else {
            throw OperationEngineError.commandNotAllowed(executable)
        }
        guard arguments.count <= 64,
            arguments.allSatisfy({
                $0.count <= 8_192 && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r")
            })
        else {
            throw OperationEngineError.commandArgumentsNotAllowed(executable)
        }

        switch executable {
        case "git":
            let target = gitBackupRoot.path(percentEncoded: false)
            guard arguments == ["-C", target, "init"] || arguments == ["-C", target, "status", "--short"] else {
                throw OperationEngineError.commandArgumentsNotAllowed(executable)
            }
        case "claude": try validateClaude(arguments)
        case "codex": try validateCodex(arguments)
        case "gemini": try validateGemini(arguments)
        default: throw OperationEngineError.commandNotAllowed(executable)
        }
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
        if arguments.count == 5,
            ["install", "uninstall", "update"].contains(arguments[1]),
            arguments[0] == "plugin",
            arguments[3] == "--scope",
            arguments[4] == "user",
            Self.isSafePluginIdentifier(arguments[2])
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

    private static let allowedCommands: Set<String> = ["claude", "codex", "gemini", "git"]

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
