import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// D34: the setup stage's audit reads nothing the person was not shown. It
/// never scans, never asks the login shell for its PATH and never runs the
/// accounts read; Checkup's own audit still does all three.
@Suite("Setup stage audit", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceSetupSessionStageAuditTests {
    @Test func theStageAuditScansNothingAsksNoShellAndReadsNoAccount() async throws {
        let (fixture, accounts) = try await Self.fixture()
        defer { fixture.remove() }
        let workspace = try await Self.uncheckedWorkspace(fixture)

        await workspace.setup.audit(scansIfUnchecked: false, asksLoginShell: false, readsAccounts: false)

        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.setup.searchPathCalls == 0)
        #expect(accounts.reads == 0)
        #expect(workspace.setup.checkup != nil)
    }

    /// Tool folders the read found are added to the audit's search path
    /// without asking the shell for its own.
    @Test func foldersTheStageFoundNeedNoShell() async throws {
        let (fixture, accounts) = try await Self.fixture()
        defer { fixture.remove() }
        let workspace = try await Self.uncheckedWorkspace(fixture)

        await workspace.setup.audit(
            scansIfUnchecked: false, asksLoginShell: false, readsAccounts: false,
            extraFolders: [fixture.home.appending(path: ".npm-global/bin", directoryHint: .isDirectory)])

        #expect(fixture.setup.searchPathCalls == 0)
        #expect(fixture.observer.fullChecks == 0)
        #expect(accounts.reads == 0)
    }

    /// The flow's own audit is the stage's, after the commit as after a join.
    @Test func theFlowAuditsTheStageWay() async throws {
        let (fixture, accounts) = try await Self.fixture()
        defer { fixture.remove() }
        let workspace = try await Self.uncheckedWorkspace(fixture)
        let flow = fixture.flow(.finishJoin(workspace.store.workspaceID))

        await flow.didJoin(workspace)
        await flow.runStageAuditIfChanged()

        #expect(workspace.setup.checkup != nil)
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.setup.searchPathCalls == 0)
        #expect(accounts.reads == 0)
    }

    /// Done audits again only when the library or this Mac's check moved.
    @Test func doneAuditsAgainOnlyWhenSomethingMoved() async throws {
        let (fixture, _) = try await Self.fixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.continueFirstRun(.done), workspace: workspace)
        await flow.runStageAudit()
        let first = try #require(workspace.setup.checkup?.audit.generatedAt)

        await flow.runStageAuditIfChanged()
        #expect(workspace.setup.checkup?.audit.generatedAt == first)

        await workspace.device.adopt(fixture.orderedObservations)
        await flow.runStageAuditIfChanged()
        #expect(workspace.setup.checkup?.audit.generatedAt != first)
    }

    /// D34 and D35: a sign-in read that landed before the commit seeds the
    /// accounts before the stage audit runs, so the one audit has it. One
    /// that lands later seeds then, and the audit runs again because the
    /// sign-ins moved. Neither reads an account itself.
    @Test func theCommitAuditsWithTheSignInsThatLanded() async throws {
        let (fixture, accounts) = try await Self.fixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        let signIns = LaunchpadFixture.signIns(for: .juniper)
        var auditedBeforeTheSeed: Bool?

        try await flow.commitStartHere(observations: fixture.orderedObservations, seed: fixture.seed) { workspace in
            auditedBeforeTheSeed = workspace.setup.checkup != nil
            await workspace.accounts.seed(signIns[.chatGPT].map { [$0] } ?? [])
        }

        let workspace = try #require(flow.workspace)
        #expect(auditedBeforeTheSeed == false)
        #expect(Set(workspace.accounts.observations.keys) == [.chatGPT])
        let first = try #require(workspace.setup.checkup?.audit.generatedAt)
        await flow.runStageAuditIfChanged()
        #expect(workspace.setup.checkup?.audit.generatedAt == first)

        // Claude Code's sign-in read lands after the commit.
        await workspace.accounts.seed(signIns[.claude].map { [$0] } ?? [])
        await flow.runStageAuditIfChanged()
        #expect(workspace.setup.checkup?.audit.generatedAt != first)
        #expect(accounts.reads == 0)
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.setup.searchPathCalls == 0)
    }

    /// The other side of the rule: Checkup's audit on a Mac never checked
    /// scans, asks the shell and reads the accounts, so the counters above
    /// would have seen each.
    @Test func checkupsOwnAuditStillDoesAllThree() async throws {
        let (fixture, accounts) = try await Self.fixture()
        defer { fixture.remove() }
        let workspace = try await Self.uncheckedWorkspace(fixture)

        await workspace.setup.audit()

        #expect(fixture.observer.fullChecks == 1)
        #expect(fixture.setup.searchPathCalls == 1)
        #expect(accounts.reads == 1)
    }

    // MARK: - Helpers

    /// Juniper's stage with an account reader that counts its reads.
    private static func fixture() async throws -> (LaunchpadFixture, CountingAccountReader) {
        var fixture = try await LaunchpadFixture()
        let accounts = CountingAccountReader()
        fixture.environment.sessions.accountReader = { _ in accounts }
        return (fixture, accounts)
    }

    /// A library Juniper made with its apps chosen and nothing checked yet,
    /// so an audit that may scan would.
    private static func uncheckedWorkspace(_ fixture: LaunchpadFixture) async throws -> WorkspaceLaunch.Workspace {
        try await WorkspaceLaunch.create(
            observations: [], preferences: fixture.seed.preferences, supportRoot: fixture.support, homeRoot: fixture.home,
            beforeRecord: { _ in }, services: fixture.environment.sessions)
    }
}

/// An account reader that counts how many reads reach it.
private final class CountingAccountReader: AccountSurfaceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var reads: Int { lock.withLock { count } }

    func read(_ providers: [AccountProvider], depth: AccountSurfaceProbe.Depth, now: Date) async -> [AccountObservation] {
        lock.withLock { count += 1 }
        return providers.map { AccountObservation(provider: $0, observedAt: now, unavailableReason: "Not read in tests.") }
    }
}

/// D35: before a workspace exists, the stage reads how the chosen apps sign
/// in with one login-shell probe and one cancellable read per provider; the
/// reads join the workspace's accounts when they land, so neither the stage
/// audit nor Checkup's first light read runs them again.
@Suite("Setup sign-in read", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SetupSignInReadTests {
    @Test func withNoAccountToReadNothingRunsNotEvenTheShell() async {
        let reader = StubSignInReader(answers: LaunchpadFixture.signIns(for: .juniper))
        let read = SetupSignInRead(reader: reader, now: { ClientHomeFixture.now })

        read.start(apps: [.gemini, .kiro])
        await read.waitUntilFinished()

        #expect(read.isFinished)
        #expect(reader.shellProbes == 0)
        #expect(reader.reads.isEmpty)
        #expect(read.line(for: .gemini) == LaunchpadCopy.Found.SignIn.cannotCheck)
    }

    @Test func oneShellProbeThenOneReadPerProvider() async {
        let reader = StubSignInReader(answers: LaunchpadFixture.signIns(for: .juniper))
        let read = SetupSignInRead(reader: reader, now: { ClientHomeFixture.now })

        read.start(apps: [.codex, .claude, .gemini])
        await read.waitUntilFinished()

        #expect(reader.shellProbes == 1)
        #expect(Set(reader.reads) == [.chatGPT, .claude])
        #expect(reader.reads.count == 2)
        #expect(read.landed.map(\.provider) == AccountProvider.allCases.filter { [.chatGPT, .claude].contains($0) })
        #expect(read.line(for: .codex) == "ChatGPT · Plus")
        #expect(read.line(for: .claude) == "claude.ai · Max")
        #expect(read.line(for: .gemini) == "Can’t check sign-in yet")
    }

    /// Skipping an app stops its provider's read and no other's.
    @Test func skippingAnAppStopsOnlyItsRead() async {
        let gate = GatedCommandRunner()
        let reader = StubSignInReader(answers: LaunchpadFixture.signIns(for: .juniper), gate: gate)
        let read = SetupSignInRead(reader: reader, now: { ClientHomeFixture.now })

        read.start(apps: [.codex, .claude])
        await gate.waitUntilCalled(times: 2)
        #expect(read.line(for: .claude) == LaunchpadCopy.Found.SignIn.checking)
        #expect(!read.isFinished)
        read.cancel(.claude)
        #expect(read.line(for: .claude) == nil)
        #expect(!read.isFinished)
        gate.release()
        await read.waitUntilFinished()

        #expect(read.landed.map(\.provider) == [.chatGPT])
        #expect(read.line(for: .codex) == "ChatGPT · Plus")
        #expect(gate.cancelledCalls == 1)
    }

    /// What the stage read joins the workspace's accounts as read, so the
    /// first light read Checkup makes reads nothing again.
    @Test func whatTheStageReadIsSeededAsRead() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let accounts = CountingSignInAccounts()
        fixture.environment.sessions.accountReader = { _ in accounts }
        let read = SetupSignInRead(reader: fixture.signIn, now: { ClientHomeFixture.now })
        read.start(apps: fixture.world.found)
        await read.waitUntilFinished()
        let workspace = try await WorkspaceLaunch.create(
            observations: fixture.orderedObservations, preferences: fixture.seed.preferences, supportRoot: fixture.support,
            homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)

        await workspace.accounts.seed(read.landed)
        await workspace.accounts.readIfNeverRead(depth: .signInOnly)

        #expect(accounts.reads == 0)
        #expect(workspace.accounts.observations[.claude]?.signIn?.plan == "max")
        #expect(workspace.accounts.observations[.chatGPT]?.signIn?.plan == "plus")
    }
}

/// An account reader that counts its reads, for the seeding test.
private final class CountingSignInAccounts: AccountSurfaceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var reads: Int { lock.withLock { count } }

    func read(_ providers: [AccountProvider], depth: AccountSurfaceProbe.Depth, now: Date) async -> [AccountObservation] {
        lock.withLock { count += 1 }
        return []
    }
}
