import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// What the launch decides from before any window is drawn: the library
/// record's state, read without opening the store. No record is a first run;
/// a record this build reads names the folder its store is in; a newer
/// build's record and a damaged one are told apart, and both still count as
/// a workspace, so a second one is never started beside them.
@Suite("Workspace launch · the record's state", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceLaunchRecordStateTests {
    @Test func noRecordIsAFirstRun() throws {
        let folder = try TemporaryFolder("record-state")
        defer { try? FileManager.default.removeItem(at: folder.url) }

        #expect(WorkspaceLaunch.recordState(supportRoot: folder.url) == .none)
    }

    /// The record the stage's commit writes, with the folder the store opened.
    @Test func theCommitsRecordNamesItsStoresFolder() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await WorkspaceLaunch.create(
            observations: fixture.orderedObservations, preferences: fixture.seed.preferences, supportRoot: fixture.support,
            homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)

        guard case .present(let record, let container) = WorkspaceLaunch.recordState(supportRoot: fixture.support) else {
            Issue.record("The record the commit wrote was not read: \(WorkspaceLaunch.recordState(supportRoot: fixture.support))")
            return
        }
        #expect(record.workspaceID == workspace.store.workspaceID)
        #expect(record.deviceID == workspace.store.deviceID)
        #expect(container == workspace.store.databaseURL.deletingLastPathComponent())
        #expect(fixture.hasWorkspace)
    }

    @Test func aNewerBuildsRecordIsToldApart() throws {
        let folder = try TemporaryFolder("record-state")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let ids = (WorkspaceObjectID().rawValue.uuidString, WorkspaceObjectID().rawValue.uuidString)
        try write(
            folder.url.appending(path: WorkspaceLocator.recordFileName),
            #"{"formatVersion":2,"workspaceID":"\#(ids.0)","deviceID":"\#(ids.1)","laterField":true}"#)

        #expect(WorkspaceLaunch.recordState(supportRoot: folder.url) == .newerFormat)
    }

    @Test func aFileThatIsNotARecordIsDamaged() throws {
        let folder = try TemporaryFolder("record-state")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try write(folder.url.appending(path: WorkspaceLocator.recordFileName), "not a record")

        #expect(WorkspaceLaunch.recordState(supportRoot: folder.url) == .damaged)
    }
}
