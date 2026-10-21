import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The words for the assistant's own runs, pinned to the fragment
/// (`10-s15-assistant.html`) and the plan's new copy, and each number and
/// folder pinned to the value the runs themselves use, so the copy can never
/// promise less than a run does.
@Suite("Assistant run copy")
struct AssistantRunCopyTests {
    private static let juniper: [ClientKind] = [.codex, .claude, .gemini]

    private static func signIn(_ provider: AccountProvider, _ signIn: AccountSignIn?) -> AccountObservation {
        AccountObservation(provider: provider, observedAt: .now, signIn: signIn)
    }

    // MARK: The numbers and folders come from the runs

    @Test func everyNumberIsTheRunsOwn() {
        #expect(AssistantRunLimits.reviewDigests == SetupReviewPrompt.maximumDigests)
        #expect(AssistantRunLimits.deepDiveDigests == InsightsDeepDivePrompt.maximumDigests)
        #expect(AssistantRunLimits.messagesPerDigest == ConversationDigestBuilder.maximumUserMessages)
        #expect(AssistantRunLimits.charactersPerMessage == ConversationDigestBuilder.maximumUserMessageCharacters)
        #expect(AssistantRunLimits.lookbackDays == InsightScanOptions().lookbackDays)
        let weekly = AssistantRunCopy.plain(AssistantRunCopy.weeklyBody(reviewer: .claude, sources: [.codex, .claude]))
        #expect(weekly.contains("up to \(SetupReviewPrompt.maximumDigests) redacted conversation summaries"))
        let dive = AssistantRunCopy.plain(AssistantRunCopy.deepDiveBody(reviewer: .claude, sources: [.codex, .claude]))
        #expect(
            dive.contains(
                "up to \(InsightsDeepDivePrompt.maximumDigests) redacted summaries (\(ConversationDigestBuilder.maximumUserMessages) "
                    + "messages × \(ConversationDigestBuilder.maximumUserMessageCharacters) characters"))
        #expect(dive.contains("from \(InsightScanOptions().lookbackDays) days of"))
    }

    @Test func theFolderLineIsTheReviewsReadableFolders() {
        let line = AssistantRunCopy.folderLine(reviewer: .claude)
        #expect(line == .init(text: "~/.codex · ~/.agents · ~/.claude · ~/.gemini · ~/.kiro", isPath: true))
        #expect(line.text == SetupReviewCommandShapes.readableFolders.map { "~/" + $0 }.joined(separator: " · "))
    }

    @Test func theWithheldFoldersAreTheOnesTheRulesDeny() {
        let paths = AssistantRunCopy.weeklyBody(reviewer: .claude, sources: [.codex, .claude]).filter(\.isPath).map(\.text)
        #expect(paths == ["~/.claude/projects", "~/.codex/sessions"])
        #expect(paths == SetupReviewCommandShapes.namedWithheldFolders.map { "~/" + $0 })
        #expect(Set(SetupReviewCommandShapes.namedWithheldFolders).isSubset(of: SetupReviewCommandShapes.withheldFolders))
    }

    // MARK: Let your assistant help, as drawn

    @Test func theCardsReadAsDrawn() {
        let sources = AssistantRunCopy.sources(managed: Self.juniper)
        #expect(sources == [.codex, .claude], "Gemini CLI keeps no history Agent Tooling reads")
        #expect(
            AssistantRunCopy.plain(AssistantRunCopy.weeklyBody(reviewer: .claude, sources: sources))
                == "Once a week Claude Code reads the checkup and your apps’ configuration folders, plus up to 40 redacted "
                + "conversation summaries from Codex and Claude Code. It is not given ~/.claude/projects or ~/.codex/sessions, "
                + "where Claude Code and Codex keep conversations. Takes a few minutes, only while Agent Tooling is open.")
        #expect(
            AssistantRunCopy.plain(AssistantRunCopy.deepDiveBody(reviewer: .claude, sources: sources))
                == "Sends up to 120 redacted summaries (4 messages × 400 characters, tool names, project folder names) from 30 "
                + "days of Codex and Claude Code history to Claude Code.")
        #expect(
            AssistantRunCopy.plain(AssistantRunCopy.localBody(sources: sources))
                == "A keyword scan of the same Codex and Claude Code history. It keeps counts, not messages.")
        #expect(
            AssistantRunCopy.transientNote
                == "Chat text is processed transiently. Agent Tooling saves only aggregate counts and recommendations—not "
                + "messages or excerpts.")
    }

    @Test func eachRunIsASwitchNamedByItsTitleAndChip() {
        #expect(
            AssistantRunCopy.Run.allCases.map(AssistantRunCopy.title) == ["Weekly checkup review", "Daily deep dive", "Local insights"])
        #expect(AssistantRunCopy.Run.allCases.map(AssistantRunCopy.chip) == ["Leaves this Mac", "Leaves this Mac", "Stays on this Mac"])
        #expect(
            AssistantRunCopy.Run.allCases.map(AssistantRunCopy.accessibilityLabel) == [
                "Weekly checkup review, Leaves this Mac", "Daily deep dive, Leaves this Mac", "Local insights, Stays on this Mac",
            ])
        #expect(AssistantRunCopy.Run.allCases.filter(AssistantRunCopy.needsAssistant) == [.weeklyReview, .dailyDeepDive])
    }

    @Test func eachSwitchReadsAndWritesItsOwnRun() {
        var consent = AssistantRunConsent.off
        for run in AssistantRunCopy.Run.allCases {
            #expect(!AssistantRunCopy.isOn(run, in: consent))
            consent = AssistantRunCopy.setting(run, true, in: consent)
            #expect(AssistantRunCopy.isOn(run, in: consent))
        }
        #expect(consent == AssistantRunConsent(weeklyReview: true, dailyDeepDive: true, localInsights: true))
        #expect(
            AssistantRunCopy.setting(.dailyDeepDive, false, in: .existingBehaviour)
                == .init(weeklyReview: true, dailyDeepDive: false, localInsights: false))
    }

    // MARK: Who the assistant is

    @Test @MainActor func theAssistantIsClaudeCodeElseCodex() {
        #expect(AssistantRunCopy.reviewer(managed: Self.juniper) == .claude)
        #expect(AssistantRunCopy.reviewer(managed: [.codex, .gemini]) == .codex)
        #expect(AssistantRunCopy.reviewer(managed: [.gemini, .kiro]) == nil)
        #expect(AssistantRunCopy.reviewer(managed: Self.juniper) == WorkspaceInsightsSession.deepDiveClient(managed: Self.juniper))
        #expect(AssistantRunCopy.noAssistant == "A review needs Claude Code or Codex; this Mac is not managing either.")
        #expect(AssistantRunCopy.sources(managed: [.kiro, .gemini, .claude, .codex]) == [.codex, .claude, .kiro])
    }

    @Test func theAssistantLineSaysHowItSignsIn() {
        let max = AccountSignIn(method: .subscription, email: "you@example.com", plan: "max")
        #expect(
            AssistantRunCopy.assistantLine(.claude, signIn: Self.signIn(.claude, max)) == "Claude Code, signed in with claude.ai · Max")
        let plus = AccountSignIn(method: .subscription, email: "you@example.com", plan: "plus")
        #expect(AssistantRunCopy.assistantLine(.codex, signIn: Self.signIn(.chatGPT, plus)) == "Codex, signed in with ChatGPT · Plus")
        #expect(
            AssistantRunCopy.assistantLine(.claude, signIn: Self.signIn(.claude, AccountSignIn(method: .apiKey)))
                == "Claude Code, signed in with an API key")
        #expect(
            AssistantRunCopy.assistantLine(.claude, signIn: Self.signIn(.claude, AccountSignIn(method: .signedOut)))
                == "Claude Code, not signed in", "never \"signed in with not signed in\"")
        #expect(AssistantRunCopy.assistantLine(.claude, signIn: nil) == "Claude Code")
        #expect(AssistantRunCopy.assistantLine(.claude, signIn: Self.signIn(.claude, nil)) == "Claude Code")
    }

    // MARK: The variants

    /// Claude Code off: Codex is the assistant, and its review cannot be
    /// held to folders, so its card says what it reads and claims no folder
    /// is withheld.
    @Test func withCodexTheCardSaysWhatItReads() {
        let sources = AssistantRunCopy.sources(managed: [.codex, .gemini])
        let weekly = AssistantRunCopy.plain(AssistantRunCopy.weeklyBody(reviewer: .codex, sources: sources))
        #expect(
            weekly
                == "Once a week Codex reads the checkup and your apps’ configuration folders, plus up to 40 redacted conversation "
                + "summaries from Codex. Takes a few minutes, only while Agent Tooling is open.")
        #expect(!weekly.contains("not given"))
        #expect(AssistantRunCopy.folderLine(reviewer: .codex) == .init(text: "Codex reads from your home folder, read-only."))
        #expect(AssistantRunCopy.plain(AssistantRunCopy.deepDiveBody(reviewer: .codex, sources: sources)).hasSuffix("history to Codex."))
    }

    @Test func anAPIKeySignInSaysItIsBilledToTheKey() {
        let key = Self.signIn(.claude, AccountSignIn(method: .apiKey))
        #expect(AssistantRunCopy.isBilledToKey(key))
        for run in [AssistantRunCopy.Run.weeklyReview, .dailyDeepDive] {
            #expect(
                AssistantRunCopy.plain(AssistantRunCopy.body(run, managed: Self.juniper, signIn: key))
                    .hasSuffix(" Uses your API key, so it is billed to that key."))
        }
        #expect(!AssistantRunCopy.plain(AssistantRunCopy.body(.localInsights, managed: Self.juniper, signIn: key)).contains("API key"))
        let subscription = Self.signIn(.claude, AccountSignIn(method: .subscription, plan: "max"))
        #expect(
            !AssistantRunCopy.plain(AssistantRunCopy.body(.weeklyReview, managed: Self.juniper, signIn: subscription)).contains("API key"))
    }

    /// With no assistant, the line above the runs says why no review can
    /// run, so the weekly review's run adds nothing to it; the deep dive's
    /// says why it cannot run either. Each sentence is said once.
    @Test func withNoAssistantTheCardsSayWhy() {
        let managed: [ClientKind] = [.gemini, .kiro]
        #expect(AssistantRunCopy.body(.weeklyReview, managed: managed, signIn: nil).isEmpty)
        #expect(
            AssistantRunCopy.plain(AssistantRunCopy.body(.dailyDeepDive, managed: managed, signIn: nil))
                == "A deep dive needs Claude Code or Codex; this Mac is not managing either.")
        #expect(AssistantRunCopy.noDeepDiveAssistant == "A deep dive needs Claude Code or Codex; this Mac is not managing either.")
        let said = AssistantRunCopy.Run.allCases.map { AssistantRunCopy.plain(AssistantRunCopy.body($0, managed: managed, signIn: nil)) }
        #expect(!said.contains(AssistantRunCopy.noAssistant), "the assistant's line says it, and only it")
        #expect(
            AssistantRunCopy.plain(AssistantRunCopy.body(.localInsights, managed: managed, signIn: nil))
                == "A keyword scan of the same Kiro CLI history. It keeps counts, not messages.")
        #expect(
            AssistantRunCopy.plain(AssistantRunCopy.body(.localInsights, managed: [.gemini], signIn: nil))
                == "None of the apps this Mac manages keeps a history Agent Tooling reads.")
    }

    // MARK: Home's notice, Checkup and Insights

    @Test func theNoticeNamesTheAssistantThatRuns() {
        #expect(AssistantRunCopy.noticeTitle == "Your assistant reviews this Mac on its own")
        #expect(
            AssistantRunCopy.noticeBody(reviewer: .claude)
                == "Once a week Claude Code reads the checkup and your apps’ configuration folders, plus up to 40 redacted "
                + "conversation summaries. Once a day the deep dive sends up to 120 redacted summaries to Claude Code. Both run only "
                + "while Agent Tooling is open.")
        #expect(
            AssistantRunCopy.noticeBody(reviewer: .codex)
                == "Once a week Codex reads the checkup and your apps’ configuration folders, plus up to 40 redacted conversation "
                + "summaries. Codex reads from your home folder, read-only. Once a day the deep dive sends up to 120 redacted "
                + "summaries to Codex. Both run only while Agent Tooling is open.")
        #expect([AssistantRunCopy.keepThemOn, AssistantRunCopy.turnThemOff] == ["Keep them on", "Turn them off"])
        #expect(
            AssistantRunCopy.changeAnyTimeLead + AssistantRunCopy.settingsPlace + AssistantRunCopy.changeAnyTimeEnd
                == "You can change this any time in Settings › General.")
    }

    @Test func checkupsHelpMentionsSummariesOnlyWhenTheyGo() {
        #expect(
            AssistantRunCopy.reviewHelp(reviewer: .claude, sendsSummaries: true)
                == "Claude Code reads the audit and your apps’ configuration folders, plus up to 40 redacted conversation summaries, "
                + "then says what to change. It can read; it cannot change anything.")
        #expect(
            AssistantRunCopy.reviewHelp(reviewer: .codex, sendsSummaries: false)
                == "Codex reads the audit and your apps’ configuration folders, then says what to change. It can read; it cannot "
                + "change anything.")
    }

    @Test func insightsSaysItRunsOnItsOwnOnlyWhenItDoes() {
        let base =
            "Runs the keyword pass, then has your signed-in Claude Code read digests of the selected conversations and say what "
            + "you keep doing by hand."
        #expect(AssistantRunCopy.deepDiveHelp(reviewer: .claude, runsDaily: false) == base)
        #expect(
            AssistantRunCopy.deepDiveHelp(reviewer: .claude, runsDaily: true) == base
                + " Runs on its own once a day when Agent Tooling opens.")
    }
}
