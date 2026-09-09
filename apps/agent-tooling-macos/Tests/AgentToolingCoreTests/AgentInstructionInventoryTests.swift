import Foundation
import Testing

@testable import AgentToolingCore

/// What each client reads as standing instructions. The locations are recorded
/// from each vendor's own page, and the clients genuinely disagree about which
/// filename they read — which is one of the more useful things this can say.
@Suite("Agent instruction inventory")
struct AgentInstructionInventoryTests {
    @Test func everyPlaceAClientLooksIsReportedWithItsScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".claude/CLAUDE.md", in: fixture.home, "user instructions\n")
        try fixture.write("CLAUDE.md", in: fixture.project, "project instructions\n")
        try fixture.write("CLAUDE.local.md", in: fixture.project, "mine only\n")

        let result = fixture.scan()

        let instructions = result.entries(for: .claudeCode, kind: .instructions)
        #expect(instructions.map(\.scope) == [.localProject, .project, .user])
        #expect(instructions.allSatisfy { $0.byteCount > 0 })
    }

    @Test func rulesAndAgentsAreFoundIncludingInSubfolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".claude/rules/testing.md", in: fixture.project, "rule\n")
        try fixture.write(".claude/rules/frontend/style.md", in: fixture.project, "nested rule\n")
        try fixture.write(".claude/agents/reviewer.md", in: fixture.project, "agent\n")
        try fixture.write(".claude/agents/team/auditor.md", in: fixture.home, "user agent\n")

        let result = fixture.scan()

        // Both clients allow organising these into subfolders, and a rule in
        // one still loads.
        #expect(result.entries(for: .claudeCode, kind: .rule).count == 2)
        #expect(result.entries(for: .claudeCode, kind: .agent).map(\.scope).sorted { $0.rawValue < $1.rawValue }
            == [.project, .user])
    }

    @Test func aProjectWithOnlyAgentsMdIsToldClaudeCodeWillNotReadIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("AGENTS.md", in: fixture.project, "instructions for other agents\n")

        let result = fixture.scan()

        // Nothing else on the screen would show this, and the consequence is
        // that none of that file reaches Claude Code at all.
        let note = try #require(result.notes.first { $0.surface == .claudeCode })
        #expect(note.detail.contains("will not read AGENTS.md"))
        #expect(result.entries(for: .claudeCode, kind: .instructions).isEmpty)
        // Codex does read it, from the same project.
        #expect(result.entries(for: .codexCLI, kind: .instructions).count == 1)
    }

    @Test func aProjectWithBothIsNotWarnedAbout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("AGENTS.md", in: fixture.project, "shared\n")
        try fixture.write("CLAUDE.md", in: fixture.project, "@AGENTS.md\n")

        let result = fixture.scan()

        #expect(result.notes.isEmpty)
        #expect(result.entries(for: .claudeCode, kind: .instructions).count == 1)
    }

    @Test func codexUsesTheFirstNonEmptyNameAndStopsThere() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("AGENTS.override.md", in: fixture.project, "the override\n")
        try fixture.write("AGENTS.md", in: fixture.project, "the ordinary one\n")

        let result = fixture.scan()

        let entries = result.entries(for: .codexCLI, kind: .instructions)
        #expect(entries.count == 1)
        #expect(entries.first?.path.hasSuffix("AGENTS.override.md") == true)
    }

    @Test func anEmptyOverrideDoesNotShadowTheFileThatHasContent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("AGENTS.override.md", in: fixture.project, "")
        try fixture.write("AGENTS.md", in: fixture.project, "the real one\n")

        let result = fixture.scan()

        // Codex uses the first *non-empty* one, so reporting the empty override
        // would name a file that contributes nothing.
        #expect(result.entries(for: .codexCLI, kind: .instructions).first?
            .path.hasSuffix("AGENTS.md") == true)
    }

    @Test func codexHomeInstructionsAreFoundSeparatelyFromTheProjects() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".codex/AGENTS.md", in: fixture.home, "my own\n")
        try fixture.write("AGENTS.md", in: fixture.project, "the team's\n")

        let result = fixture.scan()

        #expect(result.entries(for: .codexCLI, kind: .instructions).map(\.scope) == [.project, .user])
    }

    @Test func aDirectoryWhereAFileIsExpectedIsNotAnInstructionFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.project.appending(path: "CLAUDE.md"), withIntermediateDirectories: true)

        #expect(fixture.scan().entries(for: .claudeCode, kind: .instructions).isEmpty)
    }

    @Test func aMacWithNoneOfThemReportsNoneRatherThanFailing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = fixture.scan()

        #expect(result.entries.isEmpty)
        #expect(result.notes.isEmpty)
    }

    @Test func withoutAProjectOnlyThisMacsOwnFilesAreReported() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".claude/CLAUDE.md", in: fixture.home, "mine\n")
        try fixture.write("CLAUDE.md", in: fixture.project, "the team's\n")

        let result = AgentInstructionInventory.scan(homeRoot: fixture.home)

        #expect(result.entries.map(\.scope) == [.user])
    }

    @Test func everyRecordedLocationNamesThePageItWasReadFrom() {
        // A stale fact should be recheckable against its source rather than
        // argued about.
        for source in [AgentInstructionInventory.Source.claudeInstructions,
                       AgentInstructionInventory.Source.claudeAgents,
                       AgentInstructionInventory.Source.codexInstructions] {
            #expect(source.hasPrefix("https://"))
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let project: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "instruction-inventory-\(UUID())")
            home = root.appending(path: "home")
            project = root.appending(path: "project")
            for url in [home, project] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
        }

        func write(_ relativePath: String, in base: URL, _ contents: String) throws {
            let url = base.appending(path: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        func scan() -> AgentInstructionInventory.Result {
            AgentInstructionInventory.scan(homeRoot: home, projectRoot: project)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
