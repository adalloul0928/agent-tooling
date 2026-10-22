import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The deployment session's one work queue (D4): preparing, applying, a
/// reviewed apply and the direct paths run one at a time, in the order they
/// were asked for. An apply asked for while a plan is being prepared waits for
/// the plan and then applies; it never finds the session busy and silently
/// does nothing. A reviewed apply runs exactly the steps it is given, refuses
/// a library that moved, and reports each step as it starts and ends in the
/// order the review draws them.
@Suite("Apply reviewed queue", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ApplyReviewedQueueTests {
    @Test func aReviewedApplyAskedForDuringAPrepareWaitsAndThenApplies() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (deployment, sample) = try await Self.prepared(fixture)
        let gate = GatedCommandRunner()
        fixture.scriptReviewCommands(in: sample.workspace, runner: gate)
        let revision = try #require(deployment.planRevision)
        let log = EventRecorder<String>()

        // Codex's connection holds the queue: its command waits on the gate.
        let connection = try Self.connection(in: deployment, for: .codex)
        let held = Task { await deployment.applyReviewed(connection, basedOn: revision) }
        await gate.waitUntilCalled()
        #expect(deployment.isBusy)
        let preparing = Task {
            await deployment.prepare()
            log.record("prepared")
        }
        let copy = try #require(deployment.plan(for: [Self.releaseNotes(sample)]))
        let applying = Task {
            await deployment.applyReviewed(copy, basedOn: revision) { _, progress in
                if progress == .started { log.record("applying") }
            }
        }
        await Task.yield()
        #expect(log.events.isEmpty)
        gate.release()

        #expect(await held.value.isApplied)
        await preparing.value
        let outcome = await applying.value
        #expect(log.events == ["prepared", "applying"])
        guard case .applied(let result) = outcome else {
            Issue.record("The apply asked for during a prepare did not apply: \(outcome)")
            return
        }
        #expect(result.installed == [.codex])
        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/release-notes/SKILL.md").path))
    }

    /// A direct apply asked for while the session is working is not dropped
    /// either: it waits its turn.
    @Test func aDirectApplyAskedForWhileTheSessionWorksIsNotDropped() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (deployment, sample) = try await Self.prepared(fixture)
        let gate = GatedCommandRunner()
        fixture.scriptReviewCommands(in: sample.workspace, runner: gate)
        let revision = try #require(deployment.planRevision)

        let connection = try Self.connection(in: deployment, for: .codex)
        let held = Task { await deployment.applyReviewed(connection, basedOn: revision) }
        await gate.waitUntilCalled()
        let releaseNotes = try Self.releaseNotes(sample)
        let direct = Task { await deployment.apply(only: [releaseNotes]) }
        await Task.yield()
        gate.release()
        _ = await held.value
        await direct.value

        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/release-notes/SKILL.md").path))
        #expect(deployment.errorMessage == nil)
    }

    @Test func eachStepIsReportedInTheOrderTheReviewDrawsIt() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)
        await review.prepare()
        let deployment = sample.workspace.deployment
        fixture.scriptReviewCommands(in: sample.workspace, runner: fixture.reviewRunner())
        let drawn = review.groups.flatMap(\.steps).filter(\.isChange).map(\.id)
        let plan = try #require(deployment.plan)
        let runnable = WorkspaceDeploymentPlan(
            items: plan.items.filter { drawn.contains(WorkspaceDeploymentSession.installKey($0)) }, exclusions: [],
            requirements: plan.requirements, resolvedTargets: plan.resolvedTargets)
        let events = EventRecorder<String>()
        let index = Dictionary(uniqueKeysWithValues: drawn.enumerated().map { ($1, $0 + 1) })

        let outcome = await deployment.applyReviewed(runnable, basedOn: try #require(deployment.planRevision)) { key, progress in
            events.record("\(index[key] ?? 0) \(progress)")
        }

        #expect(outcome.isApplied)
        #expect(
            events.events == [
                "1 started", "1 succeeded", "2 started", "2 succeeded", "3 started", "3 succeeded", "4 started", "4 succeeded",
            ])
    }

    @Test func aMovedLibraryRunsNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (deployment, sample) = try await Self.prepared(fixture)
        let runner = fixture.reviewRunner()
        fixture.scriptReviewCommands(in: sample.workspace, runner: runner)
        let plan = try #require(deployment.plan)

        let outcome = await deployment.applyReviewed(plan, basedOn: WorkspaceObjectID())

        #expect(outcome == .stale)
        #expect(await runner.launches.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/release-notes").path))
    }

    @Test func anEmptyPlanRunsNothingAndSaysSo() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (deployment, _) = try await Self.prepared(fixture)

        let outcome = await deployment.applyReviewed(
            WorkspaceDeploymentPlan(items: [], exclusions: []), basedOn: try #require(deployment.planRevision))

        #expect(outcome == .notRun("There is nothing in this plan to install."))
    }

    // MARK: - The sample world

    private static func prepared(_ fixture: LaunchpadFixture) async throws -> (WorkspaceDeploymentSession, LaunchpadSample) {
        let sample = try await fixture.sample(.afterAsk)
        await sample.workspace.deployment.prepare()
        return (sample.workspace.deployment, sample)
    }

    private static func releaseNotes(_ sample: LaunchpadSample) throws -> ArtifactID {
        try #require(sample.decisions.adopted.first?.artifactID)
    }

    /// Agent Tooling's connection in one app, alone.
    private static func connection(in deployment: WorkspaceDeploymentSession, for client: ClientKind) throws
        -> WorkspaceDeploymentPlan
    {
        let plan = try #require(deployment.plan)
        let items = plan.items.filter {
            if case .configureManagedConnection = $0.action { return $0.surface.client == client }
            return false
        }
        #expect(items.count == 1)
        return WorkspaceDeploymentPlan(
            items: items, exclusions: [], requirements: plan.requirements, resolvedTargets: plan.resolvedTargets)
    }
}

extension ReviewedApplyOutcome {
    fileprivate var isApplied: Bool {
        if case .applied = self { true } else { false }
    }
}
