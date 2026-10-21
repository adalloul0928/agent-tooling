import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The one reviewed plan behind S12, You joined's review and the shared review
/// sheet, on the sample world after Let your apps ask: five steps listed and
/// four run, Has it hidden, each step's command or folder, the install running
/// exactly what is listed, a stale library refused, and a quit mid-install
/// stopping after the step it is on. Every command an install runs is answered
/// by a script, and each app's tool is found only in the fixture's home.
@Suite("Scoped plan review", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ScopedPlanReviewTests {
    // MARK: - What it lists

    @Test func theReviewListsFiveRunsFourAndHasItNeverShows() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.review(fixture)

        #expect(review.phase == .ready)
        #expect(review.listedCount == 5)
        #expect(review.runnableCount == 4)
        #expect(review.title == "Install 4 changes")
        #expect(review.subtitle == "Into 2 apps on this Mac. Each step shows what it runs; Cancel writes nothing.")
        #expect(review.chip == "This Mac · Juniper")
        #expect(review.appsLabel == "In your apps · 4 changes")
        #expect(review.groups.map(\.client) == [.codex, .claude])
        #expect(review.groups.map(\.summary) == ["2 changes · 1 left alone", "2 changes"])
        #expect(
            review.groups.map { $0.steps.map(\.title) } == [
                ["Copy Release Notes into Codex", "Add Agent Tooling to Codex", "Frontend Design in Codex"],
                ["Ask Claude Code to install Supabase", "Add Agent Tooling to Claude Code"],
            ])
        #expect(review.groups.map { $0.steps.map(\.number) } == [[1, 2, nil], [3, 4]])
        #expect(
            review.beforeYouApprove
                == "3 steps run a command · 1 step is left alone. Release Notes was checked for risky content; nothing was flagged.")
        #expect(review.libraryLine == "· 7 decisions · these touch no app")
        #expect(review.libraryDisclosureValue(expanded: false) == "collapsed, 7 decisions")
        #expect(review.libraryDisclosureValue(expanded: true) == "expanded, 7 decisions")
        #expect(review.canInstall)

        // Has it: Release Notes and Frontend Design in Claude Code are already
        // there, so they are not steps, and the plan says why.
        let workspace = try #require(flow.workspace)
        let plan = try #require(workspace.deployment.plan)
        let present = Set(plan.exclusions.filter { $0.reason == .alreadyPresent }.compactMap(\.artifactID))
        let names = Dictionary(
            uniqueKeysWithValues: (workspace.library.state?.snapshot.document.artifacts ?? []).map {
                ($0.identity.id, $0.identity.displayName)
            })
        #expect(Set(present.compactMap { names[$0] }) == ["Release Notes", "Frontend Design"])
        #expect(review.exclusions.allSatisfy { $0.reason != .alreadyPresent })
    }

    @Test func eachStepShowsWhatItRunsOrWhereItCopiesTo() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (_, review) = try await Self.review(fixture)
        let steps = review.groups.flatMap(\.steps)
        let helper = fixture.helperPath

        #expect(
            steps.map(\.well) == [
                .path("~/.agents/skills/release-notes"),
                .commands(["codex mcp add agent-tooling -- \"\(helper)\""]),
                nil,
                .commands(["claude plugin install supabase@claude-plugins-official --scope user"]),
                .commands(["claude mcp add --transport stdio --scope user agent-tooling -- \"\(helper)\""]),
            ])
        #expect(steps.map(\.action) == [.copy, .connection, .update, .plugin, .connection])
        #expect(steps[2].state == .leftAlone)
        #expect(steps[2].note == "Left alone: Codex already has a copy Agent Tooling did not put there. It won’t be overwritten.")
        #expect(steps.filter { $0.state != .leftAlone }.allSatisfy { $0.note == nil && $0.risk == nil })
        #expect(review.accessibilityLabel(for: steps[0]) == "Step 1 of 4, Copy Release Notes into Codex, ~/.agents/skills/release-notes")
        // Its note already says "Left alone", so VoiceOver says it once.
        #expect(
            review.accessibilityLabel(for: steps[2])
                == "Frontend Design in Codex, Left alone: Codex already has a copy Agent Tooling did not put there. It won’t be overwritten."
        )
    }

    /// A step no command can be built for is listed in place as "Will not
    /// run", with why, and counted nowhere.
    @Test func aStepWithNoToolToRunItWillNotRun() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let world = fixture.world
        // Claude Code's tool is nowhere this Mac looks.
        sample.workspace.deployment.commandServices = DeploymentCommandServices(
            runner: { RefusingCommandRunner() }, locate: { client, _ in client == .claude ? nil : world.locate(client) })
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)

        await review.prepare()

        #expect(review.listedCount == 5)
        #expect(review.runnableCount == 2)
        #expect(review.title == "Install 2 changes")
        #expect(review.groups.map(\.summary) == ["2 changes · 1 left alone", "0 changes · 2 cannot run yet"])
        let claude = try #require(review.groups.last?.steps)
        #expect(claude.map(\.number) == [nil, nil])
        let reason =
            "Claude Code's command-line tool was not found in any place this app looks, so it cannot be asked to do this."
        #expect(claude.map(\.state) == [.willNotRun(reason), .willNotRun(reason)])
        #expect(claude.map(\.note) == ["Will not run · \(reason)", "Will not run · \(reason)"])
        #expect(review.beforeYouApprove?.hasPrefix("1 step runs a command · 2 steps cannot run yet · 1 step is left alone.") == true)
    }

    /// Only a fresh ⌘↩ installs (D9): the panel binds ⌘↩ while the plan
    /// waits on it, a plain ↩ only asks for ⌘↩, a held ⌘↩ does nothing, and
    /// so does one before the plan is read or once it has a result.
    @Test func onlyAFreshCommandReturnInstalls() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)
        func press(withCommand: Bool, isRepeat: Bool = false) -> LaunchpadKeyRouter.CommandReturnAction {
            LaunchpadKeyRouter.commandReturn(withCommand: withCommand, isRepeat: isRepeat, isReady: review.canInstall)
        }

        // Before the read: the panel holds ⌘↩, and a press does nothing.
        #expect(LaunchpadReviewPanel.awaitsCommandReturn(review))
        #expect(press(withCommand: true) == .ignore)
        await review.prepare()
        #expect(press(withCommand: false) == .hint)
        #expect(press(withCommand: true, isRepeat: true) == .ignore)
        #expect(press(withCommand: true) == .perform)

        fixture.scriptReviewCommands(in: sample.workspace, runner: fixture.reviewRunner())
        await review.install()
        // With a result, ↩ is Continue's again and ⌘↩ is nobody's.
        #expect(!LaunchpadReviewPanel.awaitsCommandReturn(review))
        #expect(press(withCommand: true) == .ignore)
    }

    // MARK: - Installing

    @Test func installingRunsExactlyTheFourStepsItLists() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.review(fixture)
        let workspace = try #require(flow.workspace)
        let runner = fixture.reviewRunner()
        fixture.scriptReviewCommands(in: workspace, runner: runner)
        fixture.observer.answer(with: try await fixture.reviewObservationsAfterInstall())
        let frontendDesign = fixture.home.appending(path: ".agents/skills/frontend-design/SKILL.md")
        let before = try Data(contentsOf: frontendDesign)

        await review.install()

        guard case .finished(let outcome) = review.phase else {
            Issue.record("The install did not finish: \(review.phase)")
            return
        }
        // The three commands, in the order the steps are drawn; the copy is
        // the executor's own work, not a command.
        #expect(
            await runner.launches.map(\.display) == [
                "codex mcp add agent-tooling -- \(fixture.helperPath)",
                "claude plugin install supabase@claude-plugins-official --scope user",
                "claude mcp add --transport stdio --scope user agent-tooling -- \(fixture.helperPath)",
            ])
        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/release-notes/SKILL.md").path))
        // The step left alone left Codex's own copy exactly as it was.
        #expect(try Data(contentsOf: frontendDesign) == before)
        #expect(review.groups.flatMap(\.steps).map(\.state) == [.done, .done, .leftAlone, .done, .done])
        #expect(outcome.installed == [.codex, .claude])
        #expect(outcome.failed.isEmpty)
        #expect(outcome.succeededSteps == 4)
        #expect(outcome.leftAlone.count == 1)
        #expect(outcome.summary == "Installed to Claude Code and Codex.")
        #expect(outcome.receiptLine.hasPrefix("Installed 4 changes · "))
        // D29: only the apps whose own tool ran are checked again, once.
        #expect(fixture.observer.scopedChecks == [[.codex, .claude]])
        #expect(fixture.observer.fullChecks == 0)
    }

    /// After the install, Agent Tooling's own connection, Supabase and the
    /// step left alone are pending nowhere: not in the plan, not on Apps or
    /// Home, not in what other Macs read.
    @Test func afterTheInstallNothingIsPendingForTheHelperSupabaseOrTheStepLeftAlone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.review(fixture)
        let workspace = try #require(flow.workspace)
        fixture.scriptReviewCommands(in: workspace, runner: fixture.reviewRunner())
        fixture.observer.answer(with: try await fixture.reviewObservationsAfterInstall())

        await review.install()

        let deployment = workspace.deployment
        let names = Set((deployment.plan?.items ?? []).map(\.displayName))
        #expect(!names.contains("Supabase"))
        #expect(!names.contains("Release Notes"))
        // Frontend Design in Codex stays in the plan, held back, and is never
        // counted as waiting.
        #expect(names.contains("Frontend Design"))
        #expect(!deployment.pendingItems.map(\.displayName).contains("Frontend Design"))
        let status = try #require(
            PublishedDeviceStatus.current(device: workspace.device, library: workspace.library, deployment: deployment))
        #expect(!status.pending.contains("Frontend Design"))
        #expect(!status.pending.contains("Supabase"))
        // Codex and Claude Code now report Agent Tooling's own connection,
        // starting this Mac's helper, so nothing plans it again.
        #expect(!names.contains(AgentToolingConnection.displayName))
        // Nothing is waiting anywhere: Apps and Home count these.
        #expect(deployment.pendingItems.isEmpty)
        #expect(status.pending.isEmpty)
    }

    @Test func aReviewOverALibraryThatMovedInstallsNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.review(fixture)
        let workspace = try #require(flow.workspace)
        let runner = fixture.reviewRunner()
        fixture.scriptReviewCommands(in: workspace, runner: runner)
        // Another write lands while the review is open.
        _ = try await workspace.service.registerDevice(
            .init(expectedRevisionID: try fixture.head(of: workspace), deviceID: workspace.store.deviceID, name: "Juniper"))

        await review.install()

        #expect(review.phase == .stale)
        #expect(await runner.launches.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/release-notes").path))
        #expect(review.groups.flatMap(\.steps).map(\.state) == [.waiting, .waiting, .leftAlone, .waiting, .waiting])
        #expect(!review.canInstall)

        await review.reviewAgain()

        #expect(review.phase == .ready)
        #expect(review.canInstall)
    }

    /// The shared sheet is handed the plan the Apps screen holds. A write
    /// that lands before the sheet reads it, after which the Apps screen
    /// reads its plan again, does not lend the handed plan the newer
    /// revision: installing it is refused until it is reviewed again.
    @Test func aHandedPlanTheLibraryMovedPastInstallsNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterAsk)
        let workspace = sample.workspace
        let deployment = workspace.deployment
        await deployment.prepare()
        let review = ScopedPlanReview(workspace: workspace, reviewing: try #require(deployment.plan))
        let runner = fixture.reviewRunner()
        fixture.scriptReviewCommands(in: workspace, runner: runner)

        _ = try await workspace.service.registerDevice(
            .init(expectedRevisionID: try fixture.head(of: workspace), deviceID: workspace.store.deviceID, name: "Juniper"))
        await workspace.library.refresh()
        await deployment.prepare()
        await review.prepare()
        #expect(review.phase == .ready)
        await review.install()

        #expect(review.phase == .stale)
        #expect(await runner.launches.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/release-notes").path))

        await review.reviewAgain()

        #expect(review.phase == .ready)
        #expect(review.canInstall)
    }

    /// ⌘Q while installing (§2.6): the step under way finishes, nothing after
    /// it starts, and the receipts of what ran are written.
    @Test func quittingWhileInstallingStopsAfterTheStepItIsOn() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.review(fixture)
        let workspace = try #require(flow.workspace)
        let gate = GatedCommandRunner()
        fixture.scriptReviewCommands(in: workspace, runner: gate)
        let receiptsBefore = try workspace.store.operationReceipts().count

        let install = Task { await review.install() }
        await gate.waitUntilCalled()
        #expect(flow.interruption == .finishing(LaunchpadCopy.Footer.stoppingAfterStep))
        let quit = Task { await flow.finishPendingWork() }
        await Task.yield()
        gate.release()
        await quit.value
        await install.value

        #expect(gate.launches.map(\.display) == ["codex mcp add agent-tooling -- \(fixture.helperPath)"])
        #expect(gate.cancelledCalls == 0)
        #expect(review.groups.flatMap(\.steps).map(\.state) == [.done, .done, .leftAlone, .waiting, .waiting])
        // The copy into Codex and Codex's connection, each with its receipt.
        #expect(try workspace.store.operationReceipts().count == receiptsBefore + 2)
        guard case .finished(let outcome) = review.phase else {
            Issue.record("The install did not end: \(review.phase)")
            return
        }
        #expect(outcome.installed == [.codex])
        #expect(outcome.unfinished == [.claude])
        #expect(outcome.failed.isEmpty)
        // Claude Code was never asked, so it is not said to have refused.
        #expect(outcome.summary == "Stopped after 2 of 4 changes.")
        // A quit does not wait on checking the apps again.
        #expect(fixture.observer.scopedChecks.isEmpty)
        #expect(flow.interruption == .idle)
    }

    /// The shared sheet's Stop stops after the step under way, like a quit,
    /// but the apps whose own tool ran are still checked again (D29) and the
    /// plan read again, so nothing that ran is offered again.
    @Test func aStopChecksTheAppsThatRanAgainSoNothingThatRanWaits() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.review(fixture)
        let workspace = try #require(flow.workspace)
        let gate = GatedCommandRunner()
        fixture.scriptReviewCommands(in: workspace, runner: gate)
        // Only Codex's own tool runs before the Stop.
        fixture.observer.answer(with: try await fixture.reviewObservationsAfterInstall(installed: [.codex]))
        let releaseNotes = try #require(review.groups.first?.steps.first?.id)

        let install = Task { await review.install() }
        await gate.waitUntilCalled()
        review.stop()
        gate.release()
        await install.value

        #expect(gate.launches.map(\.display) == ["codex mcp add agent-tooling -- \(fixture.helperPath)"])
        guard case .finished(let outcome) = review.phase else {
            Issue.record("The install did not end: \(review.phase)")
            return
        }
        #expect(outcome.summary == "Stopped after 2 of 4 changes.")
        // Only Codex's own tool ran, so only Codex is checked again.
        #expect(fixture.observer.scopedChecks == [[.codex]])
        let deployment = workspace.deployment
        let pending = Set(deployment.pendingItems.map(WorkspaceDeploymentSession.installKey))
        let ran = review.groups.flatMap(\.steps).filter { $0.state == .done }.map(\.id)
        #expect(ran.count == 2)
        #expect(pending.isDisjoint(with: ran))
        #expect(ran.contains(releaseNotes))
        // What did not run is still waiting.
        #expect(deployment.pendingItems.map(\.displayName).sorted() == ["Agent Tooling", "Supabase"])
    }

    /// The install's progress, as the primary shows it and VoiceOver hears
    /// it: "Installing 2 of 4" while the second step runs.
    @Test func theProgressCountsTheStepUnderWay() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.review(fixture)
        let gate = GatedCommandRunner()
        fixture.scriptReviewCommands(in: try #require(flow.workspace), runner: gate)
        #expect(review.progressLine == nil)

        let install = Task { await review.install() }
        await gate.waitUntilCalled()

        #expect(review.phase == .running(done: 1, of: 4))
        #expect(review.progressLine == "Installing 2 of 4…")
        #expect(review.progressAnnouncement == "Installing 2 of 4.")
        #expect(review.groups.flatMap(\.steps).map(\.state) == [.done, .running, .leftAlone, .waiting, .waiting])
        gate.release()
        await install.value
        #expect(review.progressLine == nil)
    }

    /// The review is running the moment an install begins, before anything
    /// suspends: a Cancel handled next finds it busy, and a second start
    /// starts nothing.
    @Test func anInstallIsUnderWayAsSoonAsItBegins() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, review) = try await Self.review(fixture)
        fixture.scriptReviewCommands(in: try #require(flow.workspace), runner: fixture.reviewRunner())

        let installing = review.begin()

        #expect(installing != nil)
        #expect(review.isBusy)
        #expect(flow.interruption == .finishing(LaunchpadCopy.Footer.stoppingAfterStep))
        #expect(review.begin() == nil)
        await installing?.value
        guard case .finished = review.phase else {
            Issue.record("The install did not finish: \(review.phase)")
            return
        }
    }

    /// The shared sheet's review of the whole plan keeps every reason
    /// something is not being installed, even for an item with no step at
    /// all, and still does after Review again.
    @Test func theWholePlanKeepsEveryReasonSomethingIsNotInstalled() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterAsk)
        let workspace = sample.workspace
        // Linear comes from Codex's catalog; asked for in Claude Code, it
        // cannot go there.
        let linear = try #require(
            workspace.library.state?.snapshot.document.artifacts.first { $0.identity.displayName == "Linear" })
        _ = try await workspace.service.applyAssignmentBatch(
            .init(
                expectedRevisionID: try fixture.head(of: workspace),
                additions: [
                    AssignmentContribution(
                        artifactID: linear.identity.id, destination: .init(surface: .claudeCode, scope: .user), reason: .manual)
                ]))
        await workspace.library.refresh()
        fixture.scriptReviewCommands(in: workspace, runner: RefusingCommandRunner())
        await workspace.deployment.prepare()
        let plan = try #require(workspace.deployment.plan)
        #expect(plan.exclusions.contains { $0.artifactID == linear.identity.id })
        #expect(!plan.items.contains { $0.artifactID == linear.identity.id })
        let review = ScopedPlanReview(workspace: workspace, reviewing: plan)

        await review.prepare()
        #expect(review.exclusions.contains { $0.artifactID == linear.identity.id })
        await review.reviewAgain()

        #expect(review.phase == .ready)
        #expect(review.exclusions.contains { $0.artifactID == linear.identity.id })
        #expect(review.exclusions == (workspace.deployment.plan?.exclusions ?? []).filter { $0.reason != .alreadyPresent })
    }

    /// The shared sheet's review: the plan it is handed is the plan it lists
    /// and the plan it installs, nothing the session holds beside it.
    @Test func aHandedPlanIsListedAndInstalledExactly() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (_, sample) = try await fixture.flow(at: .afterAsk)
        let workspace = sample.workspace
        let runner = fixture.reviewRunner()
        fixture.scriptReviewCommands(in: workspace, runner: runner)
        await workspace.deployment.prepare()
        let releaseNotes = try #require(sample.decisions.adopted.first?.artifactID)
        let handed = try #require(workspace.deployment.plan(for: [releaseNotes]))
        let review = ScopedPlanReview(workspace: workspace, reviewing: handed)

        await review.prepare()

        #expect(review.listedCount == 1)
        #expect(review.title == "Install 1 change")
        await review.install()
        #expect(await runner.launches.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/release-notes/SKILL.md").path))
        guard case .finished(let outcome) = review.phase else {
            Issue.record("The install did not finish: \(review.phase)")
            return
        }
        #expect(outcome.installed == [.codex])
    }

    /// D30: a connection that replaces a registration Agent Tooling made (a
    /// receipt shows it set agent-tooling up in Claude Code) shows both
    /// commands in its well, the removal first, names the copy the old one
    /// started, says what a failed add leaves, and runs the removal before the
    /// add as one step.
    @Test func aReplacementShowsBothCommandsAndNamesTheOldCopy() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (_, sample) = try await fixture.flow(at: .afterAsk)
        let workspace = sample.workspace
        try await fixture.registerAnotherCopyInClaudeCode(in: workspace)
        try fixture.recordThatAgentToolingSetUpItsConnection(in: .claudeCode, workspace: workspace)
        let helper = fixture.helperPath
        let runner = fixture.replacementRunner()
        fixture.scriptReviewCommands(in: workspace, runner: runner)
        let review = ScopedPlanReview(workspace: workspace, scope: .wholePlan, deviceName: "Juniper")

        await review.prepare()

        let step = try #require(review.groups.last?.steps.last)
        #expect(step.title == "Add Agent Tooling to Claude Code")
        #expect(
            step.well
                == .commands([
                    "claude mcp remove --scope user agent-tooling",
                    "claude mcp add --transport stdio --scope user agent-tooling -- \"\(helper)\"",
                ]))
        #expect(
            step.note
                == "Connected to another copy at ~/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp. "
                + "If adding fails, agent-tooling is left removed from Claude Code; Apps will offer to add it again.")
        #expect(review.runnableCount == 4)

        await review.install()

        #expect(
            await runner.launches.map(\.display) == [
                "codex mcp add agent-tooling -- \(helper)",
                "claude plugin install supabase@claude-plugins-official --scope user",
                "claude mcp remove --scope user agent-tooling",
                "claude mcp add --transport stdio --scope user agent-tooling -- \(helper)",
            ])
        #expect(review.groups.flatMap(\.steps).map(\.state) == [.done, .done, .leftAlone, .done, .done])
    }

    /// D30 applies to proven registrations only (D10): with no receipt
    /// showing Agent Tooling set agent-tooling up in Claude Code, the
    /// registration there is the person's own. The step is drawn in place,
    /// left alone with S11's sentence, counted nowhere, and nothing removes
    /// or repoints the registration.
    @Test func aRegistrationAgentToolingDidNotMakeIsLeftAlone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (_, sample) = try await fixture.flow(at: .afterAsk)
        let workspace = sample.workspace
        try await fixture.registerAnotherCopyInClaudeCode(in: workspace)
        let runner = fixture.replacementRunner()
        fixture.scriptReviewCommands(in: workspace, runner: runner)
        let review = ScopedPlanReview(workspace: workspace, scope: .wholePlan, deviceName: "Juniper")

        await review.prepare()

        let step = try #require(review.groups.last?.steps.last)
        #expect(step.state == .leftAlone)
        #expect(step.title == "Agent Tooling in Claude Code")
        #expect(step.number == nil)
        #expect(step.well == nil)
        #expect(
            step.note
                == "Connected to another copy at ~/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp. "
                + "Agent Tooling did not add this one, so it is left alone.")
        #expect(
            review.accessibilityLabel(for: step)
                == "Agent Tooling in Claude Code, Left alone, Connected to another copy at "
                + "~/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp. "
                + "Agent Tooling did not add this one, so it is left alone.")
        #expect(review.runnableCount == 3)
        #expect(review.title == "Install 3 changes")
        #expect(review.groups.map(\.summary) == ["2 changes · 1 left alone", "1 change · 1 left alone"])
        // Never waiting anywhere (D6).
        let deployment = workspace.deployment
        #expect(!deployment.pendingItems.contains { WorkspaceDeploymentSession.installKey($0) == step.id })

        await review.install()

        #expect(
            await runner.launches.map(\.display) == [
                "codex mcp add agent-tooling -- \(fixture.helperPath)",
                "claude plugin install supabase@claude-plugins-official --scope user",
            ])
        #expect(review.groups.flatMap(\.steps).map(\.state) == [.done, .done, .leftAlone, .done, .leftAlone])
        guard case .finished(let outcome) = review.phase else {
            Issue.record("The install did not finish: \(review.phase)")
            return
        }
        #expect(outcome.leftAlone.count == 2)
        #expect(outcome.summary == "Installed to Claude Code and Codex.")
        // The person's registration is exactly as it was.
        #expect(try String(contentsOf: fixture.home.appending(path: ".claude.json"), encoding: .utf8) == fixture.anotherCopyInClaudeCode)
    }

    /// The what-if plan setup's placement grid draws from leaves the same
    /// registration alone, so the grid cannot promise what the review will
    /// not run; with the proof it is a step like any other.
    @Test func theWhatIfPlanLeavesTheSameRegistrationAlone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterAsk)
        let workspace = sample.workspace
        try await fixture.registerAnotherCopyInClaudeCode(in: workspace)
        let deployment = workspace.deployment

        let unproven = try #require(await deployment.previewPlan(assuming: []))
        let replacement = try #require(unproven.plan.items.first { WorkspaceDeploymentSession.replacesRegistration($0) })
        #expect(replacement.surface == .claudeCode)
        #expect(unproven.unproven.contains(WorkspaceDeploymentSession.installKey(replacement)))

        try fixture.recordThatAgentToolingSetUpItsConnection(in: .claudeCode, workspace: workspace)
        let proven = try #require(await deployment.previewPlan(assuming: []))
        #expect(!proven.unproven.contains(WorkspaceDeploymentSession.installKey(replacement)))
    }

    /// Without the proof, no command is built for the step at all: a path
    /// that runs every step it is given (Kiro CLI's add would overwrite with
    /// `--force`) still cannot touch the registration.
    @Test func noCommandIsBuiltForARegistrationAgentToolingDidNotMake() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterAsk)
        let workspace = sample.workspace
        try await fixture.registerAnotherCopyInClaudeCode(in: workspace)
        let runner = fixture.replacementRunner()
        fixture.scriptReviewCommands(in: workspace, runner: runner)
        let deployment = workspace.deployment
        await deployment.prepare()
        let plan = try #require(deployment.plan)
        let replacement = try #require(plan.items.first { WorkspaceDeploymentSession.replacesRegistration($0) })
        #expect(
            deployment.heldBack(in: plan).map(WorkspaceDeploymentSession.installKey).contains(
                WorkspaceDeploymentSession.installKey(replacement)))

        let outcome = await deployment.applyReviewed(
            WorkspaceDeploymentPlan(
                items: [replacement], exclusions: [], requirements: plan.requirements, resolvedTargets: plan.resolvedTargets),
            basedOn: try #require(deployment.planRevision))

        #expect(await runner.launches.isEmpty)
        guard case .applied(let result) = outcome else {
            Issue.record("The apply did not end as applied: \(outcome)")
            return
        }
        #expect(result.succeededSteps == 0)
        #expect(result.installed.isEmpty)
    }

    /// The stage's review panel at S12, read.
    private static func review(_ fixture: LaunchpadFixture) async throws -> (LaunchpadFlow, ScopedPlanReview) {
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)
        flow.presentReview(review, returnTo: nil)
        await review.prepare()
        return (flow, review)
    }
}

extension LaunchpadFixture {
    /// Every command an install in `workspace` runs goes to `runner`, with
    /// each app's tool found only in this fixture's home, so no install a test
    /// makes reaches this Mac's own apps.
    func scriptReviewCommands(in workspace: WorkspaceLaunch.Workspace, runner: some CommandRunning) {
        let world = world
        workspace.deployment.commandServices = DeploymentCommandServices(
            runner: { runner }, locate: { client, _ in world.locate(client) })
    }

    /// Claude Code's own configuration, registering agent-tooling for the
    /// person with a copy of the helper in Downloads.
    var anotherCopyInClaudeCode: String {
        let old = home.appending(path: "Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp")
        return #"{"mcpServers":{"agent-tooling":{"type":"stdio","command":"\#(old.path(percentEncoded: false))","args":[]}}}"#
            + "\n"
    }

    /// Claude Code holds agent-tooling, started from another copy of the
    /// helper (`anotherCopyInClaudeCode`), and its last check saw it there,
    /// so the step adding this Mac's helper replaces a registration.
    func registerAnotherCopyInClaudeCode(in workspace: WorkspaceLaunch.Workspace) async throws {
        try write(home.appending(path: ".claude.json"), anotherCopyInClaudeCode)
        let runner = ScriptedCommandRunner(
            byTool: world.replies,
            missingTools: Set(
                ClientKind.allCases.filter { !world.found.contains($0) }.map(ClientExecutableLocator.executableName(for:))))
        await workspace.device.adopt(await world.registry.scanAll(homeURL: world.home.url, runner: runner, clients: [.claude]))
    }

    /// A receipt of Agent Tooling setting its own connection up in `surface`
    /// earlier: the proof that lets a registration there be replaced (D30).
    func recordThatAgentToolingSetUpItsConnection(in surface: TargetSurface, workspace: WorkspaceLaunch.Workspace) throws {
        let run = WorkspaceDeploymentOperations.run(
            staged: [],
            managedConnections: [
                WorkspaceManagedMCPCommandPlan(
                    artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID(), surface: surface, scope: .user,
                    nativeServerIdentifier: AgentToolingConnection.declaredName,
                    executableURL: URL(fileURLWithPath: "/usr/local/bin/claude"), executable: "claude", arguments: [],
                    workingDirectoryPath: nil)
            ])
        let operation = try #require(run.operations.first)
        try workspace.store.recordOperationReceipt(
            OperationReceipt(
                planID: operation.id, kind: operation.kind, title: operation.title, state: .healthy,
                targetSurfaces: operation.targetSurfaces, results: [], verificationSummary: "",
                itemOutcomes: operation.steps.map { .init(id: $0.id, title: $0.title, status: .succeeded, reason: "Completed.") }))
    }

    /// The commands a review that replaces Claude Code's registration may run,
    /// each answered as done; any other command fails.
    func replacementRunner() -> ScriptedCommandRunner {
        let helper = helperPath
        return ScriptedCommandRunner(byTool: [
            "codex": [["mcp", "add", "agent-tooling", "--", helper]: .standardOutput("")],
            "claude": [
                ["plugin", "install", "supabase@claude-plugins-official", "--scope", "user"]: .standardOutput(""),
                ["mcp", "remove", "--scope", "user", "agent-tooling"]: .standardOutput(""),
                ["mcp", "add", "--transport", "stdio", "--scope", "user", "agent-tooling", "--", helper]: .standardOutput(""),
            ],
        ])
    }

    /// The three commands S12 runs, each answered as done; any other command
    /// fails, so a test sees exactly what ran.
    func reviewRunner() -> ScriptedCommandRunner {
        let helper = helperPath
        return ScriptedCommandRunner(byTool: [
            "codex": [["mcp", "add", "agent-tooling", "--", helper]: .standardOutput("")],
            "claude": [
                ["plugin", "install", "supabase@claude-plugins-official", "--scope", "user"]: .standardOutput(""),
                ["mcp", "add", "--transport", "stdio", "--scope", "user", "agent-tooling", "--", helper]: .standardOutput(""),
            ],
        ])
    }

    /// What the re-check after S12's install reads, as the bundled adapters
    /// read the files and listings each app's own install leaves: Claude Code
    /// lists Supabase among its plugins, and Codex and Claude Code each start
    /// Agent Tooling's own connection with this Mac's helper. `installed`
    /// names the apps whose install ran; every other app keeps its last
    /// check, and its files are left as they were.
    ///
    /// The files are written now, so call this just before the install.
    func reviewObservationsAfterInstall(installed: Set<ClientKind> = [.codex, .claude]) async throws -> [TargetObservation] {
        let home = world.home
        let homePath = ProjectPath.canonical(home.url)
        let supabase = "supabase@claude-plugins-official"
        let supabaseFolder = ".claude/plugins/cache/claude-plugins-official/supabase/1.0.0"
        let name = AgentToolingConnection.declaredName
        let helper = try Self.reviewJSON(helperPath)
        var replies = world.replies
        if installed.contains(.claude) {
            try home.plant("\(supabaseFolder)/.claude-plugin/plugin.json", #"{"name":"supabase","version":"1.0.0"}"# + "\n")
            try reviewMerge(into: ".claude/settings.json") { settings in
                var enabled = settings["enabledPlugins"] as? [String: Any] ?? [:]
                enabled[supabase] = true
                settings["enabledPlugins"] = enabled
            }
            try reviewMerge(into: ".claude.json") { config in
                var servers = config["mcpServers"] as? [String: Any] ?? [:]
                servers[name] = ["type": "stdio", "command": helperPath, "args": [String]()]
                config["mcpServers"] = servers
            }
            let plugins = try Self.reviewAppending(
                #"{"id":"\#(supabase)","version":"1.0.0","scope":"user","enabled":true,"installPath":"\#(homePath)/\#(supabaseFolder)"}"#,
                to: world.answers(for: .claude)[["plugin", "list", "--json"]] ?? "[]")
            replies[ClientExecutableLocator.executableName(for: .claude)]?[["plugin", "list", "--json"]] =
                .standardOutput(plugins + "\n")
        }
        if installed.contains(.codex) {
            let codexConfig = home.url.appending(path: ".codex/config.toml")
            let codexSettings = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
            try home.plant(".codex/config.toml", codexSettings + "\n[mcp_servers.\(name)]\ncommand = \(helper)\nargs = []\n")
            let servers = try Self.reviewAppending(
                #"{"name":"\#(name)","enabled":true,"transport":{"type":"stdio","command":\#(helper),"args":[]},"auth_status":"unsupported"}"#,
                to: world.answers(for: .codex)[["mcp", "list", "--json"]] ?? "[]")
            replies[ClientExecutableLocator.executableName(for: .codex)]?[["mcp", "list", "--json"]] =
                .standardOutput(servers + "\n")
        }
        let runner = ScriptedCommandRunner(
            byTool: replies,
            missingTools: Set(
                ClientKind.allCases.filter { !world.found.contains($0) }.map(ClientExecutableLocator.executableName(for:))))
        let rechecked = await world.registry.scanAll(homeURL: home.url, runner: runner, clients: installed)
        let surfaces = Set(rechecked.map(\.surface))
        let kept = orderedObservations.filter { !surfaces.contains($0.surface) }
        return ClientKind.allCases.flatMap { client in (kept + rechecked).filter { $0.surface.client == client } }
    }

    /// The JSON object in the home's file `relative`, changed by `change` and
    /// written back.
    private func reviewMerge(into relative: String, _ change: (inout [String: Any]) -> Void) throws {
        let url = world.home.url.appending(path: relative)
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        change(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try world.home.plant(relative, String(decoding: data, as: UTF8.self) + "\n")
    }

    /// `object` added to the end of the JSON array `array`.
    private static func reviewAppending(_ object: String, to array: String) throws -> String {
        var items = try JSONSerialization.jsonObject(with: Data(array.utf8)) as? [Any] ?? []
        items.append(try JSONSerialization.jsonObject(with: Data(object.utf8)))
        let data = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// `text` as a JSON string, which is also how TOML spells it.
    private static func reviewJSON(_ text: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(text), as: UTF8.self)
    }
}
