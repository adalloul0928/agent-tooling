import AgentToolingCore
import Testing

@testable import AgentToolingApp

/// The words of Put tools in apps (S10), pinned: the fragment's header,
/// Where row, cells, row subtitles, captions, empty card and footer note, and
/// plan §6's new sentences ("Track a project first, on Projects." and the
/// unchecked app's caption). The style rules hold all of them to the house
/// rules as well.
@Suite("Launchpad place wording")
struct LaunchpadPlaceWordingTests {
    private let copy = LaunchpadCopy.Place.self

    @Test func theHeader() {
        #expect(copy.eyebrow == "Put in apps")
        #expect(copy.title == "Put your tools in your apps")
        #expect(copy.subtitle == "Choose which apps get each tool. Nothing is installed until you review it.")
    }

    @Test func theWhereRow() {
        #expect(copy.whereLabel == "Where")
        #expect([copy.everyMac, copy.thisMacOnly, copy.oneProject] == ["Every Mac", "This Mac only", "One project"])
        #expect(copy.everyMacLater == "Macs that join later get it too.")
        #expect(copy.everyMacOthers == "Your other Macs get it too.")
        #expect(copy.thisMacOnlyNote == "Other Macs are left out.")
        #expect(copy.forProject("storefront") == "For storefront only, on this Mac.")
        #expect(copy.chooseProject == "Choose a project…")
        #expect(copy.trackProjectFirst == "Track a project first, on Projects.")
    }

    @Test func theCells() {
        #expect([copy.willInstall, copy.add, copy.hasIt, copy.leftAlone] == ["Will install", "Add", "Has it", "Left alone"])
        #expect(copy.through("Codex") == "Through Codex’s folder")
        #expect(copy.readsCopy(of: "Codex") == "Reads Codex’s copy")
        #expect(copy.readsFolder(of: "Codex") == "Reads Codex’s folder")
        #expect(copy.differentCopy(in: "Codex") == "Codex already has a different copy")
        #expect(copy.editedCopy(in: "Codex") == "Codex’s copy was edited since it was installed")
        #expect(copy.ownCatalog("Codex") == "Codex has its own catalog")
        #expect(copy.takesNoPlugins("Gemini CLI") == "Gemini CLI takes no plugins")
        #expect(copy.waitsForVersion == "Waits for a version")
        #expect(copy.pluginsForEveryProject == "Plugins go to every project")
        #expect(copy.cannotTakeIt == "Cannot take this here")
        #expect(copy.noVerifiedCopy == "No verified copy yet")
        #expect(copy.notSetUpHere == "Not set up on this Mac")
        #expect(copy.notOnThisMac == "Not on this Mac")
    }

    /// The reason a cell gives where nothing can go, from the planner's
    /// exclusion there. A plugin from another app's catalog says so whatever
    /// the planner stopped at, and so does any plugin in one project.
    @Test func whyNothingCanGoInACell() {
        func reason(
            _ exclusion: WorkspaceDeploymentExclusionReason, _ kind: ArtifactKind = .skill, in app: ClientKind = .claude,
            catalogs: Set<ClientKind> = [], scope: LaunchpadPlacement.Scope = .everyMac
        ) -> String {
            LaunchpadPlacement.reason(for: exclusion, kind: kind, in: app, catalogs: catalogs, scope: scope)
        }
        let claudeCodes: Set<ClientKind> = [.claude]

        #expect(reason(.missingNativeRoute, .nativePlugin, in: .codex, catalogs: claudeCodes) == "Codex has its own catalog")
        #expect(reason(.unknownClientVersion, .nativePlugin, in: .codex, catalogs: claudeCodes) == "Codex has its own catalog")
        // From the app's own catalog, with no install command for it here.
        #expect(reason(.missingNativeRoute, .nativePlugin, in: .claude, catalogs: claudeCodes) == "Cannot take this here")
        #expect(
            reason(.needsAssignmentReview, .nativePlugin, catalogs: claudeCodes, scope: .oneProject) == "Plugins go to every project")
        #expect(
            reason(.unknownClientVersion, .nativePlugin, catalogs: claudeCodes, scope: .oneProject) == "Plugins go to every project")
        #expect(
            reason(.missingNativeRoute, .nativePlugin, in: .codex, catalogs: claudeCodes, scope: .oneProject)
                == "Codex has its own catalog")
        #expect(reason(.unknownClientVersion) == "Waits for a version")
        #expect(reason(.missingContent) == "No verified copy yet")
        #expect(reason(.noDestination) == "Not on this Mac")
        #expect(reason(.needsAssignmentReview, .mcpServer) == "Not set up on this Mac")
        #expect(reason(.needsAssignmentReview) == "Cannot take this here")
        for exclusion in [WorkspaceDeploymentExclusionReason.unsupportedByAdapter, .trackedOwnership, .packageMember] {
            #expect(reason(exclusion) == "Cannot take this here")
        }
        #expect(reason(.alreadyPresent, .nativePlugin, in: .codex, catalogs: claudeCodes) == "Has it")
    }

    @Test func theRows() {
        #expect(copy.rowSubtitle(kind: copy.skill, source: "Personal library") == "Skill · Personal library")
        #expect(copy.rowSubtitle(kind: copy.plugin, source: copy.catalog(of: "Claude Code")) == "Plugin · Claude Code’s catalog")
        #expect(copy.connection == "Connection")
    }

    @Test func theCaptions() {
        #expect(
            copy.stayWithTheirApps("GitHub, Sentry and Linear", count: 3)
                == "GitHub, Sentry and Linear stay as their apps manage them.")
        #expect(copy.stayWithTheirApps("GitHub", count: 1) == "GitHub stays as its app manages it.")
        #expect(copy.placedOnceYours("Webapp Testing", count: 1) == "Webapp Testing can be placed once you make it yours.")
        #expect(
            copy.placedOnceYours("Frontend Design and Webapp Testing", count: 2)
                == "Frontend Design and Webapp Testing can be placed once you make them yours.")
        #expect(copy.off("Kiro CLI", count: 1) == "Kiro CLI is off on this Mac, so it has no column.")
        #expect(copy.off("Gemini CLI and Kiro CLI", count: 2) == "Gemini CLI and Kiro CLI are off on this Mac, so they have no columns.")
        #expect(
            copy.notChecked("Gemini CLI", count: 1)
                == "Gemini CLI was not checked, so it has no column yet. Place things there after the next check.")
        #expect(copy.notFound("Kiro CLI", count: 1) == "Kiro CLI is not on this Mac, so it has no column.")
        #expect(copy.reviewedNext == "Changes so far are reviewed after the next step.")
        #expect(copy.takesOnlyWhatNamesIt == "This Mac is set to take only what names it, so Every Mac leaves it out.")
    }

    @Test func theEmptyCard() {
        #expect(
            copy.nothingToPlace(appManaged: "GitHub, Sentry and Linear", count: 3)
                == "Nothing to place yet. Skills can be placed once they are yours; GitHub, Sentry and Linear stay as their apps manage them."
        )
        #expect(copy.nothingToPlace(appManaged: nil, count: 0) == "Nothing to place yet. Skills can be placed once they are yours.")
    }

    @Test func theFooterNote() {
        #expect(copy.changesSoFar(2) == "2 changes so far")
        #expect(copy.changesSoFar(1) == "1 change so far")
        #expect(copy.changesSoFar(0) == "No changes so far")
    }

    @Test func whatVoiceOverReads() {
        #expect(copy.cell("Release Notes", in: "Codex", copy.spokenWillInstall) == "Release Notes, Codex: will install")
        #expect(copy.cell("Release Notes", in: "Claude Code", copy.spokenHasIt) == "Release Notes, Claude Code: has it")
        #expect(
            copy.cell("Frontend Design", in: "Codex", copy.spokenLeftAlone(because: copy.differentCopy(in: "Codex")))
                == "Frontend Design, Codex: left alone. Codex already has a different copy.")
        #expect(
            copy.cell("Frontend Design", in: "Gemini CLI", copy.spokenReadsCopy(of: "Codex", in: "~/.agents/skills"))
                == "Frontend Design, Gemini CLI: left alone. It reads Codex’s own copy in ~/.agents/skills.")
        #expect(copy.spokenThrough("Codex") == "through Codex’s folder")
        #expect(copy.spokenAdd == "can be added")
        #expect(copy.spokenTurnOff == "Press Space to leave it out.")
        #expect(copy.spokenTurnOn == "Press Space to add it.")
    }

    @Test func whyTheStepWasPassedOver() {
        #expect(copy.skippedNoApps == "Nothing was put in apps, because this Mac manages no app.")
    }

    @Test func theFailures() {
        #expect(copy.Failures.notChecked == "This Mac’s apps could not be checked. Nothing was changed.")
        #expect(copy.Failures.notSaved == "Where your tools go could not be saved. Nothing was changed.")
    }
}
