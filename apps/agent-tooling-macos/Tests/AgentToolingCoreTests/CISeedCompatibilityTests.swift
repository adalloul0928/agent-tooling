// Public API only, deliberately: the CI fixture that seeds this workspace is
// compiled outside the package against the AgentToolingCore product, so a
// `@testable` import here would hide exactly the break it exists to catch.
import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

/// The Raycast CLI smoke step (`.github/workflows/macos-app.yml`) seeds an
/// empty workspace with exactly this call, then runs the CLI against it. The
/// seed must keep compiling and keep meaning what it meant: a plain workspace
/// with no setup record and no assistant choice, which the CLI opens.
@Suite("CI seed compatibility")
struct CISeedCompatibilityTests {
    @Test func theSeedCreatesAWorkspaceTheCLIOpens() async throws {
        let folder = try TemporaryFolder("ci-seed")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        // The fixture's own lines, word for word apart from the root.
        let root = URL(fileURLWithPath: folder.url.path(percentEncoded: false)).standardizedFileURL
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await WorkspaceLocator(root: root).openOrCreate(
            homeURL: home, runner: ProcessCommandRunner(homeURL: home),
            registry: ClientAdapterRegistry(adapters: []))

        // The CLI opens it the way it opens any workspace, creating nothing.
        let store = try #require(try WorkspaceLocator(root: root.standardizedFileURL).open())
        let snapshot = try #require(try store.snapshot())
        #expect(snapshot.document.artifacts.isEmpty)
        #expect(snapshot.document.revision.parentIDs.isEmpty, "the head is revision 1")
        #expect(snapshot.device.observations.isEmpty, "an empty registry reads no app")
        let preferences = try #require(snapshot.device.applicationState?.preferences)
        #expect(preferences.assistantRuns == nil, "a seed records no assistant choice, so it reads as an existing workspace")
        #expect(preferences.findsProjectsFromClaudeHistory == nil)
        #expect(preferences.chosenClients == nil)

        // The CLI's search over it answers what the smoke step asserts.
        let inventory = try VersionedInventorySource(store: store).workspaceSnapshot()
        let search = IntegrationSearchIndex.response(for: inventory, query: "release")
        #expect(search.results.isEmpty)
        #expect(search.totalResults == 0)
        #expect(!search.truncated)

        // No setup record of any kind is written by the seed.
        let written = FileManager.default.subpaths(atPath: root.path(percentEncoded: false)) ?? []
        #expect(!written.contains { $0.hasSuffix("setup-progress.json") }, "\(written)")
        #expect(written.contains(WorkspaceLocator.recordFileName))
    }

    @Test func seedingTwiceOpensTheFirstWorkspaceRatherThanASecond() async throws {
        let folder = try TemporaryFolder("ci-seed-twice")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let root = URL(fileURLWithPath: folder.url.path(percentEncoded: false)).standardizedFileURL
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let first = try await WorkspaceLocator(root: root).openOrCreate(
            homeURL: home, runner: ProcessCommandRunner(homeURL: home), registry: ClientAdapterRegistry(adapters: []))
        let second = try await WorkspaceLocator(root: root).openOrCreate(
            homeURL: home, runner: ProcessCommandRunner(homeURL: home), registry: ClientAdapterRegistry(adapters: []))

        #expect(first.workspaceID == second.workspaceID)
        #expect(first.deviceID == second.deviceID)
    }
}
