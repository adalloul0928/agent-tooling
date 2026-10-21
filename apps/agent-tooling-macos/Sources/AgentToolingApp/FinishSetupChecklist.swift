import AgentToolingCore
import Foundation

extension FinishSetupItem {
    /// Whether an open row is one of Home's suggestions rather than
    /// something setup left for later: trying a skill, tracking projects,
    /// and sharing with other Macs, which setup offers and never needs. Done
    /// counts the rest as left for later and says how many suggestions Home
    /// adds, so the two screens count alike.
    var isSuggestion: Bool { self == .trySkill || self == .trackProjects || self == .connectOtherMacs }

    /// Where the row's own action lives: the place a tick names when nobody
    /// watched it happen.
    var canonicalPlace: FinishSetupPlace {
        switch self {
        case .makeSkillsYours, .lookAtCheckup: .checkup
        case .putToolsInApps, .connectAgentTooling, .signInConnections: .apps
        case .connectOtherMacs: .settings
        case .trySkill: .library
        case .trackProjects: .projects
        }
    }

    /// Whether the row can come true while the person looks at something
    /// else: a sync pass that finishes, installs a policy runs as changes
    /// arrive. Such a tick names the row's own place, never the screen on
    /// show.
    var flipsInBackground: Bool { self == .connectOtherMacs || self == .putToolsInApps }

    /// Whether one of setup's own steps does this row, so what a first run
    /// did before it was left for later is said to be done in setup.
    var isSetupStep: Bool {
        self == .makeSkillsYours || self == .putToolsInApps || self == .connectAgentTooling || self == .connectOtherMacs
    }
}

extension FinishSetupPlace {
    /// The place a screen of the main window belongs to. Checkup is its own
    /// place, though the sidebar files it under Apps.
    init(section: AppSection) {
        switch section {
        case .overview: self = .home
        case .marketplace: self = .discover
        case .skills, .plugins, .mcpServers, .presets: self = .library
        case .checkup: self = .checkup
        case .syncCenter, .appSettings, .health, .accounts: self = .apps
        case .insights: self = .insights
        case .activity, .history: self = .activity
        case .projects: self = .projects
        case .settings, .sync: self = .settings
        }
    }

    /// The words a done row ends with: "in setup", "from Checkup".
    var phrase: String { LaunchpadCopy.FinishSetup.place(self) }
}

/// Home's Finish setting up card, worked out from the facts alone: its rows
/// in the order setup fixed them, which are done and where, and the one
/// action each open row offers.
///
/// A row is done once it is ticked, and a tick latches: nothing here unticks
/// a row. What makes a row tick is `satisfied(_:)`, which only positive
/// evidence satisfies; the tracker turns it into a tick, naming where it
/// happened. Done builds the same rows (`handOff`), so its "Left for later"
/// and Home's open rows are one count.
struct FinishSetupChecklist: Equatable {
    /// What an open row's button does.
    enum Action: Equatable, Sendable {
        /// Reopens the stage at the step a first run was left at.
        case resume(LaunchpadStep)
        /// Reopens the stage at Before you start.
        case moveToApplications
        case openCheckup
        /// Opens Apps on the prepared plan, for review.
        case reviewChanges
        /// Reopens the stage at Let your apps ask Agent Tooling.
        case connectAgentTooling
        /// Reopens the stage at Use your library on your other Macs.
        case connectOtherMacs
        /// Opens the confirmation that names the check before it runs.
        case checkConnections
        /// The same confirmation, at its sign-in.
        case signIn
        /// Checks the apps, then opens Terminal with the skill invoked.
        case trySkill(SetupProgressRecord.Trial)
        case openProjects
    }

    /// One row of the card.
    struct Row: Identifiable, Equatable, Sendable {
        /// Nil for the two rows that are not counted: Resume and Move.
        let item: FinishSetupItem?
        let title: String
        let caption: String?
        /// A command the caption ends with, set in the monospaced face:
        /// "codex $release-notes".
        var command: String?
        let isDone: Bool
        var actionTitle: String?
        var action: Action?
        /// Where a done row was done: "in setup".
        var donePlace: String?

        var id: String {
            if let item { return item.rawValue }
            return action == .moveToApplications ? "move" : "resume"
        }
    }

    /// Resume, while setup was left for later. Not counted.
    let lead: Row?
    /// Move Agent Tooling to Applications, while this copy runs from
    /// elsewhere. Not counted.
    let extra: Row?
    /// The counted rows, in the record's order: capsule `i` is row `i`.
    let rows: [Row]

    var done: Int { rows.count(where: \.isDone) }
    var total: Int { rows.count }
    var left: Int { total - done }
    /// "Finish setting up", or "Setup finished" once every row is done.
    var title: String {
        done == total ? LaunchpadCopy.FinishSetup.finishedTitle : LaunchpadCopy.FinishSetup.title
    }
    /// The capsules: one per row, filled once its row is done.
    var filled: [Bool] { rows.map(\.isDone) }

    // MARK: Showing

    /// Whether Home shows the card for `record`: a setup that handed off on
    /// a Mac that may change its library, with the card not hidden. A
    /// workspace made before Launchpad has no record and no card; a record a
    /// newer build wrote reads as finished and shows none either.
    static func isShown(_ record: SetupProgressRecord?, isWritable: Bool) -> Bool {
        guard let record, record.hiddenAt == nil else { return false }
        return isEligible(record, isWritable: isWritable)
    }

    /// The card as it stands, or nil when Home shows none. Move alone makes
    /// no card: whether the card shows never waits on where this copy runs
    /// from, which is read only once it does.
    static func make(_ facts: FinishSetupFacts, now: Date) -> FinishSetupChecklist? {
        guard let record = facts.record, isShown(record, isWritable: facts.isWritable) else { return nil }
        let card = build(record, facts: facts, now: now)
        return card.rows.isEmpty && card.lead == nil ? nil : card
    }

    /// How many rows are open while the card is hidden, for the sidebar's
    /// "Finish setting up · 4 left". Nil while the card shows, or when
    /// nothing is left.
    static func chipLeft(_ facts: FinishSetupFacts, now: Date) -> Int? {
        guard let record = facts.record, record.hiddenAt != nil, isEligible(record, isWritable: facts.isWritable) else {
            return nil
        }
        let left = build(record, facts: facts, now: now).left
        return left > 0 ? left : nil
    }

    private static func isEligible(_ record: SetupProgressRecord, isWritable: Bool) -> Bool {
        isWritable && record.state != .inProgress && record.formatVersion <= SetupProgressRecord.currentFormatVersion
    }

    // MARK: Which rows

    /// What the setup that is finishing did itself, as Done knows it.
    struct HandOff: Equatable, Sendable {
        /// The skills made yours, in the order they were made.
        var madeYours: [String] = []
        /// The review's install, when one ran: its steps, how many did not
        /// finish (failed, or stopped before), and its receipt ("Installed 4
        /// changes · 9:52 AM").
        var installed: Int?
        var installUnfinished = 0
        var receipt: String?
        /// The apps Agent Tooling's own connection reached.
        var helperApps: [ClientKind] = []
        /// Whether this walk shared the library with the other Macs: its own
        /// publish went through, or the join it made synced.
        var synced = false
        /// The skill Home offers to try, and where.
        var trial: SetupProgressRecord.Trial?
        /// The connections that may need a sign-in as this setup leaves
        /// them, which Done keeps for the card.
        var signInHints: [FinishSetupFacts.Connection] = []
    }

    /// The rows a setup leaves on Home, in the card's order. Done passes
    /// what it did; a setup left for later has no list of its own, so its
    /// card reads the rows from the facts alone. A row already ticked stays
    /// a row either way: a tick latches, so the count never goes back.
    static func items(_ facts: FinishSetupFacts, handOff: HandOff?) -> [FinishSetupItem] {
        let ticked = Set(facts.record?.ticks.map(\.item) ?? [])
        return FinishSetupItem.allCases.filter { item in
            ticked.contains(item) || isListed(item, facts: facts, handOff: handOff)
        }
    }

    /// Whether `item` is a row of the card on its own evidence.
    private static func isListed(_ item: FinishSetupItem, facts: FinishSetupFacts, handOff: HandOff?) -> Bool {
        switch item {
        case .makeSkillsYours:
            // Only when setup made a skill yours; otherwise Checkup's row
            // counts the skills that are not.
            return handOff.map { !$0.madeYours.isEmpty } ?? isSatisfied(.makeSkillsYours, facts)
        case .putToolsInApps:
            return handOff?.installed != nil || (facts.pendingChanges ?? 0) > 0
                || (handOff == nil && facts.lastInstall != nil)
        case .connectAgentTooling:
            guard !facts.managedClients.isEmpty else { return false }
            // Done lists it only when setup left it undone. A setup left for
            // later lists it on any Mac with an app that takes it, so that
            // connecting it, from the card or before, ticks it in place.
            guard let handOff else { return true }
            return facts.helperConnectedApps.isEmpty && handOff.helperApps.isEmpty
        case .connectOtherMacs:
            return true
        case .signInConnections:
            let hints = handOff?.signInHints ?? signInHints(facts)
            guard let check = facts.connectionCheck else { return !hints.isEmpty }
            return !hints.isEmpty || !check.signInOffers.isEmpty || !check.needsAuthentication.isEmpty
        case .lookAtCheckup:
            // A setup left for later keeps the findings it was left with
            // (the tracker records them), so fixing the last of them ticks
            // the row rather than taking it away.
            let recorded = handOff == nil && facts.record?.evidence.checkupFindingIDs.isEmpty == false
            return recorded || facts.openFindings?.isEmpty == false
        case .trySkill:
            if let handOff { return handOff.trial != nil }
            return trialTarget(facts) != nil
        case .trackProjects:
            return handOff == nil || facts.trackedProjects == 0
        }
    }

    /// The card's rows for `record`, in the card's order: the ones Done fixed
    /// for a finished setup, or for a setup left for later the ones its facts
    /// list, with every row already ticked kept in either case. The card and
    /// the tracker read the same rows.
    static func rows(_ record: SetupProgressRecord, facts: FinishSetupFacts) -> [FinishSetupItem] {
        guard record.state == .finished else {
            var current = facts
            current.record = record
            return items(current, handOff: nil)
        }
        let listed = Set(record.items).union(record.ticks.map(\.item))
        return FinishSetupItem.allCases.filter(listed.contains)
    }

    /// The rows Done ticks as it hands off, each done in setup.
    static func setupTicks(_ handOff: HandOff, items: [FinishSetupItem], now: Date) -> [SetupProgressRecord.Tick] {
        let copy = LaunchpadCopy.FinishSetup.self
        var ticks: [SetupProgressRecord.Tick] = []
        for item in items {
            switch item {
            case .makeSkillsYours where !handOff.madeYours.isEmpty:
                ticks.append(.init(item: item, place: .setup, at: now, summary: LaunchpadCopy.list(handOff.madeYours)))
            case .putToolsInApps where (handOff.installed ?? 0) > 0 && handOff.installUnfinished == 0:
                ticks.append(.init(item: item, place: .setup, at: now, summary: handOff.receipt))
            case .connectAgentTooling where !handOff.helperApps.isEmpty:
                ticks.append(
                    .init(item: item, place: .setup, at: now, summary: copy.connected(to: appList(handOff.helperApps))))
            case .connectOtherMacs where handOff.synced:
                ticks.append(.init(item: item, place: .setup, at: now, summary: nil))
            default:
                break
            }
        }
        return ticks
    }

    /// Open rows setup left for later: what Done counts under "Left for
    /// later". A row the facts already satisfy is not left: Home ticks it on
    /// its first look.
    static func leftForLater(_ record: SetupProgressRecord, satisfied: Set<FinishSetupItem> = []) -> [FinishSetupItem] {
        open(record, satisfied: satisfied).filter { !$0.isSuggestion }
    }

    /// Open rows Home adds as suggestions.
    static func suggestions(_ record: SetupProgressRecord, satisfied: Set<FinishSetupItem> = []) -> [FinishSetupItem] {
        open(record, satisfied: satisfied).filter(\.isSuggestion)
    }

    private static func open(_ record: SetupProgressRecord, satisfied: Set<FinishSetupItem>) -> [FinishSetupItem] {
        let ticked = Set(record.ticks.map(\.item))
        return record.items.filter { !ticked.contains($0) && !satisfied.contains($0) }
    }

    // MARK: What makes a row true

    /// The rows the facts show done now, on positive evidence only. Trying a
    /// skill is not here: it is ticked by the trial itself, where it opened.
    static func satisfied(_ facts: FinishSetupFacts) -> Set<FinishSetupItem> {
        Set(FinishSetupItem.allCases.filter { isSatisfied($0, facts) })
    }

    private static func isSatisfied(_ item: FinishSetupItem, _ facts: FinishSetupFacts) -> Bool {
        switch item {
        case .makeSkillsYours:
            return !newlyYours(facts).isEmpty
        case .putToolsInApps:
            guard let install = facts.lastInstall else { return false }
            return install.changes > 0 && install.failures == 0
        case .connectAgentTooling:
            return !facts.helperConnectedApps.isEmpty
        case .connectOtherMacs:
            return facts.sync?.lastSynced != nil
        case .signInConnections:
            // Codex reads every connection's status as unknown, and an
            // unknown one is neither a sign-in to offer nor one that needs
            // authentication, so it never holds this row open.
            guard let check = facts.connectionCheck else { return false }
            return check.signInOffers.isEmpty && check.needsAuthentication.isEmpty
        case .lookAtCheckup:
            guard let open = facts.openFindings else { return false }
            let recorded = Set(facts.record?.evidence.checkupFindingIDs ?? [])
            // Fixed (gone from the audit) or dismissed: either way, no
            // longer open.
            return recorded.isEmpty ? open.isEmpty : recorded.isDisjoint(with: open.map(\.id))
        case .trySkill:
            return false
        case .trackProjects:
            return facts.trackedProjects > 0
        }
    }

    /// What a tick says about its row, as it ticks.
    static func summary(for item: FinishSetupItem, facts: FinishSetupFacts, now: Date) -> String? {
        let copy = LaunchpadCopy.FinishSetup.self
        switch item {
        case .makeSkillsYours:
            return LaunchpadCopy.list(newlyYours(facts).map(\.name))
        case .putToolsInApps:
            return facts.lastInstall.map {
                LaunchpadCopy.Review.receipt(changes: $0.changes, at: now.formatted(date: .omitted, time: .shortened))
            }
        case .connectAgentTooling:
            return copy.connected(to: appList(facts.helperConnectedApps))
        case .connectOtherMacs, .trySkill:
            return nil
        case .signInConnections:
            let hinted = Set(signInHints(facts).map(\.serverID))
            let signedIn = facts.connectionCheck?.connected.filter { hinted.contains($0.serverID) } ?? []
            return signedIn.isEmpty ? copy.noSignInNeeded : copy.signedIn(LaunchpadCopy.list(distinct(signedIn.map(\.name))))
        case .lookAtCheckup:
            return copy.allLookedAt
        case .trackProjects:
            return copy.projectsTracked(facts.trackedProjects)
        }
    }

    /// The skills that are yours now and were not before this setup: on a
    /// join, the skills that came across from another Mac are not made
    /// yours here.
    private static func newlyYours(_ facts: FinishSetupFacts) -> [FinishSetupFacts.Skill] {
        let before = Set(facts.record?.evidence.personalSkillsBefore ?? [])
        return facts.personalSkills.filter { !before.contains($0.id) }
    }

    /// The connections that may need a sign-in before any check: what Done
    /// kept, or for a setup left for later, what the last check of the apps
    /// shows.
    static func signInHints(_ facts: FinishSetupFacts) -> [FinishSetupFacts.Connection] {
        if let record = facts.record, record.state == .finished {
            return record.evidence.mayNeedSignIn.map { .init(name: $0.connection, serverID: $0.serverID, client: $0.client) }
        }
        return facts.signInCandidates
    }

    /// The skill Home offers to try and where, from the facts alone: a skill
    /// made yours in this setup where an app that can open it has the
    /// library's copy (every app with it has the same copy), else the first
    /// skill found in Codex, then in Claude Code. Done, which knows the order
    /// skills were made yours in, decides it itself.
    static func trialTarget(_ facts: FinishSetupFacts) -> SetupProgressRecord.Trial? {
        let apps = trialApps(facts)
        for skill in newlyYours(facts) {
            guard let declared = skill.declaredName, facts.holdsOneCopy(of: declared) else { continue }
            if let app = apps.first(where: { facts.observedSkills[$0]?.contains(declared) == true }) {
                return .init(skillName: skill.name, skillID: declared, client: app)
            }
        }
        return firstObservedSkill(facts)
    }

    /// The first skill the last check found in Codex, then in Claude Code,
    /// by the library's name for it.
    static func firstObservedSkill(_ facts: FinishSetupFacts) -> SetupProgressRecord.Trial? {
        for app in [ClientKind.codex, .claude] where trialApps(facts).contains(app) {
            let named = (facts.observedSkills[app] ?? []).filter(SkillTrialCommandShapes.isValidSkillReference)
                .map { (declared: $0, name: facts.names[$0] ?? $0) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if let first = named.first { return .init(skillName: first.name, skillID: first.declared, client: app) }
        }
        return nil
    }

    /// The managed apps a skill can be tried in, in the app order.
    static func trialApps(_ facts: FinishSetupFacts) -> [ClientKind] {
        ClientKind.allCases.filter { facts.managedClients.contains($0) && SkillTrialCommandShapes.isSupported($0) }
    }

    // MARK: Building the card

    private static func build(_ record: SetupProgressRecord, facts: FinishSetupFacts, now: Date) -> FinishSetupChecklist {
        let copy = LaunchpadCopy.FinishSetup.self
        let ticks = Dictionary(record.ticks.map { ($0.item, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = Self.rows(record, facts: facts).map { row($0, tick: ticks[$0], record: record, facts: facts, now: now) }
        let lead: Row? =
            record.state == .deferred
            ? Row(
                item: nil, title: copy.resume(next: copy.next(record.cursor ?? .found, device: facts.deviceName)),
                caption: nil, isDone: false, actionTitle: copy.resumeButton, action: .resume(record.cursor ?? .found))
            : nil
        let extra: Row? =
            facts.offersMove
            ? Row(
                item: nil, title: copy.moveTitle, caption: copy.moveCaption, isDone: false, actionTitle: copy.moveButton,
                action: .moveToApplications)
            : nil
        return FinishSetupChecklist(lead: lead, extra: extra, rows: rows)
    }

    private static func row(
        _ item: FinishSetupItem, tick: SetupProgressRecord.Tick?, record: SetupProgressRecord, facts: FinishSetupFacts,
        now: Date
    ) -> Row {
        let copy = LaunchpadCopy.FinishSetup.self
        if let tick {
            return Row(
                item: item, title: title(item, record: record, facts: facts),
                caption: doneCaption(item, tick: tick, facts: facts, now: now), isDone: true, donePlace: tick.place.phrase)
        }
        let title = title(item, record: record, facts: facts)
        switch item {
        case .makeSkillsYours:
            let unmanaged = Set((facts.openFindings ?? []).filter { $0.kind == .unmanagedSkill }.map(\.name)).count
            return Row(
                item: item, title: title, caption: copy.skillsNotYoursYet(unmanaged), isDone: false,
                actionTitle: copy.openCheckup, action: .openCheckup)
        case .putToolsInApps:
            let pending = facts.pendingChanges ?? 0
            return Row(
                item: item, title: title, caption: pending > 0 ? copy.changesWaiting(pending) : copy.nothingInstalledYet,
                isDone: false, actionTitle: ActionTitles.reviewChanges(count: facts.pendingChanges), action: .reviewChanges)
        case .connectAgentTooling:
            return Row(
                item: item, title: title, caption: copy.connectAgentToolingCaption, isDone: false, actionTitle: copy.connect,
                action: .connectAgentTooling)
        case .connectOtherMacs:
            return Row(
                item: item, title: title, caption: copy.otherMacsCaption, isDone: false, actionTitle: copy.connect,
                action: .connectOtherMacs)
        case .signInConnections:
            guard let check = facts.connectionCheck else {
                return Row(
                    item: item, title: title, caption: copy.notChecked(mayNeed: who(signInHints(facts))), isDone: false,
                    actionTitle: copy.checkConnections, action: .checkConnections)
            }
            if !check.signInOffers.isEmpty {
                return Row(
                    item: item, title: title, caption: copy.needSignIn(who(check.signInOffers), count: check.signInOffers.count),
                    isDone: false, actionTitle: copy.signIn, action: .signIn)
            }
            let elsewhere = check.signInElsewhere
            return Row(
                item: item, title: title,
                caption: elsewhere.isEmpty ? copy.checkedNothingToSignIn : copy.signInInItsApp(who(elsewhere), count: elsewhere.count),
                isDone: false, actionTitle: copy.checkConnections, action: .checkConnections)
        case .lookAtCheckup:
            return Row(
                item: item, title: title,
                caption: LaunchpadCopy.list(
                    distinct(FinishSetupFacts.Finding.inWordingOrder(recordedOpen(record, facts)).map(\.name))),
                isDone: false, actionTitle: copy.openCheckup, action: .openCheckup)
        case .trySkill:
            let trial = trial(record, facts)
            return Row(
                item: item, title: title, caption: copy.tryCaption, command: trial.flatMap(command(for:)), isDone: false,
                actionTitle: copy.tryIt, action: trial.map(Action.trySkill))
        case .trackProjects:
            let folders = record.evidence.projectFolderCount ?? 0
            return Row(
                item: item, title: title, caption: folders > 0 ? copy.foldersClaudeCodeWorkedIn(folders) : copy.addFolders,
                isDone: false, actionTitle: copy.openProjects, action: .openProjects)
        }
    }

    private static func title(_ item: FinishSetupItem, record: SetupProgressRecord, facts: FinishSetupFacts) -> String {
        let copy = LaunchpadCopy.FinishSetup.self
        switch item {
        case .makeSkillsYours: return copy.makeSkillsYours
        case .putToolsInApps: return copy.putToolsInApps
        case .connectAgentTooling: return copy.connectAgentTooling
        case .connectOtherMacs: return copy.connectOtherMacs
        case .signInConnections: return copy.signInConnections
        case .lookAtCheckup:
            let recorded = record.evidence.checkupFindingIDs
            let open = recordedOpen(record, facts).count
            // Done, the title keeps the number it was set for.
            return copy.lookAtCheckup(open > 0 ? open : max(recorded.count, open))
        case .trySkill:
            guard let trial = trial(record, facts) else { return copy.trySkillTitle }
            return copy.trySkill(trial.skillName, in: trial.client.rawValue)
        case .trackProjects: return copy.trackProjects
        }
    }

    private static func doneCaption(
        _ item: FinishSetupItem, tick: SetupProgressRecord.Tick, facts: FinishSetupFacts, now: Date
    ) -> String {
        let copy = LaunchpadCopy.FinishSetup.self
        let summary: String?
        switch item {
        case .connectOtherMacs:
            summary = copy.synced(SnapshotTime.compact(facts.sync?.lastSynced ?? tick.at, now: now))
        default:
            summary = tick.summary
        }
        return copy.done(summary, place: tick.place.phrase)
    }

    /// The findings kept at hand-off that Checkup still shows. A setup left
    /// for later kept none, so its row is every finding Checkup shows.
    private static func recordedOpen(_ record: SetupProgressRecord, _ facts: FinishSetupFacts) -> [FinishSetupFacts.Finding] {
        let open = facts.openFindings ?? []
        let recorded = Set(record.evidence.checkupFindingIDs)
        return recorded.isEmpty ? open : open.filter { recorded.contains($0.id) }
    }

    private static func trial(_ record: SetupProgressRecord, _ facts: FinishSetupFacts) -> SetupProgressRecord.Trial? {
        record.state == .finished ? record.evidence.trial : (record.evidence.trial ?? trialTarget(facts))
    }

    /// What the trial runs, as typed: "codex $release-notes".
    static func command(for trial: SetupProgressRecord.Trial) -> String? {
        SkillTrialCommandShapes.invocationText(for: trial.client, skillName: trial.skillID).map {
            "\(ClientExecutableLocator.executableName(for: trial.client)) \($0)"
        }
    }

    /// Connections named by app, in the app order: "Sentry in Claude Code",
    /// "GitHub and Sentry in Claude Code and Linear in Codex".
    static func who(_ connections: [FinishSetupFacts.Connection]) -> String {
        let byApp = ClientKind.allCases.compactMap { app -> String? in
            let names = distinct(connections.filter { $0.client == app }.map(\.name))
            return names.isEmpty ? nil : LaunchpadCopy.FinishSetup.connections(LaunchpadCopy.list(names), in: app.rawValue)
        }
        return LaunchpadCopy.list(byApp)
    }

    static func appList(_ apps: [ClientKind]) -> String {
        LaunchpadCopy.list(ClientKind.allCases.filter(apps.contains).map(\.rawValue))
    }

    /// Each name once, in the order first given.
    static func distinct(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}
