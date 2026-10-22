import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Put tools in apps (S10) on the sample world: the grid drawn from the
/// what-if plan, cell for cell as the fragment draws it; the count the footer
/// says; what Space can and cannot change; the columns a missing app does
/// not get; and what Continue records, in one revision, touching no app.
@Suite("Launchpad placement", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadPlacementTests {
    private typealias Cell = LaunchpadPlacement.Cell
    private typealias Key = LaunchpadPlacement.Key

    // MARK: - The grid

    @Test func theGridIsTheFragmentsCellForCell() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, _, _) = try await placement(fixture)

        #expect(placement.phase == .ready)
        #expect(placement.items.map(\.name) == ["Release Notes", "Frontend Design", "Supabase"])
        #expect(
            placement.items.map(\.subtitle) == [
                "Skill · Personal library", "Skill · Personal library", "Plugin · Claude Code’s catalog",
            ])
        #expect(placement.items.map(\.artworkID) == [nil, nil, "supabase@claude-plugins-official"])
        #expect(placement.apps == [.codex, .claude, .gemini])
        #expect(
            cells(placement) == [
                [.willInstall, .hasIt, .through(.codex)],
                [.leftAlone(reason: "Codex already has a different copy"), .hasIt, .readsCopy(of: .codex)],
                [.unavailable("Codex has its own catalog"), .willInstall, .unavailable("Gemini CLI takes no plugins")],
            ])
        #expect(placement.changeCount == 2)
        #expect(placement.cursor == key(placement, 0, .codex))
        #expect(
            placement.libraryCaption
                == "GitHub, Linear and Sentry stay as their apps manage them. Webapp Testing can be placed once you make it yours.")
        #expect(placement.appCaptions == ["Kiro CLI is off on this Mac, so it has no column."])
        #expect(placement.projects.isEmpty)
        #expect(!placement.hasOtherMacs)
    }

    /// The footer says what the review after the next step installs: Has it
    /// never counts, nor what Gemini CLI reads through Codex's folder.
    @Test func theFooterCountsTheChangesSoFar() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await fixture.flow(at: .afterLibrary)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        #expect(LaunchpadStageView.footer(for: flow).note == nil, "no count before the grid is read")
        #expect(LaunchpadStageView.footer(for: flow).primary?.isEnabled == false)

        await placement.load(decisions: flow.decisions)

        let footer = LaunchpadStageView.footer(for: flow)
        #expect(footer.note == "2 changes so far")
        #expect(footer.primary?.title == "Continue")
        #expect(footer.primary?.key == .return)
        #expect(footer.primary?.isEnabled == true)
        #expect(flow.info.footerName == "Put in apps")
        #expect(flow.info.capsules == .init(reached: 3, total: 5))
        #expect(flow.info.back == .library)
        placement.toggle(key(placement, 2, .claude))
        #expect(LaunchpadStageView.footer(for: flow).note == "1 change so far")
        placement.toggle(key(placement, 0, .codex))
        #expect(LaunchpadStageView.footer(for: flow).note == "No changes so far")
    }

    /// Space turns Will install to Add and back, and Gemini CLI's cell
    /// follows Codex's; every other cell is read and passed over.
    @Test func spaceTurnsOnlyWillInstallAndAdd() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, _, _) = try await placement(fixture)
        let releaseNotesInCodex = key(placement, 0, .codex)

        placement.toggle(releaseNotesInCodex)
        #expect(placement.cells[releaseNotesInCodex] == .add)
        #expect(placement.cells[key(placement, 0, .gemini)] == .readsFolder(of: .codex))
        #expect(placement.changeCount == 1)
        placement.toggle(releaseNotesInCodex)
        #expect(placement.cells[releaseNotesInCodex] == .willInstall)
        #expect(placement.cells[key(placement, 0, .gemini)] == .through(.codex))

        let before = placement.cells
        let readOnly = [
            key(placement, 0, .claude), key(placement, 0, .gemini), key(placement, 1, .codex), key(placement, 1, .claude),
            key(placement, 1, .gemini), key(placement, 2, .codex), key(placement, 2, .gemini),
        ]
        for cell in readOnly {
            #expect(!placement.isToggleable(cell))
            placement.toggle(cell)
            #expect(placement.cursor == cell, "a cell Space passes over still takes the cursor, so it is read")
        }
        #expect(placement.cells == before)
        #expect(placement.isToggleable(key(placement, 2, .claude)))
    }

    @Test func theCursorMovesOverEveryCellAndStopsAtTheEdges() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, _, _) = try await placement(fixture)

        placement.moveCursor(.left)
        placement.moveCursor(.up)
        #expect(placement.cursor == key(placement, 0, .codex))
        placement.moveCursor(.right)
        placement.moveCursor(.right)
        placement.moveCursor(.right)
        #expect(placement.cursor == key(placement, 0, .gemini))
        placement.moveCursor(.down)
        placement.moveCursor(.down)
        placement.moveCursor(.down)
        #expect(placement.cursor == key(placement, 2, .gemini))
        placement.moveCursor(.left)
        #expect(placement.cursor == key(placement, 2, .claude))
    }

    /// D7: a managed app no read has checked has no column, and its caption
    /// says to place things there after the next check.
    @Test func aManagedAppNoReadCheckedHasNoColumn() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        await sample.workspace.device.setEnabled(.kiro, true)
        #expect(sample.workspace.device.managedClients.contains(.kiro))
        let placement = LaunchpadPlacement(workspace: sample.workspace)

        await placement.load(decisions: flow.decisions)

        #expect(placement.apps == [.codex, .claude, .gemini])
        #expect(
            placement.appCaptions == [
                "Kiro CLI was not checked, so it has no column yet. Place things there after the next check."
            ])
        #expect(placement.cells.keys.allSatisfy { $0.app != .kiro })
    }

    /// An app that answered without its version: what it accepts is not
    /// known, so its cells wait for one, and Gemini CLI, which reads its
    /// folder, gets nothing through it yet.
    @Test func anAppWithNoVersionWaitsForOne() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        var codex = try #require(fixture.observations[.codex])
        codex.version = nil
        await sample.workspace.device.adopt([codex])
        let placement = LaunchpadPlacement(workspace: sample.workspace)

        await placement.load(decisions: flow.decisions)

        #expect(placement.apps == [.codex, .claude, .gemini])
        #expect(placement.cells[key(placement, 0, .codex)] == .unavailable("Waits for a version"))
        #expect(placement.cells[key(placement, 0, .gemini)] == .readsFolder(of: .codex))
        #expect(placement.cells[key(placement, 0, .claude)] == .hasIt)
        #expect(placement.changeCount == 1)
    }

    /// The ↩-through path: Start your library added nothing, so there is
    /// nothing to place, and the card says what stays with its apps.
    @Test func withNothingAddedThereIsNothingToPlace() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (_, sample) = try await fixture.flow(at: .afterRead)
        let flow = fixture.flow(.continueFirstRun(.place), workspace: sample.workspace)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)
        let head = try fixture.head(of: sample.workspace)

        #expect(placement.items.isEmpty)
        #expect(placement.cells.isEmpty)
        #expect(
            placement.emptyText
                == "Nothing to place yet. Skills can be placed once they are yours; GitHub, Linear and Sentry stay as their apps manage them."
        )
        #expect(LaunchpadStageView.footer(for: flow).note == "No changes so far")

        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }
        #expect(try fixture.head(of: sample.workspace) == head)
        #expect(flow.decisions.placed.isEmpty)
        #expect(flow.decisions.contributionIDs.isEmpty)
    }

    /// V01: with no app managed the step is passed over, and Done is told
    /// why.
    @Test func withNoAppManagedTheStepSaysWhyItWasPassedOver() {
        #expect(
            LaunchpadPlaceScreen.skipReason(LaunchpadTransitionContext(startedEmpty: true))
                == "Nothing was put in apps, because this Mac manages no app.")
        #expect(LaunchpadPlaceScreen.skipReason(LaunchpadTransitionContext()) != nil)
        #expect(
            LaunchpadPlaceScreen.skipReason(
                LaunchpadTransitionContext(managed: [.codex], observed: [.codex], managesAssistant: true)) == nil)
    }

    /// V01's walk passes Put in apps over, and Done is given the reason.
    @Test func anEmptyMacsWalkRecordsWhyItWasPassedOver() async throws {
        let fixture = try await LaunchpadFixture(.emptyMac)
        defer { fixture.remove() }
        let flow = fixture.flow()
        try pressPrimary(flow)
        try pressPrimary(flow)
        await waitUntil { flow.step == .library }

        try pressPrimary(flow)

        #expect(flow.step == .behave)
        #expect(flow.outcomes.skipped[.place] == "Nothing was put in apps, because this Mac manages no app.")
    }

    /// The what-if plan is worked out beside the deployment session, never
    /// in it: its prepared plan, proven installs and results stay as they
    /// were, and nothing is saved.
    @Test func theWhatIfPlanLeavesTheDeploymentSessionAsItWas() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (_, sample) = try await fixture.flow(at: .afterLibrary)
        let deployment = sample.workspace.deployment
        await deployment.prepare()
        let prepared = try #require(deployment.plan)
        let proven = deployment.provenInstalls
        let head = try fixture.head(of: sample.workspace)
        let releaseNotes = try #require(sample.decisions.adopted.first?.artifactID)

        let preview = try #require(
            await deployment.previewPlan(assuming: [
                .init(artifactID: releaseNotes, destination: .init(surface: .codexCLI, scope: .user), reason: .manual)
            ]))

        #expect(preview.plan.items.contains { $0.artifactID == releaseNotes && $0.surface == .codexCLI })
        #expect(deployment.plan?.items == prepared.items)
        #expect(deployment.plan?.exclusions == prepared.exclusions)
        #expect(deployment.provenInstalls == proven)
        #expect(deployment.results.isEmpty)
        #expect(!deployment.isBusy)
        #expect(try fixture.head(of: sample.workspace) == head)
    }

    // MARK: - Continue

    /// Continue records Will install, Has it and Left alone as Every Mac
    /// intent in one revision, keeps the IDs for Back and the record, and
    /// touches no app.
    @Test func continueRecordsTheGridInOneRevisionAndTouchesNoApp() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, flow, sample) = try await placement(fixture)
        let workspace = sample.workspace
        let before = try fixture.head(of: workspace)

        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }

        let document = try #require(try workspace.store.snapshot()?.document)
        #expect(document.revision.parentIDs == [before], "Continue writes exactly one revision")
        #expect(document.assignments.count == 5)
        #expect(document.assignments.allSatisfy { $0.destination.deviceIDs == nil && $0.reason == .manual })
        let placed = Set(document.assignments.map { Key(item: $0.artifactID, app: $0.destination.surface.client ?? .kiro) })
        #expect(
            placed
                == Set(
                    placement.items.flatMap { item in
                        placement.apps.compactMap { app in
                            placement.cells[Key(item: item.artifactID, app: app)]?.isRecorded == true
                                ? Key(item: item.artifactID, app: app) : nil
                        }
                    }))
        #expect(!placed.contains(key(placement, 0, .gemini)), "Gemini CLI reads Codex's folder: nothing is recorded for it")
        #expect(
            flow.decisions.lines.suffix(3) == [
                "Release Notes goes to Codex and Claude Code on every Mac",
                "Frontend Design goes to Codex and Claude Code on every Mac", "Supabase goes to Claude Code on every Mac",
            ])
        #expect(Set(flow.decisions.contributionIDs) == Set(document.assignments.map(\.id)))
        #expect(fixture.savedRecord(for: workspace)?.evidence.placedContributionIDs == flow.decisions.contributionIDs)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .ask)
        // No app was checked, asked or written to.
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.observer.scopedChecks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/release-notes").path))
        #expect(try workspace.store.operationReceipts().isEmpty)
    }

    /// Back, one cell turned off, Continue: only that cell's contribution is
    /// withdrawn; the rest keep their IDs.
    @Test func goingBackAndChangingACellWithdrawsOnlyItsOwnContribution() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, flow, sample) = try await placement(fixture)
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }
        let first = flow.decisions.contributionIDs
        let saved = try fixture.head(of: sample.workspace)

        flow.goBack()
        #expect(flow.step == .place)
        await placement.load(decisions: flow.decisions)
        #expect(placement.cells[key(placement, 0, .codex)] == .willInstall, "back on the grid, it is as it was left")
        placement.toggle(key(placement, 0, .codex))
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }

        let document = try #require(try sample.workspace.store.snapshot()?.document)
        #expect(document.revision.parentIDs == [saved])
        #expect(document.assignments.count == 4)
        #expect(!document.assignments.contains { $0.artifactID == placement.items[0].artifactID && $0.destination.surface == .codexCLI })
        #expect(Set(flow.decisions.contributionIDs).isSubset(of: Set(first)))
        #expect(flow.decisions.contributionIDs.count == 4)
        #expect(flow.decisions.lines.contains("Release Notes goes to Claude Code on every Mac"))
    }

    /// Back and Continue with nothing changed writes nothing.
    @Test func continueAgainWithNothingChangedWritesNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, flow, sample) = try await placement(fixture)
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }
        let saved = try fixture.head(of: sample.workspace)
        let ids = flow.decisions.contributionIDs

        flow.goBack()
        await placement.load(decisions: flow.decisions)
        #expect(placement.changeCount == 2)
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }

        #expect(try fixture.head(of: sample.workspace) == saved)
        #expect(flow.decisions.contributionIDs == ids)
    }

    @Test func thisMacOnlyIsRecordedForThisMac() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, flow, sample) = try await placement(fixture)

        await placement.choose(.thisMacOnly, decisions: flow.decisions)
        #expect(placement.scope == .thisMacOnly)
        #expect(cells(placement)[0] == [.willInstall, .hasIt, .through(.codex)], "the same folders, so the same cells")
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }

        let document = try #require(try sample.workspace.store.snapshot()?.document)
        #expect(document.assignments.count == 5)
        #expect(document.assignments.allSatisfy { $0.destination.deviceIDs == [sample.workspace.store.deviceID] })
        #expect(flow.decisions.lines.contains("Supabase goes to Claude Code on this Mac only"))
    }

    /// One project cannot be chosen while this Mac tracks no project.
    @Test func oneProjectNeedsATrackedProject() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, flow, _) = try await placement(fixture)

        await placement.choose(.oneProject, decisions: flow.decisions)

        #expect(placement.scope == .everyMac)
        #expect(placement.projectID == nil)
    }

    /// With a project this Mac tracks, One project places into its folder,
    /// on this Mac: the cells are worked out for that folder, where Claude
    /// Code's own copy of Release Notes is not. Gemini CLI reads Codex's
    /// folder in the home folder only, so in a project it gets its own
    /// placement, and a plugin goes to every project or none.
    @Test func oneProjectPlacesIntoTheProjectsFolder() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        let workspace = sample.workspace
        let project = try await trackProject(in: sample, fixture)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)
        #expect(placement.projects.map(\.name) == ["storefront"])

        await placement.choose(.oneProject, decisions: flow.decisions)

        #expect(placement.scope == .oneProject)
        #expect(placement.projectName == "storefront")
        #expect(placement.cells[key(placement, 0, .codex)] == .willInstall)
        #expect(placement.cells[key(placement, 0, .claude)] == .willInstall, "the copy in ~/.claude/skills is not in the project")
        #expect(placement.cells[key(placement, 0, .gemini)] == .willInstall, "in a project Gemini CLI gets its own placement")
        #expect(placement.isToggleable(key(placement, 0, .gemini)))
        // Supabase is from Claude Code's catalog, in a project as anywhere,
        // and Agent Tooling installs plugins for every project only.
        #expect(placement.cells[key(placement, 2, .codex)] == .unavailable("Codex has its own catalog"))
        #expect(placement.cells[key(placement, 2, .claude)] == .unavailable("Plugins go to every project"))
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }
        let document = try #require(try workspace.store.snapshot()?.document)
        #expect(!document.assignments.isEmpty)
        #expect(
            document.assignments.allSatisfy {
                $0.destination.scope == .project && $0.destination.logicalProjectID == project
                    && $0.destination.deviceIDs == [workspace.store.deviceID]
            })
        #expect(document.assignments.contains { $0.destination.surface == .geminiCLI })
        #expect(flow.decisions.lines.contains("Release Notes goes to Codex, Claude Code and Gemini CLI in storefront"))
    }

    /// Choosing One project works the grid out again for the project's
    /// folder, and Continue waits for those cells: it never saves the home
    /// folder's cells as the project's.
    @Test func continueWaitsForTheCellsOfANewWhere() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        _ = try await trackProject(in: sample, fixture)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)
        let head = try fixture.head(of: sample.workspace)

        let choosing = Task { await placement.choose(.oneProject, decisions: flow.decisions) }
        await waitUntil { placement.scope == .oneProject }

        #expect(placement.isRefreshing, "the project's cells are still being worked out")
        #expect(!placement.canContinue)
        #expect(LaunchpadStageView.footer(for: flow).primary?.isEnabled == false)
        #expect(await placement.commit(decisions: flow.decisions) == nil)
        await choosing.value
        #expect(placement.canContinue)
        #expect(placement.cells[key(placement, 2, .claude)] == .unavailable("Plugins go to every project"))
        #expect(try fixture.head(of: sample.workspace) == head)
    }

    // MARK: - A Mac that takes only what names it

    /// What goes to every Mac leaves out a Mac set to take only what names
    /// it, so the grid opens on This Mac only there and says why. A request
    /// for every Mac the library already holds is never asked for twice, so
    /// the grid is worked out with Every Mac chosen too.
    @Test func aMacThatTakesOnlyWhatNamesItOpensOnThisMacOnly() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        let workspace = sample.workspace
        let thisMac = workspace.store.deviceID
        _ = try await workspace.service.registerDevice(
            .init(
                expectedRevisionID: try fixture.head(of: workspace), deviceID: thisMac, name: "Juniper",
                receivesSharedAssignments: false))
        let releaseNotes = try #require(flow.decisions.adopted.first?.artifactID)
        let everyMac = AssignmentContribution(
            artifactID: releaseNotes, destination: .init(surface: .codexCLI, scope: .user), reason: .manual)
        _ = try await workspace.service.applyAssignmentBatch(
            .init(expectedRevisionID: try fixture.head(of: workspace), additions: [everyMac]))
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))

        await placement.load(decisions: LaunchpadPlaceScreen.decisions(for: flow))

        #expect(placement.phase == .ready)
        #expect(placement.takesOnlyWhatNamesIt)
        #expect(placement.scope == .thisMacOnly)
        #expect(
            cells(placement) == [
                [.willInstall, .hasIt, .through(.codex)],
                [.leftAlone(reason: "Codex already has a different copy"), .hasIt, .readsCopy(of: .codex)],
                [.unavailable("Codex has its own catalog"), .willInstall, .unavailable("Gemini CLI takes no plugins")],
            ])
        #expect(placement.changeCount == 2)

        await placement.choose(.everyMac, decisions: LaunchpadPlaceScreen.decisions(for: flow))
        #expect(placement.phase == .ready, "the request for every Mac is not asked for a second time")
        #expect(placement.cells[key(placement, 0, .codex)] == .unavailable("Not on this Mac"))
        #expect(!placement.isToggleable(key(placement, 0, .codex)))
        #expect(placement.changeCount == 0)

        await placement.choose(.thisMacOnly, decisions: LaunchpadPlaceScreen.decisions(for: flow))
        #expect(placement.changeCount == 2)
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }
        let document = try #require(try workspace.store.snapshot()?.document)
        #expect(document.assignments.filter { $0.destination.deviceIDs == [thisMac] }.count == 5)
        #expect(document.assignments.contains { $0.id == everyMac.id })
    }

    // MARK: - A walk relaunched or resumed past the grid

    /// A first run relaunched past Put in apps starts with no decisions.
    /// Going back finds the grid as it was saved: the record's placements
    /// are this setup's own, so their rows come back, unlocked, and Continue
    /// keeps every one of them in the record and writes nothing.
    @Test func aRelaunchedFirstRunOpensOnWhatItPlaced() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, flow, sample) = try await placement(fixture)
        let before = cells(placement)
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }
        let placed = try #require(fixture.savedRecord(for: sample.workspace)?.evidence.placedContributionIDs)
        #expect(placed.count == 5)
        let saved = try fixture.head(of: sample.workspace)

        let relaunched = fixture.flow(.continueFirstRun(.ask), workspace: sample.workspace)
        #expect(relaunched.decisions.contributionIDs.isEmpty)
        relaunched.goBack()
        #expect(relaunched.step == .place)
        let again = try #require(LaunchpadPlaceScreen.placement(for: relaunched))
        await again.load(decisions: LaunchpadPlaceScreen.decisions(for: relaunched))

        #expect(again.items.map(\.name) == ["Release Notes", "Frontend Design", "Supabase"])
        #expect(again.items.map(\.subtitle) == placement.items.map(\.subtitle))
        #expect(again.scope == .everyMac)
        #expect(cells(again) == before)
        #expect(again.isToggleable(key(again, 0, .codex)), "this setup's own placement can still be turned off")
        #expect(again.changeCount == 2)
        try pressPrimary(relaunched)
        await waitUntil { relaunched.step == .ask }

        #expect(try fixture.head(of: sample.workspace) == saved, "nothing changed, so nothing was written")
        #expect(Set(fixture.savedRecord(for: sample.workspace)?.evidence.placedContributionIDs ?? []) == Set(placed))
        #expect(Set(relaunched.decisions.contributionIDs) == Set(placed))
        #expect(relaunched.decisions.lines == Array(flow.decisions.lines.suffix(3)))
    }

    /// Opened anew on what it saved, the grid keeps the Where choice those
    /// placements were made for and every cell they left out, so Continue
    /// changes nothing the person did not change.
    @Test func aRelaunchedGridKeepsItsWhereAndWhatWasLeftOut() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, flow, sample) = try await placement(fixture)
        await placement.choose(.thisMacOnly, decisions: flow.decisions)
        placement.toggle(key(placement, 0, .codex))
        let before = cells(placement)
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }
        let saved = try fixture.head(of: sample.workspace)

        let relaunched = fixture.flow(.continueFirstRun(.ask), workspace: sample.workspace)
        relaunched.goBack()
        let again = try #require(LaunchpadPlaceScreen.placement(for: relaunched))
        await again.load(decisions: LaunchpadPlaceScreen.decisions(for: relaunched))

        #expect(again.scope == .thisMacOnly)
        #expect(cells(again) == before)
        #expect(again.cells[key(again, 0, .codex)] == .add)
        try pressPrimary(relaunched)
        await waitUntil { relaunched.step == .ask }
        #expect(try fixture.head(of: sample.workspace) == saved)
        #expect(relaunched.decisions.contributionIDs.count == 4)
    }

    // MARK: - Moving while Continue saves

    /// Back while Continue saves: the save lands and is kept, the walk stays
    /// where Back put it, and what Your library decided meanwhile stays.
    @Test func backWhileSavingStaysBack() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, flow, sample) = try await placement(fixture)
        try pressPrimary(flow)
        flow.goBack()
        #expect(flow.step == .library)
        let added = LaunchpadLibraryDecisions.Added(artifactID: ArtifactID(), name: "Linear", source: .catalog(.claude))
        flow.decisions.added.append(added)

        await waitUntil { !flow.decisions.contributionIDs.isEmpty }

        #expect(flow.step == .library, "the save moved the walk on after Back")
        #expect(flow.decisions.contributionIDs.count == 5)
        #expect(flow.decisions.placed.count == 3)
        #expect(flow.decisions.added.last == added, "the save changes only what it decided")
        #expect(fixture.savedRecord(for: sample.workspace)?.evidence.placedContributionIDs == flow.decisions.contributionIDs)
        #expect(fixture.savedRecord(for: sample.workspace)?.cursor == .library)
        await waitUntil { placement.phase == .ready }
    }

    /// Back and forward again while Continue saves: the walk stays on the
    /// grid it came back to, and Continue there moves on.
    @Test func backAndForwardAgainWhileSavingStaysOnTheGrid() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, flow, _) = try await placement(fixture)
        try pressPrimary(flow)
        flow.goBack()
        flow.advance()
        #expect(flow.step == .place)
        // The grid appears again, and its screen reads it.
        await placement.load(decisions: LaunchpadPlaceScreen.decisions(for: flow))
        await waitUntil { !flow.decisions.contributionIDs.isEmpty && placement.phase == .ready && !placement.isRefreshing }

        #expect(flow.step == .place, "the save moved the walk on from the grid it came back to")
        try pressPrimary(flow)
        await waitUntil { flow.step == .ask }
    }

    /// Set up later while Continue saves: the save lands and the record
    /// keeps it, at the step the walk was left at.
    @Test func leavingWhileSavingKeepsTheSaveWhereTheWalkWasLeft() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (_, flow, sample) = try await placement(fixture)
        try pressPrimary(flow)
        flow.requestClose()
        flow.leave()
        #expect(flow.pendingHandOff == .overview)

        await waitUntil { !flow.decisions.contributionIDs.isEmpty }

        let record = try #require(fixture.savedRecord(for: sample.workspace))
        #expect(record.state == .deferred)
        #expect(record.cursor == .place)
        #expect(record.evidence.placedContributionIDs == flow.decisions.contributionIDs)
        #expect(flow.step == .place)
    }

    // MARK: - What VoiceOver reads

    /// Each cell reads its item, its app, what happens there and why, as the
    /// fragment labels them; Space's cells say what Space does.
    @Test func eachCellReadsItemAppStateAndReason() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (placement, _, _) = try await placement(fixture)

        #expect(
            placement.items.indices.flatMap { row in placement.apps.map { placement.accessibilityLabel(for: key(placement, row, $0)) } }
                == [
                    "Release Notes, Codex: will install", "Release Notes, Claude Code: has it",
                    "Release Notes, Gemini CLI: through Codex’s folder",
                    "Frontend Design, Codex: left alone. Codex already has a different copy.",
                    "Frontend Design, Claude Code: has it",
                    "Frontend Design, Gemini CLI: left alone. It reads Codex’s own copy in ~/.agents/skills.",
                    "Supabase, Codex: Codex has its own catalog", "Supabase, Claude Code: will install",
                    "Supabase, Gemini CLI: Gemini CLI takes no plugins",
                ])
        #expect(placement.accessibilityHint(for: key(placement, 0, .codex)) == "Press Space to leave it out.")
        #expect(placement.accessibilityHint(for: key(placement, 0, .claude)) == nil)
        placement.toggle(key(placement, 0, .codex))
        #expect(placement.accessibilityLabel(for: key(placement, 0, .codex)) == "Release Notes, Codex: can be added")
        #expect(placement.accessibilityHint(for: key(placement, 0, .codex)) == "Press Space to add it.")
        #expect(
            placement.accessibilityLabel(for: key(placement, 0, .gemini))
                == "Release Notes, Gemini CLI: reads Codex’s folder in ~/.agents/skills")
    }

    // MARK: - Helpers

    /// The grid after Start your library on Juniper, read as the screen reads
    /// it.
    private func placement(_ fixture: LaunchpadFixture) async throws -> (LaunchpadPlacement, LaunchpadFlow, LaunchpadSample) {
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)
        return (placement, flow, sample)
    }

    /// Tracks a project, "storefront", with its folder on this Mac, and
    /// returns its ID.
    private func trackProject(in sample: LaunchpadSample, _ fixture: LaunchpadFixture) async throws -> ArtifactID {
        let workspace = sample.workspace
        _ = try await workspace.service.createProject(.init(expectedRevisionID: try fixture.head(of: workspace), name: "storefront"))
        let project = try #require(try workspace.store.snapshot()?.document.logicalProjects.first { $0.name == "storefront" })
        try await workspace.service.bindProjectRoot(
            projectID: project.id, rootPath: fixture.home.appending(path: "code/storefront").path(percentEncoded: false),
            expectedRevisionID: try fixture.head(of: workspace))
        return project.id
    }

    private func cells(_ placement: LaunchpadPlacement) -> [[Cell?]] {
        placement.items.map { item in
            placement.apps.map { placement.cells[.init(item: item.artifactID, app: $0)] }
        }
    }

    private func key(_ placement: LaunchpadPlacement, _ row: Int, _ app: ClientKind) -> Key {
        Key(item: placement.items[row].artifactID, app: app)
    }

    private func pressPrimary(_ flow: LaunchpadFlow, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary, sourceLocation: sourceLocation)
        #expect(primary.isEnabled, "\(flow.step)'s primary is disabled", sourceLocation: sourceLocation)
        primary.action()
    }
}
