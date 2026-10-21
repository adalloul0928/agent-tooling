import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// You joined (J02) on Cedar, once it joined the library Juniper published:
/// the first pass, what arrived waiting for one review with nothing
/// installed on its own, the review itself, Install later, Connect it here
/// too (D23), Rename…, and the lines the screen says. When You joined shows
/// again, it says what is true then, not what it found first.
@Suite("Launchpad arrivals", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadArrivalsTests {
    @Test func whatJuniperSharesWaitsForOneReview() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }
        let arrivals = joined.arrivals

        #expect(arrivals.phase == .ready)
        // In the order the review installs them, each into its apps in the
        // app order: 5 installs in all.
        #expect(arrivals.rows.map(\.name) == ["Frontend Design", "Release Notes", "Supabase"])
        #expect(arrivals.rows.map(\.apps) == [[.codex, .claude], [.codex, .claude], [.claude]])
        #expect(arrivals.rows.map(\.kind) == [.skill, .skill, .plugin])
        #expect(arrivals.rows.last?.packageID == "supabase@claude-plugins-official")
        #expect(arrivals.installCount == 5)
        #expect(arrivals.leftOut.isEmpty)
        // Nothing installed on its own: the review is the only way in.
        let incoming = joined.workspace.incoming
        #expect(incoming.installedAutomatically.isEmpty)
        #expect(incoming.waiting.count == 3)
        #expect(joined.workspace.deployment.results.isEmpty)

        let footer = LaunchpadStageView.footer(for: joined.flow)
        #expect(footer.primary?.title == "Review 5 changes…")
        #expect(footer.primary?.key == .return)
        #expect(footer.secondary?.title == "Install later")
        #expect(footer.secondary?.help == "They stay on Home under From your other Macs.")
        #expect(footer.showsBack == nil)
        #expect(joined.flow.info.back == nil)
    }

    /// The well, the greeting and the line under it, from the registry and
    /// what the other Mac published (D24).
    @Test func theScreenSaysWhoJoinedAndWhatJuniperLastPublished() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }
        let arrivals = joined.arrivals
        let copy = LaunchpadCopy.Join.self

        #expect(arrivals.thisMacName == "Cedar")
        #expect(copy.joinedAs(arrivals.thisMacName) == "You joined as Cedar")
        #expect(arrivals.otherMacs.map(\.name) == ["Juniper"])
        #expect(arrivals.otherMacName == "Juniper")
        #expect(copy.skillsCameAcross(arrivals.personalSkillCount) == "2 of your own skills came across.")
        let juniper = try #require(arrivals.otherMacs.first)
        #expect(
            arrivals.line(for: juniper, now: ClientHomeFixture.now)
                == "Juniper · published 6 min ago · Codex 0.164.0 · Claude Code 2.1.304")
        // The library's tools, as the check counted them before the join.
        #expect(arrivals.toolCount == joined.join.passed?.toolCount)
        #expect(copy.sameLibrary(tools: arrivals.toolCount) == "Same library · \(arrivals.toolCount) tools")
        #expect(copy.otherMac == "other Mac")
        #expect(
            copy.thisMac(family: joined.flow.environment.macModelFamily(), systemVersion: 26) == "Mac mini · macOS 26 · this Mac")
        #expect(copy.thisMac(family: nil, systemVersion: 26) == "macOS 26 · this Mac")
        #expect(MacModel.symbol(forFamily: "Mac mini") == "macmini")
        #expect(MacModel.symbol(forFamily: "MacBook Pro") == "laptopcomputer")
        #expect(MacModel.symbol(forFamily: nil) == "laptopcomputer")
        #expect(copy.shares("Juniper", tools: arrivals.rows.count) == "Juniper shares 3 tools with every Mac")
        // Agent Tooling's own connection is bound on Juniper alone.
        #expect(arrivals.helper == .init(macs: ["Juniper"], isSetUpHere: false))
        #expect(copy.setUpOn(["Juniper"]) == "Set up on Juniper only")
    }

    /// The first pass published this Mac's status, so Juniper's next pass
    /// shows Cedar's versions.
    @Test func theFirstPassPublishesThisMacsStatus() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }
        let repository = MacsRepository(existing: joined.juniper.remote)

        #expect(try repository.hasStatus(of: joined.workspace.store.deviceID))
        #expect(joined.workspace.sync?.statusProvider != nil)
        #expect(joined.workspace.sync?.otherDeviceStatuses.map(\.name) == ["Juniper"])
    }

    /// Review 5 changes… opens the stage's review over You joined, with no
    /// library row, and its Continue goes on to the step after.
    @Test func theReviewListsEveryArrivalAndNoLibraryRow() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }

        try #require(LaunchpadStageView.footer(for: joined.flow).primary).action()
        let review = try #require(joined.flow.presentedReview)
        #expect(joined.flow.reviewReturn == nil)
        #expect(review.libraryDecisions == nil)
        #expect(review.scope == .artifacts(Set(joined.arrivals.rows.map(\.artifactID))))
        await review.prepare()
        #expect(review.listedCount == 5)
        #expect(review.runnableCount == 5)
        #expect(review.title == "Install 5 changes")
        #expect(review.chip == "This Mac · Cedar")
        #expect(review.groups.map(\.client) == [.codex, .claude])

        joined.flow.dismissReview()
        #expect(joined.flow.step == .arrivals)
    }

    /// Install later moves on; what arrived waits on Home.
    @Test func installLaterLeavesThemForHome() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }

        try #require(LaunchpadStageView.footer(for: joined.flow).secondary).action()

        #expect(joined.flow.step == .assistant)
        #expect(joined.workspace.incoming.waiting.count == 3)
        #expect(joined.workspace.deployment.results.isEmpty)
    }

    /// Connect it here too opens Let your apps ask for this Mac (D23): the
    /// footer keeps Arrivals and 2 of 3, and the way back is You joined.
    @Test func connectItHereTooIsTheAskDetour() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }

        LaunchpadArrivalsScreen.connectHere(joined.flow)

        #expect(joined.flow.step == .ask)
        #expect(joined.flow.isDetour)
        #expect(joined.flow.info.footerName == "Arrivals")
        #expect(joined.flow.info.capsules == .init(reached: 2, total: 3))
        joined.flow.goBack()
        #expect(joined.flow.step == .arrivals)
    }

    /// Rename… renames this Mac in the registry and shares it; a name
    /// another Mac uses is refused in the registry's own words.
    @Test func renameChangesTheRegisteredName() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }
        let arrivals = joined.arrivals

        #expect(await arrivals.rename(to: " Fir "))
        #expect(arrivals.thisMacName == "Fir")
        #expect(arrivals.renameProblem == nil)

        #expect(!(await arrivals.rename(to: "Juniper")))
        #expect(arrivals.thisMacName == "Fir")
        #expect(arrivals.renameProblem == "Another Mac is already called “Juniper”. Choose a different name. Nothing was changed.")
        arrivals.dismissRenameProblem()
        #expect(arrivals.renameProblem == nil)
    }

    /// A Mac's own setup placements never read as arrivals from another
    /// Mac, and arrivals name their apps in the app order.
    @Test func thisMacsOwnPlacementsAreNotArrivals() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterPlace)
        let workspace = sample.workspace
        await workspace.deployment.prepare()
        let plan = try #require(workspace.deployment.plan)
        let library = try #require(workspace.library.state?.library)
        let thisMac = workspace.store.deviceID

        let unexcluded = WorkspaceIncomingSession.arrivals(in: plan, library: library, thisDevice: thisMac)
        #expect(unexcluded.contains { $0.displayName == "Release Notes" })
        // Claude Code has it already, so it goes into Codex alone.
        #expect(unexcluded.first { $0.displayName == "Release Notes" }?.clients == [.codex])
        let excluded = WorkspaceIncomingSession.arrivals(
            in: plan, library: library, thisDevice: thisMac, excluding: Set(sample.decisions.contributionIDs))
        #expect(excluded.isEmpty)
    }

    /// Where the helper is set up, from the Macs its this-Mac-only
    /// placements name.
    @Test func theHelperRowReadsWhereItIsSetUp() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }
        let document = try #require(joined.workspace.library.state?.snapshot.document)
        let cedar = joined.workspace.store.deviceID

        #expect(LaunchpadArrivals.helper(in: document, thisDevice: cedar) == .init(macs: ["Juniper"], isSetUpHere: false))
        // Seen from Juniper, it is set up here.
        let juniper = try #require(document.deviceRegistry.first { $0.name == "Juniper" }?.id)
        #expect(LaunchpadArrivals.helper(in: document, thisDevice: juniper) == .init(macs: [], isSetUpHere: true))
        // Its row's line, each way.
        #expect(LaunchpadArrivals.Helper(macs: ["Juniper"], isSetUpHere: false).line == "Set up on Juniper only")
        #expect(LaunchpadArrivals.Helper(macs: ["Juniper"], isSetUpHere: true).line == "Set up on this Mac too")
        #expect(LaunchpadArrivals.Helper(macs: [], isSetUpHere: true).line == "Set up on this Mac")
    }

    /// D23 there and back: Let your apps ask records Agent Tooling's own
    /// connection for this Mac, and You joined, shown again, says it is set
    /// up here too, with nothing left to connect.
    @Test func connectItHereTooComesBackSetUpHereToo() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }
        let workspace = joined.workspace
        #expect(joined.arrivals.helper == .init(macs: ["Juniper"], isSetUpHere: false))

        LaunchpadArrivalsScreen.connectHere(joined.flow)
        #expect(joined.flow.step == .ask)
        // What Let your apps ask's primary records for this Mac's apps.
        _ = try await workspace.service.connectAgentTooling(
            ConnectAgentToolingCommand(
                expectedRevisionID: try joined.cedar.fixture.head(of: workspace),
                helperPath: joined.cedar.fixture.helperPath, apps: [.codex, .claude]))
        await workspace.library.refresh()
        joined.flow.goBack()
        #expect(joined.flow.step == .arrivals)
        await joined.arrivals.load()

        let helper = try #require(joined.arrivals.helper)
        #expect(helper == .init(macs: ["Juniper"], isSetUpHere: true))
        #expect(helper.line == "Set up on this Mac too")
        // The arrivals are as they were: the connection is this Mac's own.
        #expect(joined.arrivals.phase == .ready)
        #expect(joined.arrivals.rows.map(\.name) == ["Frontend Design", "Release Notes", "Supabase"])
    }

    /// What was installed since You joined first showed is gone from it when
    /// it shows again (Back from the next step), without a new revision: an
    /// install changes the plan, not the library.
    @Test func whatWasInstalledMeanwhileIsGoneWhenYouJoinedShowsAgain() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }
        let flow = joined.flow
        let head = try joined.cedar.fixture.head(of: joined.workspace)
        // The two skills, installed through the stage's own review: copies,
        // with no app's command run.
        let skills = Set(joined.arrivals.rows.filter { $0.kind == .skill }.map(\.artifactID))
        let review = ScopedPlanReview(workspace: joined.workspace, scope: .artifacts(skills), deviceName: "Cedar")
        await review.prepare()
        #expect(review.runnableCount == 4)
        await review.install()
        guard case .finished(let outcome) = review.phase else {
            Issue.record("the skills did not install: \(review.phase)")
            return
        }
        #expect(outcome.failed.isEmpty)
        #expect(try joined.cedar.fixture.head(of: joined.workspace) == head)

        try #require(LaunchpadStageView.footer(for: flow).secondary).action()
        #expect(flow.step == .assistant)
        flow.goBack()
        #expect(flow.step == .arrivals)
        await joined.arrivals.load()

        #expect(joined.arrivals.rows.map(\.name) == ["Supabase"])
        #expect(joined.arrivals.installCount == 1)
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Review 1 change…")
    }

    /// Shown again with nothing moved, You joined works nothing out again.
    @Test func shownAgainWithNothingMovedItLooksNoFurther() async throws {
        let joined = try await ArrivalsWorld.make()
        defer { joined.remove() }
        let checked = joined.workspace.incoming.lastChecked

        await joined.arrivals.load()

        #expect(joined.workspace.incoming.lastChecked == checked)
        #expect(joined.arrivals.phase == .ready)
        #expect(joined.arrivals.installCount == 5)
    }

    /// When the plan cannot be made, what arrived is unknown, and You joined
    /// never says it is nothing: the heading names no count, the line says
    /// why, and Install later and Continue move on. Shown again with nothing
    /// moved it stays as it was; once a plan can be made, it is worked out.
    @Test func whatArrivedThatCannotBeWorkedOutIsNeverNothing() async throws {
        let joined = try await ArrivalsWorld.make(loadsArrivals: false)
        defer { joined.remove() }
        let claude = joined.cedar.fixture.home.appending(path: ".claude", directoryHint: .isDirectory)
        let path = claude.path(percentEncoded: false)
        // Claude Code's folder cannot be read, so neither can its skills'.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        let arrivals = joined.arrivals

        await arrivals.load()

        #expect(arrivals.phase == .ready)
        #expect(arrivals.rows.isEmpty)
        #expect(
            arrivals.reviewProblem
                == "Agent Tooling could not work out what Juniper shares here. A destination folder on this Mac could not be read. Nothing was changed."
        )
        let footer = LaunchpadStageView.footer(for: joined.flow)
        #expect(footer.primary?.title == "Continue")
        #expect(footer.primary?.isEnabled == true)
        #expect(footer.secondary?.title == "Install later")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        await arrivals.load()
        #expect(arrivals.reviewProblem != nil)
        // A step that reads the plan again, as Let your apps ask or a review
        // does.
        await joined.workspace.deployment.prepare()
        await arrivals.load()
        #expect(arrivals.reviewProblem == nil)
        #expect(arrivals.installCount == 5)
    }

    /// Rename… waits for the first look to end, and Rename ↩ for a new name.
    @Test func renameWaitsForTheFirstLookAndANewName() async throws {
        let joined = try await ArrivalsWorld.make(loadsArrivals: false)
        defer { joined.remove() }
        let arrivals = joined.arrivals
        #expect(!arrivals.canRename)

        await arrivals.load()

        #expect(arrivals.canRename)
        #expect(!arrivals.canRename(to: "  "))
        #expect(!arrivals.canRename(to: "Cedar"))
        #expect(arrivals.canRename(to: " Fir "))
    }
}

/// Cedar joined, through the stage, the library Juniper published, at You
/// joined with what arrived worked out.
@MainActor
struct ArrivalsWorld {
    let juniper: JoinPublishedJuniper
    let cedar: JoinCedar
    let flow: LaunchpadFlow
    let join: LaunchpadJoin
    let arrivals: LaunchpadArrivals
    let workspace: WorkspaceLaunch.Workspace

    /// `loadsArrivals` false leaves You joined before its first look.
    static func make(loadsArrivals: Bool = true) async throws -> ArrivalsWorld {
        let juniper = try await JoinPublishedJuniper.make()
        let cedar: JoinCedar
        do {
            cedar = try await JoinCedar()
        } catch {
            juniper.remove()
            throw error
        }
        do {
            let (flow, join) = await cedar.joinStage()
            join.update(address: juniper.address)
            await join.check.checkNow(join.request)
            join.join(flow: flow)
            await waitUntil { flow.step == .arrivals }
            let arrivals = try #require(LaunchpadArrivalsScreen.arrivals(for: flow))
            if loadsArrivals { await arrivals.load() }
            return ArrivalsWorld(
                juniper: juniper, cedar: cedar, flow: flow, join: join, arrivals: arrivals,
                workspace: try #require(flow.workspace))
        } catch {
            cedar.remove()
            juniper.remove()
            throw error
        }
    }

    func remove() {
        cedar.remove()
        juniper.remove()
    }
}
