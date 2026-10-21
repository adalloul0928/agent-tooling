import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The placements this Mac's setup made, kept beside the record in
/// `setup-placements.json`: read as tolerantly as the record, never written
/// over by an older build, and never pruned of what the save that made them
/// just returned.
@Suite("Setup progress · placements made here")
@MainActor
struct SetupProgressPlacementsMadeHereTests {
    private let first = WorkspaceObjectID()
    private let second = WorkspaceObjectID()

    // MARK: - The file

    @Test func theListKeepsItsVersionAndIsPrivateToThisMacsUser() throws {
        let folder = try TemporaryFolder("setup-placements")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = LiveSetupProgressStore(container: folder.url)

        try store.savePlacementsMadeHere([first, second])

        #expect(store.loadPlacementsMadeHere() == [first, second])
        let text = try String(contentsOf: store.placementsURL, encoding: .utf8)
        #expect(text == #"{"contributionIDs":["\#(Self.id(first))","\#(Self.id(second))"],"formatVersion":1}"#)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.placementsURL.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Staged beside it and renamed into place: nothing else is left.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path(percentEncoded: false)) == ["setup-placements.json"])
    }

    /// A list with no version is this build's; an ID this build cannot read
    /// is skipped; a file that is not a list at all reads as an empty one.
    @Test func whatThisBuildCannotReadIsSkippedOrEmpty() throws {
        let folder = try TemporaryFolder("setup-placements")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = LiveSetupProgressStore(container: folder.url)
        #expect(store.loadPlacementsMadeHere().isEmpty)

        try write(store.placementsURL, #"{"contributionIDs":["\#(Self.id(first))","not-an-id",7]}"#)
        #expect(store.loadPlacementsMadeHere() == [first])

        try write(store.placementsURL, "not a list")
        #expect(store.loadPlacementsMadeHere().isEmpty)
        try store.savePlacementsMadeHere([second])
        #expect(store.loadPlacementsMadeHere() == [second], "an unreadable list is written over")
    }

    /// A newer build's list is read, so its placements are still never
    /// arrivals, but this build never writes over it.
    @Test func aNewerListIsReadButNeverWrittenOver() throws {
        let folder = try TemporaryFolder("setup-placements")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = LiveSetupProgressStore(container: folder.url)
        try write(store.placementsURL, #"{"contributionIDs":["\#(Self.id(first))"],"formatVersion":2,"laterField":{"kept":true}}"#)
        let bytes = try Data(contentsOf: store.placementsURL)

        #expect(store.loadPlacementsMadeHere() == [first])
        try store.savePlacementsMadeHere([second])
        #expect(try Data(contentsOf: store.placementsURL) == bytes)

        let session = WorkspaceSetupProgressSession(store: store)
        session.recordPlacementsMadeHere([second], inLibrary: nil)
        #expect(session.placementsMadeHere == [first, second], "this launch still knows both")
        #expect(try Data(contentsOf: store.placementsURL) == bytes)
    }

    /// Beside a newer build's record the stage writes nothing at all, the
    /// list included.
    @Test func besideANewerRecordTheListIsNotWritten() throws {
        let folder = try TemporaryFolder("setup-placements")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = LiveSetupProgressStore(container: folder.url)
        try write(
            store.fileURL,
            #"{"formatVersion":2,"state":"finished","path":"startHere","startedAt":"2026-10-17T16:41:00Z"}"#)
        let session = WorkspaceSetupProgressSession(store: store)

        session.recordPlacementsMadeHere([first], inLibrary: nil)

        #expect(session.ownPlacements == [first])
        #expect(!FileManager.default.fileExists(atPath: store.placementsURL.path(percentEncoded: false)))
    }

    // MARK: - Pruning

    /// The library's assignments, read before the save that made a
    /// placement (its refresh after the save failed), never prune that
    /// placement: the save itself vouches for it. A placement a later walk
    /// took back leaves the list.
    @Test func whatASaveReturnedStaysWhenTheLibraryWasReadBeforeIt() throws {
        let folder = try TemporaryFolder("setup-placements")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = LiveSetupProgressStore(container: folder.url)
        let session = WorkspaceSetupProgressSession(store: store)

        session.recordPlacementsMadeHere([first], inLibrary: [first])
        session.recordPlacementsMadeHere([second], inLibrary: [first])
        #expect(session.placementsMadeHere == [first, second])

        session.recordPlacementsMadeHere([], inLibrary: [second])
        #expect(session.placementsMadeHere == [second])
        #expect(WorkspaceSetupProgressSession(store: store).placementsMadeHere == [second], "as the next launch reads it")
    }

    private static func id(_ id: WorkspaceObjectID) -> String {
        id.rawValue.uuidString.lowercased()
    }
}
