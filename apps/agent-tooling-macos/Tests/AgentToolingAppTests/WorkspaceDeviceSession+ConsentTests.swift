import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// This Mac's assistant runs and its project-history choice, as Let your
/// assistant help, Home's notice, Settings and a rerun's What Agent Tooling
/// reads record them: on this Mac's own record only, shown at once, queued
/// with every other device write so the last flip stays, and put back with
/// the stage's one sentence when a write does not save.
@Suite("Device session consent", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceDeviceSessionConsentTests {
    private static let weekly = AssistantRunConsent(weeklyReview: true, dailyDeepDive: false, localInsights: false)
    private static let dive = AssistantRunConsent(weeklyReview: false, dailyDeepDive: true, localInsights: false)

    /// A second device session over the fixture's store, writing through
    /// `recorder` when one is given.
    private func session(
        _ fixture: ShellRenderFixture, recorder: (any DeviceStateRecording)? = nil
    ) -> WorkspaceDeviceSession {
        WorkspaceDeviceSession(
            service: fixture.workspace.service, library: fixture.workspace.library, store: fixture.store,
            homeRoot: fixture.home, observer: StubDeviceObserver(), recorder: recorder, registerToolRoots: { _ in })
    }

    private func recordedRuns(_ fixture: ShellRenderFixture) throws -> AssistantRunConsent? {
        try #require(try fixture.store.snapshot()).device.applicationState?.preferences.assistantRuns
    }

    // MARK: The assistant's runs

    @Test func aChoiceIsRecordedOnThisMacOnlyAndReadBack() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let device = fixture.workspace.device
        #expect(device.assistantRuns == nil)
        let artifactsBefore = try #require(try fixture.store.snapshot()).document.artifacts

        await device.setAssistantRuns(Self.weekly)

        #expect(device.errorMessage == nil, "\(device.errorMessage ?? "")")
        #expect(device.assistantRuns == Self.weekly)
        #expect(device.effectiveAssistantRuns == Self.weekly)
        #expect(try recordedRuns(fixture) == Self.weekly)
        #expect(device.preferences.assistantRuns == Self.weekly)
        #expect(try #require(try fixture.store.snapshot()).document.artifacts == artifactsBefore, "nothing portable changes")
        #expect(session(fixture).assistantRuns == Self.weekly, "a session opened later reads it back")
    }

    /// Recording today's runs is still a choice: it ends the notice a
    /// workspace made before the choice existed shows, and changes no run.
    @Test func recordingTodaysRunsMakesThemAChoice() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let device = fixture.workspace.device
        #expect(device.effectiveAssistantRuns == .existingBehaviour)

        await device.setAssistantRuns(.existingBehaviour)

        #expect(device.assistantRuns == .existingBehaviour)
        #expect(try recordedRuns(fixture) == .existingBehaviour)
    }

    @Test func twoQuickFlipsLeaveTheLastOne() async throws {
        let fixture = try await ShellRenderFixture(assistantRuns: .off)
        defer { fixture.remove() }
        let device = fixture.workspace.device

        let first = Task { await device.setAssistantRuns(Self.weekly) }
        let second = Task { await device.setAssistantRuns(.off) }
        _ = await (first.value, second.value)

        #expect(device.errorMessage == nil, "\(device.errorMessage ?? "")")
        #expect(device.assistantRuns == .off)
        #expect(try recordedRuns(fixture) == .off)
    }

    @Test func aFlipThatDoesNotSaveGoesBackAndSaysNothingWasChanged() async throws {
        let fixture = try await ShellRenderFixture(assistantRuns: .off)
        defer { fixture.remove() }
        let device = session(fixture, recorder: ConsentRecorder(service: fixture.workspace.service, failing: [1]))

        await device.setAssistantRuns(Self.weekly)

        #expect(device.assistantRuns == .off)
        #expect(device.errorMessage == LaunchpadCopy.Footer.Failures.notRecorded)
        #expect(try recordedRuns(fixture) == .off)
    }

    /// The first of two flips fails while the second waits behind it: the
    /// second is what stays, on screen and in the store, and the failure's
    /// "Nothing was changed" comes down once a later choice saved.
    @Test func aFailedFlipNeverUndoesALaterOne() async throws {
        let fixture = try await ShellRenderFixture(assistantRuns: .off)
        defer { fixture.remove() }
        let device = session(fixture, recorder: ConsentRecorder(service: fixture.workspace.service, failing: [1]))

        let first = Task { await device.setAssistantRuns(Self.weekly) }
        let second = Task { await device.setAssistantRuns(Self.dive) }
        _ = await (first.value, second.value)

        #expect(device.assistantRuns == Self.dive)
        #expect(try recordedRuns(fixture) == Self.dive)
        #expect(device.errorMessage == nil)
    }

    /// Another setting landing while a flip of the runs waits does not show
    /// the runs as they were before the flip.
    @Test func anotherSettingLandingMeanwhileKeepsTheFlipOnScreen() async throws {
        let fixture = try await ShellRenderFixture(assistantRuns: .off)
        defer { fixture.remove() }
        let device = fixture.workspace.device

        let health = Task { await device.setAutomaticallyCheckHealth(false) }
        let runs = Task { await device.setAssistantRuns(Self.weekly) }
        await health.value
        #expect(device.assistantRuns == Self.weekly, "the flip still on its way is what shows")
        await runs.value

        #expect(device.assistantRuns == Self.weekly)
        #expect(!device.automaticallyCheckHealth)
        #expect(try recordedRuns(fixture) == Self.weekly)
        #expect(device.preferences.automaticallyCheckHealth == false)
    }

    // MARK: Claude Code's history for projects

    @Test func theProjectHistoryChoiceIsRecordedAndPutBackWhenItDoesNotSave() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let device = fixture.workspace.device
        #expect(device.findsProjectsFromClaudeHistory == nil, "nil reads as on")

        await device.setFindsProjectsFromClaudeHistory(false)
        #expect(device.findsProjectsFromClaudeHistory == false)
        #expect(try #require(try fixture.store.snapshot()).device.applicationState?.preferences.findsProjectsFromClaudeHistory == false)

        let failing = session(fixture, recorder: ConsentRecorder(service: fixture.workspace.service, failing: [1]))
        await failing.setFindsProjectsFromClaudeHistory(true)
        #expect(failing.findsProjectsFromClaudeHistory == false)
        #expect(failing.errorMessage == LaunchpadCopy.Footer.Failures.notRecorded)
    }

    /// With the choice off, finding projects never reads Claude Code's
    /// session index; the folders this Mac was told to look in still count.
    @Test func projectDiscoveryReadsTheSessionIndexOnlyWhenAllowed() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "consent-projects-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appending(path: "home", directoryHint: .isDirectory)
        let project = base.appending(path: "work", directoryHint: .isDirectory).appending(
            path: "alpha", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("# alpha".utf8).write(to: project.appending(path: "CLAUDE.md"))
        // Claude Code's own naming: the absolute path with every "/" and "."
        // replaced by "-".
        let encoded = ProjectPath.canonical(project).replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        try FileManager.default.createDirectory(
            at: home.appending(path: ".claude/projects", directoryHint: .isDirectory).appending(
                path: encoded, directoryHint: .isDirectory),
            withIntermediateDirectories: true)

        func found(_ reads: Bool) -> [String] {
            WorkspaceProjectDiscoverySession.discover(
                homeURL: home, scanRoots: [], boundPaths: [], clients: [.claude], options: ProjectDiscoveryOptions(),
                readsSessionIndex: reads
            ).map { ProjectPath.canonical($0.path) }
        }
        #expect(found(true) == [ProjectPath.canonical(project)])
        #expect(found(false).isEmpty)
    }

    // MARK: What the launch work reads

    @Test func aCheckCountsForThisLaunchOnlyOnceThisSessionMadeOne() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let device = fixture.workspace.device
        #expect(!device.hasCheckedThisLaunch)

        await device.refresh()
        #expect(device.hasCheckedThisLaunch)
        #expect(!session(fixture).hasCheckedThisLaunch, "a session opened on a recorded check has not checked")

        let adopted = session(fixture)
        await adopted.adopt([ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true, version: "0.164.0")])
        #expect(adopted.hasCheckedThisLaunch, "the setup stage's read counts as this launch's check")

        // The read a first run made on the stage, which the shell opened
        // straight from, counts too, and nothing is read or written for it.
        let handedOff = session(fixture)
        let observations = handedOff.observations
        let head = try fixture.store.snapshot()?.document.revision.id
        handedOff.countStageReadAsThisLaunchsCheck()
        #expect(handedOff.hasCheckedThisLaunch)
        #expect(handedOff.observations == observations)
        #expect(try fixture.store.snapshot()?.document.revision.id == head)
    }
}

/// Writes through the service, failing the calls it was told to.
private actor ConsentRecorder: DeviceStateRecording {
    private let service: WorkspaceApplicationService
    private let failing: Set<Int>
    private var calls = 0

    init(service: WorkspaceApplicationService, failing: Set<Int>) {
        self.service = service
        self.failing = failing
    }

    func recordDeviceChange(
        _ change: @escaping @Sendable (inout DeviceWorkspaceState) throws -> Void
    ) async throws -> DeviceWorkspaceState {
        calls += 1
        guard !failing.contains(calls) else { throw CocoaError(.fileWriteNoPermission) }
        return try await service.recordDeviceChange(change)
    }
}
