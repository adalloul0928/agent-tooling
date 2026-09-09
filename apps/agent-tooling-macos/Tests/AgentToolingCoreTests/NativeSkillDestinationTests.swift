import Foundation
import Testing

@testable import AgentToolingCore

struct NativeSkillDestinationTests {
    private let home = URL(fileURLWithPath: "/private/tmp/agent-tooling-home", isDirectory: true)
    private let project = URL(fileURLWithPath: "/private/tmp/agent-tooling-project", isDirectory: true)

    @Test(arguments: [
        (ClientKind.claude, "/private/tmp/agent-tooling-home/.claude/skills"),
        (ClientKind.codex, "/private/tmp/agent-tooling-home/.agents/skills"),
        (ClientKind.gemini, "/private/tmp/agent-tooling-home/.gemini/skills"),
    ])
    func routesUserDirectories(_ client: ClientKind, _ expected: String) throws {
        let destination = try NativeSkillDestination.directory(
            client: client, homeURL: home, scope: .user, projectRoot: nil
        )
        #expect(destination.path == expected)
    }

    @Test(arguments: [
        (ClientKind.claude, "/private/tmp/agent-tooling-project/.claude/skills"),
        (ClientKind.codex, "/private/tmp/agent-tooling-project/.agents/skills"),
        (ClientKind.gemini, "/private/tmp/agent-tooling-project/.gemini/skills"),
    ])
    func routesProjectDirectories(_ client: ClientKind, _ expected: String) throws {
        let destination = try NativeSkillDestination.directory(
            client: client, homeURL: home, scope: .project, projectRoot: project
        )
        #expect(destination.path == expected)
    }

    @Test func appendsOneSafeSkillPathComponent() throws {
        let destination = try NativeSkillDestination.skillURL(
            client: .codex, skillID: "review-documents", homeURL: home, scope: .project, projectRoot: project
        )
        #expect(destination.path == "/private/tmp/agent-tooling-project/.agents/skills/review-documents")
    }

    @Test func projectScopeRequiresAnExplicitValidatedRoot() throws {
        #expect(throws: NativeSkillDestinationError.missingProjectRoot) {
            try NativeSkillDestination.directory(client: .claude, homeURL: home, scope: .project, projectRoot: nil)
        }
        #expect(throws: NativeSkillDestinationError.invalidProjectRoot) {
            try NativeSkillDestination.directory(
                client: .claude, homeURL: home, scope: .project,
                projectRoot: URL(string: "https://example.com/project")
            )
        }
    }

    @Test(arguments: [ToolingScope.localProject, .workspace, .managed, .account, .session])
    func rejectsScopesWithoutLegacySkillRouting(_ scope: ToolingScope) {
        #expect(throws: NativeSkillDestinationError.unsupportedScope) {
            try NativeSkillDestination.directory(client: .codex, homeURL: home, scope: scope, projectRoot: project)
        }
    }

    @Test func rejectsNonFileAndNonNormalizedRoots() {
        #expect(throws: NativeSkillDestinationError.invalidHomeURL) {
            try NativeSkillDestination.directory(
                client: .gemini, homeURL: URL(string: "https://example.com/home")!, scope: .user, projectRoot: nil
            )
        }
        #expect(throws: NativeSkillDestinationError.invalidHomeURL) {
            try NativeSkillDestination.directory(
                client: .gemini,
                homeURL: URL(fileURLWithPath: "/private/tmp/agent-tooling-home/../other", isDirectory: true),
                scope: .user,
                projectRoot: nil
            )
        }
    }

    @Test(arguments: ["", ".", "..", "/absolute", "nested/skill", "nested\\skill", "bad\u{0000}name"])
    func rejectsUnsafeSkillPathComponents(_ skillID: String) {
        #expect(throws: NativeSkillDestinationError.invalidSkillID) {
            try NativeSkillDestination.skillURL(
                client: .claude, skillID: skillID, homeURL: home, scope: .user, projectRoot: nil
            )
        }
    }
}
