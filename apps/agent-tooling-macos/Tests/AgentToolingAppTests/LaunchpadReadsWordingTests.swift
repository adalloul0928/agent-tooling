import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The words of Your apps, the read and what was found, pinned to the
/// fragments (03-s02-agents, 17-v01-empty, 04-s04-reads, 05-s06-found) and
/// to plan §6's rerun variants. Copy built from what the walk knows (the
/// read's counts, the sign-in variables, the sign-in reads) is checked
/// against the source it comes from.
@Suite("Launchpad reads wording", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadReadsWordingTests {
    // MARK: - S02 and V01

    @Test func yourAppsWords() {
        let apps = LaunchpadCopy.Apps.self
        #expect(apps.eyebrow == "Your coding agents")
        #expect(apps.title == "Choose the apps this Mac manages")
        #expect(
            apps.subtitle
                == "Codex, Claude Code, Gemini CLI and Kiro CLI are the coding agents Agent Tooling works with. Here they are your apps, under Apps in the sidebar."
        )
        #expect([apps.foundAt, apps.notFound, apps.whereLooked] == ["Found at", "Not found", "Where Agent Tooling looked…"])
        #expect(apps.whereLookedTitle == "Where Agent Tooling looked")
        #expect(apps.nothingFound("Kiro CLI") == "Nothing from Kiro CLI was found on this Mac.")
        #expect(apps.howToInstall("Kiro CLI") == "How to install Kiro CLI")
        #expect(apps.lookAgainWithLoginShell == "Look again with my login shell")
        #expect(apps.lookAgain == "Look again")
        #expect(apps.looking == "Looking…")
        #expect(apps.onlyLooked == "Agent Tooling has only looked for each app’s command. Nothing has been opened or run yet.")
        #expect(apps.turningOff == "Turning an app off changes nothing in it.")
        #expect([apps.manage(3), apps.manage(1), apps.manage(4)] == ["Manage 3 apps", "Manage 1 app", "Manage 4 apps"])
        #expect(apps.continueWithoutApps == "Continue without apps")
    }

    @Test func theEmptyMacsWords() {
        let apps = LaunchpadCopy.Apps.self
        #expect(apps.emptyTitle == "No apps found on this Mac yet")
        #expect(
            apps.emptySubtitle
                == "Codex, Claude Code, Gemini CLI and Kiro CLI are the coding agents Agent Tooling works with. Once one is installed, it is one of your apps, under Apps in the sidebar."
        )
        #expect(apps.worksWithout == "Your library works without an app; turn one on when it is installed.")
        #expect(
            ClientKind.allCases.map { apps.howToInstall($0.rawValue) } == [
                "How to install Codex", "How to install Claude Code", "How to install Gemini CLI", "How to install Kiro CLI",
            ])
    }

    @Test func whatTheLoginShellFound() {
        let apps = LaunchpadCopy.Apps.self
        #expect(apps.loginShellFound("Kiro CLI") == "Your login shell found Kiro CLI.")
        #expect(apps.loginShellFoundNothing("Gemini CLI and Kiro CLI") == "Your login shell does not know Gemini CLI and Kiro CLI either.")
    }

    // MARK: - S04

    @Test func theConsentsWords() {
        let reads = LaunchpadCopy.Reads.self
        #expect(reads.eyebrow == "Before anything is read")
        #expect(reads.title == "Agent Tooling looks before it changes anything")
        #expect(
            reads.lineOne(places: 14, commands: 9, apps: 3)
                == "It reads 14 places and runs 9 commands for the 3 apps you chose. Nothing leaves this Mac.")
        #expect(
            reads.lineOne(places: 4, commands: 3, apps: 1)
                == "It reads 4 places and runs 3 commands for the app you chose. Nothing leaves this Mac.")
        #expect(reads.lineTwo == "It writes one folder of its own, your library, and that comes last. Chat history is not read here.")
        #expect(
            reads.fork(mac: "Juniper")
                == "This starts a new library on Juniper. If your library is already on another Mac, go back and choose Join.")
        // A Mac whose name is not read yet, or that has none, is "this Mac"
        // in the sentence.
        let screen = LaunchpadTileSequenceScreen.self
        #expect([screen.forkName(nil), screen.forkName("This Mac"), screen.forkName("Juniper")] == ["this Mac", "this Mac", "Juniper"])
        #expect(
            reads.fork(mac: screen.forkName("This Mac"))
                == "This starts a new library on this Mac. If your library is already on another Mac, go back and choose Join.")
        #expect(reads.projectsTitle == "Also find projects from Claude Code’s history")
        #expect(
            String(LaunchpadTileSequenceScreen.projectsDetail(URL(filePath: "/Users/example", directoryHint: .isDirectory)).characters)
                == "Reads only the folder names in ~/.claude/projects, never the conversations in them.")
        #expect(reads.offNotRead == "Off · not read in this first read")
        #expect(reads.goBackToTurnOn == "Go back to turn it on.")
        #expect(reads.signInLabel == "How your apps sign in")
        #expect(reads.linkedSuffix("Codex") == "with Codex")
    }

    /// The header's counts are the manifest's, in both builds, and grow
    /// with Kiro CLI turned on (17 places, 10 commands).
    @Test func theConsentsCountsAreTheManifests() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)
        func lineOne() -> String {
            LaunchpadTileSequenceScreen.subtitle(.consent, flow: flow, read: read).components(separatedBy: "\n")[0]
        }

        #expect(lineOne() == "It reads 14 places and runs 9 commands for the 3 apps you chose. Nothing leaves this Mac.")
        let manifest = LaunchpadReadSession.plannedManifest(for: flow)
        #expect(manifest.placeCount == 14)
        #expect(manifest.commandCount == 9)
        flow.seedOverride?.findsProjectsFromClaudeHistory = false
        #expect(lineOne() == "It reads 13 places and runs 9 commands for the 3 apps you chose. Nothing leaves this Mac.")
        flow.seedOverride?.findsProjectsFromClaudeHistory = true
        flow.seedOverride?.chosen.insert(.kiro)
        #expect(lineOne() == "It reads 17 places and runs 10 commands for the 4 apps you chose. Nothing leaves this Mac.")
        flow.seedOverride?.chosen.remove(.kiro)
    }

    /// How the apps sign in is the manifest's own sign-in reads, Codex's
    /// first, and the caption's twelve variables are the overrides the
    /// login shell is asked about.
    @Test func theSignInStripIsTheSignInReads() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let manifest = FirstReadManifest.build(chosen: fixture.world.found, homeURL: fixture.home, includeProjectHistory: true)
        let shell = try #require(manifest.signIn.commands.last)

        #expect(manifest.signIn.commands.map(\.display) == ["codex app-server", "claude auth status --json", "zsh -l -i"])
        #expect(manifest.signIn.places.map(\.display) == ["/Library/Application Support/ClaudeCode/managed-settings.json"])
        #expect(AccountShellOverride.allCases.count == 12)
        #expect(
            String(LaunchpadTileSequenceScreen.shellCaption(shell.display).characters)
                == "Your login shell, zsh -l -i: runs ~/.zshrc and keeps only the names of 12 sign-in variables, never their values.")
    }

    // MARK: - S05

    @Test func theReadsWords() {
        let reads = LaunchpadCopy.Reads.self
        #expect(reads.readingEyebrow == "Your apps")
        #expect(reads.readingTitle == "Reading what each app holds")
        #expect(reads.readingLineOne == "Nothing is installed or changed. Your library is created when this finishes.")
        #expect(reads.readingLineTwo == "Stop at any time; nothing is kept.")
        #expect(reads.checkingVersion == "Checking version…")
        #expect(reads.versionUnknown == "Version unknown")
        #expect(reads.notCheckedYet == "Not checked yet")
        #expect([reads.elapsed(2.4), reads.elapsed(1.84), reads.elapsed(0.9), reads.elapsed(-1)] == ["2.4 s", "1.8 s", "0.9 s", "0.0 s"])
        #expect(
            reads.tallyReading(places: 11, of: 14, commands: 7, of: 9) + reads.tallySeparator + reads.zeroChanged
                == "11 of 14 places read · 7 of 9 commands run · 0 changed in your apps")
        #expect(reads.commitPending == "Then: create your library")
        #expect(reads.commitDone == "Your library is created")
        #expect(LaunchpadCopy.Footer.creatingLibrary == "Creating your library…")
        #expect(reads.takingAWhile("Codex") == "Codex is taking a while (up to a minute).")
        #expect(reads.skipThisApp == "Skip this app")
        #expect(reads.didNotAnswerVersion("Codex") == "Codex did not answer --version. Installs into it wait until it does.")
        #expect(reads.didNotAnswerInAMinute("Codex") == "Codex did not answer in a minute. Its files were read from disk only.")
        #expect(reads.updateToReadAccount("Codex", account: "ChatGPT") == "Update Codex to read your ChatGPT account here")
        #expect(
            reads.updateToReadAccountNotice("Claude Code", account: "claude.ai")
                == "Update Claude Code to read your claude.ai account here.")
        #expect(LaunchpadCopy.Reads.Failures.notCreated == "Your library could not be created. Nothing was changed.")
        #expect(reads.tryAgain == "Try again")
        #expect(reads.nothingToRead == "No app was turned on, so nothing was read.")
    }

    /// §6: a rerun's read updates the library rather than creating it.
    @Test func theRerunVariants() {
        let reads = LaunchpadCopy.Reads.self
        #expect(reads.lineTwoRerun == "Your library is updated last, from what this reads. Chat history is not read here.")
        #expect(reads.offNotReadRerun == "Off · not read this time")
        #expect(reads.readingLineOneRerun == "Nothing is installed or changed. Your library is updated when this finishes.")
        #expect(reads.commitPendingRerun == "Then: update your library")
        #expect(reads.commitDoneRerun == "Your library is up to date")
        #expect(LaunchpadCopy.Footer.updatingLibrary == "Updating your library…")
    }

    /// An app turned off is "not read in this first read" on a first run,
    /// before its read and once the library holds it, and "not read this
    /// time" when the read updates a library already there.
    @Test func anAppTurnedOffSaysWhichReadPassesItBy() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        typealias Screen = LaunchpadTileSequenceScreen
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)
        #expect(Screen.offNotRead(.consent, flow: flow, read: read) == "Off · not read in this first read")
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.phase == .finished }
        #expect(flow.isPostCommit)
        #expect(Screen.offNotRead(.reading, flow: flow, read: read) == "Off · not read in this first read")

        let workspace = try #require(flow.workspace)
        let rerun = fixture.flow(.rerun, workspace: workspace)
        LaunchpadStageView.footer(for: rerun).primary?.action()
        let again = LaunchpadReadSession.of(rerun)
        #expect(Screen.offNotRead(.consent, flow: rerun, read: again) == "Off · not read this time")
        LaunchpadStageView.footer(for: rerun).primary?.action()
        await waitUntil { again.phase == .finished }
        #expect(Screen.offNotRead(.reading, flow: rerun, read: again) == "Off · not read this time")
    }

    @Test func theSkipReasonIsTheReadsOwn() {
        #expect(
            LaunchpadTileSequenceScreen.skipReason(LaunchpadTransitionContext(startedEmpty: true))
                == "No app was turned on, so nothing was read.")
        #expect(LaunchpadTileSequenceScreen.skipReason(LaunchpadTransitionContext(managed: [.codex])) == nil)
    }

    // MARK: - S06

    @Test func whatWasFoundsWords() {
        let found = LaunchpadCopy.Found.self
        #expect(found.eyebrow == "Your library")
        #expect(found.title == "Here is what this Mac has")
        #expect(found.nothingAssignedYet == "Nothing is installed or assigned yet.")
        #expect(
            LaunchpadCopy.Reads.tallyDone(places: 14, commands: 9) + LaunchpadCopy.Reads.tallySeparator
                + LaunchpadCopy.Reads.zeroChanged == "14 places read · 9 commands run · 0 changed in your apps")
        #expect(found.listHeading + " " + found.listCount(8) == "In your library · 8")
        #expect(found.thingsToLookAt(8) == "8 things to look at, later on Checkup")
        #expect(found.onlyIn("Claude Code") == "Only in Claude Code")
        #expect(found.configuredIn(2) == "Configured in 2 apps")
        #expect(found.empty == "Nothing was found in these apps yet.")
        #expect(found.offNotRead == "Off · not read")
        #expect(found.notRecordedLink == "Not recorded, and why…")
        #expect(found.notRecordedTitle == "Not recorded, and why")
        #expect(found.checkAgain == "Check again")
        #expect(found.readBy("Codex and Gemini CLI") == "Read by Codex and Gemini CLI")
        #expect([found.files(1), found.files(3)] == ["1 file", "3 files"])
        #expect(LaunchpadCopy.Found.SignIn.checking == "Checking sign-in…")
        #expect(LaunchpadCopy.Found.SignIn.cannotCheck == "Can’t check sign-in yet")
    }

    /// The copies chip is SkillCopySummary's compact label (D37).
    @Test func theCopiesChipIsTheLibrarysOwn() throws {
        let differ = try #require(SkillCopySummary(copies: 2, versions: 2))
        let same = try #require(SkillCopySummary(copies: 2, versions: 1))
        #expect(differ.compactLabel == "2 copies · 2 versions")
        #expect(same.compactLabel == "2 copies · same content")
        #expect(SkillCopySummary(copies: 1, versions: 1) == nil)
    }
}
