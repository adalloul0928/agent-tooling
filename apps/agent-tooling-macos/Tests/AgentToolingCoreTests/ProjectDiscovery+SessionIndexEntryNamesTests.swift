import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// What a first read takes from Claude Code's project history: the names of
/// the folders in its session index and nothing more, so nothing outside the
/// index is looked at — not even a project in `~/Documents`, which would
/// have macOS ask the person for access in the middle of setup.
@Suite("Project discovery · session index names")
struct SessionIndexEntryNamesTests {
    /// Juniper's four, the one whose project is in `~/Documents` included,
    /// though that folder is not even there: no name is turned back into a
    /// folder.
    @Test func juniperListsItsFourNames() throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        let names = ProjectDiscovery.sessionIndexEntryNames(homeURL: world.url)

        #expect(names == world.projectHistoryEntryNames)
        #expect(names.count == 4)
        #expect(ProjectDiscovery.sessionIndexRoots(homeURL: world.url).count == 3, "only three of the folders are on this Mac")
    }

    /// Only the index is looked at, with the project folders it names
    /// planted, the one in `~/Documents` among them.
    @Test func onlyTheIndexIsLookedAt() throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        try world.plantDecoys()
        let trace = FirstReadPlaceLog()

        let names = ScanTrace.$current.withValue(trace) { ProjectDiscovery.sessionIndexEntryNames(homeURL: world.url) }

        #expect(names.count == 4)
        #expect(trace.places == [ProjectDiscovery.sessionIndexURL(homeURL: world.url)])
    }

    /// A file, a link, or a name Claude Code does not write is not a folder
    /// it ran in, and none is followed to find out.
    @Test func onlyFoldersNamedAsClaudeCodeNamesThemAreListed() throws {
        let home = try FixtureHome("session-index-names")
        defer { home.remove() }
        let index = ProjectDiscovery.sessionIndexURL(homeURL: home.url)
        try home.plant(".claude/projects/-Users-you-code-app/session.jsonl", "{}\n")
        try home.plant(".claude/projects/-Users-you-notes.md", "a file\n")
        try home.plant(".claude/projects/scratch/session.jsonl", "{}\n")
        try home.plant("Documents/private/notes.md", "private\n")
        try FileManager.default.createSymbolicLink(
            at: index.appending(path: "-Users-you-Documents-private"),
            withDestinationURL: home.appending("Documents/private", directoryHint: .isDirectory))

        #expect(ProjectDiscovery.sessionIndexEntryNames(homeURL: home.url) == ["-Users-you-code-app"])
    }

    @Test func aMacWithoutAnIndexHasNoNames() throws {
        let home = try FixtureHome("session-index-none")
        defer { home.remove() }

        #expect(ProjectDiscovery.sessionIndexEntryNames(homeURL: home.url).isEmpty)
    }

    /// The same bound as the folders Projects resolves, kept in name order.
    @Test func theNamesAreBounded() throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        let names = ProjectDiscovery.sessionIndexEntryNames(
            homeURL: world.url, options: ProjectDiscoveryOptions(maximumSessionIndexEntries: 2))

        #expect(names == Array(world.projectHistoryEntryNames.prefix(2)))
    }
}
