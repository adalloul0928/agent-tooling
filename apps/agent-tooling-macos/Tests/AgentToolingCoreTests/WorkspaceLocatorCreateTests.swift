import AgentToolingTestSupport
import Foundation
import Testing
import os

@testable import AgentToolingCore

/// Creating this Mac's workspace from what setup read. Unlike `openOrCreate`,
/// it never opens one: a record already here refuses it, so a first run can
/// never hand back somebody else's library instead of the one it read.
@Suite("Workspace locator · create")
struct WorkspaceLocatorCreateTests {
    @Test func thisMacsChoicesAreInRevisionOne() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let choices = DeviceWorkspacePreferences(
            chosenClients: [.codex, .claude], customToolDirectories: ["/opt/fixture-tools/bin"],
            assistantRuns: .off, findsProjectsFromClaudeHistory: false)

        let store = try await fixture.locator.create(
            homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []), preferences: choices)

        let snapshot = try #require(try store.snapshot())
        #expect(snapshot.document.revision.parentIDs.isEmpty, "the choices are in revision 1, not a second revision")
        #expect(snapshot.device.applicationState?.preferences == choices)
        let record = try #require(try fixture.locator.read())
        #expect(record.workspaceID == store.workspaceID)
        #expect(record.deviceID == store.deviceID)
    }

    @Test func withNoPreferencesTheDefaultsAreKept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let store = try await fixture.locator.create(
            homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []), preferences: nil)

        #expect(try store.snapshot()?.device.applicationState?.preferences == DeviceWorkspacePreferences())
    }

    @Test func aWorkspaceAlreadyHereRefusesTheCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.locator.openOrCreate(
            homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []))
        let recorded = try Data(contentsOf: fixture.locator.recordURL)

        await #expect(throws: WorkspaceLocatorError.alreadyExists) {
            _ = try await fixture.locator.create(
                homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []), preferences: nil)
        }
        // The record still names the first workspace, byte for byte.
        #expect(try Data(contentsOf: fixture.locator.recordURL) == recorded)
        #expect(try fixture.locator.read()?.workspaceID == first.workspaceID)
    }

    /// A record this build cannot read is still a workspace that exists.
    /// Creating beside it would leave two, so the read's own reason refuses
    /// the creation and the record is left as it was.
    @Test(arguments: [
        (#"{"formatVersion":2}"#, WorkspaceLocatorError.newerFormat),
        ("not a record", WorkspaceLocatorError.damaged),
    ])
    func anUnreadableRecordAlsoRefusesTheCreation(contents: String, reason: WorkspaceLocatorError) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try write(fixture.locator.recordURL, contents)

        await #expect(throws: reason) {
            _ = try await fixture.locator.create(
                homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []), preferences: nil)
        }
        #expect(String(decoding: try Data(contentsOf: fixture.locator.recordURL), as: UTF8.self) == contents)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "workspaces-v1").path(percentEncoded: false)))
    }

    @Test func beforeRecordRunsInTheNewWorkspacesFolderBeforeTheRecordExists() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seen = OSAllocatedUnfairLock<Observed?>(initialState: nil)
        let recordURL = fixture.locator.recordURL

        let store = try await fixture.locator.create(
            homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []), preferences: nil,
            beforeRecord: { container in
                let observed = Observed(
                    container: container,
                    recordExisted: FileManager.default.fileExists(atPath: recordURL.path(percentEncoded: false)),
                    storeExisted: FileManager.default.fileExists(
                        atPath: container.appending(path: "revisions.sqlite").path(percentEncoded: false)))
                seen.withLock { $0 = observed }
                try write(container.appending(path: "setup-progress.json"), "{}")
            })

        let observed = try #require(seen.withLock { $0 })
        #expect(!observed.recordExisted, "the locator record is written last")
        #expect(observed.storeExisted, "revision 1 is written first")
        #expect(observed.container == store.databaseURL.deletingLastPathComponent())
        let record = try #require(try fixture.locator.read())
        #expect(fixture.locator.containerDirectory(for: record) == observed.container)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.locator.containerDirectory(for: record).appending(path: "setup-progress.json").path(percentEncoded: false)))
    }

    /// A record that appears while the workspace is being made, here written
    /// by `beforeRecord` as a second first run on this Mac would, still
    /// refuses the creation, and is left exactly as it was written.
    @Test func aRecordWrittenWhileCreatingStillRefusesTheCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let theirs = WorkspaceLocator.Record(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID())
        let locator = fixture.locator

        await #expect(throws: WorkspaceLocatorError.alreadyExists) {
            _ = try await locator.create(
                homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []), preferences: nil,
                beforeRecord: { _ in try locator.write(theirs) })
        }
        #expect(try fixture.locator.read() == theirs)
        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path(percentEncoded: false))
        #expect(left.sorted() == [WorkspaceLocator.recordFileName, "workspaces-v1"], "no staged copy is left behind")
    }

    /// The last guard: even past every look beforehand, the record is moved
    /// into place by a rename that will not replace a file already there.
    @Test func theRecordIsNeverPutOverAFileAlreadyThere() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try write(fixture.locator.recordURL, "theirs")

        #expect(throws: WorkspaceLocatorError.alreadyExists) {
            try WorkspaceLocator.place(Data("ours".utf8), at: fixture.locator.recordURL)
        }
        #expect(String(decoding: try Data(contentsOf: fixture.locator.recordURL), as: UTF8.self) == "theirs")
        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path(percentEncoded: false))
        #expect(left == [WorkspaceLocator.recordFileName], "no staged copy is left behind")
    }

    /// Created on a Mac with no record, the record lands where `read()` finds
    /// it, readable by this Mac only.
    @Test func aCreatedRecordIsReadableByThisMacOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let store = try await fixture.locator.create(
            homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []), preferences: nil)

        #expect(try fixture.locator.read()?.workspaceID == store.workspaceID)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.locator.recordURL.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aBeforeRecordThatThrowsLeavesNoRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        struct Refused: Error, Equatable {}

        await #expect(throws: Refused()) {
            _ = try await fixture.locator.create(
                homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []), preferences: nil,
                beforeRecord: { _ in throw Refused() })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.locator.recordURL.path(percentEncoded: false)))
        #expect(try fixture.locator.read() == nil)
        #expect(try fixture.locator.open() == nil, "nothing points at the store that was started")
    }

    /// The format version is read first and on its own, so only a record a
    /// newer build wrote says to update; everything else unreadable is damaged.
    @Test(arguments: [
        (#"{"formatVersion":2}"#, WorkspaceLocatorError.newerFormat),
        (#"{"formatVersion":99,"workspaceID":"x","somethingNew":true}"#, .newerFormat),
        ("not json", .damaged),
        (#"{"workspaceID":"00000000-0000-0000-0000-000000000001"}"#, .damaged),
        (#"{"formatVersion":1}"#, .damaged),
        (#"{"formatVersion":0,"workspaceID":"00000000-0000-0000-0000-000000000001"}"#, .damaged),
        (#"{"formatVersion":"one"}"#, .damaged),
        (String(repeating: " ", count: 8_193) + #"{"formatVersion":1}"#, .damaged),
    ])
    func aNewerRecordIsToldApartFromADamagedOne(contents: String, reason: WorkspaceLocatorError) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try write(fixture.locator.recordURL, contents)

        #expect(throws: reason) { _ = try fixture.locator.read() }
    }

    @Test func onlyANewerRecordSaysToUpdate() {
        #expect(WorkspaceLocatorError.newerFormat.errorDescription?.contains("made by a newer Agent Tooling") == true)
        for other in [WorkspaceLocatorError.invalidRoot, .unreadable, .damaged, .alreadyExists] {
            #expect(other.errorDescription?.contains("newer") == false, "\(other)")
            #expect(other.errorDescription?.hasSuffix("Nothing was changed.") == true, "\(other)")
        }
    }

    @Test func theContainerDirectoryIsTheStoresOwnFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try await fixture.locator.openOrCreate(
            homeURL: fixture.home, runner: RefusingCommandRunner(), registry: .init(adapters: []))
        let record = try #require(try fixture.locator.read())

        #expect(fixture.locator.containerDirectory(for: record) == store.databaseURL.deletingLastPathComponent())
    }

    /// The commit of a first read: the registry answers with what was read,
    /// so the workspace holds exactly those observations and nothing runs.
    @Test func aReplayingRegistryRecordsWhatWasReadAndRunsNothing() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let read = await world.registry.scanAll(
            homeURL: world.url, runner: world.scriptedRunner(), clients: [.codex, .claude, .gemini])
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedCommandRunner([:])

        let store = try await fixture.locator.create(
            homeURL: world.url, runner: runner, registry: .replaying(read),
            preferences: .init(chosenClients: [.codex, .claude, .gemini], assistantRuns: .off))

        #expect(await runner.launches.isEmpty, "a replayed commit runs no command")
        let device = try #require(try store.snapshot()?.device)
        // Stored dates keep milliseconds, so compare with the read's dates kept
        // the same way.
        let expected = read.map { observation in
            var stored = observation
            stored.lastScannedAt = WorkspaceDomainValidation.canonicalDate(observation.lastScannedAt)
            return stored
        }
        #expect(device.observations == expected.sorted { $0.surface.rawValue < $1.surface.rawValue })
        #expect(Set(device.observations.compactMap(\.version)) == ["codex-cli 0.164.0", "2.1.304 (Claude Code)", "0.38.2"])
    }

    @Test func aReplayKeepsTheLatestReadOfEachSurface() async throws {
        let capabilities = try #require(ClientAdapterRegistry().adapter(for: .codex)?.capabilities)
        let earlier = TargetObservation(
            surface: .codexCLI, installed: true, version: "codex-cli 0.163.0", capabilities: capabilities,
            lastScannedAt: Date(timeIntervalSince1970: 1_000))
        let later = TargetObservation(
            surface: .codexCLI, installed: true, version: "codex-cli 0.164.0", capabilities: capabilities,
            lastScannedAt: Date(timeIntervalSince1970: 2_000))
        let registry = ClientAdapterRegistry.replaying([later, earlier])

        #expect(registry.adapters.count == 1)
        let replayed = await registry.scanAll(homeURL: URL(filePath: "/nonexistent-home"), runner: RefusingCommandRunner())
        #expect(replayed == [later])
        #expect(
            registry.adapter(for: .codex)?.skillDestination(skillID: "release-notes", homeURL: URL(filePath: "/home"))
                == CodexAdapter().skillDestination(skillID: "release-notes", homeURL: URL(filePath: "/home")))
    }

    private struct Observed: Sendable {
        let container: URL
        let recordExisted: Bool
        let storeExisted: Bool
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let locator: WorkspaceLocator

        init() throws {
            let base = try TemporaryFolder("workspace-locator-create").url
            root = base.appending(path: "support")
            home = base.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            locator = try WorkspaceLocator(root: root)
        }

        func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }
}
