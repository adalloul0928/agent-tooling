import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The words the stage's foundation owns, pinned: the footer, FooterConfirm
/// in each of its moments, the finishing sentences, ⌘↩'s hint, the stage
/// kit's spoken labels, and the sentences built from what the walk did
/// (decisions, an install's outcome, a sign-in line, a review's groups).
/// Each comes from the fragments or from plan §6.
@Suite("Launchpad foundation wording")
@MainActor
struct LaunchpadFoundationWordingTests {
    @Test func theFootersStepNamesAndControls() {
        let footer = LaunchpadCopy.Footer.self
        #expect(
            [
                footer.stepBeforeYouStart, footer.stepWelcome, footer.stepYourApps, footer.stepYourLibrary,
                footer.stepPutInApps, footer.stepPreferences, footer.stepThisMac, footer.stepOtherMacs, footer.stepDone,
                footer.stepJoin, footer.stepArrivals,
            ] == [
                "Before you start", "Welcome", "Your apps", "Your library", "Put in apps", "Preferences", "This Mac",
                "Other Macs", "Done", "Join", "Arrivals",
            ])
        #expect([footer.setUpLater, footer.stop, footer.back, footer.continue] == ["Set up later", "Stop", "Back", "Continue"])
        #expect(footer.groupLabel == "Setup actions")
        #expect(footer.stepOf(2, 5) == "Step 2 of 5")
        #expect(footer.stepOf(3, 3) == "Step 3 of 3")
    }

    /// FooterConfirm before the commit point and after it come from the
    /// fragments; the rerun sentence is §6's.
    @Test func footerConfirmSaysWhatLeavingDoesAtEachMoment() {
        let cases: [(LaunchpadLeaveMoment, String, String)] = [
            (.beforeCommit, "Nothing is written yet. Agent Tooling asks again when it next opens.", "Quit setup"),
            (.afterCommit, "Finish later? Your choices so far are saved, and Home shows where you left off.", "Go to Home"),
            (.rerun, "Leave setup? What you saved stays saved. Run it again from Settings › General.", "Go to Home"),
            (.finishing("Creating your library…"), "Creating your library…", "Go to Home"),
        ]
        for (moment, sentence, leave) in cases {
            let confirm = FooterConfirm(moment: moment, keepGoing: {}, leave: {})
            #expect(confirm.sentence == sentence)
            #expect(confirm.leaveTitle == leave)
        }
        #expect(LaunchpadCopy.Footer.keepGoing == "Keep going")
    }

    @Test func theFinishingSentences() {
        let footer = LaunchpadCopy.Footer.self
        #expect(
            [footer.creatingLibrary, footer.updatingLibrary, footer.finishingJoin, footer.stoppingAfterStep, footer.publishing]
                == ["Creating your library…", "Updating your library…", "Finishing joining…", "Stopping after this step…", "Publishing…"])
    }

    @Test func commandReturnsHintAndItsSpokenForms() {
        #expect(LaunchpadCopy.Footer.commandReturnHint == "Press ⌘↩ to install")
        #expect(LaunchpadCopy.Footer.commandReturnSpoken == "Press Command-Return to install.")
        #expect(LaunchpadCopy.Footer.commandReturnAccessibilityHint == "Command-Return installs.")
    }

    /// The failure sentences the foundation's contracts say for their owners
    /// until those owners word their own.
    @Test func theFoundationsFailureSentences() {
        #expect(LaunchpadCopy.Footer.Failures.notRecorded == "This Mac could not record that choice. Nothing was changed.")
        #expect(LaunchpadCopy.Review.Failures.notChecked == "This Mac’s apps could not be checked. Nothing was changed.")
        #expect(LaunchpadCopy.Helper.Failures.notMoved == "Agent Tooling could not be copied to Applications. Nothing was changed.")
    }

    @Test func theStageKitsSpokenLabels() {
        #expect(LaunchpadCopy.Kit.markLabel == "Agent Tooling")
        #expect(LaunchpadCopy.Kit.placesLabel == "Places for Codex, Claude Code, Gemini CLI and Kiro CLI, not looked for yet")
        #expect(LaunchpadCopy.Kit.readsLabel == "Reads")
        #expect(LaunchpadCopy.Kit.runsLabel == "Runs")
    }

    @Test func aListOfNamesReadsAsASentence() {
        #expect(LaunchpadCopy.list([]) == "")
        #expect(LaunchpadCopy.list(["Codex"]) == "Codex")
        #expect(LaunchpadCopy.list(["Codex", "Claude Code"]) == "Codex and Claude Code")
        #expect(LaunchpadCopy.list(["Codex", "Claude Code", "Gemini CLI"]) == "Codex, Claude Code and Gemini CLI")
    }

    // MARK: - Sentences built from the walk

    /// The review panel's first row and Done: one line per decision, in the
    /// order they were made, apps in the app order.
    @Test func eachDecisionHasItsLine() {
        var decisions = LaunchpadLibraryDecisions()
        decisions.adopted = [
            .init(artifactID: ArtifactID(), name: "Release Notes", copyFrom: nil),
            .init(artifactID: ArtifactID(), name: "Frontend Design", copyFrom: .claude),
        ]
        decisions.added = [
            .init(artifactID: ArtifactID(), name: "Supabase", source: .catalog(.claude)),
            .init(artifactID: ArtifactID(), name: "MCP Builder", source: .skillsSh),
            .init(artifactID: ArtifactID(), name: "Changelog", source: .written),
            .init(artifactID: ArtifactID(), name: "Linear", source: .pasted),
        ]
        decisions.placed = [
            .init(artifactID: ArtifactID(), name: "Release Notes", apps: [.claude, .codex], scope: .everyMac),
            .init(artifactID: ArtifactID(), name: "Changelog", apps: [.gemini], scope: .thisMacOnly),
            .init(artifactID: ArtifactID(), name: "Linear", apps: [.codex], scope: .project("storefront")),
        ]
        decisions.helperApps = [.claude, .codex]

        #expect(
            decisions.lines == [
                "Made Release Notes yours", "Made Frontend Design yours, from Claude Code’s copy",
                "Added Supabase, from Claude Code’s catalog", "Added MCP Builder, from skills.sh", "Added Changelog, written here",
                "Added Linear, from a pasted command", "Release Notes goes to Codex and Claude Code on every Mac",
                "Changelog goes to Gemini CLI on this Mac only", "Linear goes to Codex in storefront",
                "Agent Tooling’s own connection, for Codex and Claude Code on this Mac only",
            ])
        #expect(decisions.count == 10)
        #expect(LaunchpadLibraryDecisions().count == 0)
    }

    /// The shipped result wording: apps alphabetical, a partial install
    /// counted, a receipt line naming the steps.
    @Test func anInstallsOutcomeInWords() {
        let at = ClientHomeFixture.now
        #expect(
            DeploymentOutcome(installed: [.codex, .claude], succeededSteps: 4, finishedAt: at).summary
                == "Installed to Claude Code and Codex.")
        #expect(
            DeploymentOutcome(
                installed: [.codex], failed: [.claude: "It did not answer."], succeededSteps: 2, failedSteps: 1, finishedAt: at
            )
            .summary == "Installed to 1 of 2 apps.")
        #expect(DeploymentOutcome(installed: [], succeededSteps: 0, finishedAt: at).summary == "Nothing was installed.")
        #expect(
            DeploymentOutcome(installed: [], failed: [.claude: "No."], succeededSteps: 0, failedSteps: 1, finishedAt: at).summary
                == "Nothing was installed. One app did not take it.")
        #expect(
            DeploymentOutcome(
                installed: [], failed: [.claude: "No.", .codex: "No."], succeededSteps: 0, failedSteps: 2, finishedAt: at
            )
            .summary == "Nothing was installed. 2 apps did not take it.")
        let receipt = DeploymentOutcome(installed: [.codex, .claude], succeededSteps: 4, finishedAt: at).receiptLine
        #expect(receipt == "Installed 4 changes · \(at.formatted(date: .omitted, time: .shortened))")
        #expect(
            DeploymentOutcome(installed: [.codex], succeededSteps: 1, finishedAt: at).receiptLine.hasPrefix("Installed 1 change · "))
        // The apps are kept in the app order, whatever order they were given.
        #expect(DeploymentOutcome(installed: [.claude, .codex], succeededSteps: 2, finishedAt: at).installed == [.codex, .claude])
    }

    /// The line under a read app's tile: the account and plan, "Not signed
    /// in", the sign-in's own words, or "Can’t check sign-in yet".
    @Test func aSignInReadsAsOneLine() {
        let now = ClientHomeFixture.now
        let signIns = LaunchpadFixture.signIns(for: .juniper)
        #expect(signIns[.claude].map(SetupSignInRead.line(for:)) == "claude.ai · Max")
        #expect(signIns[.chatGPT].map(SetupSignInRead.line(for:)) == "ChatGPT · Plus")
        #expect(
            SetupSignInRead.line(
                for: AccountObservation(provider: .claude, observedAt: now, signIn: AccountSignIn(method: .signedOut)))
                == "Not signed in")
        #expect(
            SetupSignInRead.line(for: AccountObservation(provider: .claude, observedAt: now, signIn: AccountSignIn(method: .apiKey)))
                == "An API key")
        #expect(
            SetupSignInRead.line(for: AccountObservation(provider: .claude, observedAt: now, unavailableReason: "No tool."))
                == "Can’t check sign-in yet")
        #expect(LaunchpadCopy.Found.SignIn.checking == "Checking sign-in…")
    }

    /// A review's group header: what runs, and what is left alone.
    @Test func aReviewGroupSaysWhatRunsAndWhatIsLeftAlone() {
        func step(_ state: ScopedPlanReview.StepState) -> ScopedPlanReview.Step {
            .init(
                id: .init(artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID()), client: .codex,
                title: "A step", state: state)
        }
        #expect(
            ScopedPlanReview.Group(client: .codex, steps: [step(.waiting), step(.waiting), step(.leftAlone)]).summary
                == "2 changes · 1 left alone")
        #expect(ScopedPlanReview.Group(client: .claude, steps: [step(.waiting), step(.done)]).summary == "2 changes")
        #expect(ScopedPlanReview.Group(client: .claude, steps: [step(.waiting)]).summary == "1 change")
    }

    // MARK: - Shared wording the stage reuses

    @Test func aSkillsCopiesOnOneChip() throws {
        #expect(try #require(SkillCopySummary(copies: 2, versions: 2)).compactLabel == "2 copies · 2 versions")
        #expect(try #require(SkillCopySummary(copies: 2, versions: 1)).compactLabel == "2 copies · same content")
        #expect(try #require(SkillCopySummary(copies: 3, versions: 0)).compactLabel == "3 copies · same content")
    }

    @Test func aCommandReadsAsAShellWouldShowIt() {
        #expect(
            CommandLineDisplay.rendered(
                executable: URL(filePath: "/opt/homebrew/bin/codex"),
                arguments: ["mcp", "add", "agent-tooling", "--", "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"])
                == #"codex mcp add agent-tooling -- "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp""#)
        #expect(CommandLineDisplay.rendered(executableName: "claude", arguments: ["plugin", "list"]) == "claude plugin list")
    }

    /// S06's sentence on Juniper, and the one-plugin form. sample-world.md
    /// reads "It holds 12 tools. 4 of them come inside plugins."; the read
    /// finds 11 and 3, because Codex reports no connection inside its Linear
    /// plugin (WP0a's recorded deviation 1).
    @Test func theLibrarysHoldingsInASentence() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let juniper = try #require(try await fixture.sample(.afterRead).workspace.library.state?.library)
        #expect(juniper.holdingsSentence == "It holds 11 tools. 3 of them come inside plugins.")
        #expect(juniper.rows.count == 8)

        // A plugin carrying one skill, a standalone skill and a server.
        let small = try await ShellRenderFixture()
        defer { small.remove() }
        let library = try #require(small.workspace.library.state?.library)
        #expect(library.holdingsSentence == "It holds 4 tools. One of them comes inside a plugin.")
    }

    @Test func appearanceTagsReadBackAsTheirChoice() {
        #expect(AppAppearance("Light") == .light)
        #expect(AppAppearance("Dark") == .dark)
        #expect(AppAppearance("System") == .system)
        #expect(AppAppearance("light") == .system)
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.system.colorScheme == nil)
        // The pickers' choices, in their order, under the tags they store.
        #expect(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(AppAppearance.allCases.map(\.rawValue) == ["System", "Light", "Dark"])
        #expect(
            [AppPreferenceKey.appearance, AppPreferenceKey.showMenuBarItem, AppPreferenceKey.sidebarCollapsed] == [
                "appearance", "showMenuBarItem", "sidebarCollapsed",
            ])
    }
}
