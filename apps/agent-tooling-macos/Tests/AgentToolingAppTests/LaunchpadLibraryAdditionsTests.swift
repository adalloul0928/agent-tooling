import AgentToolingTestSupport
import CryptoKit
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Start your library (S08) on the sample world: what it offers, what ticking
/// and picking do, and the one revision Add writes, with nothing in an app's
/// folder changed and no app's tool run.
@Suite("Launchpad library additions", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadLibraryAdditionsTests {
    // MARK: What it offers

    @Test func juniperOffersItsThreeLooseSkillsAsTheMockupDrawsThem() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)

        #expect(model.showsSkills)
        #expect(model.rows.map(\.name) == ["Release Notes", "Frontend Design", "Webapp Testing"], "the newest change first")
        let releaseNotes = try #require(model.rows.first)
        #expect(releaseNotes.sameness == .one)
        #expect(model.detail(for: releaseNotes).clause == "Only in Claude Code")
        #expect(model.detail(for: releaseNotes).path == "~/.claude/skills/release-notes")
        #expect(model.marksLabel(for: releaseNotes) == "In Claude Code")

        let design = model.rows[1]
        #expect(design.sameness == .different)
        #expect(model.detail(for: design).clause == "Codex and Claude Code have different copies. Choose which copy to bring in:")
        #expect(model.options(for: design).map(\.title) == ["Codex’s copy", "Claude Code’s copy"], "in the app order")
        #expect(model.options(for: design).map(\.detail) == ["2 files · changed Aug 14", "3 files · changed Oct 2"])
        #expect(model.chosenCopy(for: design)?.readers == [.claude], "the chooser starts on the newer copy")
        #expect(model.chooserCaption(for: design) == "Codex’s copy is older (2 files, Aug 14). It stays in Codex either way.")
        #expect(model.copyRefusal(for: design) == nil)
        #expect(model.marksLabel(for: design) == "In Codex, Claude Code and Gemini CLI")

        let testing = model.rows[2]
        #expect(testing.sameness == .same)
        #expect(model.detail(for: testing).clause == "Same in Codex and Claude Code")
        #expect(model.marksLabel(for: testing) == "In Codex and Claude Code")

        #expect(model.picks.map(\.entry.name) == ["Supabase", "Vercel", "GitHub for Codex", "MCP Builder"])
        #expect(
            model.picks.map(model.source(for:)) == [
                "Claude Code’s catalog", "Claude Code’s catalog", "Codex’s catalog · separate from Claude Code’s GitHub",
                "skills.sh · anthropics/skills",
            ])
        #expect(model.picks.allSatisfy { $0.state == .available })
        #expect(model.cardRefusals.isEmpty)
        #expect(model.leftAlone.isEmpty)
        #expect(
            model.finePrint
                == "Skills inside plugins, like Triage Issue in Sentry, stay with their plugin. Skills you leave stay where they are, and Checkup keeps listing them."
        )
    }

    @Test func nothingIsTickedUntilThePersonTicksIt() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)

        #expect(model.ticked.isEmpty)
        #expect(model.picked.isEmpty)
        #expect(model.count == 0)
        #expect(model.primaryTitle == "Continue")
        #expect(model.addAllTitle == "Add all 3 to library")
        #expect(model.canAddAll)
    }

    @Test func pickingACopyTicksItsRow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let design = model.rows[1]
        let codexCopy = try #require(design.copies.first)

        model.choose(codexCopy.path, for: design.id)

        #expect(model.ticked == [design.id])
        #expect(model.chosenCopy(for: design)?.readers == [.codex, .gemini])
        #expect(model.chooserCaption(for: design) == "Claude Code’s copy is newer (3 files, Oct 2). It stays in Claude Code either way.")
        #expect(model.primaryTitle == "Add 1 to library")
        // Choosing again keeps the row ticked; the checkbox unticks it.
        model.choose(codexCopy.path, for: design.id)
        #expect(model.ticked == [design.id])
        model.toggle(design.id)
        #expect(model.ticked.isEmpty)
    }

    @Test func theCountFollowsTicksAndPicks() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)

        for row in model.rows { model.toggle(row.id) }
        #expect(model.primaryTitle == "Add 3 to library")
        model.togglePick("claude:supabase@claude-plugins-official")
        #expect(model.primaryTitle == "Add 4 to library")
        model.toggle(model.rows[2].id)
        #expect(model.primaryTitle == "Add 3 to library")
    }

    /// ⌘A does what its button says, "Add all 3 to library": it ticks every
    /// skill and adds them, with the card already picked, in the one
    /// revision ↩ writes, then moves on as ↩ does.
    @Test func commandAAddsEverySkillWithThePicksInOneRevisionAndMovesOn() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let flow = model.flow
        let workspace = try #require(flow.workspace)
        let head = try fixture.head(of: workspace)
        model.togglePick("claude:supabase@claude-plugins-official")

        model.addAll()
        #expect(model.ticked == Set(model.rows.map(\.id)), "every skill is ticked first")
        #expect(!model.canAddAll, "and a second press does nothing while it adds")
        await model.commitTask?.value

        #expect(flow.step == .place, "everything landed, so the stage moved on")
        let saved = try #require(try workspace.store.snapshot())
        #expect(saved.document.revision.parentIDs == [head], "the three skills and Supabase in one revision")
        #expect(flow.decisions.adopted.map(\.name) == ["Release Notes", "Frontend Design", "Webapp Testing"])
        #expect(flow.decisions.adopted[1].copyFrom == .claude, "Frontend Design from the copy the chooser was on")
        #expect(flow.decisions.added.map(\.name) == ["Supabase"])
    }

    @Test func continueWithNothingTickedWritesNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let head = try fixture.head(of: model.flow.workspace!)

        #expect(await model.commit())

        #expect(try fixture.head(of: model.flow.workspace!) == head)
        #expect(model.flow.decisions == LaunchpadLibraryDecisions())
    }

    // MARK: The keyboard

    /// ↑↓ go through the rows and on to the cards, ←→ along the cards, and
    /// ←→ on a row whose apps hold different copies choose a copy, ticking
    /// the row as a click on the copy does.
    @Test func theArrowsMoveThroughTheRowsAndCardsAndChooseACopy() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let rows = model.rows.map(\.id)
        let cards = model.picks.map(\.id)

        #expect(model.focus(after: .row(rows[0]), moving: .down) == .row(rows[1]))
        #expect(model.focus(after: .row(rows[0]), moving: .up) == nil)
        #expect(model.focus(after: .row(rows[2]), moving: .down) == .card(cards[0]), "on from the last row to the cards")
        #expect(model.focus(after: .card(cards[2]), moving: .up) == .row(rows[2]))
        #expect(model.focus(after: .card(cards[0]), moving: .right) == .card(cards[1]))
        #expect(model.focus(after: .card(cards[0]), moving: .left) == nil)
        #expect(model.focus(after: .card(cards[3]), moving: .right) == nil)
        #expect(model.focus(after: .row(rows[0]), moving: .left) == nil)

        #expect(model.stepCopy(of: rows[1], by: -1), "← on Frontend Design: Codex's copy")
        #expect(model.chosenCopy(for: model.rows[1])?.readers.first == .codex)
        #expect(model.ticked == [rows[1]])
        #expect(!model.stepCopy(of: rows[1], by: -1), "there is no copy before Codex's")
        #expect(!model.stepCopy(of: rows[0], by: 1), "Release Notes has one copy, so nothing to choose")
    }

    // MARK: The primary

    @Test func continueWithNothingTickedMovesOnAtOnce() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let flow = model.flow
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Continue")
        #expect(primary.isEnabled)

        primary.action()

        #expect(flow.step == .place)
        #expect(flow.decisions == LaunchpadLibraryDecisions())
    }

    /// ↩ on the mockup's choices adds them, then moves on to Put in apps,
    /// which the record keeps as the cursor.
    @Test func addingWithThePrimaryMovesOnOnceEverythingLanded() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let flow = model.flow
        let workspace = try #require(flow.workspace)
        LaunchpadLibraryRenderTests.tickAsTheMockupDoes(model)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Add 3 to library")
        #expect(primary.key == .return, "adding to the library reaches no app, so it is ↩")

        primary.action()
        primary.action()
        await model.commitTask?.value

        #expect(flow.step == .place)
        #expect(flow.decisions.adopted.map(\.name) == ["Release Notes", "Frontend Design"], "a second press added nothing more")
        #expect(fixture.savedRecord(for: workspace)?.cursor == .place)
    }

    // MARK: Adding

    /// The acceptance: Release Notes and Frontend Design (Claude Code's copy)
    /// ticked and Supabase picked make exactly one revision, and no app file
    /// changes.
    @Test func theMockupsTicksAndPickAddThreeInOneRevisionAndTouchNoAppFile() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let workspace = try #require(model.flow.workspace)
        let head = try fixture.head(of: workspace)
        let before = try Self.files(under: fixture.home)
        let releaseNotes = model.rows[0]
        let design = model.rows[1]
        let claudeCopy = try #require(design.copies.first { $0.readers == [.claude] })

        model.toggle(releaseNotes.id)
        model.choose(claudeCopy.path, for: design.id)
        model.togglePick("claude:supabase@claude-plugins-official")
        #expect(model.primaryTitle == "Add 3 to library")
        let landed = await model.commit()

        #expect(landed, "everything asked for landed, so the stage moves on")
        let saved = try #require(try workspace.store.snapshot())
        #expect(saved.document.revision.parentIDs == [head], "exactly one revision")
        let document = saved.document
        let notes = try #require(document.artifacts.first { $0.identity.id == releaseNotes.id })
        let frontend = try #require(document.artifacts.first { $0.identity.id == design.id })
        #expect(notes.authority == .centralPersonal)
        #expect(frontend.authority == .centralPersonal)
        let claudeTree = try await WorkspaceSkillPreparation.capturePersonal(
            directory: URL(filePath: claudeCopy.path, directoryHint: .isDirectory))
        #expect(frontend.contentDigest == claudeTree.tree.digest, "Claude Code's copy is the one in the library")
        let supabase = try #require(document.artifacts.first { $0.declaredName == "supabase@claude-plugins-official" })
        #expect(supabase.authority == .nativeOwned)
        #expect(supabase.nativeRoutes == [.init(client: .claude, externalPluginID: "supabase@claude-plugins-official")])
        #expect(document.artifacts.first { $0.identity.id == model.rows[2].id }?.authority == .trackedOnly, "Webapp Testing was not ticked")
        #expect(document.assignments.isEmpty, "nothing is put in an app yet")
        #expect(try Self.files(under: fixture.home) == before, "no file in the apps' folders changed")

        #expect(
            model.flow.decisions.adopted == [
                .init(artifactID: releaseNotes.id, name: "Release Notes", copyFrom: nil),
                .init(artifactID: design.id, name: "Frontend Design", copyFrom: .claude),
            ])
        #expect(model.flow.decisions.added == [.init(artifactID: supabase.identity.id, name: "Supabase", source: .catalog(.claude))])
        #expect(model.flow.outcomes.addedPluginsAwaitingCheck == ["Supabase"])
        #expect(
            model.flow.decisions.lines == [
                "Made Release Notes yours", "Made Frontend Design yours, from Claude Code’s copy",
                "Added Supabase, from Claude Code’s catalog",
            ])
        #expect(model.rows[0].state == .added)
        #expect(model.rows[1].state == .added)
        #expect(model.detail(for: model.rows[0]).clause == "Personal library")
        #expect(model.picks.first?.state == .added)
        #expect(model.source(for: try #require(model.picks.first)) == "In library")
        #expect(model.primaryTitle == "Continue", "what landed is no longer counted")
    }

    @Test func theChosenCopysFilesAreWhatLands() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let design = model.rows[1]
        let codexCopy = try #require(design.copies.first { $0.readers.first == .codex })

        model.choose(codexCopy.path, for: design.id)
        #expect(await model.commit())

        let workspace = try #require(model.flow.workspace)
        let artifact = try #require(try workspace.store.snapshot()?.document.artifacts.first { $0.identity.id == design.id })
        let codexTree = try await WorkspaceSkillPreparation.capturePersonal(
            directory: URL(filePath: codexCopy.path, directoryHint: .isDirectory))
        #expect(artifact.contentDigest == codexTree.tree.digest)
        let stored = try await workspace.service.skillContent(
            artifactID: design.id, revisionID: try fixture.head(of: workspace))
        #expect(stored.tree == codexTree.tree)
        #expect(model.flow.decisions.adopted.first?.copyFrom == .codex)
    }

    /// Start your library reaches no app, whatever the person adds, writes
    /// or pastes. The workspace sessions take no runner a test could swap
    /// for one that refuses, so this holds what reaching an app would leave
    /// behind: no file an app reads changed, no operation ran or was
    /// receipted, nothing was installed or put in an app, no tool was looked
    /// for, no app was checked, no sign-in read and no catalog asked.
    @Test func startYourLibraryRunsNoAppCommandIncludingBothSheets() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let catalog = LibraryCountingCatalog()
        fixture.environment.sessions.marketplaceProviders = { _ in [catalog] }
        let model = try await Self.library(fixture)
        let workspace = try #require(model.flow.workspace)
        let checksBefore = (fixture.observer.fullChecks, fixture.observer.scopedChecks.count)
        let searchesBefore = fixture.setup.searchPathCalls
        let receiptsBefore = try workspace.store.operationReceipts().map(\.id)
        let filesBefore = try Self.files(under: fixture.home)

        for row in model.rows { model.toggle(row.id) }
        model.togglePick("claude:supabase@claude-plugins-official")
        model.togglePick("skills-sh:anthropics/skills/mcp-builder")
        #expect(await model.commit())
        // Write your own…: the editor's Create skill.
        var draft = SkillDraft()
        draft.name = "code-review"
        draft.purpose = "Reviews a change before it is merged."
        draft.triggers = ["Review this pull request"]
        draft.negativeTrigger = "Fix the failing test"
        #expect(await model.write(draft))
        // Paste a command or URL…: a SKILL.md read as the sheet reads it,
        // saved by the sheet's own Create skill, and what it saved told to
        // the stage as the sheet tells it.
        let pasted = try Self.pastedSkill("---\nname: triage-notes\ndescription: Notes for triage.\n---\n\nTriage it.\n")
        let saved = try #require(try await PasteImportSheet.saveSkill(pasted, in: workspace))
        model.pasteSaved(saved.artifactID, name: saved.name)

        #expect(try Self.files(under: fixture.home) == filesBefore, "no file an app reads changed")
        #expect(try workspace.store.operationReceipts().map(\.id) == receiptsBefore, "no operation ran")
        #expect(workspace.deployment.results.isEmpty, "nothing was installed")
        #expect(try workspace.store.snapshot()?.document.assignments.isEmpty == true, "nothing was put in an app")
        #expect(fixture.setup.searchPathCalls == searchesBefore, "no tool was looked for")
        #expect(fixture.observer.fullChecks == checksBefore.0, "no app was checked")
        #expect(fixture.observer.scopedChecks.count == checksBefore.1)
        #expect(fixture.signIn.reads.isEmpty, "no sign-in was read")
        #expect(await catalog.searches == 0, "no catalog was asked")
        #expect(workspace.marketplace.lastRefreshedAt == nil)
        #expect(
            model.flow.decisions.added.map(\.source) == [.catalog(.claude), .skillsSh, .written, .pasted],
            "\(model.flow.decisions.added)")
        #expect(model.flow.decisions.added.suffix(2).map(\.name) == ["Code Review", "triage-notes"])
        #expect(model.flow.decisions.added.last?.artifactID == saved.artifactID, "exactly what the sheet saved")
        #expect(model.savedLine == "Added triage-notes, from a pasted command")
    }

    @Test func aWrittenSkillJoinsTheLibraryAsWrittenHere() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let workspace = try #require(model.flow.workspace)
        let head = try fixture.head(of: workspace)
        var draft = SkillDraft()
        draft.name = "code-review"
        draft.purpose = "Reviews a change before it is merged."
        draft.triggers = ["Review this pull request"]
        draft.negativeTrigger = "Fix the failing test"

        #expect(await model.write(draft))

        let saved = try #require(try workspace.store.snapshot())
        #expect(saved.document.revision.parentIDs == [head], "the editor's save is its own revision")
        let written = try #require(saved.document.artifacts.first { $0.declaredName == "code-review" })
        #expect(written.authority == .centralPersonal)
        #expect(model.flow.decisions.added == [.init(artifactID: written.identity.id, name: "Code Review", source: .written)])
        #expect(model.savedLine == "Added Code Review, written here")
        #expect(model.existingNames.contains("Code Review"))
        #expect(model.writeFailure == nil)
    }

    /// A skill the editor cannot save says why, as the Library's editor
    /// does, and the library is as it was.
    @Test func aWrittenSkillTheLibraryRefusesSaysWhy() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let workspace = try #require(model.flow.workspace)
        var draft = SkillDraft()
        draft.name = "release/notes"
        draft.purpose = "Drafts release notes."
        draft.triggers = ["Write the release notes"]
        let head = try fixture.head(of: workspace)

        #expect(!(await model.write(draft)))

        #expect(model.writeFailure == "Use lowercase letters, numbers and single hyphens for the name. Nothing was changed.")
        #expect(try fixture.head(of: workspace) == head)
        #expect(model.flow.decisions.added.isEmpty)
        let failures = LaunchpadCopy.Library.Failures.self
        let failure = LaunchpadLibraryAdditions.saveFailure(for:)
        #expect(failure(WorkspaceSkillCommandError.identityCollision) == failures.nameTaken)
        #expect(failure(WorkspaceSkillCommandError.contentStoreUnavailable) == failures.contentUnreachable)
        #expect(failure(WorkspaceSkillCommandError.reviewMismatch) == failures.libraryMoved)
        #expect(failure(WorkspaceRevisionStoreError.staleRevision(current: head)) == failures.libraryMoved)
        #expect(failure(WorkspaceSkillPreparationError.invalidSkillDefinition) == failures.incompleteDefinition)
        #expect(failure(CocoaError(.fileWriteUnknown)) == failures.notSaved)
    }

    @Test func aSkillsShPickIsFetchedFirstAndJoinsTheSameRevision() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let fetches = LibraryFetchLog()
        let model = try await Self.library(fixture, services: Self.services(fetches: fetches))
        let workspace = try #require(model.flow.workspace)
        let head = try fixture.head(of: workspace)

        model.toggle(model.rows[0].id)
        model.togglePick("skills-sh:anthropics/skills/mcp-builder")
        #expect(await model.commit())

        #expect(fetches.asked == ["anthropics/skills mcp-builder"])
        let saved = try #require(try workspace.store.snapshot())
        #expect(saved.document.revision.parentIDs == [head], "the fetched skill shares the one revision")
        let builder = try #require(saved.document.artifacts.first { $0.declaredName == "mcp-builder" })
        guard case .centralUpstream = builder.authority else {
            Issue.record("a skills.sh skill follows its repository: \(builder.authority)")
            return
        }
        #expect(model.flow.decisions.added == [.init(artifactID: builder.identity.id, name: "MCP Builder", source: .skillsSh)])
        #expect(model.flow.outcomes.addedPluginsAwaitingCheck.isEmpty, "a skill is not a plugin awaiting a check")
    }

    /// The card that failed keeps its summary, marks its last line, and says
    /// why under the cards, in a sentence about it alone: Supabase, picked
    /// with it, landed.
    @Test func aFetchThatFailsSaysSoUnderTheCardsAndTheRestLands() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture, services: Self.services(fetches: LibraryFetchLog(), failing: true))

        model.togglePick("claude:supabase@claude-plugins-official")
        model.togglePick("skills-sh:anthropics/skills/mcp-builder")
        let movedOn = await model.commit()

        #expect(!movedOn, "the card that failed is there to read")
        let builder = try #require(model.picks.first { $0.id == "skills-sh:anthropics/skills/mcp-builder" })
        let sentence = "MCP Builder could not be fetched from its repository, so it was not added."
        #expect(builder.state == .refused(sentence))
        #expect(builder.isRefused)
        #expect(model.summary(for: builder) == "Guides building an MCP server.", "the card keeps its summary")
        #expect(model.source(for: builder) == "Not added")
        #expect(model.cardRefusals == [sentence])
        #expect(model.accessibilityLabel(for: builder) == "MCP Builder, Guides building an MCP server. \(sentence)")
        #expect(model.failure == nil, "the Add wrote Supabase, so nothing says it wrote nothing")
        #expect(model.picks.first?.state == .added, "Supabase landed")
        #expect(model.flow.decisions.added.map(\.name) == ["Supabase"])
    }

    @Test func withoutGitASkillsShCardReadsNeedsGitAndCannotBePicked() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture, services: Self.services(fetches: LibraryFetchLog(), hasGit: false))
        let builder = try #require(model.picks.last)

        #expect(builder.state == .needsGit)
        #expect(model.source(for: builder) == "skills.sh · anthropics/skills · Needs Git")
        model.togglePick(builder.id)
        #expect(model.picked.isEmpty)
    }

    @Test func aListingTheLibraryHoldsReadsInLibrary() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try await Self.flow(fixture)
        let workspace = try #require(flow.workspace)
        _ = try await workspace.service.adoptNativePackage(
            .init(expectedRevisionID: try fixture.head(of: workspace), package: LaunchpadFixture.supabaseListing, client: .claude))
        await workspace.library.refresh()
        let model = LaunchpadLibraryAdditions.of(flow)
        model.services = Self.services(fetches: LibraryFetchLog())
        await model.load()

        let supabase = try #require(model.picks.first)
        #expect(supabase.state == .inLibrary, "the library held it before this setup")
        #expect(!model.isPicked(supabase))
        #expect(model.source(for: supabase) == "In library")
        model.togglePick(supabase.id)
        #expect(model.picked.isEmpty)
    }

    /// An install count is shown only when a catalog was read in this
    /// launch and reported one: the page this Mac keeps holds none, so a
    /// first run's shelf shows none.
    @Test func aCatalogsInstallCountShowsOnlyFromALiveRead() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let listed = try #require(
            StarterShelf.packages(retained: []).last.map { package -> MarketplacePackage in
                var listed = package
                listed.installCount = 12_400
                return listed
            })
        fixture.environment.sessions.marketplaceProviders = { _ in [StubMarketplaceProvider(packages: [listed])] }
        let flow = try await Self.flow(fixture)
        let workspace = try #require(flow.workspace)
        let kept = LaunchpadLibraryAdditions(flow: flow, services: Self.services(fetches: LibraryFetchLog()))
        await kept.load()
        #expect(kept.source(for: try #require(kept.picks.last)) == "skills.sh · anthropics/skills", "no read, no count")

        // The shell's Discover reads its catalogs in this launch.
        await workspace.marketplace.refresh()
        let model = LaunchpadLibraryAdditions(flow: flow, services: Self.services(fetches: LibraryFetchLog()))
        await model.load()

        #expect(model.source(for: try #require(model.picks.last)) == "skills.sh · anthropics/skills · 12.4k installs")
        #expect(model.source(for: model.picks[0]) == "Claude Code’s catalog", "no count where no catalog gave one")
    }

    /// When this launch read the catalogs and skills.sh could not be
    /// reached, the shelf says so under its label; with no read, it says
    /// nothing.
    @Test func skillsShUnreachableIsSaidUnderTheCatalogLabel() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        fixture.environment.sessions.marketplaceProviders = { _ in
            [StubMarketplaceProvider(id: "skills-sh.registry", displayName: "skills.sh", packages: [], fails: true)]
        }
        let flow = try await Self.flow(fixture)
        let workspace = try #require(flow.workspace)
        let unread = LaunchpadLibraryAdditions(flow: flow, services: Self.services(fetches: LibraryFetchLog()))
        await unread.load()
        #expect(unread.offlineNote == nil)

        await workspace.marketplace.refresh()
        let model = LaunchpadLibraryAdditions(flow: flow, services: Self.services(fetches: LibraryFetchLog()))
        await model.load()

        #expect(model.offlineNote == "skills.sh could not be reached.")
    }

    // MARK: Stopping

    /// Stop ⎋ while a skills.sh pick is fetched: the fetch stops, nothing is
    /// written, and every tick and pick is there for the next Add.
    @Test func stopWhileAPickIsFetchedWritesNothingAndKeepsEveryTick() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture, services: Self.heldFetch())
        let flow = model.flow
        let workspace = try #require(flow.workspace)
        let head = try fixture.head(of: workspace)
        let notes = model.rows[0].id
        #expect(model.interruption == .idle)
        model.toggle(notes)
        model.togglePick("skills-sh:anthropics/skills/mcp-builder")

        model.addAndMoveOn()
        await waitUntil { model.isFetching }
        #expect(model.interruption == .stoppable)
        #expect(flow.interruption == .stoppable, "a quit stops it first")
        guard case .stop(let stop) = LaunchpadStageView.footer(for: flow).later else {
            Issue.record("the footer offers Stop ⎋ while a pick is fetched")
            return
        }
        stop()
        await model.commitTask?.value

        #expect(try fixture.head(of: workspace) == head, "nothing was written")
        #expect(flow.step == .library)
        #expect(model.ticked == [notes])
        #expect(model.picked == ["skills-sh:anthropics/skills/mcp-builder"])
        #expect(model.rows[0].state == .ready)
        #expect(model.picks.last?.state == .available)
        #expect(model.failure == nil)
        #expect(model.cardRefusals.isEmpty, "a stopped fetch is not a failed one")
        #expect(model.interruption == .idle)
        guard case .setUpLater = LaunchpadStageView.footer(for: flow).later else {
            Issue.record("Set up later is back once nothing is fetched")
            return
        }
    }

    /// A quit while a pick is fetched stops the fetch and waits for it, and
    /// nothing is written.
    @Test func aQuitStopsAFetchAndWritesNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture, services: Self.heldFetch())
        let flow = model.flow
        let workspace = try #require(flow.workspace)
        let head = try fixture.head(of: workspace)
        model.togglePick("skills-sh:anthropics/skills/mcp-builder")
        model.addAndMoveOn()
        await waitUntil { model.isFetching }

        await flow.prepareToQuit()

        #expect(model.commitTask == nil, "the Add ended before the quit went on")
        #expect(try fixture.head(of: workspace) == head)
        #expect(flow.interruption == .idle)
    }

    // MARK: Refusals

    @Test func aSkillMDThatNamesAnotherSkillIsRefusedOnItsRowAndTheRestLand() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        // Release Notes' folder is still release-notes, but its SKILL.md now
        // calls it notes-for-releases.
        try fixture.world.home.plant(
            ".claude/skills/release-notes/SKILL.md",
            "---\nname: notes-for-releases\ndescription: Drafts release notes from merged pull requests.\n---\n\nRead the merged pull requests.\n"
        )
        let model = try await Self.library(fixture)
        let notes = try #require(model.rows.first { $0.copies.first?.path.hasSuffix("/release-notes") == true })
        let testing = try #require(model.rows.first { $0.name == "Webapp Testing" })

        model.toggle(notes.id)
        model.toggle(testing.id)
        let movedOn = await model.commit()

        #expect(!movedOn)
        let refused = try #require(model.rows.first { $0.id == notes.id })
        let sentence = "Its SKILL.md calls it notes-for-releases, not release-notes, so it cannot be added yet. Rename one to match."
        #expect(refused.state == .refused(sentence), "with no other copy to choose, the row is refused")
        #expect(model.detail(for: refused).clause == sentence)
        #expect(model.rows.first { $0.id == testing.id }?.state == .added)
        #expect(model.flow.decisions.adopted.map(\.name) == ["Webapp Testing"])
        #expect(!model.ticked.contains(notes.id), "a refused row is no longer ticked")
        model.toggle(notes.id)
        #expect(!model.ticked.contains(notes.id), "and cannot be ticked again")
    }

    /// The fragment's own refusal: Claude Code's copy of Frontend Design
    /// calls itself frontend-ui. The row stays a chooser, unticked, with the
    /// sentence under it while that copy is chosen, so Codex's copy can still
    /// be brought in.
    @Test func aChosenCopyTheLibraryWillNotTakeLeavesTheOtherCopyToChoose() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.libraryWithClaudesCopyRenamed(fixture)
        let design = try #require(model.rows.first { $0.name == "Frontend Design" })
        let claude = try #require(design.copies.first { $0.readers == [.claude] })
        let codex = try #require(design.copies.first { $0.readers.first == .codex })

        model.choose(claude.path, for: design.id)
        #expect(!(await model.commit()))

        let row = try #require(model.rows.first { $0.id == design.id })
        let sentence = "Its SKILL.md calls it frontend-ui, not frontend-design, so it cannot be added yet. Rename one to match."
        #expect(row.state == .ready, "the row stays open")
        #expect(!model.ticked.contains(design.id), "and unticked")
        #expect(model.chosenCopy(for: row)?.path == claude.path)
        #expect(model.copyRefusal(for: row) == sentence)
        #expect(model.accessibilityLabel(for: row).hasSuffix(sentence))

        model.choose(codex.path, for: design.id)
        #expect(model.ticked == [design.id], "choosing the other copy ticks the row")
        #expect(model.copyRefusal(for: row) == nil, "the sentence is about Claude Code's copy alone")
        #expect(await model.commit())
        #expect(model.rows.first { $0.id == design.id }?.state == .added)
        #expect(model.flow.decisions.adopted == [.init(artifactID: design.id, name: "Frontend Design", copyFrom: .codex)])
    }

    /// A row whose record the library will not take from any copy says so on
    /// its own line, drawn as a tall row: there is nothing left to choose.
    @Test func aRowNoCopyCanMakeYoursIsRefusedOnItsLine() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let workspace = try #require(model.flow.workspace)
        let design = try #require(model.rows.first { $0.name == "Frontend Design" })
        // Behind the screen's back, Checkup makes it yours first.
        _ = await workspace.setup.adopt(paths: [try #require(design.copies.last).path])

        model.toggle(design.id)
        #expect(!(await model.commit()))

        #expect(model.rows.first { $0.id == design.id }?.state == .refused("It is in your library already."))
        #expect(model.copyRefusals.isEmpty, "it is not about the copy")
    }

    @Test func skillsAnotherToolKeepsInStepAreLeftAlone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try await Self.flow(fixture)
        let workspace = try #require(flow.workspace)
        // The check found Release Notes placed and kept in step by Example Manager.
        let observations = workspace.device.observations.map { observation -> TargetObservation in
            var observation = observation
            if observation.surface.client == .claude {
                observation.skillMetadata["release-notes"]?.externalManager = ObservedExternalManager(tool: "Example Manager")
            }
            return observation
        }
        await workspace.device.adopt(observations)
        await workspace.library.refresh()
        let model = LaunchpadLibraryAdditions.of(flow)
        model.services = Self.services(fetches: LibraryFetchLog())
        await model.load()

        #expect(model.rows.map(\.name) == ["Frontend Design", "Webapp Testing"])
        #expect(model.leftAlone == [.init(manager: "Example Manager", names: ["Release Notes"])])
        #expect(LaunchpadCopy.Library.keptInStep(by: "Example Manager") == "Kept in step by Example Manager — left alone")
        #expect(model.addAllTitle == "Add all 2 to library")
    }

    // MARK: Copies

    /// Three managed apps holding three different copies: three cells, two
    /// to a row, and the row as much taller as the chooser's second row of
    /// cells is.
    @Test func threeDifferentCopiesAreThreeCellsAndMakeTheRowTaller() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.threeCopies(fixture)
        let design = try #require(model.rows.first { $0.name == "Frontend Design" })

        #expect(design.sameness == .different)
        #expect(model.options(for: design).map(\.title) == ["Codex’s copy", "Claude Code’s copy", "Gemini CLI’s copy"])
        #expect(
            model.detail(for: design).clause == "Codex, Claude Code and Gemini CLI have different copies. Choose which copy to bring in:")
        #expect(model.chooserCaption(for: design) == "The other copies stay where they are either way.")
        let layout = StageLayout.CopyChooser.self
        #expect(layout.extraHeight(forCopies: 2) == 0)
        #expect(layout.extraHeight(forCopies: 3) == layout.cell.height + layout.cellGap)
        #expect(layout.extraHeight(forCopies: 5) == (layout.cell.height + layout.cellGap) * 2)
    }

    // MARK: Empty Macs and coming back

    /// Continue without apps (V01): only the catalogs apply, so the screen
    /// leaves its first section out, and its fine print with it.
    @Test func aMacThatManagesNoAppShowsOnlyTheCatalogs() async throws {
        let fixture = try await LaunchpadFixture(.emptyMac)
        defer { fixture.remove() }
        let model = try await Self.library(fixture)

        #expect(!model.showsSkills)
        #expect(model.rows.isEmpty)
        #expect(model.primaryTitle == "Continue")
        #expect(model.picks.count == 4, "the shelf is there with no apps")
    }

    /// Apps whose skills are all the library's already: section A is one
    /// line, and the primary reads Continue.
    @Test func appsWhoseSkillsAreAllYoursSayItInOneLine() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try await Self.flow(fixture)
        let workspace = try #require(flow.workspace)
        let skills = fixture.home.appending(path: ".claude/skills", directoryHint: .isDirectory)
        _ = await workspace.setup.adopt(
            paths: ["release-notes", "frontend-design", "webapp-testing"].map {
                skills.appending(path: $0).path(percentEncoded: false)
            })
        await workspace.library.refresh()
        let model = LaunchpadLibraryAdditions.of(flow)
        model.services = Self.services(fetches: LibraryFetchLog())
        await model.load()

        #expect(model.showsSkills)
        #expect(model.rows.isEmpty)
        #expect(model.emptyLine == "Every skill your apps hold is in your library already.")
        #expect(model.primaryTitle == "Continue")
    }

    @Test func appsThatHoldNoLooseSkillSayItInOneLine() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try await Self.flow(fixture)
        let workspace = try #require(flow.workspace)
        let observations = workspace.device.observations.map { observation -> TargetObservation in
            var observation = observation
            observation.skillMetadata = observation.skillMetadata.filter { $0.value.providerPluginID != nil }
            return observation
        }
        await workspace.device.adopt(observations)
        await workspace.library.refresh()
        let model = LaunchpadLibraryAdditions.of(flow)
        model.services = Self.services(fetches: LibraryFetchLog())
        await model.load()

        #expect(model.showsSkills)
        #expect(model.rows.isEmpty)
        #expect(model.emptyLine == "Your apps hold no skills of their own to bring in.")
    }

    /// The stage back on this screen afresh, after Start your library: the
    /// skills it made yours read ticked "Personal library", and the listing
    /// it added reads added and picked, as both did when they landed.
    @Test func goingBackShowsWhatThisSetupAddedAsAdded() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await fixture.flow(at: .afterLibrary)
        let model = LaunchpadLibraryAdditions.of(flow)
        model.services = Self.services(fetches: LibraryFetchLog())
        await model.load()

        #expect(model.rows.map(\.name) == ["Release Notes", "Frontend Design", "Webapp Testing"])
        #expect(model.rows.map(\.state) == [.added, .added, .ready])
        #expect(model.rows.prefix(2).allSatisfy(model.isTicked))
        let supabase = try #require(model.picks.first)
        #expect(supabase.state == .added)
        #expect(model.isPicked(supabase))
        #expect(model.source(for: supabase) == "In library")
        #expect(model.addAllTitle == "Add to library")
        #expect(model.primaryTitle == "Continue")
    }

    // MARK: Labels

    @Test func voiceOverReadsTheChooserAsARadioGroupAndTheCardsAsCheckboxes() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let model = try await Self.library(fixture)
        let design = model.rows[1]

        #expect(LaunchpadCopy.Library.chooserLabel(design.name) == "Copy of Frontend Design to bring in")
        #expect(
            model.options(for: design).map(\.accessibilityLabel) == [
                "Codex’s copy, 2 files, changed Aug 14", "Claude Code’s copy, 3 files, changed Oct 2",
            ])
        #expect(
            model.accessibilityLabel(for: model.rows[0])
                == "Release Notes, Only in Claude Code, ~/.claude/skills/release-notes")
        #expect(
            model.accessibilityLabel(for: try #require(model.picks.first))
                == "Supabase, Supabase database, auth and storage from Claude Code. Claude Code’s catalog")
    }

    // MARK: - Helpers

    /// The stage at Start your library over Juniper's library as read.
    static func flow(_ fixture: LaunchpadFixture) async throws -> LaunchpadFlow {
        let (_, sample) = try await fixture.flow(at: .afterRead)
        let flow = fixture.flow(.continueFirstRun(.library), workspace: sample.workspace)
        flow.seedOverride = fixture.seed
        flow.outcomes = sample.outcomes
        return flow
    }

    /// The screen's model, loaded, with services that reach nothing.
    static func library(
        _ fixture: LaunchpadFixture, services: LaunchpadLibraryServices? = nil
    ) async throws -> LaunchpadLibraryAdditions {
        let flow = try await flow(fixture)
        let model = LaunchpadLibraryAdditions.of(flow)
        model.services = services ?? Self.services(fetches: LibraryFetchLog())
        await model.load()
        return model
    }

    /// Juniper with a third copy of Frontend Design, Gemini CLI's own, unlike
    /// Codex's and Claude Code's: the screen's model over it, loaded.
    static func threeCopies(_ fixture: LaunchpadFixture) async throws -> LaunchpadLibraryAdditions {
        let flow = try await flow(fixture)
        let workspace = try #require(flow.workspace)
        try fixture.world.home.plantSkill(
            ".gemini/skills/frontend-design", name: "frontend-design", description: "Gemini CLI’s own way with UI.",
            instructions: "Sketch first.", modifiedAt: ClientHomeFixture.now.addingTimeInterval(-86_400))
        let gemini = fixture.home.appending(path: ".gemini/skills/frontend-design").path(percentEncoded: false)
        let observations = workspace.device.observations.map { observation -> TargetObservation in
            var observation = observation
            if observation.surface.client == .gemini {
                observation.skillMetadata["frontend-design"] = ObservedSkillMetadata(
                    path: gemini, source: "user", definitionDigest: String(repeating: "c", count: 64))
            }
            return observation
        }
        await workspace.device.adopt(observations)
        await workspace.library.refresh()
        let model = LaunchpadLibraryAdditions.of(flow)
        model.services = services(fetches: LibraryFetchLog())
        await model.load()
        return model
    }

    /// The screen's model, loaded, once Claude Code's copy of Frontend
    /// Design was renamed in its SKILL.md to frontend-ui after the check read
    /// it and the library recorded it: still the newer copy, and still
    /// Frontend Design in the library.
    static func libraryWithClaudesCopyRenamed(_ fixture: LaunchpadFixture) async throws -> LaunchpadLibraryAdditions {
        let flow = try await flow(fixture)
        try fixture.world.home.plantSkill(
            ".claude/skills/frontend-design", name: "frontend-ui", description: "Builds distinctive UI.",
            instructions: "Choose one visual direction.", modifiedAt: ClientHomeFixture.now.addingTimeInterval(-3_600))
        let model = LaunchpadLibraryAdditions.of(flow)
        model.services = services(fetches: LibraryFetchLog())
        await model.load()
        return model
    }

    /// Services that fetch a skills.sh skill from memory, and say this Mac
    /// has Git unless told otherwise.
    static func services(fetches: LibraryFetchLog, failing: Bool = false, hasGit: Bool = true) -> LaunchpadLibraryServices {
        LaunchpadLibraryServices(
            fetchSkill: { repository, skillID, _ in
                fetches.record("\(repository) \(skillID)")
                if failing { throw SkillRepositoryError.sourceMissing }
                return try Self.fetchedSkill(skillID, from: repository)
            },
            hasGit: { hasGit })
    }

    /// Services whose skills.sh fetch never ends until it is stopped.
    static func heldFetch() -> LaunchpadLibraryServices {
        LaunchpadLibraryServices(fetchSkill: { _, _, _ in try await LibraryHeldFetch.waitUntilStopped() }, hasGit: { true })
    }

    /// A skill as a fetch of `repository` would leave it.
    nonisolated static func fetchedSkill(_ skillID: String, from repository: String) throws -> PreparedStandaloneSkill {
        let markdown = "---\nname: \(skillID)\ndescription: Guides building an MCP server.\n---\n\nStart from the protocol.\n"
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data(markdown.utf8), executable: false))
        ])
        return try PreparedStandaloneSkill(
            tree: tree,
            upstream: PreparedSkillUpstream(
                repositoryURL: "https://github.com/\(repository)", requestedRef: "main",
                revision: .init(kind: .gitCommitSHA1, value: String(repeating: "a", count: 40)),
                packageRelativePath: "skills/\(skillID)", publisherID: "github:anthropics"))
    }

    /// A pasted SKILL.md, read into the draft the paste sheet reviews.
    static func pastedSkill(_ markdown: String) throws -> SkillDraft {
        guard case .skill(let pasted) = try PastedDefinitionParser.parse(markdown) else {
            throw LibraryTestError.notASkill
        }
        return pasted.draft
    }

    /// Every regular file under `root`, with its bytes' digest and its date:
    /// what an app reads, to prove none of it changed.
    static func files(under root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [:] }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            files[url.path(percentEncoded: false)] = "\(digest) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return files
    }
}

private enum LibraryTestError: Error {
    case notASkill
}

/// The skills.sh fetches a test's services were asked for.
final class LibraryFetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var asked: [String] { lock.withLock { log } }

    func record(_ fetch: String) {
        lock.withLock { log.append(fetch) }
    }
}

/// A catalog that counts how often it was asked anything.
actor LibraryCountingCatalog: MarketplaceProvider {
    nonisolated let id = "counting.catalog"
    nonisolated let displayName = "Counting catalog"
    private(set) var searches = 0

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        searches += 1
        return MarketplacePage(packages: [])
    }
}

/// A skills.sh fetch that hangs the way a slow repository does, without a
/// clock, until the task fetching it is cancelled.
enum LibraryHeldFetch {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<Void, any Error>?
        var isCancelled = false
    }

    /// Returns only by throwing `CancellationError`, once the calling task is
    /// cancelled.
    static func waitUntilStopped() async throws -> PreparedStandaloneSkill {
        let state = State()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.lock.withLock { () -> Bool in
                    if state.isCancelled { return true }
                    state.continuation = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiting = state.lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                state.isCancelled = true
                let waiting = state.continuation
                state.continuation = nil
                return waiting
            }
            waiting?.resume(throwing: CancellationError())
        }
        throw CancellationError()
    }
}
