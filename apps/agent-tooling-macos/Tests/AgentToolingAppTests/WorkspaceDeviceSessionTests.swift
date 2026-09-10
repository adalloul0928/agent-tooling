import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Checking this Mac's apps, and choosing which of them it manages.
///
/// The scan is stubbed throughout: a test that ran a real client would depend
/// on what happens to be installed on the machine running it, and would take a
/// verdict from a Mac nobody is looking at.
@MainActor
struct WorkspaceDeviceSessionTests {
    @Test func nothingIsCheckedUntilSomethingAsks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let observer = ScriptedObserver(results: [.success([Fixture.claudeCode(commandAvailable: true)])])

        let session = await fixture.session(observer: observer)

        // Opening the workspace must not start a scan; the shell decides when.
        #expect(await observer.calls == 0)
        #expect(session.observations.isEmpty)
        #expect(session.lastCheckedAt == nil)
        #expect(session.verdict(for: .claude) == ClientVerdict(state: .pending, text: "Not checked yet"))
    }

    @Test func aClientWhoseCommandAnswersIsHealthyAndSaysWhenItWasChecked() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let earlier = Date.now.addingTimeInterval(-40 * 24 * 60 * 60)
        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([
                    // The later of the two is the one reported, so a stale
                    // surface cannot make a fresh check look old.
                    Fixture.claudeCode(commandAvailable: true, scannedAt: .now),
                    Fixture.observation(
                        .claudeDesktop, installed: true, commandAvailable: false,
                        scannedAt: earlier),
                ])
            ]))

        await session.refresh()

        let verdict = session.verdict(for: .claude)
        #expect(verdict.state == .healthy)
        #expect(verdict.text.hasPrefix("Checked "))
        // Today is said as a time; anything older is said as a date.
        #expect(!verdict.text.contains(earlier.formatted(.dateTime.month(.abbreviated).day())))
        #expect(session.lastCheckedAt != nil)
        #expect(session.errorMessage == nil)
    }

    @Test func aCheckFromAnotherDayIsSaidAsADateRatherThanATime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let earlier = Date.now.addingTimeInterval(-40 * 24 * 60 * 60)
        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([Fixture.claudeCode(commandAvailable: true, scannedAt: earlier)])
            ]))

        await session.refresh()

        #expect(
            session.verdict(for: .claude)
                == ClientVerdict(
                    state: .healthy,
                    text: "Checked \(earlier.formatted(.dateTime.month(.abbreviated).day()))"))
    }

    @Test func filesWithoutACommandAreDistinguishedFromNothingAtAll() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([
                    Fixture.observation(.claudeCode, installed: true, commandAvailable: false),
                    Fixture.observation(.codexCLI, installed: false, commandAvailable: false),
                ])
            ]))

        await session.refresh()

        #expect(
            session.verdict(for: .claude)
                == ClientVerdict(state: .attention, text: "Command unavailable"))
        #expect(session.verdict(for: .codex) == ClientVerdict(state: .attention, text: "Not found"))
        // Never scanned is not the same as looked for and missing.
        #expect(
            session.verdict(for: .gemini)
                == ClientVerdict(state: .pending, text: "Not checked yet"))
    }

    @Test func onlyTheAppsThisMacManagesAreCountedAsNeedingAttention() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([
                    Fixture.observation(.claudeCode, installed: true, commandAvailable: false),
                    Fixture.observation(.codexCLI, installed: false, commandAvailable: false),
                    Fixture.observation(.geminiCLI, installed: true, commandAvailable: true),
                ])
            ]))
        await session.refresh()
        #expect(session.attentionCount == 2)

        await session.setEnabled(.codex, false)

        // The verdict is still known and still honest; it is just not this
        // Mac's problem any more.
        #expect(session.attentionCount == 1)
        #expect(session.verdict(for: .codex) == ClientVerdict(state: .attention, text: "Not found"))
    }

    @Test func choosingWhichAppsThisMacManagesIsRememberedOnThisMacOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        #expect(session.availableClients == ClientKind.allCases)
        #expect(session.enabledClients == Set(ClientKind.allCases))

        await session.setEnabled(.gemini, false)

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.isEnabled(.gemini) == false)
        #expect(session.isEnabled(.claude))
        // A surface with no client of its own is never hidden by the choice.
        #expect(session.isEnabled(nil))

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.device.applicationState?.preferences.enabledClients == [.claude, .codex])
        // The choice is this Mac's. Nothing about it goes into portable bytes.
        #expect(snapshot.document.artifacts.map(\.identity.id) == [Fixture.skill])
        #expect(snapshot.document.assignments.isEmpty)

        // A session opened over the same store reads the choice back.
        let reopened = await fixture.session()
        #expect(reopened.enabledClients == [.claude, .codex])
        #expect(reopened.attentionCount == 0)
    }

    @Test func managingAnAppAgainIsRememberedTheSameWay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.setEnabled(.gemini, false)

        await session.setEnabled(.gemini, true)

        #expect(session.enabledClients == Set(ClientKind.allCases))
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(
            snapshot.device.applicationState?.preferences.enabledClients
                == [.claude, .codex, .gemini])
    }

    @Test func automaticHealthChecksDefaultOnAndAreRememberedOnThisMacOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        #expect(session.automaticallyCheckHealth)

        await session.setAutomaticallyCheckHealth(false)

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.automaticallyCheckHealth == false)

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.device.applicationState?.preferences.automaticallyCheckHealth == false)
        // The choice is this Mac's. Nothing about it goes into portable bytes.
        #expect(snapshot.document.artifacts.map(\.identity.id) == [Fixture.skill])
        #expect(snapshot.document.assignments.isEmpty)

        // A session opened over the same store reads the choice back.
        let reopened = await fixture.session()
        #expect(reopened.automaticallyCheckHealth == false)
    }

    @Test func turningAutomaticHealthChecksBackOnIsRememberedTheSameWay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.setAutomaticallyCheckHealth(false)

        await session.setAutomaticallyCheckHealth(true)

        #expect(session.automaticallyCheckHealth)
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.device.applicationState?.preferences.automaticallyCheckHealth == true)
    }

    @Test func anOverlappingCheckJoinsTheOneAlreadyRunning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let observer = ScriptedObserver(
            results: [.success([Fixture.claudeCode(commandAvailable: true)])], held: true)
        let session = await fixture.session(observer: observer)
        #expect(session.isChecking == false)

        async let running: Void = session.refresh()
        await observer.waitUntilCalled()
        #expect(session.isChecking)

        // Asking again while one is running must not scan a second time.
        await session.refresh()
        #expect(await observer.calls == 1)

        await observer.release()
        await running
        #expect(session.isChecking == false)
        #expect(session.observations.count == 1)
        #expect(session.lastCheckedAt != nil)
        #expect(await observer.lastHomeRoot == fixture.home)
    }

    @Test func aFailedCheckSaysSoAndKeepsWhatTheLastOneFound() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let observer = ScriptedObserver(results: [
            .success([Fixture.claudeCode(commandAvailable: true)]),
            .failure(ScanFailure()),
        ])
        let session = await fixture.session(observer: observer)
        await session.refresh()
        let checkedAt = try #require(session.lastCheckedAt)

        await session.refresh()

        #expect(session.errorMessage != nil)
        // What was found before is still the truest thing known about this Mac.
        #expect(session.observations.count == 1)
        #expect(session.verdict(for: .claude).state == .healthy)
        // A check that did not happen is not recorded as one that did.
        #expect(session.lastCheckedAt == checkedAt)
        #expect(session.isChecking == false)
    }

    @Test func aCheckThatSucceedsAfterOneThatFailedClearsTheMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let observer = ScriptedObserver(results: [
            .failure(ScanFailure()),
            .success([Fixture.claudeCode(commandAvailable: true)]),
        ])
        let session = await fixture.session(observer: observer)
        await session.refresh()
        #expect(session.errorMessage != nil)
        #expect(session.observations.isEmpty)

        await session.refresh()

        #expect(session.errorMessage == nil)
        #expect(session.observations.count == 1)
    }

    @Test func aCheckKeepsWhatItFoundAndWhatEachAppCanCarry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let observed = [
            Fixture.claudeCode(commandAvailable: true, version: "2.1.263", scannedAt: scannedAt)
        ]
        let session = await fixture.session(observer: ScriptedObserver(results: [.success(observed)]))

        await session.refresh()

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let snapshot = try #require(try fixture.store.snapshot())
        // Before this, the persisted observations were the first run's forever,
        // so checking this Mac's apps changed nothing the planner reads.
        #expect(snapshot.device.observations == observed)
        #expect(
            snapshot.device.capabilityEvidence
                == TargetCapabilityEvidence.derive(from: observed))
        #expect(!snapshot.device.capabilityEvidence.isEmpty)
        #expect(snapshot.device.capabilityEvidence.allSatisfy { $0.installedClientVersion == "2.1.263" })
        // This Mac's record of this Mac. Nothing about it is portable.
        #expect(snapshot.document.artifacts.map(\.identity.id) == [Fixture.skill])
    }

    @Test func checkingAgainWithTheSameAnswerLeavesTheSameRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([
                    Fixture.claudeCode(commandAvailable: true, version: "2.1.263", scannedAt: scannedAt)
                ])
            ]))

        await session.refresh()
        let first = try #require(try fixture.store.snapshot()).device
        await session.refresh()
        let second = try #require(try fixture.store.snapshot()).device

        #expect(second.observations == first.observations)
        #expect(second.capabilityEvidence == first.capabilityEvidence)
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
    }

    @Test func aCheckThatFailedLeavesWhatWasRecordedExactlyAsItWas() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let observed = [Fixture.claudeCode(commandAvailable: true, version: "2.1.263")]
        let observer = ScriptedObserver(results: [.success(observed), .failure(ScanFailure())])
        let session = await fixture.session(observer: observer)
        await session.refresh()
        let recorded = try #require(try fixture.store.snapshot()).device

        await session.refresh()

        #expect(session.errorMessage != nil)
        let after = try #require(try fixture.store.snapshot()).device
        // A check that did not happen writes nothing down.
        #expect(after.observations == recorded.observations)
        #expect(after.capabilityEvidence == recorded.capabilityEvidence)
    }

    @Test func aClientThatDidNotAnswerIsRecordedAsSeenAndNotAsCapable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let observed = [
            Fixture.claudeCode(
                commandAvailable: false, scannedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ]
        let session = await fixture.session(observer: ScriptedObserver(results: [.success(observed)]))

        await session.refresh()

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.device.observations == observed)
        // Unknown never becomes an actionable install claim.
        #expect(snapshot.device.capabilityEvidence.isEmpty)
    }

    private struct ScanFailure: Error {}

    /// A scan the test drives: it counts how many times it ran, can be held
    /// open so an overlapping call has something to overlap with, and answers
    /// with exactly what the test wrote down.
    private actor ScriptedObserver: DeviceObserving {
        private var results: [Result<[TargetObservation], ScanFailure>]
        private var isHeld: Bool
        private var held: [CheckedContinuation<Void, Never>] = []
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0
        private(set) var lastHomeRoot: URL?

        init(results: [Result<[TargetObservation], ScanFailure>], held isHeld: Bool = false) {
            self.results = results
            self.isHeld = isHeld
        }

        func observe(homeRoot: URL) async throws -> [TargetObservation] {
            calls += 1
            lastHomeRoot = homeRoot
            for arrival in arrivals { arrival.resume() }
            arrivals = []
            if isHeld { await withCheckedContinuation { held.append($0) } }
            // The last answer repeats, so a test only writes down what changes.
            let result = results.count > 1 ? results.removeFirst() : (results.first ?? .success([]))
            return try result.get()
        }

        /// Returns once a scan has started, so the test can look at the session
        /// while one is genuinely in flight rather than after a guessed delay.
        func waitUntilCalled() async {
            guard calls == 0 else { return }
            await withCheckedContinuation { arrivals.append($0) }
        }

        func release() {
            isHeld = false
            for waiter in held { waiter.resume() }
            held = []
        }
    }

    /// A real store in a temporary folder, wired the way the app wires it.
    @MainActor private struct Fixture {
        /// One artifact, only so the document has something in it that this
        /// session must leave alone.
        static let skill = ArtifactID()
        let root: URL
        let home: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let library: WorkspaceLibrarySession
        let writerID = WorkspaceObjectID()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "device-session-\(UUID())", directoryHint: .isDirectory)
            let container = root.appending(path: "store", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            for directory in [container, home] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                    artifacts: [
                        .init(
                            identity: .init(id: Self.skill, kind: .skill, displayName: "Standalone Skill"),
                            authority: .centralPersonal)
                    ]))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: container, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
            library = WorkspaceLibrarySession(
                service: service, workspaceID: document.workspaceID, deviceID: device.deviceID,
                access: .writable)
        }

        func session(observer: any DeviceObserving = ScriptedObserver(results: [.success([])]))
            async -> WorkspaceDeviceSession
        {
            await library.refresh()
            return WorkspaceDeviceSession(
                service: service, library: library, store: store, homeRoot: home, observer: observer)
        }

        static func observation(
            _ surface: TargetSurface, installed: Bool, commandAvailable: Bool,
            version: String? = nil, scannedAt: Date = .now
        ) -> TargetObservation {
            .init(
                surface: surface, installed: installed, commandAvailable: commandAvailable,
                version: version,
                capabilities: .init(
                    supportsPluginInstall: false, supportsProjectScope: false,
                    supportsLocalMarketplace: false, supportsMCPAuthentication: false,
                    supportsConnectorDiscovery: false, requiresNewSession: false,
                    requiresRestart: false, supportsMachineReadableOutput: false),
                lastScannedAt: scannedAt)
        }

        static func claudeCode(
            commandAvailable: Bool, version: String? = nil, scannedAt: Date = .now
        ) -> TargetObservation {
            observation(
                .claudeCode, installed: true, commandAvailable: commandAvailable, version: version,
                scannedAt: scannedAt)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
