import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Let your apps ask Agent Tooling on the sample world: which rows start
/// ticked, what the primary counts, the one revision it records, the review
/// it opens with the exact commands, and every state an app or this copy can
/// be in. Nothing here runs an app's own tool.
@Suite("Agent Tooling hook-up", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct AgentToolingHookUpTests {
    /// Juniper at Let your apps ask: the three apps that answered start
    /// ticked, Kiro CLI is not found, and each row carries its exact command.
    @Test func theAppsThatAnsweredStartTickedWithTheirCommands() async throws {
        let (fixture, flow, _) = try await Self.juniper(at: .afterPlace)
        defer { fixture.remove() }
        let model = AgentToolingHookUp.of(flow)
        let helper = fixture.helperPath

        #expect(model.rows.map(\.status) == [.ready, .ready, .ready, .notFound])
        #expect(model.rows.map(\.isTicked) == [true, true, true, false])
        #expect(model.appsToRecord == [.codex, .claude, .gemini])
        for row in model.rows where row.status == .ready {
            let expected = CommandLineDisplay.rendered(
                executableName: ClientExecutableLocator.executableName(for: row.client),
                arguments: AgentToolingConnection.previewArguments(client: row.client, helperPath: helper))
            #expect(row.command == expected, "\(row.client)")
            #expect(row.command?.contains("\"\(helper)\"") == true, "the path with a space is quoted")
        }
        #expect(model.answeredApps == [.codex, .claude, .gemini])
        #expect(model.primaryTitle == "Review changes…", "nothing is counted before the plan is read")
    }

    /// The primary counts what the review will list: S10's two changes and a
    /// step for each ticked app (the fragment's 4, 5 and 2).
    @Test func thePrimaryCountsWhatTheReviewWillList() async throws {
        let (fixture, flow, _) = try await Self.juniper(at: .afterPlace)
        defer { fixture.remove() }
        let model = AgentToolingHookUp.of(flow)
        await model.load(decisions: flow.decisions)

        #expect(model.changeCount == 5)
        model.toggle(.gemini)
        #expect(model.primaryTitle == "Review 4 changes…")
        model.toggle(.codex)
        model.toggle(.claude)
        #expect(model.primaryTitle == "Review 2 changes…")
        #expect(LaunchpadAskScreen.footer(flow).primary?.title == "Review 2 changes…")
    }

    /// S11's ↩ records one device-bound connection in one revision, and the
    /// review it opens lists S10's steps beside the two it adds, each running
    /// exactly the command the row showed.
    @Test func thePrimaryRecordsOneConnectionAndOpensTheReviewWithTheExactCommands() async throws {
        let (fixture, flow, sample) = try await Self.juniper(at: .afterPlace)
        defer { fixture.remove() }
        let model = AgentToolingHookUp.of(flow)
        await model.load(decisions: flow.decisions)
        model.toggle(.gemini)
        let shown = Dictionary(uniqueKeysWithValues: model.rows.compactMap { row in row.command.map { (row.client, $0) } })
        let before = try #require(try sample.workspace.store.snapshot()).document.revision.id

        try #require(LaunchpadAskScreen.footer(flow).primary).action()
        await waitUntil { flow.presentedReview != nil }

        let snapshot = try #require(try sample.workspace.store.snapshot())
        #expect(snapshot.document.revision.parentIDs == [before], "one revision")
        let own = try #require(AgentToolingConnection.ownConnection(in: snapshot.document))
        #expect(snapshot.document.artifacts.count { $0.declaredName == AgentToolingConnection.declaredName } == 1)
        #expect(snapshot.document.mcpDefinitions?.first { $0.artifactID == own.identity.id }?.connection == .deviceBound(transport: .stdio))
        #expect(
            snapshot.device.mcpBindings?.first { $0.artifactID == own.identity.id }?.destination
                == .stdio(executable: fixture.helperPath, arguments: []))
        let thisMac = sample.workspace.store.deviceID
        let contributions = snapshot.document.assignments.filter { $0.artifactID == own.identity.id }
        #expect(
            Set(contributions.map(\.destination)) == [
                .init(surface: .codexCLI, scope: .user, deviceIDs: [thisMac]),
                .init(surface: .claudeCode, scope: .user, deviceIDs: [thisMac]),
            ])
        #expect(flow.decisions.helperArtifactID == own.identity.id)
        #expect(flow.decisions.helperApps == [.codex, .claude])
        #expect(flow.outcomes.helperApps == [.codex, .claude])
        #expect(flow.decisions.count == 7)
        #expect(flow.decisions.lines.last == "Agent Tooling’s own connection, for Codex and Claude Code on this Mac only")

        let review = try #require(flow.presentedReview)
        await review.prepare()
        #expect(review.listedCount == 5)
        #expect(review.runnableCount == 4)
        #expect(review.title == "Install 4 changes")
        #expect(review.chip == "This Mac · Juniper")
        #expect(flow.reviewReturn == nil)

        // The review's connection steps run the commands the rows showed.
        let deployment = sample.workspace.deployment
        let plan = try #require(deployment.plan(for: [own.identity.id]))
        let snapshotNow = try #require(sample.workspace.library.state?.snapshot)
        let commands = WorkspaceDeploymentSession.commandPlans(plan: plan, snapshot: snapshotNow, homeRoot: fixture.home)
        #expect(commands.connections.count == 2)
        for command in commands.connections {
            let client = try #require(command.surface.client)
            #expect(CommandLineDisplay.rendered(executable: command.executableURL, arguments: command.arguments) == shown[client])
        }
    }

    /// Back on the step with the choice recorded, the rows start from it, and
    /// pressing the primary again writes nothing and opens the review at once.
    @Test func aRecordedChoiceIsWhereTheRowsStartAndPressingAgainWritesNothing() async throws {
        let (fixture, flow, sample) = try await Self.juniper(at: .afterAsk)
        defer { fixture.remove() }
        let model = AgentToolingHookUp.of(flow)
        let head = try #require(try sample.workspace.store.snapshot()).document.revision.id

        #expect(model.rows.map(\.isTicked) == [true, true, false, false])
        try #require(LaunchpadAskScreen.footer(flow).primary).action()

        #expect(flow.presentedReview != nil)
        #expect(try #require(try sample.workspace.store.snapshot()).document.revision.id == head)
    }

    /// An app this Mac chose that stops answering (its last check found no
    /// version) keeps the choice, without a checkbox: a check that failed
    /// once does not undo it, and pressing on writes nothing.
    @Test func aChosenAppThatStopsAnsweringKeepsItsChoice() async throws {
        let (fixture, flow, sample) = try await Self.juniper(at: .afterAsk)
        defer { fixture.remove() }
        await sample.workspace.device.adopt(
            sample.workspace.device.observations.filter { $0.surface == .codexCLI }.map { observation in
                var silent = observation
                silent.version = nil
                return silent
            })
        let model = AgentToolingHookUp.of(flow)
        let head = try #require(try sample.workspace.store.snapshot()).document.revision.id

        #expect(model.rows[0].status == .waitsForVersion)
        #expect(model.rows[0].isTicked && !model.rows[0].canTick && !model.rows[0].addsStep)
        #expect(model.appsToRecord == [.codex, .claude])
        try #require(LaunchpadAskScreen.footer(flow).primary).action()

        #expect(flow.presentedReview != nil)
        #expect(try #require(try sample.workspace.store.snapshot()).document.revision.id == head)
        #expect(flow.decisions.helperApps == [.codex, .claude])
    }

    /// An app that already runs this copy's helper, connected by hand, is
    /// already connected (no checkbox, still recorded; one Agent Tooling
    /// connected is a checkbox, `AgentToolingHookUp+RemovalTests`); one that
    /// runs another copy is left alone unless a receipt proves Agent Tooling
    /// set it up, and then it may be ticked to replace it, but starts
    /// unticked.
    @Test func registrationsAreConnectedLeftAloneOrReplaceableByProof() async throws {
        let (fixture, flow, sample) = try await Self.juniper(at: .afterPlace)
        defer { fixture.remove() }
        let elsewhere = "/Users/example/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
        try fixture.world.home.plant(
            ".claude.json", #"{"mcpServers":{"agent-tooling":{"type":"stdio","command":"\#(fixture.helperPath)","args":[]}}}"#)
        try fixture.world.home.plant(".gemini/settings.json", #"{"mcpServers":{"agent-tooling":{"command":"\#(elsewhere)"}}}"#)
        await sample.workspace.device.adopt(
            sample.workspace.device.observations.map { observation in
                guard observation.surface == .claudeCode || observation.surface == .geminiCLI else { return observation }
                var registered = observation
                registered.discoveredMCPServers.append(AgentToolingConnection.declaredName)
                registered.mcpMetadata[AgentToolingConnection.declaredName] = .init(
                    transport: "stdio", authentication: "Not inferred", source: "\(observation.surface.displayName) configuration")
                return registered
            })
        let model = AgentToolingHookUp.of(flow)

        #expect(model.rows[1].status == .alreadyConnected(provenOurs: false))
        #expect(model.rows[1].isTicked && !model.rows[1].canTick && !model.rows[1].removesStep)
        #expect(model.rows[2].status == .connectedElsewhere(path: elsewhere, provenOurs: false))
        #expect(!model.rows[2].canTick && !model.rows[2].isTicked)
        #expect(model.appsToRecord == [.codex, .claude])

        try sample.workspace.store.recordOperationReceipt(
            OperationReceipt(
                planID: UUID(), kind: .configureMCP, title: "Set up 1 connection in Gemini CLI", state: .healthy,
                targetSurfaces: [.geminiCLI], results: [], verificationSummary: "",
                itemOutcomes: [.init(id: UUID(), title: "Set up agent-tooling", status: .succeeded, reason: "Completed.")]))
        await model.load(decisions: flow.decisions)

        #expect(model.rows[2].status == .connectedElsewhere(path: elsewhere, provenOurs: true))
        #expect(model.rows[2].canTick && !model.rows[2].isTicked)
        model.toggle(.gemini)
        #expect(model.rows[2].addsStep)
    }

    /// A copy outside Applications offers its helper to nobody: the rows wait,
    /// the move is offered first, the primary records nothing and still opens
    /// the review, and Done is told why.
    @Test func aCopyOutsideApplicationsConnectsNothingAndSaysWhy() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let volume = fixture.world.home.root.appending(path: "Volumes/Agent Tooling", directoryHint: .isDirectory)
        let image = HelperBundle.onDiskImage(volume.appending(path: HelperBundle.name, directoryHint: .isDirectory), volume: volume)
        fixture.environment.installation = { image }
        let (flow, sample) = try await fixture.flow(at: .afterPlace)
        let model = AgentToolingHookUp.of(flow)
        let head = try #require(try sample.workspace.store.snapshot()).document.revision.id

        #expect(model.unavailable == .outsideApplications(offersMove: true))
        #expect(model.rows.allSatisfy { !$0.canTick && !$0.isTicked })
        #expect(model.rows.first?.command?.contains("\"/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp\"") == true)
        try #require(LaunchpadAskScreen.footer(flow).primary).action()

        #expect(flow.presentedReview != nil)
        #expect(try #require(try sample.workspace.store.snapshot()).document.revision.id == head)
        #expect(flow.outcomes.helperUnavailable == LaunchpadCopy.Helper.moveFirst)
        #expect(flow.decisions.helperApps.isEmpty)
    }

    @Test func aDevelopmentBuildHasNoHelperToOffer() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await fixture.flow(at: .afterPlace)
        let model = AgentToolingHookUp.of(flow)

        #expect(model.unavailable == .developmentBuild)
        #expect(model.rows.allSatisfy { $0.commandLines.isEmpty && !$0.canTick })
        // With no command to show, an app's row is the short one.
        #expect(model.rows.allSatisfy { $0.isQuiet })
        try #require(LaunchpadAskScreen.footer(flow).primary).action()
        #expect(flow.outcomes.helperUnavailable == LaunchpadCopy.Helper.noHelper)
    }

    /// Cedar's detour from You joined: the review covers this connection
    /// alone (You joined reviews what arrived) and returns to You joined.
    @Test func joinsDetourReviewsTheConnectionAloneAndReturnsToYouJoined() async throws {
        var fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let applications = fixture.world.home.root.appending(path: "Applications", directoryHint: .isDirectory)
        fixture.environment.installation = { HelperBundle.inApplications(applications) }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        flow.go(to: .ask)
        #expect(flow.isDetour)
        #expect(flow.info.footerName == LaunchpadCopy.Footer.stepArrivals)
        #expect(flow.info.capsules == .init(reached: 2, total: 3))
        let model = AgentToolingHookUp.of(flow)
        // Juniper set it up for itself; Cedar has not chosen, so the default
        // rule applies here too.
        #expect(model.appsToRecord == [.codex, .claude])

        try #require(LaunchpadAskScreen.footer(flow).primary).action()
        await waitUntil { flow.presentedReview != nil }

        #expect(flow.reviewReturn == .arrivals)
        let own = try #require(flow.decisions.helperArtifactID)
        #expect(model.reviewScope(for: flow.decisions) == [own])
        let snapshot = try #require(try sample.workspace.store.snapshot())
        let byDevice = Set(snapshot.document.assignments.filter { $0.artifactID == own }.compactMap(\.destination.deviceIDs))
        #expect(byDevice.contains([sample.workspace.store.deviceID]))
        #expect(byDevice.count == 2, "Juniper's contributions stay beside Cedar's")
        flow.advance()
        #expect(flow.step == .arrivals)
    }

    /// From a copy kept outside Applications, Move to Applications… opens
    /// Before you start, whose Keep it here comes back here; nothing is
    /// recorded as the cursor on the way.
    @Test func theMoveOfferedHereGoesToBeforeYouStartAndKeepItHereComesBack() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let volume = fixture.world.home.root.appending(path: "Volumes/Agent Tooling", directoryHint: .isDirectory)
        let image = HelperBundle.onDiskImage(volume.appending(path: HelperBundle.name, directoryHint: .isDirectory), volume: volume)
        fixture.environment.installation = { image }
        let (flow, sample) = try await fixture.flow(at: .afterPlace)

        flow.go(to: .move)
        #expect(flow.step == .move)
        #expect(fixture.savedRecord(for: sample.workspace)?.cursor == .ask)
        try #require(LaunchpadStageView.footer(for: flow).secondary).action()

        #expect(flow.step == .ask)
        #expect(flow.outcomes.helperUnavailable == LaunchpadCopy.Helper.moveFirst)
    }

    /// ↓ goes to the first row that can be ticked, Space ticks it, and the
    /// keyboard never lands on a row that cannot be.
    @Test func theKeyboardWalksTheRowsThatCanBeTicked() async throws {
        let (fixture, flow, _) = try await Self.juniper(at: .afterPlace)
        defer { fixture.remove() }
        let model = AgentToolingHookUp.of(flow)

        model.moveFocus(by: 1)
        #expect(model.focused == .codex)
        model.moveFocus(by: 1)
        model.moveFocus(by: 1)
        model.moveFocus(by: 1)
        #expect(model.focused == .gemini, "Kiro CLI, not found, is never focused")
        model.toggle(.gemini)
        #expect(model.rows[2].isTicked == false)
        model.moveFocus(by: -1)
        #expect(model.focused == .claude)
    }

    /// Passed over when no app is managed: Done says why.
    @Test func aWalkWithNoAppsSaysWhyItPassedThisStepOver() {
        let empty = LaunchpadTransitionContext(managed: [], observed: [], startedEmpty: true)
        #expect(LaunchpadStageView.skipReason(for: .ask, context: empty) == LaunchpadCopy.Helper.skippedNoApps)
    }

    /// After the install, nothing plans the helper again, the library's
    /// sizes leave it out, and Checkup says nothing about agent-tooling.
    ///
    /// The mockups' Done reads "13 tools in your library (9 entries)"; the
    /// sample world as the code reads it has one tool fewer inside plugins
    /// (WP0a's deviation 1), so it is 12 in 9 here. With the helper counted
    /// it would be 13 in 10.
    @Test func afterTheInstallTheHelperIsInPlaceAndOutOfTheCounts() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterInstall)
        let workspace = sample.workspace
        let own = try #require(sample.decisions.helperArtifactID)

        await workspace.deployment.prepare()
        let plan = try #require(workspace.deployment.plan)
        #expect(!plan.items.contains { $0.artifactID == own })
        #expect(plan.exclusions.filter { $0.artifactID == own }.map(\.reason) == [.alreadyPresent, .alreadyPresent])
        let library = try #require(workspace.library.state?.library)
        #expect(library.rows.count == 10)
        #expect(library.rows.filter(\.isOwnConnection).map(\.artifactID) == [own])
        #expect(library.entryCount == 9)
        #expect(library.toolCount == 12)
        let findings = try #require(workspace.setup.checkup).audit.findings
        #expect(!findings.contains { $0.subject == AgentToolingConnection.declaredName })
    }

    /// The caption says why the rows start as they do only while that is the
    /// reason: once this Mac has recorded a choice, the rows start from it,
    /// so an app that answered can start unticked, and the caption does not
    /// say otherwise (a return after the choice, and after the install).
    @Test func theCaptionSaysWhyRowsStartTickedOnlyBeforeAChoiceIsRecorded() async throws {
        let (first, firstFlow, _) = try await Self.juniper(at: .afterPlace)
        defer { first.remove() }
        #expect(
            AgentToolingHookUp.of(firstFlow).startingTicksSentence
                == "All three answered with a version, so all three start ticked.")

        for snapshot in [LaunchpadSampleSnapshot.afterAsk, .afterInstall] {
            let (fixture, flow, _) = try await Self.juniper(at: snapshot)
            defer { fixture.remove() }
            let model = AgentToolingHookUp.of(flow)
            let gemini = try #require(model.rows.first { $0.client == .gemini })

            #expect(gemini.status == .ready, "\(snapshot)")
            #expect(!gemini.isTicked, "\(snapshot): this Mac chose Codex and Claude Code")
            #expect(model.startingTicksSentence == nil, "\(snapshot)")
        }
    }

    /// An app that answered, but whose step the plan would leave out (it
    /// cannot be asked to run the command), is not counted: the primary
    /// says what the review will run (D6).
    @Test func aStepThePlanWouldLeaveOutIsNotCounted() async throws {
        let (fixture, flow, sample) = try await Self.juniper(at: .afterPlace)
        defer { fixture.remove() }
        await sample.workspace.device.adopt(
            sample.workspace.device.observations.map { observation in
                guard observation.surface == .geminiCLI else { return observation }
                var unanswered = observation
                unanswered.commandAvailable = false
                return unanswered
            })
        let model = AgentToolingHookUp.of(flow)
        await model.load(decisions: flow.decisions)
        let gemini = try #require(model.rows.first { $0.client == .gemini })

        #expect(gemini.status == .ready && gemini.isTicked)
        #expect(!gemini.addsStep)
        #expect(model.primaryTitle == "Review 4 changes…")
        try #require(LaunchpadAskScreen.footer(flow).primary).action()
        await waitUntil { flow.presentedReview != nil }
        let review = try #require(flow.presentedReview)
        await review.prepare()
        #expect(review.runnableCount == 4)
    }

    /// A registration Agent Tooling is proven to have made, that names no
    /// command this can read (an address), may be ticked; ticked, it is a
    /// step the plan runs (a replacement), and is counted as one.
    @Test func aProvenRegistrationWithNoCommandIsAStepThePlanRuns() async throws {
        let (fixture, flow, sample) = try await Self.juniper(at: .afterPlace)
        defer { fixture.remove() }
        try fixture.world.home.plant(".gemini/settings.json", #"{"mcpServers":{"agent-tooling":{"httpUrl":"https://example.com/mcp"}}}"#)
        let settings = fixture.world.home.appending(".gemini/settings.json").path(percentEncoded: false)
        await sample.workspace.device.adopt(
            sample.workspace.device.observations.map { observation in
                guard observation.surface == .geminiCLI else { return observation }
                var registered = observation
                registered.discoveredMCPServers.append(AgentToolingConnection.declaredName)
                registered.mcpMetadata[AgentToolingConnection.declaredName] = .init(
                    transport: "streamable_http", authentication: "Not inferred", source: "Gemini CLI configuration")
                if !registered.configurationPaths.contains(settings) { registered.configurationPaths.append(settings) }
                return registered
            })
        #expect(sample.workspace.device.errorMessage == nil, "the check was recorded")
        try sample.workspace.store.recordOperationReceipt(
            OperationReceipt(
                planID: UUID(), kind: .configureMCP, title: "Set up 1 connection in Gemini CLI", state: .healthy,
                targetSurfaces: [.geminiCLI], results: [], verificationSummary: "",
                itemOutcomes: [.init(id: UUID(), title: "Set up agent-tooling", status: .succeeded, reason: "Completed.")]))
        let model = AgentToolingHookUp.of(flow)
        await model.load(decisions: flow.decisions)

        #expect(model.rows[2].status == .connectedElsewhere(path: "", provenOurs: true))
        model.toggle(.gemini)
        #expect(model.rows[2].addsStep)
        #expect(model.appsThePlanRuns?.contains(.gemini) == true)
        #expect(model.primaryTitle == "Review 5 changes…")
    }

    /// On Join's detour, Move to Applications… and then Keep it here comes
    /// back to the detour: the footer at Arrivals 2/3, and the review
    /// returning to You joined.
    @Test func keepItHereFromJoinsDetourComesBackToTheDetour() async throws {
        var fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let image = Self.onDiskImage(fixture)
        fixture.environment.installation = { image }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        flow.go(to: .ask)
        #expect(AgentToolingHookUp.of(flow).unavailable == .outsideApplications(offersMove: true))

        LaunchpadMoveModel.open(from: flow)
        #expect(flow.step == .move)
        try #require(LaunchpadStageView.footer(for: flow).secondary).action()

        #expect(flow.step == .ask)
        #expect(flow.isDetour)
        #expect(flow.info.footerName == LaunchpadCopy.Footer.stepArrivals)
        #expect(flow.info.capsules == .init(reached: 2, total: 3))
        try #require(LaunchpadAskScreen.footer(flow).primary).action()
        #expect(flow.reviewReturn == .arrivals)
        flow.advance()
        #expect(flow.step == .arrivals)
    }

    /// A revisit of Let your apps ask (Home's Connect Agent Tooling row) that
    /// opens Before you start comes back to Let your apps ask; only a revisit
    /// of Before you start itself goes on to Home.
    @Test func keepItHereOnARevisitComesBackToWhereItWasOpened() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let image = Self.onDiskImage(fixture)
        fixture.environment.installation = { image }
        let sample = try await fixture.sample(.afterAsk)

        let ask = fixture.flow(.revisit(.ask), workspace: sample.workspace)
        LaunchpadMoveModel.open(from: ask)
        #expect(ask.step == .move)
        try #require(LaunchpadStageView.footer(for: ask).secondary).action()
        #expect(ask.step == .ask)
        #expect(ask.pendingHandOff == nil)

        let move = fixture.flow(.revisit(.move), workspace: sample.workspace)
        try #require(LaunchpadStageView.footer(for: move).secondary).action()
        #expect(move.pendingHandOff == .overview)
    }

    // MARK: - Juniper with its copy in Applications

    /// This copy as it runs from a mounted disk image inside the fixture.
    private static func onDiskImage(_ fixture: LaunchpadFixture) -> AgentToolingInstallation {
        let volume = fixture.world.home.root.appending(path: "Volumes/Agent Tooling", directoryHint: .isDirectory)
        return HelperBundle.onDiskImage(volume.appending(path: HelperBundle.name, directoryHint: .isDirectory), volume: volume)
    }

    private static func juniper(
        at snapshot: LaunchpadSampleSnapshot
    ) async throws -> (LaunchpadFixture, LaunchpadFlow, LaunchpadSample) {
        var fixture = try await LaunchpadFixture()
        let applications = fixture.world.home.root.appending(path: "Applications", directoryHint: .isDirectory)
        fixture.environment.installation = { HelperBundle.inApplications(applications) }
        do {
            let (flow, sample) = try await fixture.flow(at: snapshot)
            return (fixture, flow, sample)
        } catch {
            fixture.remove()
            throw error
        }
    }
}
