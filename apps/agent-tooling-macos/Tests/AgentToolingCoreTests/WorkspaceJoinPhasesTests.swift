import AgentToolingTestSupport
import Foundation
import SQLite3
import Testing

@testable import AgentToolingCore

/// One thing a join reported, in the order it happened.
private enum JoinEvent: Equatable, Sendable, CustomStringConvertible {
    case step(WorkspaceJoin.Step, WorkspaceJoin.StepState)
    /// `afterStoreCreated` ran: what was on disk, and how many Macs the new
    /// store's registry held, at that moment.
    case storeCreated(enrollmentWritten: Bool, locatorWritten: Bool, registeredMacs: Int)

    var description: String {
        switch self {
        case .step(let step, let state): "\(step) \(state)"
        case .storeCreated(let enrollment, let locator, let macs):
            "store created (enrollment \(enrollment), locator \(locator), \(macs) Macs)"
        }
    }

    static func steps(_ steps: [WorkspaceJoin.Step]) -> [JoinEvent] {
        steps.flatMap { [JoinEvent.step($0, .started), .step($0, .finished)] }
    }
}

/// The Mac that joins: an empty home and support folder of its own, and a
/// place to set aside a checkout an earlier attempt left, so nothing goes to
/// the Trash of the Mac running the tests.
private struct JoiningMac: Sendable {
    let name: String
    let home: URL
    let support: URL
    let checkout: URL
    let locator: WorkspaceLocator
    let runner: ProcessCommandRunner
    let setAside: EventRecorder<URL>
    private let setAsideFolder: URL

    init(_ name: String, in fixture: GitLibraryFixture) throws {
        self.name = name
        home = try fixture.home(name)
        support = fixture.root.appending(path: "\(name)/support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        checkout = support.appending(path: "sync-checkout", directoryHint: .isDirectory)
        locator = try WorkspaceLocator(root: support)
        runner = fixture.runner(for: home)
        setAside = EventRecorder()
        setAsideFolder = fixture.root.appending(path: "\(name)/set-aside", directoryHint: .isDirectory)
    }

    /// Moves a stale checkout into the fixture, recording it.
    var discard: @Sendable (URL) throws -> Void {
        { [setAside, setAsideFolder] item in
            setAside.record(item)
            try FileManager.default.createDirectory(at: setAsideFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: item, to: setAsideFolder.appending(path: UUID().uuidString))
        }
    }

    /// The content store inside the joined store's own folder, where the
    /// workspace's sessions read it.
    static let contentStoreAt: @Sendable (URL) throws -> CentralPackageContentStore? = { container in
        let folder = container.appending(path: "content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try CentralPackageContentStore(directory: folder)
    }

    /// The store a join left for `workspace`, as the device it was made for.
    func leftoverStore(of workspace: WorkspaceObjectID) throws -> WorkspaceRevisionStore? {
        guard let recorded = try WorkspaceRevisionStore.recordedIdentity(containerRoot: support, workspaceID: workspace) else { return nil }
        return try WorkspaceRevisionStore(
            containerRoot: support, workspaceID: workspace, deviceID: recorded.deviceID, access: .existingReadOnly)
    }

    func join(
        _ fixture: GitLibraryFixture, remote: String? = nil, deviceName: String? = nil,
        observe: (@Sendable () async throws -> [TargetObservation])? = { [] },
        registry: ClientAdapterRegistry = ClientAdapterRegistry(adapters: []),
        devicePreferences: DeviceWorkspacePreferences? = nil,
        afterStoreCreated: (@Sendable (URL) throws -> Void)? = nil,
        progress: @escaping @Sendable (WorkspaceJoin.Step, WorkspaceJoin.StepState) -> Void = { _, _ in }
    ) async throws -> WorkspaceJoin.Result {
        try await WorkspaceJoin.join(
            remote: remote ?? fixture.remote.path, checkout: checkout, containerRoot: support, homeURL: home,
            deviceName: deviceName ?? name, runner: runner, registry: registry, locator: locator, observe: observe,
            devicePreferences: devicePreferences, contentStoreAt: Self.contentStoreAt, afterStoreCreated: afterStoreCreated,
            discardStaleCheckout: discard, progress: progress)
    }

    /// J01's Finish joining, for the join this Mac left for `workspace`,
    /// with the name and choices that join was given.
    func finish(
        _ workspace: WorkspaceObjectID, devicePreferences: DeviceWorkspacePreferences? = nil,
        progress: @escaping @Sendable (WorkspaceJoin.Step, WorkspaceJoin.StepState) -> Void = { _, _ in }
    ) async throws -> WorkspaceJoin.Result {
        try await WorkspaceJoin.finish(
            containerRoot: support, workspaceID: workspace, homeURL: home, deviceName: name, devicePreferences: devicePreferences,
            runner: runner, locator: locator, contentStoreAt: Self.contentStoreAt, discardStaleCheckout: discard,
            progress: progress)
    }

    /// A join that stopped between creating its store and starting it: a
    /// store for `workspace` with no revision in it, and the enrollment its
    /// join was making beside it. Returns the device it was made for.
    func storeNeverStarted(for workspace: WorkspaceObjectID, joining remote: URL) throws -> WorkspaceObjectID {
        let device = WorkspaceObjectID()
        let store = try WorkspaceRevisionStore(containerRoot: support, workspaceID: workspace, deviceID: device)
        #expect(try store.snapshot() == nil)
        try WorkspaceSyncEnrollmentStore(containerRoot: store.databaseURL.deletingLastPathComponent()).write(
            try WorkspaceSyncEnrollment(
                workspaceID: workspace, remote: remote.path, checkoutPath: checkout.standardizedFileURL.path, branch: "main"))
        return device
    }
}

/// Codex as a joining Mac's read finds it.
private func codexObservation() throws -> TargetObservation {
    let codex = try #require(ClientAdapterRegistry().adapter(for: .codex))
    return TargetObservation(surface: codex.surface, installed: true, version: "codex-cli 0.164.0", capabilities: codex.capabilities)
}

/// The names in `store`'s registry, as its head has them.
private func registeredNames(_ store: WorkspaceRevisionStore) throws -> Set<String> {
    Set(try #require(try store.snapshot()).document.deviceRegistry.map(\.name))
}

/// J01's join, phase by phase: the steps it reports, where a Stop still
/// reaches it, what it writes and in which order, and how a join that stopped
/// once its store existed is finished. Real Git against a bare repository on
/// this Mac; each test pays for one publish and one join.
@Suite("Workspace join phases", .serialized, .timeLimit(.minutes(5)))
struct WorkspaceJoinPhasesTests {
    @Test func aJoinReportsEachStepAndWritesTheEnrollmentBeforeTheLocator() async throws {
        let fixture = try GitLibraryFixture("join-phases")
        defer { fixture.remove() }
        let codexStatus = PublishedDeviceStatus.AppSummary(
            surface: .codexCLI, installed: true, version: "0.164.0", skillCount: 2, pluginCount: 1, mcpServerCount: 1)
        let juniper = try await fixture.publishLibrary(from: "Juniper", skills: ["Release Notes"], statusApps: [codexStatus])
        // An older Mac called Cedar is still in the library, so this Cedar is numbered.
        let head = try #require(try juniper.store.snapshot()).document.revision.id
        _ = try await juniper.service.registerDevice(.init(expectedRevisionID: head, deviceID: WorkspaceObjectID(), name: "Cedar"))
        _ = try await juniper.coordinator.sync()
        // Oak used the library once and was retired; its last status stays.
        _ = try await fixture.retiredMac("Oak", in: juniper)
        let cedar = try JoiningMac("Cedar", in: fixture)
        let events = EventRecorder<JoinEvent>()
        let preferences = DeviceWorkspacePreferences(
            chosenClients: [.codex, .claude], assistantRuns: .off, findsProjectsFromClaudeHistory: false)
        let observed = try codexObservation()
        let locator = cedar.locator
        let support = cedar.support
        let workspace = juniper.workspaceID

        // Pasted with the spaces a copy brings along.
        let result = try await cedar.join(
            fixture, remote: " \(fixture.remote.path)\n", observe: { [observed] }, devicePreferences: preferences,
            afterStoreCreated: { container in
                let store = try #require(try WorkspaceRevisionStore.recordedIdentity(containerRoot: support, workspaceID: workspace))
                let opened = try WorkspaceRevisionStore(
                    containerRoot: support, workspaceID: workspace, deviceID: store.deviceID, access: .existingReadOnly)
                events.record(
                    .storeCreated(
                        enrollmentWritten: try WorkspaceSyncEnrollmentStore(containerRoot: container).read() != nil,
                        locatorWritten: try locator.read() != nil,
                        registeredMacs: try registeredNames(opened).count))
            },
            progress: { events.record(.step($0, $1)) })

        // Each step in order, and the hook once the store and its enrollment
        // exist, before this Mac is registered and before the locator: the
        // registry then holds Juniper, the older Cedar and retired Oak.
        #expect(
            events.events
                == JoinEvent.steps([.reachingRepository, .readingLibrary, .checkingApps])
                + [
                    .step(.registering, .started),
                    .storeCreated(enrollmentWritten: true, locatorWritten: false, registeredMacs: 3),
                    .step(.registering, .finished),
                ] + JoinEvent.steps([.sharing]))
        // The name it was registered under, numbered on the clash.
        #expect(result.registeredName == "Cedar 2")
        let snapshot = try #require(try result.store.snapshot())
        #expect(snapshot.document.deviceRegistry.first { $0.id == result.deviceID }?.name == "Cedar 2")
        // This Mac's choices and what it read, from the store's first revision on.
        #expect(snapshot.device.applicationState?.preferences == preferences)
        #expect(snapshot.device.observations.map(\.surface) == [.codexCLI])
        // What Juniper last published about itself. Retired Oak's last status
        // is no other Mac's news.
        #expect(result.deviceStatuses.map(\.name) == ["Juniper"])
        #expect(result.deviceStatuses.first?.apps == [codexStatus])
        // Juniper's skill files arrived in the joined store's own folder.
        let container = result.store.databaseURL.deletingLastPathComponent()
        let skill = try #require(juniper.skillIDs.first)
        let digest = try #require(snapshot.document.artifacts.first { $0.identity.id == skill }?.contentDigest)
        let joinedContent = try CentralPackageContentStore(
            directory: container.appending(path: "content", directoryHint: .isDirectory), initializeIfEmpty: false)
        #expect(result.importedContent == 1)
        #expect(try await joinedContent.read(digest) == juniper.contentStore.read(digest))
        #expect(!FileManager.default.fileExists(atPath: cedar.support.appending(path: "content").path))
        // The enrollment beside the store, and the locator naming it.
        #expect(try WorkspaceSyncEnrollmentStore(containerRoot: container).read() == result.enrollment)
        #expect(result.enrollment.remote == fixture.remote.path)
        #expect(result.enrollment.workspaceID == workspace)
        let record = WorkspaceLocator.Record(workspaceID: workspace, deviceID: result.deviceID)
        #expect(try locator.read() == record)
        // Juniper learns of Cedar 2 on its next pass, and its own record is
        // untouched by the Mac that joined it.
        _ = try await juniper.coordinator.sync()
        #expect(try registeredNames(juniper.store) == ["Juniper", "Cedar", "Cedar 2", "Oak"])
        #expect(try WorkspaceLocator(root: juniper.support).read() == .init(workspaceID: workspace, deviceID: juniper.deviceID))
    }

    @Test func aStopBeforeTheStoreLeavesNoStoreAndNoLocator() async throws {
        let fixture = try GitLibraryFixture("join-stop")
        defer { fixture.remove() }
        let juniper = try await fixture.publishLibrary(from: "Juniper")

        // A read that honours the Stop itself.
        let cedar = try JoiningMac("Cedar", in: fixture)
        let gate = GatedCommandRunner()
        let cedarEvents = EventRecorder<JoinEvent>()
        let reading = Task {
            try await cedar.join(
                fixture,
                observe: {
                    _ = try await gate.run(executable: "scan", arguments: ["codex"], currentDirectory: nil)
                    return []
                },
                progress: { cedarEvents.record(.step($0, $1)) })
        }
        await gate.waitUntilCalled()
        reading.cancel()
        await #expect(throws: CancellationError.self) { _ = try await reading.value }
        #expect(gate.cancelledCalls == 1)
        try expectNothingKept(by: cedar, of: juniper.workspaceID, events: cedarEvents.events)

        // A scan that swallows the Stop and answers anyway, as a real scan
        // does: the join notices before anything could record its answer.
        let oak = try JoiningMac("Oak", in: fixture)
        let scanGate = GatedCommandRunner()
        let swallowing = ClientAdapterRegistry(adapters: [ScriptedClientAdapter(try codexObservation(), client: .codex, gate: scanGate)])
        let oakEvents = EventRecorder<JoinEvent>()
        let scanning = Task {
            try await oak.join(fixture, observe: nil, registry: swallowing, progress: { oakEvents.record(.step($0, $1)) })
        }
        await scanGate.waitUntilCalled()
        scanning.cancel()
        await #expect(throws: CancellationError.self) { _ = try await scanning.value }
        #expect(scanGate.cancelledCalls == 1)
        try expectNothingKept(by: oak, of: juniper.workspaceID, events: oakEvents.events)
    }

    /// A Stop during "Checking this Mac’s apps": that step never finished,
    /// Registering never started, and there is no store and no locator.
    private func expectNothingKept(
        by mac: JoiningMac, of workspace: WorkspaceObjectID, events: [JoinEvent], _ location: SourceLocation = #_sourceLocation
    ) throws {
        #expect(
            events == JoinEvent.steps([.reachingRepository, .readingLibrary]) + [.step(.checkingApps, .started)], sourceLocation: location)
        #expect(
            try WorkspaceRevisionStore.recordedIdentity(containerRoot: mac.support, workspaceID: workspace) == nil, sourceLocation: location
        )
        #expect(!FileManager.default.fileExists(atPath: mac.support.appending(path: "workspaces-v1").path), sourceLocation: location)
        #expect(try mac.locator.read() == nil, sourceLocation: location)
    }

    @Test func oncePastTheLastStopAJoinFinishesEvenWhenCancelled() async throws {
        let fixture = try GitLibraryFixture("join-no-cancel")
        defer { fixture.remove() }
        let juniper = try await fixture.publishLibrary(from: "Juniper")
        let cedar = try JoiningMac("Cedar", in: fixture)
        let (registering, signal) = AsyncStream<Void>.makeStream()

        let joining = Task {
            try await cedar.join(
                fixture,
                progress: { step, state in
                    if step == .registering, state == .started { signal.yield() }
                })
        }
        for await _ in registering { break }
        joining.cancel()

        // Registering has begun: the cancellation waits for the join instead
        // of leaving half of one.
        let result = try await joining.value
        #expect(result.registeredName == "Cedar")
        #expect(try cedar.locator.read() == .init(workspaceID: juniper.workspaceID, deviceID: result.deviceID))
    }

    @Test func aJoinThatStopsAfterRegisteringIsCompletedByFinish() async throws {
        let fixture = try GitLibraryFixture("join-finish")
        defer { fixture.remove() }
        let juniper = try await fixture.publishLibrary(from: "Juniper", skills: ["Release Notes"])
        let cedar = try JoiningMac("Cedar", in: fixture)
        let remote = fixture.remote
        let away = fixture.root.appending(path: "remote-away.git", directoryHint: .isDirectory)

        // The repository goes away the moment this Mac is registered: what a
        // join killed there leaves on disk.
        await #expect(throws: WorkspaceJoinError.lateFailure(workspaceID: juniper.workspaceID)) {
            _ = try await cedar.join(
                fixture,
                progress: { step, state in
                    if step == .registering, state == .finished { try? FileManager.default.moveItem(at: remote, to: away) }
                })
        }
        let leftover = try #require(try cedar.leftoverStore(of: juniper.workspaceID))
        #expect(try registeredNames(leftover) == ["Juniper", "Cedar"])
        let container = leftover.databaseURL.deletingLastPathComponent()
        #expect(try WorkspaceSyncEnrollmentStore(containerRoot: container).read()?.remote == remote.path)
        #expect(try cedar.locator.read() == nil)

        try FileManager.default.moveItem(at: away, to: remote)
        let events = EventRecorder<JoinEvent>()
        let finished = try await WorkspaceJoin.finish(
            containerRoot: cedar.support, workspaceID: juniper.workspaceID, homeURL: cedar.home, runner: cedar.runner,
            locator: cedar.locator, contentStoreAt: JoiningMac.contentStoreAt, discardStaleCheckout: cedar.discard,
            progress: { events.record(.step($0, $1)) })

        // Reopened as the device it was made for, registered once, shared,
        // and recorded last.
        #expect(finished.deviceID == leftover.deviceID)
        #expect(finished.registeredName == "Cedar")
        #expect(events.events == JoinEvent.steps([.reachingRepository, .registering, .sharing]))
        #expect(try cedar.locator.read() == .init(workspaceID: juniper.workspaceID, deviceID: leftover.deviceID))
        #expect(finished.importedContent == 1)
        // The checkout the join cloned was still good, so it was kept.
        #expect(cedar.setAside.events.isEmpty)
        _ = try await juniper.coordinator.sync()
        #expect(try registeredNames(juniper.store) == ["Juniper", "Cedar"])
        // Finishing what is finished changes nothing and says who this Mac is.
        let again = try await WorkspaceJoin.finish(
            containerRoot: cedar.support, workspaceID: juniper.workspaceID, homeURL: cedar.home, runner: cedar.runner,
            locator: cedar.locator, discardStaleCheckout: cedar.discard)
        #expect(again.deviceID == leftover.deviceID)
        #expect(again.registeredName == "Cedar")
    }

    @Test func finishingAStoreThatNeverStartedRecordsTheJoinsChoices() async throws {
        let fixture = try GitLibraryFixture("join-finish-unstarted")
        defer { fixture.remove() }
        let juniper = try await fixture.publishLibrary(from: "Juniper", skills: ["Release Notes"])
        let cedar = try JoiningMac("Cedar", in: fixture)
        let cedarDevice = try cedar.storeNeverStarted(for: juniper.workspaceID, joining: fixture.remote)
        let events = EventRecorder<JoinEvent>()

        let finished = try await cedar.finish(juniper.workspaceID, progress: { events.record(.step($0, $1)) })

        // Started from the remote ("Reading your library"), then registered,
        // shared and recorded, as the device the store was made for.
        #expect(events.events == JoinEvent.steps([.reachingRepository, .readingLibrary, .registering, .sharing]))
        #expect(finished.deviceID == cedarDevice)
        #expect(finished.registeredName == "Cedar")
        #expect(finished.importedContent == 1)
        #expect(try cedar.locator.read() == .init(workspaceID: juniper.workspaceID, deviceID: cedarDevice))
        // Given none of the join's choices, what a join seeds (D16, D17): the
        // assistant's own runs off, and no projects from Claude Code's history.
        let seeded = try #require(try finished.store.snapshot()?.device.applicationState?.preferences)
        #expect(seeded.assistantRuns == .off)
        #expect(seeded.effectiveAssistantRuns == .off)
        #expect(seeded.findsProjectsFromClaudeHistory == false)

        // Given the join's choices, those are what it records.
        let oak = try JoiningMac("Oak", in: fixture)
        _ = try oak.storeNeverStarted(for: juniper.workspaceID, joining: fixture.remote)
        let chosen = DeviceWorkspacePreferences(
            chosenClients: [.codex], assistantRuns: .init(weeklyReview: true, dailyDeepDive: false, localInsights: false),
            findsProjectsFromClaudeHistory: false)
        let oakFinished = try await oak.finish(juniper.workspaceID, devicePreferences: chosen)
        #expect(try oakFinished.store.snapshot()?.device.applicationState?.preferences == chosen)
        _ = try await juniper.coordinator.sync()
        #expect(try registeredNames(juniper.store) == ["Juniper", "Cedar", "Oak"])
    }

    @Test func finishingSetsAsideACheckoutThatHoldsAnotherRepositoryAndOutlivesItsCaller() async throws {
        let fixture = try GitLibraryFixture("join-finish-checkout")
        defer { fixture.remove() }
        let juniper = try await fixture.publishLibrary(from: "Juniper")
        let cedar = try JoiningMac("Cedar", in: fixture)
        let remote = fixture.remote
        let away = fixture.root.appending(path: "remote-away.git", directoryHint: .isDirectory)
        await #expect(throws: WorkspaceJoinError.lateFailure(workspaceID: juniper.workspaceID)) {
            _ = try await cedar.join(
                fixture,
                progress: { step, state in
                    if step == .registering, state == .finished { try? FileManager.default.moveItem(at: remote, to: away) }
                })
        }
        try FileManager.default.moveItem(at: away, to: remote)
        let leftover = try #require(try cedar.leftoverStore(of: juniper.workspaceID))
        // Meanwhile the checkout came to hold a clone of another repository.
        let other = try fixture.repository("other-library", holding: ["README.md": "# Elsewhere\n"])
        try GitTestFixture.git(["remote", "set-url", "origin", other.path], in: cedar.checkout, checkingStatus: true)
        #expect(cedar.setAside.events.isEmpty)

        // The person who asked to finish stops at once; finishing, once
        // begun, is not stopped with them.
        let (begun, signal) = AsyncStream<Void>.makeStream()
        let finishing = Task {
            try await cedar.finish(
                juniper.workspaceID,
                progress: { step, state in
                    if step == .reachingRepository, state == .started { signal.yield() }
                })
        }
        for await _ in begun { break }
        finishing.cancel()
        let finished = try await finishing.value

        #expect(finished.deviceID == leftover.deviceID)
        #expect(finished.registeredName == "Cedar")
        // The stale clone was set aside and the library cloned afresh into
        // the same folder, which the enrollment still names.
        #expect(cedar.setAside.events == [cedar.checkout])
        let origin = try await cedar.runner.run(
            executable: "/usr/bin/git", arguments: ["remote", "get-url", "origin"], currentDirectory: cedar.checkout)
        #expect(origin.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == remote.path)
        #expect(try cedar.locator.read() == .init(workspaceID: juniper.workspaceID, deviceID: leftover.deviceID))
        _ = try await juniper.coordinator.sync()
        #expect(try registeredNames(juniper.store) == ["Juniper", "Cedar"])
    }

    @Test func finishingRefusesWhileThisMacRecordsAnotherWorkspace() async throws {
        let support = try TemporaryFolder("join-finish-other").url
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = WorkspaceObjectID()
        let device = WorkspaceObjectID()
        let store = try WorkspaceRevisionStore(containerRoot: support, workspaceID: workspace, deviceID: device)
        // Found while its own connection is still open and has not read
        // since the store was made, before SQLite has a log index for it.
        #expect(try WorkspaceRevisionStore.recordedIdentity(containerRoot: support, workspaceID: workspace)?.deviceID == device)
        let container = store.databaseURL.deletingLastPathComponent()
        try WorkspaceSyncEnrollmentStore(containerRoot: container).write(
            try WorkspaceSyncEnrollment(
                workspaceID: workspace, remote: "https://github.com/you/library.git",
                checkoutPath: support.appending(path: "sync-checkout").path, branch: "main"))
        let locator = try WorkspaceLocator(root: support)
        let elsewhere = WorkspaceLocator.Record(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID())
        try WorkspaceLocator.place(try AgentToolingCoding.encoder().encode(elsewhere), at: locator.recordURL)

        // This Mac uses another workspace now: nothing runs, nothing changes.
        await #expect(throws: WorkspaceJoinError.alreadyHasWorkspace) {
            _ = try await WorkspaceJoin.finish(
                containerRoot: support, workspaceID: workspace, homeURL: support, runner: RefusingCommandRunner(), locator: locator)
        }
        #expect(try locator.read() == elsewhere)
        #expect(try store.snapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "sync-checkout").path))
    }

    @Test func aStoreWhoseCreationStoppedBeforeItsSchemaIsCreatedOver() async throws {
        let fixture = try GitLibraryFixture("join-empty-store")
        defer { fixture.remove() }
        let juniper = try await fixture.publishLibrary(from: "Juniper")
        let cedar = try JoiningMac("Cedar", in: fixture)
        // What the app leaves when it stops, or the disk fills, between
        // SQLite making the file and the store's schema being committed.
        let folder = cedar.support.appending(
            path: "workspaces-v1/\(juniper.workspaceID.rawValue.uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(FileManager.default.createFile(atPath: folder.appending(path: "revisions.sqlite").path, contents: Data()))
        #expect(try WorkspaceRevisionStore.recordedIdentity(containerRoot: cedar.support, workspaceID: juniper.workspaceID) == nil)

        let result = try await cedar.join(fixture)

        #expect(result.registeredName == "Cedar")
        #expect(result.store.databaseURL.deletingLastPathComponent().path == folder.resolvingSymlinksInPath().path)
        #expect(try cedar.locator.read() == .init(workspaceID: juniper.workspaceID, deviceID: result.deviceID))
        // A database that holds something other than a store is still refused.
        let foreign = try JoiningMac("Oak", in: fixture)
        let foreignFolder = foreign.support.appending(
            path: "workspaces-v1/\(juniper.workspaceID.rawValue.uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: foreignFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        #expect(sqlite3_open(foreignFolder.appending(path: "revisions.sqlite").path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "CREATE TABLE notes(text TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(throws: WorkspaceRevisionStoreError.unsupportedStoreFormat) {
            _ = try WorkspaceRevisionStore.recordedIdentity(containerRoot: foreign.support, workspaceID: juniper.workspaceID)
        }
    }

    @Test func aStoreAnAppWasKilledInIsStillFound() throws {
        let support = try TemporaryFolder("join-killed").url
        defer { try? FileManager.default.removeItem(at: support) }
        let document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: WorkspaceObjectID())))
        let device = WorkspaceObjectID()
        let live = support.appending(path: "live", directoryHint: .isDirectory)
        let store = try WorkspaceRevisionStore(containerRoot: live, workspaceID: document.workspaceID, deviceID: device)
        try store.initialize(document: document, device: DeviceWorkspaceState(workspaceID: document.workspaceID, deviceID: device))
        // The files as a kill leaves them: copied while the store is open, so
        // its last transaction is still only in the write-ahead log.
        let left = support.appending(path: "left", directoryHint: .isDirectory)
        let leftFolder = left.appending(
            path: "workspaces-v1/\(document.workspaceID.rawValue.uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: leftFolder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: store.databaseURL.deletingLastPathComponent(), to: leftFolder)
        #expect(FileManager.default.fileExists(atPath: leftFolder.appending(path: "revisions.sqlite-wal").path))

        let recorded = try #require(try WorkspaceRevisionStore.recordedIdentity(containerRoot: left, workspaceID: document.workspaceID))

        #expect(recorded.deviceID == device)
        let reopened = try WorkspaceRevisionStore(containerRoot: left, workspaceID: document.workspaceID, deviceID: device)
        #expect(try reopened.snapshot()?.document.revision.id == document.revision.id)
    }

    @Test func joiningTheSameLibraryAgainCompletesWhatAStoppedJoinLeft() async throws {
        let fixture = try GitLibraryFixture("join-again")
        defer { fixture.remove() }
        let juniper = try await fixture.publishLibrary(from: "Juniper")
        let cedar = try JoiningMac("Cedar", in: fixture)
        let remote = fixture.remote
        let away = fixture.root.appending(path: "remote-away.git", directoryHint: .isDirectory)
        await #expect(throws: WorkspaceJoinError.lateFailure(workspaceID: juniper.workspaceID)) {
            _ = try await cedar.join(
                fixture,
                progress: { step, state in
                    if step == .registering, state == .finished { try? FileManager.default.moveItem(at: remote, to: away) }
                })
        }
        let leftover = try #require(try cedar.leftoverStore(of: juniper.workspaceID))
        try FileManager.default.moveItem(at: away, to: remote)
        // The first attempt read no apps.
        #expect(try leftover.snapshot()?.device.observations.isEmpty == true)

        // A store pins the device it was made with, so a second join that
        // made a new one would be refused. It takes up the leftover instead,
        // from a fresh checkout, with what this attempt read and chose.
        let observed = try codexObservation()
        let chosen = DeviceWorkspacePreferences(
            chosenClients: [.codex, .claude], assistantRuns: .off, findsProjectsFromClaudeHistory: false)
        let result = try await cedar.join(fixture, observe: { [observed] }, devicePreferences: chosen)

        #expect(result.deviceID == leftover.deviceID)
        #expect(result.registeredName == "Cedar")
        #expect(cedar.setAside.events == [cedar.checkout])
        #expect(try cedar.locator.read() == .init(workspaceID: juniper.workspaceID, deviceID: leftover.deviceID))
        let device = try #require(try result.store.snapshot()).device
        #expect(device.observations.map(\.surface) == [.codexCLI])
        #expect(Set(device.capabilityEvidence.map(\.surface)) == Set(TargetCapabilityEvidence.derive(from: [observed]).map(\.surface)))
        #expect(device.applicationState?.preferences == chosen)
        _ = try await juniper.coordinator.sync()
        #expect(try registeredNames(juniper.store) == ["Juniper", "Cedar"])
    }

    @Test func aRepositoryWithNoLibraryInItCreatesNothing() async throws {
        let fixture = try GitLibraryFixture("join-refused")
        defer { fixture.remove() }
        let notes = try fixture.repository("notes", holding: ["README.md": "# Notes\n"]).path
        let reading = JoinEvent.steps([.reachingRepository]) + [.step(.readingLibrary, .started)]
        let cases: [(remote: String, branch: String, problem: GitRemoteProblem, reached: [JoinEvent])] = [
            (notes, "main", .notALibrary, reading),
            // A typo in the branch of a repository that has one.
            (notes, "mian", .noSuchBranch("mian"), reading),
            (
                try fixture.repository("other-json", holding: ["workspace.json": "{\"name\": \"an editor's workspace\"}"]).path,
                "main", .notALibrary, reading
            ),
            (
                try fixture.repository("newer", holding: ["workspace.json": GitLibraryFixture.newerLibraryFile(for: WorkspaceObjectID())])
                    .path,
                "main", .newerFormat, reading
            ),
            (
                fixture.root.appending(path: "agent-tooling-workspce.git").path, "main", .notFound(host: nil),
                [.step(.reachingRepository, .started)]
            ),
            // An address the field refuses: nothing runs at all.
            (
                "http://github.com/you/agent-tooling-workspace.git", "main",
                .invalidAddress(suggestion: "https://github.com/you/agent-tooling-workspace.git", carriesSignIn: false), []
            ),
        ]
        for (index, item) in cases.enumerated() {
            let mac = try JoiningMac("Mac\(index)", in: fixture)
            let events = EventRecorder<JoinEvent>()
            await #expect(throws: WorkspaceJoinError.remote(item.problem)) {
                _ = try await WorkspaceJoin.join(
                    remote: item.remote, checkout: mac.checkout, branch: item.branch, containerRoot: mac.support,
                    homeURL: mac.home, deviceName: mac.name, runner: mac.runner, locator: mac.locator, observe: { [] },
                    discardStaleCheckout: mac.discard, progress: { events.record(.step($0, $1)) })
            }
            #expect(events.events == item.reached, "\(item.problem)")
            #expect(!FileManager.default.fileExists(atPath: mac.support.appending(path: "workspaces-v1").path))
            #expect(try mac.locator.read() == nil)
        }
    }

    @Test func finishingWhenNothingWasLeftSaysSo() async throws {
        let support = try TemporaryFolder("join-nothing").url
        defer { try? FileManager.default.removeItem(at: support) }

        await #expect(throws: WorkspaceJoinError.nothingToFinish) {
            _ = try await WorkspaceJoin.finish(
                containerRoot: support, workspaceID: WorkspaceObjectID(), homeURL: support, runner: RefusingCommandRunner())
        }
        #expect(
            WorkspaceJoinError.lateFailure(workspaceID: WorkspaceObjectID()).errorDescription
                == "Joining stopped before it finished. Finish joining completes it; nothing in your apps changes.")
        #expect(
            WorkspaceJoinError.remote(.notFound(host: "github.com")).errorDescription
                == GitRemoteProblem.notFound(host: "github.com").errorDescription)
    }
}
