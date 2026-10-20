import AgentToolingCore
import AgentToolingTestSupport
import Testing

@testable import AgentToolingApp

/// Let your assistant help's and How Agent Tooling behaves's words, verbatim
/// from their fragments (`10-s15-assistant.html`, `11-s16-behave.html`), with
/// what each screen's footer and VoiceOver say, and the stage's rules held
/// over the new files outside `Launchpad/`.
@Suite("Launchpad preferences wording")
@MainActor
struct LaunchpadPreferencesWordingTests {
    private let copy = LaunchpadCopy.Preferences.self

    @Test func letYourAssistantHelpReadsAsDrawn() {
        #expect(copy.eyebrow == "Preferences")
        #expect(copy.assistantTitle == "Let your assistant help")
        #expect(
            copy.assistantSubtitle
                == "Your own signed-in assistant can read your setup and suggest what to do. It can read; it cannot change anything.")
        #expect(copy.firstReview == "The first review starts when Home opens.")
    }

    /// "The first review starts when Home opens." only where Home will start
    /// it: the weekly review on, an assistant to run it, none run yet, and a
    /// stage whose hand-off opens Home. A rerun or a resumed setup sits over
    /// a Home that is already open and whose launch has run.
    @Test func theFirstReviewIsPromisedOnlyWhereHomeWillStartIt() {
        let weekly = AssistantRunConsent(weeklyReview: true, dailyDeepDive: false, localInsights: false)
        let juniper: [ClientKind] = [.codex, .claude, .gemini]
        func promises(
            _ entry: SetupEntry, _ runs: AssistantRunConsent = weekly, managed: [ClientKind] = juniper, hasReview: Bool = false
        ) -> Bool {
            LaunchpadAssistantScreen.promisesFirstReview(entry: entry, runs: runs, managed: managed, hasReview: hasReview)
        }
        for entry: SetupEntry in [.firstRun, .continueFirstRun(.assistant), .finishJoin(WorkspaceObjectID())] {
            #expect(promises(entry), "\(entry)")
            #expect(!promises(entry, .off), "\(entry): every run off, as a new setup opens")
            #expect(
                !promises(entry, AssistantRunConsent(weeklyReview: false, dailyDeepDive: true, localInsights: true)),
                "\(entry): the weekly review off")
            #expect(!promises(entry, hasReview: true), "\(entry): a review has run already")
            #expect(!promises(entry, managed: [.gemini, .kiro]), "\(entry): no assistant")
        }
        for entry: SetupEntry in [.rerun, .resume(.assistant), .revisit(.assistant)] {
            #expect(!promises(entry), "\(entry): Home is already open")
            #expect(!promises(entry, .existingBehaviour), "\(entry): Home is already open")
        }
    }

    @Test func howAgentToolingBehavesReadsAsDrawn() {
        #expect(copy.behaveTitle == "How Agent Tooling behaves")
        #expect(copy.behaveSubtitle == "These choices are for this Mac. Change them any time in Settings.")
        let rows = LaunchpadBehaveScreen.Row.allCases
        #expect(
            rows.map(\.title) == [
                "Appearance", "Show Agent Tooling in the menu bar", "Check my apps each time Agent Tooling opens", "Check for updates",
                "Skills", "Plugins", "Connections",
            ])
        #expect(
            rows.map(\.detail) == [
                "System follows macOS.", "Open Agent Tooling, Check Apps and Review Changes… from the menu bar.",
                "Read what each app holds on this Mac. Nothing is changed.",
                "Looks for newer versions of your skills, plugins and connections.", nil, nil, nil,
            ])
        #expect(
            rows.map(\.symbol) == [
                "sun.max", "menubar.rectangle", "stethoscope", "arrow.down.circle", "doc.text", "puzzlepiece.extension", "server.rack",
            ])
        #expect(copy.updatesSection == "Updates")
        #expect(copy.decidesArrivals == "This also decides what arrives from your other Macs.")
        #expect(copy.connectionsWait == "Updates to connections always wait for you.")
    }

    /// The menu-bar row names the menu's items as the menu itself does.
    @Test func theMenuBarRowNamesTheMenusOwnItems() {
        #expect(copy.menuBarDetail.contains(ActionTitles.checkAppsCommand(.menu)))
        #expect(copy.menuBarDetail.contains(ActionTitles.reviewChangesCommand(.menu)))
    }

    /// The pop-ups and the segment show the titles Settings shows.
    @Test func theChoicesUseTheirShippedTitles() {
        #expect(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(UpdateCheckCadence.allCases.map(\.title) == ["When the app opens", "Once a day", "Only when I ask"])
        #expect(UpdateInstallPolicy.allCases.map(\.title) == ["Install automatically", "Ask me first"])
        #expect(
            UpdatePolicy() == UpdatePolicy(cadence: .onOpen, skills: .ask, plugins: .ask, mcpServers: .ask), "the defaults the screen keeps"
        )
        #expect(LaunchpadBehaveScreen.Row.allCases.compactMap(\.kind) == [.skill, .plugin, .mcpServer])
    }

    @Test func aFailureIsShownOnlyUnderTheChoiceThatFailed() {
        let failed = LaunchpadCopy.Footer.Failures.notRecorded
        #expect(failed == "This Mac could not record that choice. Nothing was changed.")
        #expect(LaunchpadBehaveScreen.failure(under: .skills, lastChanged: .skills, message: failed) == failed)
        #expect(LaunchpadBehaveScreen.failure(under: .plugins, lastChanged: .skills, message: failed) == nil)
        #expect(
            LaunchpadBehaveScreen.failure(under: .checkOnOpen, lastChanged: .checkOnOpen, message: "This Mac's apps could not be checked.")
                == nil, "a check's own message is not a choice's")
        #expect(LaunchpadAssistantScreen.failure(under: .weeklyReview, lastFlipped: .weeklyReview, message: failed) == failed)
        #expect(LaunchpadAssistantScreen.failure(under: .dailyDeepDive, lastFlipped: .weeklyReview, message: failed) == nil)
        #expect(LaunchpadAssistantScreen.failure(under: .weeklyReview, lastFlipped: .weeklyReview, message: nil) == nil)
    }

    // MARK: Footers

    @Test func bothFootersContinueOnReturnAndCanBeLeftForLater() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterInstall)
        defer { sample.remove() }
        for step: LaunchpadStep in [.assistant, .behave] {
            #expect(flow.step == step)
            let footer = LaunchpadStageView.footer(for: flow)
            #expect(footer.primary?.title == "Continue")
            #expect(footer.primary?.key == .return)
            #expect(footer.primary?.isEnabled == true)
            guard case .setUpLater = footer.later else {
                Issue.record("\(step) has no Set up later")
                return
            }
            #expect(flow.info.footerName == "Preferences")
            #expect(flow.info.capsules == LaunchpadStepInfo.Capsules(reached: 4, total: 5))
            footer.primary?.action()
        }
        #expect(flow.step == .macs)
    }

    @Test func withNoAssistantLetYourAssistantHelpSaysWhyItWasPassedOver() {
        #expect(LaunchpadAssistantScreen.skipReason(LaunchpadTransitionContext(managed: [.gemini])) == AssistantRunCopy.noAssistant)
        #expect(LaunchpadAssistantScreen.skipReason(LaunchpadTransitionContext(managed: [.claude], managesAssistant: true)) == nil)
        #expect(LaunchpadBehaveScreen.skipReason(LaunchpadTransitionContext()) == nil, "How Agent Tooling behaves is never passed over")
    }

    // MARK: VoiceOver

    @Test func voiceOverNamesTheGroupsAndTheSwitches() {
        #expect(copy.runsLabel == "The assistant’s runs")
        #expect(copy.behaveLabel == "This Mac’s preferences")
        #expect(AssistantRunCopy.accessibilityLabel(.weeklyReview) == "Weekly checkup review, Leaves this Mac")
    }

    // MARK: The stage's rules over the new files

    /// The stage's copy rules read this package's copy files.
    @Test func theCopyRulesReadThesePackagesCopy() throws {
        let paths = try LaunchpadStyleRulesTests.copySources().map(\.path)
        #expect(paths.contains("Launchpad/LaunchpadCopy+Preferences.swift"))
        #expect(paths.contains("AssistantRunCopy.swift"))
        #expect(paths.contains("AssistantRunsNotice.swift"))
    }

    /// The stage's code rules over the new files outside `Launchpad/`: no
    /// raw number in a view.
    @Test func theNewFilesTypeNoNumber() throws {
        let names: Set<String> = [
            "AssistantRunCopy.swift", "AssistantRunRow.swift", "AssistantRunsNotice.swift", "LaunchWorkPolicy.swift",
            "StageAppearanceFade.swift",
        ]
        let files = try PackageSourceFile.all(in: "AgentToolingApp").filter { names.contains($0.path) }
        #expect(Set(files.map(\.path)) == names)
        let found = files.flatMap(LaunchpadSourceRulesTests.rawNumbers(in:))
        #expect(found.isEmpty, "raw numbers: \(found.joined(separator: "; "))")
    }
}
