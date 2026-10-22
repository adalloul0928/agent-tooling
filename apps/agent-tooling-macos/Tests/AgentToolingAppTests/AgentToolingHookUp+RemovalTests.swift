import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// D10's way to take Agent Tooling's own connection back: untick an app on
/// Let your apps ask (a revisit), and review. Only a connection a receipt
/// shows Agent Tooling set up is a checkbox; the review lists and runs the
/// app's own removal; afterwards nothing plans the helper there again, and
/// the proof that let Agent Tooling take it out is gone. A registration
/// somebody made by hand keeps its glyph and is never taken out.
@Suite("Agent Tooling hook-up · taking it out", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct AgentToolingHookUpRemovalTests {
    @Test func untickingAnAppAgentToolingConnectedTakesItOutThroughTheReview() async throws {
        let fixture = try await Self.juniperInApplications()
        defer { fixture.remove() }
        let (_, sample) = try await fixture.flow(at: .afterAsk)
        let workspace = sample.workspace
        let own = try #require(sample.decisions.helperArtifactID)
        try await Self.installForReal(fixture, in: workspace)

        // Home's Connect Agent Tooling, or a rerun, comes back to the step.
        let revisit = fixture.flow(.revisit(.ask), workspace: workspace)
        let model = AgentToolingHookUp.of(revisit)
        await model.load(decisions: revisit.decisions)

        #expect(model.provenSurfaces == [.codexCLI, .claudeCode])
        #expect(Array(model.rows.prefix(2).map(\.status)) == [.alreadyConnected(provenOurs: true), .alreadyConnected(provenOurs: true)])
        #expect(model.rows.prefix(2).allSatisfy { $0.canTick && $0.isTicked && !$0.removesStep })
        #expect(model.primaryTitle == "Review changes…", "nothing to change while both stay ticked")

        model.toggle(.claude)

        let claude = model.rows[1]
        #expect(!claude.isTicked && claude.removesStep && !claude.addsStep)
        #expect(claude.commandLines == ["claude mcp remove --scope user agent-tooling"], "the row shows what the review runs")
        #expect(model.primaryTitle == "Review 1 change…")
        let before = try #require(try workspace.store.snapshot()).document.revision.id

        try #require(LaunchpadAskScreen.footer(revisit).primary).action()
        await waitUntil { revisit.presentedReview != nil }

        // One revision: this Mac now asks for the connection in Codex alone.
        let recorded = try #require(try workspace.store.snapshot())
        #expect(recorded.document.revision.parentIDs == [before])
        #expect(AgentToolingConnection.apps(on: workspace.store.deviceID, in: recorded.document) == [.codex])

        let runner = ScriptedCommandRunner(byTool: [
            "claude": [["mcp", "remove", "--scope", "user", "agent-tooling"]: .standardOutput("")]
        ])
        fixture.scriptReviewCommands(in: workspace, runner: runner)
        let review = try #require(revisit.presentedReview)
        await review.prepare()

        #expect(review.groups.map(\.client) == [.claude])
        let step = try #require(review.groups.first?.steps.first)
        #expect(step.title == "Remove Agent Tooling from Claude Code")
        #expect(step.action == .disconnect)
        #expect(step.number == 1)
        #expect(step.well == .commands(["claude mcp remove --scope user agent-tooling"]))
        #expect(review.runnableCount == 1)
        #expect(review.title == "Apply 1 change")

        fixture.observer.answer(with: try Self.observationsWithout(.claude, in: workspace, home: fixture.world.home))
        await review.install()

        #expect(await runner.launches.map(\.display) == ["claude mcp remove --scope user agent-tooling"])
        guard case .finished(let outcome) = review.phase else {
            Issue.record("The removal did not finish: \(review.phase)")
            return
        }
        #expect(outcome.summary == "Applied to Claude Code.")
        #expect(outcome.receiptLine.hasPrefix("Applied 1 change · "))
        #expect(fixture.observer.scopedChecks.last == [.claude], "the app its own tool ran in is checked again (D29)")

        // Nothing plans the helper in Claude Code again, nor counts it as
        // waiting, and the proof that let it come out is gone.
        let plan = try #require(workspace.deployment.plan)
        #expect(!plan.items.contains { $0.artifactID == own })
        #expect(!workspace.deployment.pendingItems.contains { $0.artifactID == own })
        #expect(await WorkspaceDeploymentSession.provenConnections(in: workspace.store) == [.codexCLI: ["agent-tooling"]])
        await model.load(decisions: revisit.decisions)
        #expect(model.provenSurfaces == [.codexCLI])
        #expect(model.rows[1].status == .ready)
        #expect(!model.rows[1].isTicked)
        #expect(model.rows[0].status == .alreadyConnected(provenOurs: true) && model.rows[0].isTicked)
    }

    /// A connection to this copy that Agent Tooling cannot show it made (the
    /// sample world's install was not receipted) keeps the fragment's glyph:
    /// it cannot be unticked, and withdrawing it plans nothing.
    @Test func aConnectionNobodyCanShowAgentToolingMadeIsNeverTakenOut() async throws {
        let fixture = try await Self.juniperInApplications()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterInstall)
        let workspace = sample.workspace
        let own = try #require(sample.decisions.helperArtifactID)
        let model = AgentToolingHookUp.of(flow)
        await model.load(decisions: flow.decisions)

        #expect(Array(model.rows.prefix(2).map(\.status)) == [.alreadyConnected(provenOurs: false), .alreadyConnected(provenOurs: false)])
        #expect(model.rows.prefix(2).allSatisfy { !$0.canTick && $0.isTicked && !$0.removesStep })

        let head = try #require(try workspace.store.snapshot()).document.revision.id
        _ = try await workspace.service.connectAgentTooling(
            try ConnectAgentToolingCommand(expectedRevisionID: head, helperPath: fixture.helperPath, apps: [.codex]))
        await workspace.library.refresh()
        await workspace.deployment.prepare()

        let plan = try #require(workspace.deployment.plan)
        #expect(!plan.items.contains { $0.artifactID == own && $0.action.isRemoval })
    }

    // MARK: - Juniper with its copy in Applications

    private static func juniperInApplications() async throws -> LaunchpadFixture {
        var fixture = try await LaunchpadFixture()
        let applications = fixture.world.home.root.appending(path: "Applications", directoryHint: .isDirectory)
        fixture.environment.installation = { HelperBundle.inApplications(applications) }
        return fixture
    }

    /// S12's install, run through the executor with each app's commands
    /// answered: Codex and Claude Code start this copy's helper afterwards,
    /// and the receipts show Agent Tooling set it up in both.
    private static func installForReal(_ fixture: LaunchpadFixture, in workspace: WorkspaceLaunch.Workspace) async throws {
        let review = ScopedPlanReview(workspace: workspace, scope: .wholePlan, deviceName: "Juniper")
        await review.prepare()
        fixture.scriptReviewCommands(in: workspace, runner: fixture.reviewRunner())
        fixture.observer.answer(with: try await fixture.reviewObservationsAfterInstall())
        await review.install()
        guard case .finished(let outcome) = review.phase, outcome.isComplete else {
            Issue.record("The install did not finish: \(review.phase)")
            return
        }
    }

    /// This Mac's observations as the check after a removal reads them:
    /// `client`'s own configuration no longer registers agent-tooling, and its
    /// last check does not list it. Every other app keeps its check.
    private static func observationsWithout(
        _ client: ClientKind, in workspace: WorkspaceLaunch.Workspace, home: FixtureHome
    ) throws -> [TargetObservation] {
        let name = AgentToolingConnection.declaredName
        let config = home.url.appending(path: ".claude.json")
        var object = (try JSONSerialization.jsonObject(with: Data(contentsOf: config))) as? [String: Any] ?? [:]
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        servers[name] = nil
        object["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try home.plant(".claude.json", String(decoding: data, as: UTF8.self) + "\n")
        return workspace.device.observations.map { observation in
            guard observation.surface.client == client else { return observation }
            var removed = observation
            removed.discoveredMCPServers.removeAll { $0 == name }
            removed.mcpMetadata[name] = nil
            return removed
        }
    }
}
