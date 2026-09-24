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
        #expect(session.verdict(for: .claude).state == .pending)
        #expect(session.verdict(for: .claude).text == "Not checked yet")
    }

    @Test func aClientWhoseCommandAnswersIsHealthyAndSaysWhenItWasChecked() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let earlier = Date.now.addingTimeInterval(-40 * 24 * 60 * 60)
        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([
                    // The later of the two is the one reported, so a stale
                    // surface cannot make a fresh check look old. A version is
                    // present, so the client is genuinely healthy.
                    Fixture.claudeCode(commandAvailable: true, version: "2.1.263", scannedAt: .now),
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
                .success([Fixture.claudeCode(commandAvailable: true, version: "2.1.263", scannedAt: earlier)])
            ]))

        await session.refresh()

        let verdict = session.verdict(for: .claude)
        #expect(verdict.state == .healthy)
        #expect(verdict.text == "Checked \(earlier.formatted(.dateTime.month(.abbreviated).day()))")
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

        #expect(session.verdict(for: .claude).state == .attention)
        #expect(session.verdict(for: .claude).text == "Command unavailable")
        #expect(session.verdict(for: .codex).state == .attention)
        #expect(session.verdict(for: .codex).text == "Not found")
        // Never scanned is not the same as looked for and missing.
        #expect(session.verdict(for: .gemini).state == .pending)
        #expect(session.verdict(for: .gemini).text == "Not checked yet")
    }

    /// A command that ran but reported no version has not said what it accepts,
    /// so it is neither healthy nor missing: it is attention, and the words say
    /// why a tool asked for in it would wait.
    @Test func aCommandThatAnsweredWithoutAVersionIsAttentionNotHealthy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([Fixture.claudeCode(commandAvailable: true, version: nil)])
            ]))

        await session.refresh()

        let verdict = session.verdict(for: .claude)
        #expect(verdict.state == .attention)
        #expect(verdict.text == "Found, version unknown")
        #expect(verdict.detail.contains("did not answer --version"))
        #expect(verdict.detail.contains("wait until it does"))
        // A blank version string is treated the same as none.
        let blank = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([Fixture.claudeCode(commandAvailable: true, version: "")])
            ]))
        await blank.refresh()
        #expect(blank.verdict(for: .claude).state == .attention)
        #expect(blank.verdict(for: .claude).text == "Found, version unknown")
    }

    /// Every state carries a plain explanation for a tooltip or an
    /// accessibility value, and it names the client it is about.
    @Test func everyVerdictStateCarriesAPlainExplanation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([
                    Fixture.claudeCode(commandAvailable: true, version: "2.1.263"),
                    Fixture.observation(.codexCLI, installed: false, commandAvailable: false),
                    Fixture.observation(.geminiCLI, installed: true, commandAvailable: false),
                ])
            ]))

        // Before any check: "Run Check apps to look."
        #expect(session.verdict(for: .kiro).detail == "Run Check apps to look.")

        await session.refresh()

        #expect(session.verdict(for: .claude).detail == "Claude Code answered and reported version 2.1.263.")
        #expect(session.verdict(for: .codex).detail == "Nothing from Codex was found on this Mac.")
        #expect(session.verdict(for: .gemini).detail.contains("files were found on this Mac, but its command-line tool was not"))
        // Kiro was in this scan at all only if the scan reported it; it did not,
        // so it stays "not checked" with its own instruction.
        #expect(session.verdict(for: .kiro).detail == "Run Check apps to look.")
    }

    /// The managed set is every available client this Mac has been left
    /// managing, in the registry's own order, and it narrows exactly as the
    /// choice does.
    @Test func managedClientsFollowTheChoiceInRegistryOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        #expect(session.managedClients == ClientKind.allCases)

        await session.setEnabled(.gemini, false)
        #expect(session.managedClients == [.codex, .claude, .kiro])
        // Order is the registry's (ClientKind.allCases), not the order clients
        // were toggled in.
        await session.setEnabled(.gemini, true)
        #expect(session.managedClients == ClientKind.allCases)
    }

    @Test func onlyTheAppsThisMacManagesAreCountedAsNeedingAttention() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([
                    Fixture.observation(.claudeCode, installed: true, commandAvailable: false),
                    Fixture.observation(.codexCLI, installed: false, commandAvailable: false),
                    Fixture.observation(.geminiCLI, installed: true, commandAvailable: true, version: "1.4.0"),
                ])
            ]))
        await session.refresh()
        // Nobody has chosen, so the check decides what is shown — and set up
        // means the tool runs. Gemini's does and reports a version, so it is
        // healthy; Claude's files without a runnable tool do not count, and
        // Codex is not here at all.
        #expect(session.enabledClients == [.gemini])
        #expect(session.attentionCount == 0)

        // Turning a broken app on explicitly is the opt-in: its missing tool
        // becomes this Mac's problem because somebody said so.
        await session.setEnabled(.claude, true)
        #expect(session.attentionCount == 1)
        await session.setEnabled(.codex, true)
        #expect(session.attentionCount == 2)

        await session.setEnabled(.codex, false)

        // The verdict is still known and still honest; it is just not this
        // Mac's problem any more.
        #expect(session.attentionCount == 1)
        #expect(session.verdict(for: .codex).state == .attention)
        #expect(session.verdict(for: .codex).text == "Not found")
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
        #expect(snapshot.device.applicationState?.preferences.enabledClients == [.claude, .codex, .kiro])
        #expect(snapshot.device.applicationState?.preferences.chosenClients == [.claude, .codex, .kiro])
        // The choice is this Mac's. Nothing about it goes into portable bytes.
        #expect(snapshot.document.artifacts.map(\.identity.id) == [Fixture.skill])
        #expect(snapshot.document.assignments.isEmpty)

        // A session opened over the same store reads the choice back.
        let reopened = await fixture.session()
        #expect(reopened.enabledClients == [.claude, .codex, .kiro])
        #expect(reopened.attentionCount == 0)
    }

    /// Finding a missing tool records where it lives, says so, and the message
    /// leaves on its own once a check finds nothing missing any more.
    @Test func findingAMissingToolRecordsItsFolderAndTheMessageDoesNotStrand() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let toolDirectory = fixture.root.appending(path: "elsewhere/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
        let tool = toolDirectory.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        struct ShellRunner: CommandRunning {
            let answer: String
            func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
                guard executable == "/bin/zsh", arguments.last?.hasSuffix("claude") == true else {
                    return CommandOutput(status: 1, standardOutput: "", standardError: "")
                }
                return CommandOutput(status: 0, standardOutput: answer, standardError: "")
            }
        }

        let session = await fixture.session(
            observer: ScriptedObserver(results: [
                .success([
                    Fixture.observation(.claudeCode, installed: true, commandAvailable: false),
                    Fixture.observation(.geminiCLI, installed: true, commandAvailable: true, version: "1.4.0"),
                ]),
                .success([
                    Fixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.263"),
                    Fixture.observation(.geminiCLI, installed: true, commandAvailable: true, version: "1.4.0"),
                ]),
            ]),
            toolProbeRunner: ShellRunner(answer: tool.path))
        await session.refresh()
        // Claude's tool did not run, so it is hidden until managed explicitly.
        await session.setEnabled(.claude, true)
        #expect(session.missingManagedClients == [.claude])

        await session.smartFindTools()

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(
            snapshot.device.applicationState?.preferences.customToolDirectories
                == [toolDirectory.path])
        // The find re-checked, the second check found everything, and the
        // message left with the work instead of stranding as a problem.
        #expect(session.missingManagedClients.isEmpty)
        #expect(session.smartFindMessage == nil)
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
                == [.claude, .codex, .gemini, .kiro])
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
            .success([Fixture.claudeCode(commandAvailable: true, version: "2.1.263")]),
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

        func session(
            observer: any DeviceObserving = ScriptedObserver(results: [.success([])]),
            toolProbeRunner: (any CommandRunning)? = nil
        ) async -> WorkspaceDeviceSession {
            await library.refresh()
            return WorkspaceDeviceSession(
                service: service, library: library, store: store, homeRoot: home, observer: observer,
                toolProbeRunner: toolProbeRunner)
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
