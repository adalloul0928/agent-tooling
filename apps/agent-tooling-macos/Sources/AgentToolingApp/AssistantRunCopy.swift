import AgentToolingCore
import Foundation

/// What Agent Tooling says about the assistant's own runs: the weekly
/// checkup review, the daily deep dive and the local insights scan.
///
/// Let your assistant help, Settings › General, Home's notice, Checkup and
/// Insights all say it in these words, built from the values the runs use
/// (`AssistantRunLimits`: how many summaries, what each holds, how far back,
/// which folders), from the apps this Mac manages, in the app order, and from
/// which assistant runs them. So no screen can promise less than a run does,
/// or name an app it does not read.
enum AssistantRunCopy {
    /// One of the three runs a Mac allows or not.
    enum Run: CaseIterable, Hashable, Sendable {
        case weeklyReview
        case dailyDeepDive
        case localInsights
    }

    /// A stretch of a sentence; a path is set in the mono face.
    struct Span: Equatable, Sendable {
        let text: String
        var isPath = false
    }

    // MARK: The runs

    static func title(_ run: Run) -> String {
        switch run {
        case .weeklyReview: "Weekly checkup review"
        case .dailyDeepDive: "Daily deep dive"
        case .localInsights: "Local insights"
        }
    }

    /// Whether anything leaves this Mac: the one fact the person needs before
    /// turning a run on, so it is shown at full strength either way.
    static func chip(_ run: Run) -> String {
        run == .localInsights ? "Stays on this Mac" : "Leaves this Mac"
    }

    /// What VoiceOver calls a run's switch: its title and its chip.
    static func accessibilityLabel(_ run: Run) -> String {
        "\(title(run)), \(chip(run))"
    }

    /// Whether a run needs Claude Code or Codex to run it.
    static func needsAssistant(_ run: Run) -> Bool {
        run != .localInsights
    }

    /// Whether `consent` allows `run`.
    static func isOn(_ run: Run, in consent: AssistantRunConsent) -> Bool {
        switch run {
        case .weeklyReview: consent.weeklyReview
        case .dailyDeepDive: consent.dailyDeepDive
        case .localInsights: consent.localInsights
        }
    }

    /// `consent` with `run` turned on or off.
    static func setting(_ run: Run, _ isOn: Bool, in consent: AssistantRunConsent) -> AssistantRunConsent {
        var next = consent
        switch run {
        case .weeklyReview: next.weeklyReview = isOn
        case .dailyDeepDive: next.dailyDeepDive = isOn
        case .localInsights: next.localInsights = isOn
        }
        return next
    }

    // MARK: Who and what

    /// The assistants in the order one is chosen: Claude Code, else Codex.
    static let assistants: [ClientKind] = [.claude, .codex]

    /// The assistant that runs the review and the deep dive on a Mac that
    /// manages `managed`, or nil when it manages neither.
    static func reviewer(managed: [ClientKind]) -> ClientKind? {
        assistants.first(where: managed.contains)
    }

    /// The apps whose history the runs read: the managed ones that keep a
    /// history this app can read at all, in the app order.
    static func sources(managed: [ClientKind]) -> [ClientKind] {
        ClientKind.allCases.filter { managed.contains($0) && AssistantRunLimits.historyClients.contains($0) }
    }

    /// Why no review can run on a Mac that manages neither assistant. The
    /// assistants are named in the order one is chosen.
    static var noAssistant: String {
        "A review needs \(assistantNames); this Mac is not managing either."
    }

    /// Why no deep dive can run on such a Mac: Insights' Deep dive button
    /// and the deep dive's switch say it.
    static var noDeepDiveAssistant: String {
        "A deep dive needs \(assistantNames); this Mac is not managing either."
    }

    private static var assistantNames: String {
        assistants.map(\.rawValue).joined(separator: " or ")
    }

    /// Why local insights has nothing to read on a Mac whose apps keep no
    /// history this app reads.
    static let noHistory = "None of the apps this Mac manages keeps a history Agent Tooling reads."

    /// Who the assistant is and how it signs in: "Claude Code, signed in with
    /// claude.ai · Max". Just the name until its sign-in has been read.
    static func assistantLine(_ reviewer: ClientKind, signIn observation: AccountObservation?) -> String {
        guard let observation, let signIn = observation.signIn else { return reviewer.rawValue }
        if signIn.method == .signedOut { return "\(reviewer.rawValue), not signed in" }
        return "\(reviewer.rawValue), signed in with \(signIn.summary(for: observation.provider))"
    }

    /// Whether the assistant signs in with an API key, which the runs that
    /// use it are billed to.
    static func isBilledToKey(_ observation: AccountObservation?) -> Bool {
        observation?.signIn?.method == .apiKey
    }

    static let billedToKey = "Uses your API key, so it is billed to that key."

    // MARK: What each run does

    /// The weekly card's words. With Claude Code they name the two folders
    /// its rules withhold, where Claude Code and Codex keep conversations;
    /// Codex's review cannot be held to folders, so its card says nothing it
    /// could not keep.
    static func weeklyBody(reviewer: ClientKind, sources: [ClientKind], billedToKey billed: Bool = false) -> [Span] {
        var spans = [
            Span(
                text: "Once a week \(reviewer.rawValue) reads the checkup and your apps’ configuration folders, plus up to "
                    + "\(AssistantRunLimits.reviewDigests) redacted conversation summaries from \(names(sources)). ")
        ]
        if reviewer == .claude {
            let withheld = AssistantRunLimits.namedWithheldFolders
            let owners = withheld.compactMap(owner(of:)).map(\.rawValue)
            spans.append(Span(text: "It is not given "))
            for (index, folder) in withheld.enumerated() {
                if index > 0 { spans.append(Span(text: " or ")) }
                spans.append(Span(text: "~/" + folder, isPath: true))
            }
            spans.append(Span(text: ", where \(LaunchpadCopy.list(owners)) keep conversations. "))
        }
        spans.append(Span(text: "Takes a few minutes, only while Agent Tooling is open."))
        if billed { spans.append(Span(text: " " + billedToKey)) }
        return spans
    }

    /// The folders the weekly review reads, under its card: Claude Code's
    /// readable folders in the app order, or Codex's honest sentence.
    static func folderLine(reviewer: ClientKind) -> Span {
        guard reviewer == .claude else { return Span(text: "Codex reads from your home folder, read-only.") }
        return Span(text: AssistantRunLimits.reviewFolders.map { "~/" + $0 }.joined(separator: " · "), isPath: true)
    }

    static func deepDiveBody(reviewer: ClientKind, sources: [ClientKind], billedToKey billed: Bool = false) -> [Span] {
        let limits = AssistantRunLimits.self
        var text =
            "Sends up to \(limits.deepDiveDigests) redacted summaries (\(limits.messagesPerDigest) messages × "
            + "\(limits.charactersPerMessage) characters, tool names, project folder names) from \(limits.lookbackDays) days of "
            + "\(names(sources)) history to \(reviewer.rawValue)."
        if billed { text += " " + billedToKey }
        return [Span(text: text)]
    }

    static func localBody(sources: [ClientKind]) -> [Span] {
        guard !sources.isEmpty else { return [Span(text: noHistory)] }
        return [Span(text: "A keyword scan of the same \(names(sources)) history. It keeps counts, not messages.")]
    }

    /// A run's words on a Mac that manages `managed`, as Let your assistant
    /// help and Settings show them. With no assistant, the line above the
    /// runs already says why no review can run, so the weekly review's run
    /// adds nothing to it, and the deep dive's says why it cannot run either.
    static func body(_ run: Run, managed: [ClientKind], signIn: AccountObservation?) -> [Span] {
        let sources = sources(managed: managed)
        guard let reviewer = reviewer(managed: managed) else {
            switch run {
            case .weeklyReview: return []
            case .dailyDeepDive: return [Span(text: noDeepDiveAssistant)]
            case .localInsights: return localBody(sources: sources)
            }
        }
        switch run {
        case .weeklyReview: return weeklyBody(reviewer: reviewer, sources: sources, billedToKey: isBilledToKey(signIn))
        case .dailyDeepDive: return deepDiveBody(reviewer: reviewer, sources: sources, billedToKey: isBilledToKey(signIn))
        case .localInsights: return localBody(sources: sources)
        }
    }

    /// Spans as one sentence, for VoiceOver and for a test to read.
    static func plain(_ spans: [Span]) -> String {
        spans.map(\.text).joined()
    }

    /// The note every place that offers the runs ends with.
    static let transientNote =
        "Chat text is processed transiently. Agent Tooling saves only aggregate counts and recommendations—not messages or excerpts."

    // MARK: Home's notice

    /// The one-time notice on Home for a workspace made before the choice
    /// existed, whose runs go on as they always did until it is answered.
    static let noticeTitle = "Your assistant reviews this Mac on its own"

    /// What the runs a workspace made before the choice existed keep doing,
    /// naming the assistant that does it.
    static func noticeBody(reviewer: ClientKind) -> String {
        let limits = AssistantRunLimits.self
        var text =
            "Once a week \(reviewer.rawValue) reads the checkup and your apps’ configuration folders, plus up to "
            + "\(limits.reviewDigests) redacted conversation summaries. "
        if reviewer != .claude { text += folderLine(reviewer: reviewer).text + " " }
        text +=
            "Once a day the deep dive sends up to \(limits.deepDiveDigests) redacted summaries to \(reviewer.rawValue). "
            + "Both run only while Agent Tooling is open."
        return text
    }

    static let keepThemOn = "Keep them on"
    static let turnThemOff = "Turn them off"
    /// The place the notice points at, set as a link.
    static let settingsPlace = "Settings › General"
    /// The notice's last line, around `settingsPlace`.
    static let changeAnyTimeLead = "You can change this any time in "
    static let changeAnyTimeEnd = "."

    // MARK: Checkup and Insights

    /// The help on Checkup's Ask button. Summaries go with a review only
    /// while this Mac allows the weekly one, and the help says so then.
    static func reviewHelp(reviewer: ClientKind, sendsSummaries: Bool) -> String {
        let summaries = sendsSummaries ? ", plus up to \(AssistantRunLimits.reviewDigests) redacted conversation summaries" : ""
        return "\(reviewer.rawValue) reads the audit and your apps’ configuration folders\(summaries), then says what to change. "
            + "It can read; it cannot change anything."
    }

    /// The help on Insights' Deep dive button. It runs on its own only while
    /// this Mac allows the daily one.
    static func deepDiveHelp(reviewer: ClientKind, runsDaily: Bool) -> String {
        "Runs the keyword pass, then has your signed-in \(reviewer.rawValue) read digests of the selected conversations "
            + "and say what you keep doing by hand." + (runsDaily ? " Runs on its own once a day when Agent Tooling opens." : "")
    }

    // MARK: Helpers

    /// The app whose folder `relative` is in: ".claude/projects" is Claude
    /// Code's.
    static func owner(of relative: String) -> ClientKind? {
        switch relative.split(separator: "/").first {
        case ".codex": .codex
        case ".claude": .claude
        case ".gemini": .gemini
        case ".kiro": .kiro
        default: nil
        }
    }

    private static func names(_ apps: [ClientKind]) -> String {
        LaunchpadCopy.list(apps.map(\.rawValue))
    }
}
