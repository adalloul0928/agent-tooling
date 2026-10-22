import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Measuring the copies a person chooses between: how many files each holds
/// and when the newest changed. Whether two copies are the same skill is
/// still the definition digest the check read, which measuring never changes.
@Suite("Observed skill copies · measure")
struct ObservedSkillCopiesMeasureTests {
    @Test func juniperFrontendDesignCopiesReadTheirFileCountsAndDates() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let observations = await world.registry.scanAll(homeURL: world.url, runner: world.scriptedRunner(), clients: world.found)
        let copies = ObservedSkillCopies.group(
            observations: observations, managed: [.codex, .claude, .gemini], declaredName: "frontend-design")

        let measured = await ObservedSkillCopies.measure(copies)

        // Codex's copy (which Gemini CLI reads too) holds two files and changed
        // on August 14; Claude Code's holds three and changed on October 2.
        #expect(measured.map(\.fileCount) == [2, 3])
        let calendar = Calendar(identifier: .gregorian)
        #expect(
            measured.map { $0.changedAt.map { calendar.dateComponents([.month, .day], from: $0) } } == [
                DateComponents(month: 8, day: 14), DateComponents(month: 10, day: 2),
            ])
        // Measuring adds a count and a date, and nothing else.
        #expect(measured.map(\.path) == copies.map(\.path))
        #expect(measured.map(\.readers) == copies.map(\.readers))
        #expect(measured.map(\.definitionDigest) == copies.map(\.definitionDigest))
        #expect(ObservedSkillCopies.differ(measured) == ObservedSkillCopies.differ(copies))
    }

    /// Two copies that differ only in a packaging stamp, a manager's hidden
    /// marker and a newer file date are the same skill before and after they
    /// are measured: "same" is the definition digest, never a file count or a
    /// date.
    @Test func aPackagingStampDoesNotMakeTwoCopiesDiffer() async throws {
        let home = try FixtureHome("measure-stamp")
        defer { home.remove() }
        try home.plantSkill(
            ".claude/skills/shared", name: "shared", description: "Shared.",
            modifiedAt: Self.date(month: 9, day: 1))
        try home.plant(
            ".codex/skills/shared/SKILL.md",
            "---\nname: shared\ndescription: Shared.\nmetadata:\n  build: 2026.10.16\n  commit: 4f1c2e9\n---\n\nFollow the steps.\n")
        try home.plant(".codex/skills/shared/.manager-stamp", "placed by a package manager\n")
        let claude = home.appending(".claude/skills/shared", directoryHint: .isDirectory)
        let codex = home.appending(".codex/skills/shared", directoryHint: .isDirectory)
        let copies = [
            ObservedSkillCopy(
                path: ProjectPath.canonical(codex), readers: [.codex],
                definitionDigest: ToolCopyIdentity.definitionDigest(ofSkillAt: codex)),
            ObservedSkillCopy(
                path: ProjectPath.canonical(claude), readers: [.claude],
                definitionDigest: ToolCopyIdentity.definitionDigest(ofSkillAt: claude)),
        ]
        #expect(!ObservedSkillCopies.differ(copies), "the stamp is dropped before the digest")

        let measured = await ObservedSkillCopies.measure(copies)

        #expect(!ObservedSkillCopies.differ(measured))
        #expect(measured.map(\.fileCount) == [1, 1], "a hidden marker is the manager's, not a file of the skill")
        #expect(measured[0].changedAt != measured[1].changedAt)
    }

    @Test func aFolderThatCannotBeReadKeepsAnUnknownCountAndDate() async {
        let missing = ObservedSkillCopy(path: "/nowhere/\(UUID().uuidString)/skill", readers: [.claude], definitionDigest: nil)

        let measured = await ObservedSkillCopies.measure([missing])

        #expect(measured == [missing], "unknown, never zero")
    }

    @Test func nestedFilesCountAndTheNewestDateWins() async throws {
        let home = try FixtureHome("measure-nested")
        defer { home.remove() }
        try home.plantSkill(
            "skills/deep", name: "deep", description: "Deep.",
            files: ["a/b/c.md": "c\n", "scripts/run.sh": "#!/bin/sh\n"], modifiedAt: Self.date(month: 7, day: 1))
        let newest = Self.date(month: 9, day: 30)
        try FileManager.default.setAttributes(
            [.modificationDate: newest],
            ofItemAtPath: home.appending("skills/deep/a/b/c.md").path(percentEncoded: false))
        let folder = home.appending("skills/deep", directoryHint: .isDirectory)

        let measured = await ObservedSkillCopies.measure([
            ObservedSkillCopy(path: ProjectPath.canonical(folder), readers: [.kiro], definitionDigest: nil)
        ])

        #expect(measured.first?.fileCount == 3)
        #expect(measured.first?.changedAt == newest)
    }

    private static func date(month: Int, day: Int) -> Date {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: month, day: day, hour: 12).date
            ?? Date(timeIntervalSince1970: 0)
    }
}
