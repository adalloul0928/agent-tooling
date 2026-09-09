import Foundation
import Testing

@testable import AgentToolingCore

/// Settings whose files add up rather than override each other. The misreading
/// worth preventing is someone believing their own file replaced a project's
/// hooks — and therefore believing commands are not running that are.
@Suite("Combined setting breakdown")
struct CombinedSettingBreakdownTests {
    @Test func everyFilesEntriesAreCountedNotJustTheOneWithTheMostSay() {
        let configuration = Self.resolve(layers: [
            .init(kind: .project, sourcePath: "/p/.claude/settings.json", isWritable: true,
                  values: ["hooks": .list([.opaque("a"), .opaque("b")])]),
            .init(kind: .user, sourcePath: "/h/.claude/settings.json", isWritable: true,
                  values: ["hooks": .list([.opaque("c")])]),
        ])

        let hooks = configuration.combinedBreakdowns.first { $0.key == "hooks" }
        #expect(hooks?.totalEntryCount == 3)
        #expect(hooks?.contributingFileCount == 2)
        // Precedence order, so the list reads the way the client reads it.
        #expect(hooks?.contributions.map(\.layer) == [.project, .user])
        #expect(hooks?.contributions.map(\.entryCount) == [2, 1])
    }

    @Test func aSettingThatReplacesGetsNoBreakdownAtAll() {
        let configuration = Self.resolve(layers: [
            .init(kind: .project, sourcePath: "/p/.claude/settings.json", isWritable: true,
                  values: ["model": .string("project-model")]),
            .init(kind: .user, sourcePath: "/h/.claude/settings.json", isWritable: true,
                  values: ["model": .string("user-model")]),
        ])

        // A breakdown would imply the lower file still matters. It does not.
        #expect(!configuration.combinedBreakdowns.contains { $0.key == "model" })
        #expect(configuration.rows.first { $0.key == "model" }?.value == .string("project-model"))
    }

    @Test func aFileThatMentionsTheKeyButAddsNothingIsNotAContributingFile() {
        let configuration = Self.resolve(layers: [
            .init(kind: .project, sourcePath: "/p/.claude/settings.json", isWritable: true,
                  values: ["hooks": .list([])]),
            .init(kind: .user, sourcePath: "/h/.claude/settings.json", isWritable: true,
                  values: ["hooks": .list([.opaque("a")])]),
        ])

        let hooks = configuration.combinedBreakdowns.first { $0.key == "hooks" }
        // Present but empty is a different fact from not mentioning it, and the
        // count says so without dropping the row.
        #expect(hooks?.contributions.map(\.entryCount) == [0, 1])
        #expect(hooks?.contributingFileCount == 1)
        #expect(hooks?.totalEntryCount == 1)
    }

    @Test func everyContributionNamesTheFileItCameFrom() {
        let configuration = Self.resolve(layers: [
            .init(kind: .user, sourcePath: "/h/.claude/settings.json", isWritable: true,
                  values: ["hooks": .list([.opaque("a")])]),
        ])

        // The honest answer to "what does this hook do" is to take the person to
        // the file, which needs the file's own path.
        #expect(configuration.combinedBreakdowns.first?.contributions.first?.sourcePath
            == "/h/.claude/settings.json")
    }

    @Test func aWorkspaceWithNoCombinedSettingsHasNothingToBreakDown() {
        let configuration = Self.resolve(layers: [
            .init(kind: .user, sourcePath: "/h/.claude/settings.json", isWritable: true,
                  values: ["model": .string("user-model")]),
        ])

        #expect(configuration.combinedBreakdowns.allSatisfy { $0.contributingFileCount == 0 })
    }

    private static func resolve(layers: [ConfigurationLayer]) -> EffectiveConfiguration {
        EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0",
            layers: layers)
    }
}
