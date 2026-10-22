import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The words of Home's Finish setting up card (P01), its chip, the
/// connection check's confirmation, the Raycast and Terminal tips, and Done
/// (S22), pinned to the fragments; and the words derived from something else
/// held to their source.
@Suite("Finish setting up wording", .timeLimit(.minutes(5)))
@MainActor
struct FinishSetupWordingTests {
    private typealias Copy = LaunchpadCopy.FinishSetup

    @Test func theCardsHeaderFootAndChip() {
        #expect(Copy.title == "Finish setting up")
        #expect(Copy.finishedTitle == "Setup finished")
        #expect(Copy.count(done: 3, of: 7) == "3 of 7 done")
        #expect(Copy.cardLabel(Copy.title, done: 3, of: 7) == "Finish setting up, 3 of 7 done")
        #expect(Copy.hide == "Hide")
        #expect(Copy.useFromRaycastOrTerminal == "Use it from Raycast or Terminal…")
        #expect(Copy.runSetupAgain == "Run setup again from Settings › General.")
        #expect(Copy.chip(left: 4) == "Finish setting up · 4 left")
        #expect(Copy.chipLabel(left: 4) == "Finish setting up, 4 left")
        #expect(Copy.chipHint == "Shows the card on Home again")
        // What VoiceOver says a row's state is.
        #expect(Copy.doneValue(FinishSetupPlace.setup.phrase) == "Done, in setup")
        #expect(Copy.notDone == "Not done")
    }

    @Test func theRowsTitlesCaptionsAndButtons() {
        #expect(Copy.makeSkillsYours == "Make your skills yours")
        #expect(Copy.putToolsInApps == "Put your tools in your apps")
        #expect(Copy.connectAgentTooling == "Connect Agent Tooling to your apps")
        #expect(Copy.connectOtherMacs == "Connect your other Macs")
        #expect(Copy.signInConnections == "Sign in to your connections")
        #expect(Copy.lookAtCheckup(4) == "Look at 4 things on Checkup")
        #expect(Copy.lookAtCheckup(1) == "Look at 1 thing on Checkup")
        #expect(Copy.trySkill("Release Notes", in: "Codex") == "Try Release Notes in Codex")
        #expect(Copy.trackProjects == "Track your projects")
        #expect(Copy.done("Release Notes and Frontend Design", place: "in setup") == "Release Notes and Frontend Design · in setup")
        #expect(Copy.done(nil, place: "from Home") == "Done from Home")
        #expect(Copy.synced("just now") == "Synced just now")
        #expect(Copy.notChecked(mayNeed: "Sentry in Claude Code") == "Not checked yet · Sentry in Claude Code may need you to sign in")
        #expect(Copy.notChecked(mayNeed: "") == "Not checked yet")
        #expect(Copy.needSignIn("Sentry in Claude Code", count: 1) == "Sentry in Claude Code needs you to sign in")
        #expect(Copy.needSignIn("GitHub and Sentry in Claude Code", count: 2) == "GitHub and Sentry in Claude Code need you to sign in")
        #expect(Copy.tryCaption == "Checks apps first, then opens Terminal running")
        #expect(Copy.foldersClaudeCodeWorkedIn(4) == "4 folders Claude Code has worked in")
        #expect(Copy.addFolders == "Add the folders you work in")
        #expect(Copy.signedIn("Sentry") == "Sentry signed in")
        #expect(Copy.changesWaiting(4) == "4 changes waiting")
        #expect(Copy.skillsNotYoursYet(1) == "1 skill in your apps is not in your library yet")
        #expect(
            [Copy.checkConnections, Copy.signIn, Copy.openCheckup, Copy.tryIt, Copy.openProjects, Copy.connect]
                == ["Check connections…", "Sign in…", "Open Checkup", "Try it", "Open Projects", "Connect…"])
    }

    @Test func theRowsLeftForLaterAndMoved() {
        #expect(Copy.resume(next: Copy.next(.place)) == "Resume setup — next: Put your tools in your apps")
        #expect(Copy.resumeButton == "Resume")
        #expect(Copy.moveTitle == "Move Agent Tooling to Applications")
        #expect(Copy.moveButton == "Move…")
        // Each step a setup can be left at reads by its screen's title.
        #expect(Copy.next(.found) == "Here is what this Mac has")
        #expect(Copy.next(.library) == "Start your library")
        #expect(Copy.next(.ask) == "Let your apps ask Agent Tooling")
        #expect(Copy.next(.assistant) == "Let your assistant help")
        #expect(Copy.next(.behave) == "How Agent Tooling behaves")
        #expect(Copy.next(.macs) == "Use your library on your other Macs")
    }

    @Test func eachPlaceAsADoneRowNamesIt() {
        #expect(
            FinishSetupPlace.allCases.map(\.phrase) == [
                "in setup", "from Home", "from Library", "from Discover", "from Apps", "from Checkup", "from Projects",
                "from Settings", "from Insights", "from Activity",
            ])
        #expect(FinishSetupPlace(section: .checkup) == .checkup)
        #expect(FinishSetupPlace(section: .health) == .apps)
        #expect(FinishSetupPlace(section: .plugins) == .library)
        #expect(FinishSetupPlace(section: .sync) == .settings)
    }

    /// The confirmation, as P01 draws it before a check.
    @Test func theConnectionChecksConfirmation() {
        #expect(Copy.checkTitle == "Check your connections?")
        #expect(Copy.checkRuns == "Runs, and can take up to a minute:")
        #expect(
            Copy.signInComesNext(Copy.either(["Sentry"])) == "If Sentry needs you, its sign-in comes next, with its command shown first:")
        #expect(Copy.either(["GitHub", "Sentry"]) == "GitHub or Sentry")
        #expect(Copy.signInRuns == "Sign in ⌘↩ runs it and opens the page it prints; Agent Tooling never sees a token.")
        #expect([Copy.cancel, Copy.check, Copy.signInButton] == ["Cancel", "Check", "Sign in"])
        #expect(Copy.pressCommandReturn == "Press ⌘↩ to sign in")
    }

    /// The commands the confirmation names are the ones the check runs, in
    /// the order it runs them; and the sign-in it shows first is the health
    /// session's own command.
    @Test func theConfirmationNamesWhatTheCheckRuns() async throws {
        #expect(ConnectionsCheckFlow.listCommands(for: [.claude, .codex]) == ["claude mcp list", "codex mcp list --json"])
        #expect(ConnectionsCheckFlow.listCommands(for: [.claude, .gemini]) == ["claude mcp list"])
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        #expect(
            fixture.workspace.health.loginCommandText(client: .claude, serverID: "plugin:sentry:sentry")
                == "claude mcp login plugin:sentry:sentry --no-browser")
        #expect(fixture.workspace.health.loginCommandText(client: .gemini, serverID: "anything") == nil)
    }

    /// The tips, as P01 draws them for a Mac with Raycast and no extension.
    @Test func theRaycastAndTerminalTips() {
        let commands = CompanionPresence.raycastCommands
        #expect(
            Copy.raycastWithoutExtension(commands)
                == "Raycast is on this Mac; the Agent Tooling extension is not. Its six commands: Search Agent Tooling, Create Skill Draft, Check Setup, Review Sync, Review Tooling Insights, Open Agent Tooling. It needs the signed release build."
        )
        #expect(
            Copy.raycastWithExtension(commands)
                == "Raycast and the Agent Tooling extension are on this Mac. Its six commands: Search Agent Tooling, Create Skill Draft, Check Setup, Review Sync, Review Tooling Insights, Open Agent Tooling."
        )
        #expect(
            Copy.noRaycast(commands)
                == "Raycast is not on this Mac. Its Agent Tooling extension adds six commands: Search Agent Tooling, Create Skill Draft, Check Setup, Review Sync, Review Tooling Insights, Open Agent Tooling. It needs the signed release build."
        )
        #expect(Copy.terminalCommands == ["agent-tooling scan", "agent-tooling doctor", "agent-tooling search <words>"])
        #expect(Copy.noCommandLineTool == "The command-line tool comes inside Agent Tooling in Applications.")
        #expect([Copy.raycast, Copy.terminal] == ["Raycast", "Terminal"])
    }

    /// The card's words the fragment does not draw, new here (O6), each
    /// pinned whole.
    @Test func theCardsNewWordsReadWhole() {
        #expect(Copy.moveCaption == "Your apps keep its connection only from there")
        #expect(Copy.connectAgentToolingCaption == "So your apps can find what is in your library")
        #expect(Copy.otherMacsCaption == "Use this library on your other Macs too")
        #expect(Copy.nothingInstalledYet == "Nothing is installed yet")
        #expect(Copy.skillsNotYoursYet(2) == "2 skills in your apps are not in your library yet")
        #expect(Copy.trySkillTitle == "Try a skill in your apps")
        #expect(Copy.checkingApps == "Checking apps…")
        #expect(Copy.notCheckedYet == "Not checked yet")
        #expect(
            Copy.signInInItsApp("Gmail in Claude Code", count: 1) == "Checked · Gmail in Claude Code needs you to sign in from its app")
        #expect(
            Copy.signInInItsApp("Gmail in Claude Code and Linear in Codex", count: 2)
                == "Checked · Gmail in Claude Code and Linear in Codex need you to sign in from their apps")
        #expect(Copy.checkedNothingToSignIn == "Checked · no connection needs a sign-in")
        #expect(Copy.noSignInNeeded == "No connection needs a sign-in")
        #expect(Copy.allLookedAt == "All looked at")
        #expect(Copy.tried("Release Notes", in: "Codex") == "Tried Release Notes in Codex")
        #expect(Copy.projectsTracked(2) == "2 projects tracked")
        // The step a setup left for later resumes at, by its screen's title.
        #expect(Copy.next(.move) == "Put Agent Tooling in Applications")
        #expect(Copy.next(.welcome) == "Welcome to Agent Tooling")
        #expect(Copy.next(.apps) == "Choose the apps this Mac manages")
        #expect(Copy.next(.reads) == "Agent Tooling looks before it changes anything")
        #expect(Copy.next(.join) == "Join your library")
        #expect(Copy.next(.done) == "See what happened")
        #expect(Copy.next(.arrivals, device: "Cedar") == "You joined as Cedar")
        #expect(Copy.next(.arrivals) == "You joined as this Mac")
    }

    /// The confirmation's words past the fragment's first moment, new here
    /// (O6), each pinned whole.
    @Test func theConfirmationsNewWordsReadWhole() {
        #expect(Copy.signInComesNextIfAny == "If a connection needs you, its sign-in comes next, with its command shown first.")
        #expect(
            Copy.signInRunsEach == "Sign in ⌘↩ runs each in turn and opens the page it prints; Agent Tooling never sees a token.")
        #expect(Copy.signInTitle == "Sign in to your connections?")
        #expect(Copy.checkedTitle == "Connections checked")
        #expect(Copy.nothingToSignIn == "No connection needs you to sign in.")
        #expect(
            Copy.signInFromApps("Gmail in Claude Code", count: 1)
                == "Gmail in Claude Code needs you to sign in from its app. Apps › Health shows how.")
        #expect([Copy.checking, Copy.signingIn, Copy.close] == ["Checking…", "Signing in…", "Done"])
        #expect(Copy.pressCommandReturnSpoken == "Press Command-Return to sign in.")
    }

    /// Why a skill cannot be tried, as Library's Try… and Home's Try it say
    /// it.
    @Test func whyASkillCannotBeTried() {
        #expect(
            SkillTrialAvailability.cannotTryReason(skillName: nil, in: .codex, observedIn: [.codex], canOpen: true)
                == "This skill has no name an app could call.")
        #expect(
            SkillTrialAvailability.cannotTryReason(skillName: "release-notes", in: .claude, observedIn: [.claude], canOpen: false)
                == "Claude Code’s command-line tool was not found on this Mac.")
    }

    /// The commands the tips name are the Raycast extension's own.
    @Test func theTipsNameTheExtensionsCommands() throws {
        let manifest = try PackageSourceFile.text(at: "../../integrations/raycast/agent-tooling/package.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any])
        let titles = (object["commands"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }

        #expect(object["name"] as? String == CompanionPresence.raycastExtensionName)
        #expect(titles == CompanionPresence.raycastCommands)
    }

    // MARK: - Done

    @Test func donesFixedWords() {
        let done = LaunchpadCopy.Done.self
        #expect(done.eyebrow == "What happened")
        #expect(done.title(left: 2) == "Set up, with 2 things left")
        #expect(done.title(left: 1) == "Set up, with 1 thing left")
        #expect(done.title(left: 0) == "All set")
        #expect(done.leftForLater(2) == "Left for later · 2")
        #expect(done.homeAdds(2) == "Home adds 2 suggestions")
        #expect(done.homeAdds(1) == "Home adds 1 suggestion")
        #expect(done.runsOnItsOwn == "Runs on its own")
        #expect(done.onlyWhileOpen == "only while Agent Tooling is open")
        #expect([done.keySearch, done.keyReview, done.keyCheckApps] == ["Search everything", "Review changes", "Check apps"])
        #expect(done.openCheckup == "Open Checkup")
        #expect(done.checking == "Checking…")
        #expect(done.notConnected(device: "Cedar") == "Agent Tooling is not connected to Cedar’s apps yet")
        #expect(done.leftOnCheckup(1) == "1 thing left on Checkup")
        #expect(done.library(tools: 1, entries: 1) == "1 tool in your library (1 entry)")
        #expect(done.nowYours(["Release Notes"]) == "1 is now yours: Release Notes")
        #expect(done.contentsAfterTheNextCheck(["Supabase", "Vercel"]) == "Supabase’s and Vercel’s contents appear after the next check.")
        #expect(
            done.assistantRuns(weekly: true, deepDive: true, with: "Codex") == "Weekly checkup review and daily deep dive on, with Codex")
    }

    /// Done's words the fragment does not draw, new here (O6), each pinned
    /// whole.
    @Test func donesNewWordsReadWhole() {
        let done = LaunchpadCopy.Done.self
        let glue = done.glue
        #expect(done.shares(with: "https://example.com/library") == "Shares this library with https://example.com/\u{200B}library")
        #expect(done.nothingRuns == "Nothing runs on its own.")
        #expect(
            [done.whenItOpens, done.onceADay, done.weekly, done.daily, done.afterAChange] == [
                "When it opens:", "Once a day:", "Weekly:", "Daily:", "After a change:",
            ])
        #expect(done.deepDive(with: "Claude Code") == "the deep dive, with Claude Code")
        #expect(done.checkupReview(with: "Claude Code") == "the checkup review, with Claude Code")
        #expect(
            done.assistantRuns(weekly: false, deepDive: true, with: "Codex")
                == "Daily deep dive on, with Codex\(glue)· weekly checkup review off")
        #expect(done.assistantRuns(weekly: false, deepDive: false, with: "Codex") == "Weekly checkup review and daily deep dive off")
        #expect(done.nothingInstalled == "Nothing was installed")
        #expect(done.installed(changes: 2) == "2 changes installed")
        #expect(done.didNotFinish(1, in: ["Claude Code"]) == "1 did not finish (Claude Code)")
        #expect(done.didNotFinish(2) == "2 did not finish")
        #expect(done.waitForReview(1) == "1 change waits for your review")
        #expect(done.waitForReview(4) == "4 changes wait for your review")
        #expect(done.notConnected(device: nil) == "Agent Tooling is not connected to this Mac’s apps yet")
        #expect(done.leftAlone(1, named: []) == "1 left alone")
        #expect(done.notFound == "Not found")
        #expect(done.skipped == "Skipped")
        #expect(
            done.alsoShows("Gemini CLI", "Release Notes", reading: "~/.agents/skills")
                == "After the next check, Gemini CLI also shows Release Notes, because it reads ~/.agents/skills.")
    }

    /// "At most every 15 minutes" is the sync scheduler's own interval.
    @Test func theSyncIntervalIsTheSchedulers() {
        let minutes = Int((WorkspaceSyncScheduler.interval / 60).rounded())
        #expect(LaunchpadCopy.Done.syncAtMost(everyMinutes: minutes) == "sync with your other Macs, at most every 15 minutes")
    }

    /// The keys Done teaches are the main window's own, never the stage's.
    @Test func theKeyStripTeachesTheMainWindowsKeys() {
        #expect(KeyCombo.keys(of: KeyboardShortcut("k", modifiers: .command)) == [.command, .character("K")])
        #expect(KeyCombo.keys(of: KeyboardShortcut("r", modifiers: [.shift, .command])) == [.shift, .command, .character("R")])
        #expect(KeyCombo.spoken(KeyboardShortcut("d", modifiers: [.shift, .command])) == "Shift-Command-D")
        #expect(LaunchpadCopy.Done.key("Check apps", spoken: "Shift-Command-D") == "Check apps, Shift-Command-D")
    }
}
