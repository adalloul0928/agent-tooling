import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Review labels for approvals, skipped changes, progress, and results.
@Suite("Launchpad review wording")
struct LaunchpadReviewWordingTests {
    private typealias Copy = LaunchpadCopy.Review

    @Test func theHeaderAndTheLibraryRow() {
        #expect(Copy.subtitle(apps: 2) == "Into 2 apps on this Mac. Each step shows what it runs; Cancel writes nothing.")
        #expect(Copy.subtitle(apps: 1) == "Into 1 app on this Mac. Each step shows what it runs; Cancel writes nothing.")
        #expect(Copy.chip(deviceName: "Juniper") == "This Mac · Juniper")
        #expect(Copy.preparingTitle == "Install changes")
        #expect(Copy.checking == "Checking destinations and package contents…")
        #expect(Copy.inYourLibrary == "In your library")
        #expect(Copy.libraryDecisions(7) == "· 7 decisions · these touch no app")
        #expect(Copy.libraryDecisions(1) == "· 1 decision · these touch no app")
        #expect(Copy.saved == "Saved")
        #expect(Copy.libraryDisclosure(expanded: false, decisions: 7) == "collapsed, 7 decisions")
        #expect(Copy.libraryDisclosure(expanded: true, decisions: 7) == "expanded, 7 decisions")
        // VoiceOver hears the count once, in the value.
        #expect(Copy.libraryHint == "These touch no app")
    }

    @Test func beforeYouApprove() {
        #expect(Copy.beforeYouApprove == "Before you approve")
        #expect(Copy.leftAlone(steps: 1) == "1 step is left alone")
        #expect(Copy.leftAlone(steps: 2) == "2 steps are left alone")
        #expect(Copy.checkedClean(["Release Notes"]) == "Release Notes was checked for risky content; nothing was flagged.")
        #expect(
            Copy.checkedClean(["Release Notes", "Frontend Design"])
                == "Release Notes and Frontend Design were checked for risky content; nothing was flagged.")
    }

    @Test func theGroupsAndTheirSteps() {
        #expect(Copy.inYourApps(changes: 4) == "In your apps · 4 changes")
        #expect(Copy.groupSummary(changes: 2, leftAlone: 1) == "2 changes · 1 left alone")
        #expect(Copy.groupSummary(changes: 2, leftAlone: 0) == "2 changes")
        #expect(Copy.groupSummary(changes: 1, leftAlone: 0, cannotRun: 1) == "1 change · 1 cannot run yet")
        #expect(Copy.leftAloneState == "Left alone")
        #expect(
            Copy.leftAloneNotOurs(app: "Codex")
                == "Left alone: Codex already has a copy Agent Tooling did not put there. It won’t be overwritten.")
        #expect(
            Copy.leftAloneEdited(app: "Codex")
                == "Left alone: the copy in Codex was changed after Agent Tooling put it there. It won’t be overwritten.")
        #expect(Copy.willNotRun("No tool.") == "Will not run · No tool.")
        #expect(Copy.stepNumber(1, of: 4) == "Step 1 of 4")
        #expect(Copy.noNumber == "–")
        #expect(Copy.prompt == "$ ")
    }

    /// D30's replacement: the old path, then what a failed add leaves. Agent
    /// Tooling's own connection keeps §6's words (S11's sentence and replace
    /// note); any other connection is named as itself.
    @Test func aReplacementNamesTheOldCopyAndWhatAFailedAddLeaves() {
        let old = "~/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
        #expect(
            Copy.registeredNow(server: "agent-tooling", app: "Claude Code", path: old)
                == "Connected to another copy at ~/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp.")
        #expect(Copy.registeredNow(server: "agent-tooling", app: "Claude Code", path: nil) == "Connected to another copy.")
        #expect(
            Copy.replaceNote(server: "agent-tooling", app: "Claude Code")
                == "If adding fails, agent-tooling is left removed from Claude Code; Apps will offer to add it again.")
        #expect(
            Copy.registeredNow(server: "files", app: "Claude Code", path: "/usr/local/bin/files-mcp")
                == "Claude Code starts files from /usr/local/bin/files-mcp now.")
        #expect(Copy.registeredNow(server: "files", app: "Codex", path: nil) == "Codex already has files set up another way.")
        #expect(
            Copy.replaceNote(server: "files", app: "Claude Code")
                == "If adding fails, files is left removed from Claude Code; Apps will offer to add it again.")
    }

    /// A registration Agent Tooling cannot prove it made is left alone, in
    /// S11's words (§6).
    @Test func aRegistrationItDidNotMakeIsLeftAlone() {
        #expect(Copy.notOurs == "Agent Tooling did not add this one, so it is left alone.")
        #expect(Copy.notOurs == LaunchpadCopy.Helper.notOurs)
    }

    /// Each step names the item and its app in one phrase, the app as a
    /// person knows it ("Codex", never "Codex CLI").
    @Test func eachStepsTitle() {
        let digest = ContentDigest(algorithm: .sha256TreeV1, value: String(repeating: "a", count: 64))
        func item(_ name: String, _ action: WorkspaceDeploymentAction, _ surface: TargetSurface = .codexCLI)
            -> WorkspaceDeploymentItem
        {
            .init(
                artifactID: ArtifactID(), displayName: name, physicalDestinationID: WorkspaceObjectID(), surface: surface,
                scope: .user, logicalProjectID: nil, action: action, desiredEnabled: nil, reasons: [.manual])
        }
        let copy = item("Release Notes", .installContent(digest: digest))
        #expect(copy.appName == "Codex")
        #expect(copy.reviewTitle(app: copy.appName) == "Copy Release Notes into Codex")
        let plugin = item(
            "Supabase",
            .installNativePackage(route: .init(client: .claude, externalPluginID: "supabase@claude-plugins-official")),
            .claudeCode)
        #expect(plugin.reviewTitle(app: plugin.appName) == "Ask Claude Code to install Supabase")
        let connection = item("Agent Tooling", .configureManagedConnection(transport: .stdio))
        #expect(connection.reviewTitle(app: "Codex") == "Add Agent Tooling to Codex")
        #expect(item("Frontend Design", .updateContent(from: nil, to: digest)).leftAloneTitle(app: "Codex") == "Frontend Design in Codex")
        let update = item("Release Notes", .updateContent(from: digest, to: digest))
        #expect(update.reviewTitle(app: "Codex") == "Update Release Notes in Codex")
        let replace = item("Release Notes", .updateContent(from: nil, to: digest))
        #expect(replace.reviewTitle(app: "Codex") == "Replace Release Notes in Codex")
        let removal = item("Release Notes", .removeContent(installed: digest))
        #expect(removal.reviewTitle(app: "Codex") == "Remove Release Notes from Codex")
    }

    @Test func theBarTheProgressAndTheResult() {
        #expect(Copy.cancel == "Cancel")
        #expect(Copy.safety == "Changes files on this Mac. Removals go to Agent Tooling’s trash; configuration files are backed up first.")
        #expect(Copy.installing(2, of: 4) == "Installing 2 of 4…")
        #expect(Copy.installingSpoken(2, of: 4) == "Installing 2 of 4.")
        #expect(Copy.changedWhileOpen == "Your library changed while this was open. Review again.")
        #expect(Copy.reviewAgain == "Review again")
        #expect(Copy.nothingToInstall == "Nothing to install.")
        #expect(Copy.nothingCanRun == "Nothing here can run yet.")
        #expect(Copy.copyWell == "Copy")
        #expect(Copy.copied == "Copied")
        #expect(LaunchpadCopy.Footer.commandReturnHint == "Press ⌘↩ to install")
        #expect(LaunchpadCopy.Footer.commandReturnSpoken == "Press Command-Return to install.")
        #expect(LaunchpadCopy.Footer.commandReturnAccessibilityHint == "Command-Return installs.")
        #expect(LaunchpadCopy.Footer.stoppingAfterStep == "Stopping after this step…")
        #expect(Copy.receipt(changes: 4, at: "9:52 AM") == "Installed 4 changes · 9:52 AM")
        #expect(Copy.installed(to: "Claude Code and Codex") == "Installed to Claude Code and Codex.")
        #expect(Copy.installed(1, of: 2) == "Installed to 1 of 2 apps.")
        #expect(Copy.installedChanges(1, of: 4) == "Installed 1 of 4 changes.")
        #expect(Copy.stopped(after: 2, of: 4) == "Stopped after 2 of 4 changes.")
        #expect(Copy.stoppedBeforeAnything == "Stopped before anything was installed.")
    }

    /// A well is drawn so a flag or a name never breaks across lines, with
    /// characters a shell does not read as the command's: the text drawn is
    /// not selectable, and what the copy button copies is the exact command,
    /// character for character. The button shows on hover and on keyboard
    /// focus.
    @Test func theWellCopiesTheExactCommand() {
        let commands = [
            "claude mcp remove --scope user agent-tooling",
            "claude mcp add --transport stdio --scope user agent-tooling -- \"/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp\"",
        ]
        let copied = ReviewWell.plain(.commands(commands))
        #expect(copied == commands.joined(separator: "\n"))
        #expect(!copied.contains("\u{2011}") && !copied.contains("\u{200B}"))
        #expect(ReviewWell.plain(.path("~/.agents/skills/release-notes")) == "~/.agents/skills/release-notes")
        // What is drawn differs from what is copied, which is why it is not
        // selectable.
        #expect(ReviewWell.breakable(commands[1]) != commands[1])
        #expect(ReviewWell.breakable(commands[1]).contains("\u{2011}"))
        #expect(ReviewWell.showsCopy(hovering: true, focused: false))
        #expect(ReviewWell.showsCopy(hovering: false, focused: true))
        #expect(!ReviewWell.showsCopy(hovering: false, focused: false))
    }

    @Test func failuresSayNothingWasChanged() {
        #expect(Copy.Failures.notChecked == "This Mac’s apps could not be checked. Nothing was changed.")
        #expect(
            Copy.Failures.noContentStore
                == "This library has no verified content store, so nothing in it could be read before it was written. Nothing was changed.")
        #expect(Copy.Failures.notRead == "The library has not been read yet, so there is nothing to review. Nothing was changed.")
    }

    /// The title counts only what runs (D6): five listed and four run is
    /// "Install 4 changes", never five.
    @Test func theTitleCountsOnlyWhatRuns() {
        #expect(PlanReviewLabels.title(listedCount: 5, runnableCount: 4, hasRemoval: false, hasExclusions: false) == "Install 4 changes")
        #expect(PlanReviewLabels.title(listedCount: 2, runnableCount: 0, hasRemoval: false, hasExclusions: false) == "Nothing can run yet")
        #expect(
            PlanReviewLabels.title(listedCount: 0, runnableCount: 0, hasRemoval: false, hasExclusions: true)
                == "Nothing can be installed right now")
    }
}
