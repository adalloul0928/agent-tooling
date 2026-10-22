import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The setup record beside the store, and the session the stage and Home's
/// card write it through.
///
/// The record is read by builds older and newer than the one that wrote it,
/// so decoding is tolerant by rule; every change is saved before it is shown
/// as kept; and the D20 rules decide what a rerun, a resume and Done write.
@Suite("Setup progress record and session")
@MainActor
struct SetupProgressSessionTests {
    private static let started = ClientHomeFixture.now
    private static let later = ClientHomeFixture.now.addingTimeInterval(600)

    // MARK: - The file

    @Test func aRecordSurvivesTheFileAndIsPrivateToThisMacsUser() throws {
        let folder = try TemporaryFolder("setup-record")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = LiveSetupProgressStore(container: folder.url)
        var record = SetupProgressRecord.started(
            path: .startHere, cursor: .found,
            evidence: .init(
                personalSkillsBefore: [ArtifactID()], placedContributionIDs: [WorkspaceObjectID()],
                checkupFindingIDs: ["finding-1"], trial: .init(skillName: "Release Notes", skillID: "release-notes", client: .codex),
                projectFolderCount: 4, mayNeedSignIn: [.init(connection: "Sentry", serverID: "sentry", client: .claude)]),
            now: Self.started)
        record.ticks = [.init(item: .putToolsInApps, place: .setup, at: Self.later, summary: "Installed 4 changes · 9:52 AM")]
        record.items = [.makeSkillsYours, .putToolsInApps]

        try store.save(record)

        #expect(store.load() == record)
        #expect(store.fileURL.lastPathComponent == "setup-progress.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Nothing but the record is left in the folder: the staged copy was
        // renamed into place.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path(percentEncoded: false)) == ["setup-progress.json"])
    }

    @Test func theSameRecordAlwaysWritesTheSameBytes() throws {
        let folder = try TemporaryFolder("setup-record")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = LiveSetupProgressStore(container: folder.url)
        let record = SetupProgressRecord.started(path: .join, cursor: .arrivals, now: Self.started)

        try store.save(record)
        let first = try Data(contentsOf: store.fileURL)
        try store.save(record)
        let second = try Data(contentsOf: store.fileURL)

        #expect(first == second)
        let text = String(decoding: first, as: UTF8.self)
        // Sorted keys, ISO 8601 dates, and the steps seen in the steps' order.
        #expect(text.hasPrefix(#"{"cursor":"arrivals","evidence":"#))
        #expect(text.contains(#""seen":["welcome","join","arrivals"]"#))
        #expect(text.contains(#""startedAt":"\#(ISO8601DateFormatter().string(from: Self.started))""#))
    }

    @Test func aMissingDamagedOrOversizedFileReadsAsNoRecord() throws {
        let folder = try TemporaryFolder("setup-record")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = LiveSetupProgressStore(container: folder.url)
        #expect(store.load() == nil)

        try write(store.fileURL, "not a record")
        #expect(store.load() == nil)

        try write(store.fileURL, String(repeating: " ", count: LiveSetupProgressStore.byteLimit + 1))
        #expect(store.load() == nil)
    }

    // MARK: - Tolerant decoding

    /// An older build reads a newer build's record: what it does not know is
    /// skipped, never fatal.
    @Test func whatThisBuildDoesNotKnowIsSkipped() throws {
        let json = #"""
            {"formatVersion":1,"state":"inProgress","path":"startHere","cursor":"someFutureStep",
             "seen":["welcome","someFutureStep","apps"],"startedAt":"2026-10-17T16:41:00Z","updatedAt":"2026-10-17T16:41:00Z",
             "items":["makeSkillsYours","someFutureItem"],
             "ticks":[{"item":"putToolsInApps","place":"setup","at":"2026-10-17T16:52:00Z"},
                      {"item":"someFutureItem","place":"setup","at":"2026-10-17T16:52:00Z"},
                      {"item":"trySkill","place":"someFuturePlace","at":"2026-10-17T16:52:00Z"}],
             "evidence":{"checkupFindingIDs":["a"],"mayNeedSignIn":[{"connection":"Sentry","serverID":"sentry","client":"Someday CLI"},
                         {"connection":"Linear","serverID":"linear","client":"Codex"}],"someFutureEvidence":true},
             "someFutureField":42}
            """#
        let record = try Self.decode(json)

        #expect(record.state == .inProgress)
        #expect(record.cursor == nil)
        #expect(record.seen == [.welcome, .apps])
        #expect(record.items == [.makeSkillsYours])
        #expect(record.ticks.map(\.item) == [.putToolsInApps])
        #expect(record.evidence.checkupFindingIDs == ["a"])
        #expect(record.evidence.mayNeedSignIn.map(\.connection) == ["Linear"])
    }

    @Test func anUnknownStateDefersAndAnUnknownPathIsARerun() throws {
        let record = try Self.decode(
            #"{"state":"someFutureState","path":"someFuturePath","startedAt":"2026-10-17T16:41:00Z"}"#)

        #expect(record.state == .deferred)
        #expect(record.path == .rerun)
        #expect(record.formatVersion == SetupProgressRecord.currentFormatVersion)
        #expect(record.updatedAt == record.startedAt)
        #expect(record.items.isEmpty)
        #expect(record.evidence == .init())
    }

    /// A record of a newer format never resumes and shows no card.
    @Test func aNewerFormatReadsAsFinished() throws {
        let record = try Self.decode(
            #"{"formatVersion":2,"state":"inProgress","path":"startHere","cursor":"place","startedAt":"2026-10-17T16:41:00Z"}"#)

        #expect(record.state == .finished)
        #expect(SetupStatus(record) == .finished(path: .startHere, seenPreferences: false))
    }

    /// An older build only reads a newer build's record: nothing it does,
    /// Done and Home's card included, writes over the newer build's fields
    /// or its state.
    @Test func aNewerFormatIsNeverWritten() throws {
        let folder = try TemporaryFolder("setup-record")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = LiveSetupProgressStore(container: folder.url)
        try write(
            store.fileURL,
            #"{"formatVersion":2,"state":"inProgress","path":"startHere","cursor":"place","#
                + #""startedAt":"2026-10-17T16:41:00Z","laterField":{"kept":true}}"#)
        let bytes = try Data(contentsOf: store.fileURL)
        let session = WorkspaceSetupProgressSession(store: store)
        let read = session.record

        session.tick(.trySkill, place: .home, now: Self.later)
        session.finish(items: FinishSetupItem.allCases, evidence: .init(projectFolderCount: 4), seen: [.done], now: Self.later)
        session.setChecklistHidden(true, now: Self.later)
        session.recordEvidence { $0.projectFolderCount = 2 }
        session.move(to: .behave, now: Self.later)
        session.deferSetup(at: .behave, now: Self.later)

        #expect(try Data(contentsOf: store.fileURL) == bytes)
        #expect(session.record == read)
        #expect(session.status == .finished(path: .startHere, seenPreferences: false))
        #expect(session.errorMessage == nil)
    }

    @Test func aRecordWithNoStartIsNotARecord() {
        #expect(throws: DecodingError.self) {
            try Self.decode(#"{"state":"inProgress","path":"startHere"}"#)
        }
    }

    // MARK: - What the shell reads

    @Test func theStatusFollowsTheRecord() {
        #expect(SetupStatus(nil) == .legacy)
        var record = SetupProgressRecord.started(path: .startHere, cursor: .place, now: Self.started)
        #expect(SetupStatus(record) == .inProgress(.place))
        record.state = .deferred
        #expect(SetupStatus(record) == .deferred(.place, path: .startHere, seenPreferences: false))
        record.seen.insert(.behave)
        #expect(SetupStatus(record) == .deferred(.place, path: .startHere, seenPreferences: true))
        record.state = .finished
        #expect(SetupStatus(record) == .finished(path: .startHere, seenPreferences: true))
    }

    @Test func aStartedRecordHasSeenEveryStepUpToItsCursor() {
        let startHere = SetupProgressRecord.started(path: .startHere, cursor: .found, now: Self.started)
        #expect(startHere.seen == [.welcome, .apps, .reads, .found])
        #expect(startHere.state == .inProgress)
        #expect(startHere.startedAt == Self.started)
        let join = SetupProgressRecord.started(path: .join, cursor: .join, now: Self.started)
        #expect(join.seen == [.welcome, .join])
        let elsewhere = SetupProgressRecord.started(path: .join, cursor: .place, now: Self.started)
        #expect(elsewhere.seen == [.place])
    }

    // MARK: - The session

    @Test func movingKeepsTheStateAndMarksTheStepSeen() {
        let store = StubSetupProgressStore(SetupProgressRecord.started(path: .startHere, cursor: .found, now: Self.started))
        let session = WorkspaceSetupProgressSession(store: store)

        session.move(to: .library, now: Self.later)

        #expect(store.saved?.cursor == .library)
        #expect(store.saved?.state == .inProgress)
        #expect(store.saved?.seen.contains(.library) == true)
        #expect(store.saved?.updatedAt == Self.later)
        #expect(session.record == store.saved)
    }

    @Test func aFinishedRecordHasNoCursorToMoveOrDefer() {
        var finished = SetupProgressRecord.started(path: .startHere, cursor: .done, now: Self.started)
        finished.state = .finished
        let store = StubSetupProgressStore(finished)
        let session = WorkspaceSetupProgressSession(store: store)

        session.move(to: .place, now: Self.later)
        session.deferSetup(at: .place, now: Self.later)

        #expect(store.saveCount == 0)
        #expect(session.record == finished)
    }

    @Test func noRecordHasNothingToMove() {
        let store = StubSetupProgressStore()
        let session = WorkspaceSetupProgressSession(store: store)

        session.move(to: .place)
        session.deferSetup(at: .place)
        session.tick(.trySkill, place: .home)
        session.setChecklistHidden(true)
        session.recordEvidence { $0.projectFolderCount = 4 }

        #expect(store.saveCount == 0)
        #expect(session.status == .legacy)
    }

    @Test func leavingForLaterDefersAtTheStep() {
        let store = StubSetupProgressStore(SetupProgressRecord.started(path: .startHere, cursor: .found, now: Self.started))
        let session = WorkspaceSetupProgressSession(store: store)

        session.deferSetup(at: .place, now: Self.later)

        #expect(session.status == .deferred(.place, path: .startHere, seenPreferences: false))
        #expect(store.saved?.seen.contains(.place) == true)
    }

    /// A row ticks once, and the first place it was done is the one kept.
    @Test func aTickLatches() {
        let store = StubSetupProgressStore(SetupProgressRecord.started(path: .startHere, cursor: .found, now: Self.started))
        let session = WorkspaceSetupProgressSession(store: store)

        session.tick(.putToolsInApps, place: .setup, summary: "Installed 4 changes · 9:52 AM", now: Self.started)
        session.tick(.putToolsInApps, place: .apps, now: Self.later)

        #expect(store.saveCount == 1)
        #expect(session.record?.ticks.count == 1)
        #expect(session.record?.ticks.first?.place == .setup)
        #expect(session.record?.ticks.first?.summary == "Installed 4 changes · 9:52 AM")
    }

    /// D14: a save that fails puts the record back and says so, in the stage's
    /// one sentence for a choice that did not save.
    @Test func aFailedSaveSnapsBack() {
        let original = SetupProgressRecord.started(path: .startHere, cursor: .found, now: Self.started)
        let store = StubSetupProgressStore(original)
        let session = WorkspaceSetupProgressSession(store: store)
        store.failsSaves = true

        session.move(to: .library, now: Self.later)

        #expect(session.record == original)
        #expect(session.errorMessage == "This Mac could not record that choice. Nothing was changed.")
        #expect(store.saved == original)

        store.failsSaves = false
        session.move(to: .library, now: Self.later)
        #expect(session.record?.cursor == .library)
        #expect(session.errorMessage == nil)
    }

    @Test func theCardHidesAndShowsAgain() {
        let store = StubSetupProgressStore(SetupProgressRecord.started(path: .startHere, cursor: .found, now: Self.started))
        let session = WorkspaceSetupProgressSession(store: store)

        session.setChecklistHidden(true, now: Self.later)
        #expect(session.record?.hiddenAt == Self.later)
        session.setChecklistHidden(false, now: Self.later)
        #expect(session.record?.hiddenAt == nil)
    }

    @Test func evidenceThatDidNotChangeIsNotWrittenAgain() {
        let store = StubSetupProgressStore(SetupProgressRecord.started(path: .startHere, cursor: .found, now: Self.started))
        let session = WorkspaceSetupProgressSession(store: store)

        session.recordEvidence { $0.projectFolderCount = 4 }
        session.recordEvidence { $0.projectFolderCount = 4 }

        #expect(store.saveCount == 1)
        #expect(store.saved?.evidence.projectFolderCount == 4)
    }

    // MARK: - Done, per D20

    /// A rerun on a workspace made before Launchpad: Done creates a finished
    /// record on the rerun path.
    @Test func doneWithNoRecordCreatesAFinishedRerun() throws {
        let store = StubSetupProgressStore()
        let session = WorkspaceSetupProgressSession(store: store)

        session.finish(items: [.lookAtCheckup], seen: [.apps, .reads, .found], now: Self.later)

        let record = try #require(store.saved)
        #expect(record.state == .finished)
        #expect(record.path == .rerun)
        #expect(record.startedAt == Self.later)
        #expect(record.finishedAt == Self.later)
        #expect(record.cursor == .done)
        #expect(record.seen == [.apps, .reads, .found, .done])
        #expect(record.items == [.lookAtCheckup])
        #expect(session.status == .finished(path: .rerun, seenPreferences: false))
    }

    /// Done on a Mac that has a record keeps where and when setup began,
    /// rebuilds the rows, keeps the ticks made, and shows the card again.
    @Test func doneWithARecordRefreshesIt() throws {
        var existing = SetupProgressRecord.started(path: .startHere, cursor: .found, now: Self.started)
        existing.state = .finished
        existing.ticks = [.init(item: .putToolsInApps, place: .setup, at: Self.started)]
        existing.hiddenAt = Self.started
        existing.evidence.projectFolderCount = 4
        let store = StubSetupProgressStore(existing)
        let session = WorkspaceSetupProgressSession(store: store)

        session.finish(
            items: [.putToolsInApps, .lookAtCheckup],
            ticks: [
                .init(item: .putToolsInApps, place: .apps, at: Self.later), .init(item: .lookAtCheckup, place: .checkup, at: Self.later),
            ],
            seen: [.apps, .behave], now: Self.later)

        let record = try #require(store.saved)
        #expect(record.path == .startHere)
        #expect(record.startedAt == Self.started)
        #expect(record.finishedAt == Self.later)
        #expect(record.items == [.putToolsInApps, .lookAtCheckup])
        #expect(record.ticks.map(\.item) == [.putToolsInApps, .lookAtCheckup])
        #expect(record.ticks.first?.place == .setup)
        #expect(record.hiddenAt == nil)
        #expect(record.evidence.projectFolderCount == 4)
        #expect(session.status == .finished(path: .startHere, seenPreferences: true))

        session.finish(items: [], evidence: .init(projectFolderCount: 2), now: Self.later)
        #expect(store.saved?.evidence.projectFolderCount == 2)
    }

    /// D20: a resumed setup that was left for later finishes at Done.
    @Test func doneFinishesADeferredSetup() {
        var deferred = SetupProgressRecord.started(path: .join, cursor: .arrivals, now: Self.started)
        deferred.state = .deferred
        let store = StubSetupProgressStore(deferred)
        let session = WorkspaceSetupProgressSession(store: store)

        session.finish(items: FinishSetupItem.allCases, now: Self.later)

        #expect(session.status == .finished(path: .join, seenPreferences: false))
        #expect(store.saved?.startedAt == Self.started)
    }

    // MARK: - Helpers

    private static func decode(_ json: String) throws -> SetupProgressRecord {
        try LiveSetupProgressStore.decoder().decode(SetupProgressRecord.self, from: Data(json.utf8))
    }
}
