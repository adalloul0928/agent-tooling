import Foundation
import Testing

@testable import AgentToolingCore

/// Claude Code lists a connection a plugin brought under a plugin-scoped
/// name, `plugin:<plugin>:<server>`, and signs in to it by that name. Home's
/// Sign in and Apps › Health run exactly `claude mcp login plugin:sentry:sentry
/// --no-browser`, so the policy admits that one shape, and only for the
/// sign-in: the colon is refused everywhere else, and so is every near miss.
@Suite("Operation command policy · a plugin's sign-in")
struct OperationCommandPolicyPluginLoginTests {
    @Test func theSignInToAPluginsConnectionIsAdmitted() throws {
        let policy = Self.policy()
        for name in ["plugin:sentry:sentry", "plugin:github:github", "plugin:my-tools.v2:inspector_1"] {
            #expect(throws: Never.self, "\(name) was refused") {
                try policy.validate(executable: "claude", arguments: ["mcp", "login", name, "--no-browser"])
            }
        }
    }

    /// An extra colon, an empty part, a word other than `plugin`, shell
    /// characters, a part that reads as a flag, or no `--no-browser`.
    @Test(arguments: [
        ["mcp", "login", "plugin:sentry:sentry:extra", "--no-browser"],
        ["mcp", "login", "plugin:sentry", "--no-browser"],
        ["mcp", "login", "plugin::sentry", "--no-browser"],
        ["mcp", "login", "plugin:sentry:", "--no-browser"],
        ["mcp", "login", ":sentry:sentry", "--no-browser"],
        ["mcp", "login", "plugins:sentry:sentry", "--no-browser"],
        ["mcp", "login", "Plugin:sentry:sentry", "--no-browser"],
        ["mcp", "login", "plugin:sentry;rm -rf ~:sentry", "--no-browser"],
        ["mcp", "login", "plugin:sentry:$(whoami)", "--no-browser"],
        ["mcp", "login", "plugin:sentry:sentry`id`", "--no-browser"],
        ["mcp", "login", "plugin:sentry:a b", "--no-browser"],
        ["mcp", "login", "plugin:-x:sentry", "--no-browser"],
        ["mcp", "login", "plugin:sentry:--all", "--no-browser"],
        ["mcp", "login", "plugin:sentry:sentry"],
        ["mcp", "login", "plugin:sentry:sentry", "--browser"],
        ["mcp", "login", "plugin:sentry:sentry", "--no-browser", "x"],
    ])
    func aNearMissIsRefused(arguments: [String]) throws {
        #expect(throws: OperationEngineError.self, "\(arguments.joined(separator: " ")) was accepted") {
            try Self.policy().validate(executable: "claude", arguments: arguments)
        }
    }

    /// The plugin-scoped name is a sign-in's only: every other command that
    /// takes a server name still needs a plain one, and Codex never takes it.
    @Test(arguments: [
        ("claude", ["mcp", "get", "plugin:sentry:sentry"]),
        ("claude", ["mcp", "login", "plugin:sentry:sentry"]),
        ("claude", ["mcp", "remove", "--scope", "user", "plugin:sentry:sentry"]),
        ("claude", ["mcp", "add", "--transport", "http", "--scope", "user", "plugin:sentry:sentry", "https://mcp.sentry.dev/mcp"]),
        ("claude", ["mcp", "logout", "plugin:sentry:sentry"]),
        ("codex", ["mcp", "login", "plugin:sentry:sentry", "--no-browser"]),
        ("codex", ["mcp", "get", "plugin:sentry:sentry"]),
    ])
    func otherCommandsStillRefuseThePluginScopedName(executable: String, arguments: [String]) throws {
        #expect(throws: OperationEngineError.self, "\(executable) \(arguments.joined(separator: " ")) was accepted") {
            try Self.policy().validate(executable: executable, arguments: arguments)
        }
    }

    @Test func thePluginScopedNameRuleNamesExactlyThreeSafeParts() {
        #expect(OperationCommandPolicy.isPluginScopedMCPIdentifier("plugin:sentry:sentry"))
        #expect(!OperationCommandPolicy.isPluginScopedMCPIdentifier("sentry"))
        #expect(!OperationCommandPolicy.isPluginScopedMCPIdentifier("plugin:sentry:sentry:x"))
        #expect(!OperationCommandPolicy.isPluginScopedMCPIdentifier("plugin::"))
        #expect(!OperationCommandPolicy.isSafeMCPIdentifier("plugin:sentry:sentry"), "a plain name still takes no colon")
    }

    private static func policy() -> OperationCommandPolicy {
        let root = FileManager.default.temporaryDirectory.appending(path: "plugin-login-policy", directoryHint: .isDirectory)
        return OperationCommandPolicy(
            libraryURL: root.appending(path: "library", directoryHint: .isDirectory),
            gitBackupRoot: root.appending(path: "backup", directoryHint: .isDirectory),
            homeURL: root.appending(path: "home", directoryHint: .isDirectory))
    }
}
