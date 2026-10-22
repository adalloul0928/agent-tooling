import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The copies of one skill this Mac's managed apps hold, grouped by folder,
/// and whether they hold the same skill. "Same" is the definition digest the
/// Library already shows, never a guess from a name.
@Suite("Observed skill copies")
struct ObservedSkillCopiesTests {
    @Test func juniperHasTwoDifferentCopiesOfFrontendDesign() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let observations = await Self.read(world)

        let copies = ObservedSkillCopies.group(
            observations: observations, managed: [.codex, .claude, .gemini], declaredName: "frontend-design")

        // Codex's folder comes first, in the app order, and Gemini CLI reads
        // the same folder through ~/.agents/skills: one copy, two readers.
        #expect(
            copies.map(\.path) == [Self.path(world, ".agents/skills/frontend-design"), Self.path(world, ".claude/skills/frontend-design")])
        #expect(copies.map(\.readers) == [[.codex, .gemini], [.claude]])
        #expect(copies.allSatisfy { $0.definitionDigest?.count == 64 })
        #expect(ObservedSkillCopies.differ(copies))
        #expect(copies.allSatisfy { $0.fileCount == nil && $0.changedAt == nil }, "measuring is a separate step")
    }

    @Test func juniperHasTwoIdenticalCopiesOfWebappTesting() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let observations = await Self.read(world)

        let copies = ObservedSkillCopies.group(
            observations: observations, managed: [.codex, .claude, .gemini], declaredName: "webapp-testing")

        #expect(
            copies.map(\.path) == [Self.path(world, ".codex/skills/webapp-testing"), Self.path(world, ".claude/skills/webapp-testing")])
        #expect(copies.map(\.readers) == [[.codex], [.claude]])
        #expect(!ObservedSkillCopies.differ(copies))
    }

    @Test func aSkillInOneAppIsOneCopy() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let observations = await Self.read(world)

        let copies = ObservedSkillCopies.group(
            observations: observations, managed: [.codex, .claude, .gemini], declaredName: "release-notes")

        #expect(copies.map(\.readers) == [[.claude]])
        #expect(!ObservedSkillCopies.differ(copies))
    }

    @Test func anAppThatIsNotManagedIsNotLookedAt() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let observations = await Self.read(world)

        let withoutGemini = ObservedSkillCopies.group(
            observations: observations, managed: [.codex, .claude], declaredName: "frontend-design")
        #expect(withoutGemini.map(\.readers) == [[.codex], [.claude]])

        let claudeOnly = ObservedSkillCopies.group(observations: observations, managed: [.claude], declaredName: "frontend-design")
        #expect(claudeOnly.map(\.readers) == [[.claude]])
        #expect(!ObservedSkillCopies.differ(claudeOnly))
    }

    @Test func aPluginsMemberIsNotACopyToChoose() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let observations = await Self.read(world)
        let claude = try #require(observations.first { $0.surface == .claudeCode })
        let member = try #require(claude.skillMetadata["sentry:triage-issue"])
        #expect(member.providerPluginID == "sentry@claude-plugins-official")

        #expect(ObservedSkillCopies.group(observations: observations, managed: [.claude], declaredName: "sentry:triage-issue").isEmpty)
        #expect(ObservedSkillCopies.group(observations: observations, managed: [.claude], declaredName: "triage-issue").isEmpty)
    }

    /// A folder another tool placed and keeps in step is that tool's: taking
    /// it into the library would fork it.
    @Test func aCopyAnotherToolKeepsInStepIsNotACopyToChoose() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        var observations = await Self.read(world)
        let index = try #require(observations.firstIndex { $0.surface == .claudeCode })
        observations[index].skillMetadata["release-notes"]?.externalManager = .init(tool: "Example Manager", package: "Example Package")
        #expect(observations[index].skillMetadata["release-notes"]?.externalManager?.tool == "Example Manager")

        #expect(ObservedSkillCopies.group(observations: observations, managed: [.claude], declaredName: "release-notes").isEmpty)
    }

    @Test func copiesNotReadAlikeAreNeverTheSame() {
        let read = ObservedSkillCopy(path: "/a", readers: [.codex], definitionDigest: "1")
        let alike = ObservedSkillCopy(path: "/b", readers: [.claude], definitionDigest: "1")
        let unread = ObservedSkillCopy(path: "/c", readers: [.claude], definitionDigest: nil)

        #expect(!ObservedSkillCopies.differ([read, alike]))
        #expect(ObservedSkillCopies.differ([read, unread]), "nil is not compared, so it is never the same")
        #expect(!ObservedSkillCopies.differ([unread]), "one copy differs from nothing")
        #expect(!ObservedSkillCopies.differ([]))
    }

    @Test func oneFolderIsOneCopyHoweverItIsSpelled() throws {
        let capabilities = try #require(ClientAdapterRegistry().adapter(for: .codex)?.capabilities)
        func observation(_ surface: TargetSurface, path: String) -> TargetObservation {
            TargetObservation(
                surface: surface, installed: true,
                skillMetadata: ["shared": .init(path: path, source: "Standalone", definitionDigest: "d")],
                capabilities: capabilities)
        }

        let copies = ObservedSkillCopies.group(
            observations: [
                observation(.geminiCLI, path: "/home/.agents/skills/shared/"),
                observation(.codexCLI, path: "/home/.agents/./skills/shared"),
            ],
            managed: [.codex, .gemini], declaredName: "shared")

        #expect(copies.count == 1)
        #expect(copies.first?.readers == [.codex, .gemini])
    }

    private static func read(_ world: ClientHomeFixture) async -> [TargetObservation] {
        await world.registry.scanAll(homeURL: world.url, runner: world.scriptedRunner(), clients: world.found)
    }

    private static func path(_ world: ClientHomeFixture, _ relative: String) -> String {
        ProjectPath.canonical(world.home.appending(relative, directoryHint: .isDirectory))
    }
}
