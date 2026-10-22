import AgentToolingCore
import Foundation
import Observation

/// What FooterConfirm says when ⎋, ⌘W or the close button asks to leave.
enum LaunchpadLeaveMoment: Equatable, Sendable {
    /// Nothing is written yet: Quit setup.
    case beforeCommit
    /// A join stopped after this Mac's store for the library was made, and
    /// J01 offers Finish joining: Quit setup, and the next launch offers it
    /// again (D32).
    case unfinishedJoin
    /// A first run, or a resumed one, past its commit point: Go to Home
    /// leaves it for later at the cursor.
    case afterCommit
    /// A rerun or a revisit: Go to Home writes nothing.
    case rerun
    /// Something is finishing and cannot be left: the sentence only.
    case finishing(String)
}

/// The setup stage's one state: where the walk is, what it has decided, what
/// it has done, and every move from one screen to the next.
///
/// Screens read and call it; they never move each other. Every transition is
/// the pure table in `LaunchpadStep`, so a test walks a path without drawing
/// a screen. The commit point is the library's existence: before it nothing
/// is on disk and leaving quits; after it every step the walk reaches is
/// recorded as the cursor (on a first run), and leaving goes to Home.
@MainActor @Observable
final class LaunchpadFlow {
    let entry: SetupEntry
    let environment: LaunchpadEnvironment

    /// Which walk this is. Nil on a first run until Welcome's fork is taken.
    private(set) var path: LaunchpadPath?
    private(set) var step: LaunchpadStep
    /// The library, once it exists: created at the commit point, joined, or
    /// handed in by a rerun, a resume or a revisit.
    private(set) var workspace: WorkspaceLaunch.Workspace?
    /// What Your apps and What Agent Tooling reads decided before the
    /// commit: the chosen apps, found tool folders, the projects choice.
    var seedOverride: LaunchpadSeed?
    /// What the walk did in the library, for the review and Done.
    var decisions = LaunchpadLibraryDecisions()
    /// What the walk's steps did, for Done.
    var outcomes = LaunchpadOutcomes()
    /// The review panel over the stage, while one is up.
    private(set) var presentedReview: ScopedPlanReview?
    /// Where the review's Continue goes; nil for the step after the one it
    /// was opened on.
    private(set) var reviewReturn: LaunchpadStep?
    /// FooterConfirm is up in place of the footer's clusters.
    private(set) var isConfirmingLeave = false
    /// A plain ↩ reached a screen where only ⌘↩ acts: "Press ⌘↩ to install".
    private(set) var commandReturnHint = false
    /// Bumped on each plain ↩ there, so the keycaps flash once per press.
    private(set) var commandReturnFlash = 0
    /// Set when the walk is over and the main window should open on this
    /// section; the stage's window performs the hand-off.
    private(set) var pendingHandOff: AppSection?
    /// Set by Quit setup, before the commit point: the stage's window quits.
    private(set) var quitRequested = false
    /// True while Let your apps ask was opened from You joined: its footer
    /// and its review return there. A join picked up again at Let your apps
    /// ask is on it too, since that is the only way Join's path goes there.
    private(set) var isDetour = false
    /// The popover or chooser open on the current step, by the name its
    /// screen gives it. ⎋ closes it first.
    var openPopover: String?
    /// Every step this walk has shown.
    private(set) var visited: Set<LaunchpadStep> = []
    /// True while the library is being created or updated from a read.
    private(set) var isCommitting = false
    /// Whether this walk read this Mac's apps into the library, then audited
    /// them: Start here's read (an empty one included), a rerun's read, or a
    /// join that read the apps it chose. A walk carried on from an earlier
    /// launch, Finish joining and a revisit read nothing, so the shell they
    /// hand off to checks and audits as it does on any launch.
    private(set) var hasReadTheApps = false

    @ObservationIgnored private var models: [LaunchpadStep: AnyObject] = [:]
    @ObservationIgnored private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    /// The library, the check and the sign-ins the last stage audit read, so
    /// Done audits again only when one of them moved.
    @ObservationIgnored private var lastAudited: AuditMark?
    /// A first run's library was created with no apps (Continue without
    /// apps). A rerun never sets it.
    @ObservationIgnored private var committedEmpty = false

    /// How long a quit waits for stoppable work to stop before it goes on.
    static let stopGrace: Duration = .seconds(2)

    /// A stage at `entry`. A first run and an unfinished join start with no
    /// workspace; every other entry is handed the one that exists.
    init(entry: SetupEntry, environment: LaunchpadEnvironment, workspace: WorkspaceLaunch.Workspace? = nil) {
        self.entry = entry
        self.environment = environment
        self.workspace = workspace
        let recordedPath = workspace?.setupProgress.record?.path
        switch entry {
        case .firstRun:
            path = nil
            step = environment.installation().offersMove ? .move : .welcome
        case .continueFirstRun(let cursor), .resume(let cursor):
            path = recordedPath ?? .startHere
            step = cursor
            // Join's path reaches Let your apps ask only as You joined's
            // detour (D23), so a join picked up there, after leaving for
            // later, a quit or the move's relaunch, is on the detour again:
            // its footer, its Back and its review return to You joined.
            isDetour = recordedPath == .join && cursor == .ask
        case .finishJoin:
            path = .join
            step = .join
        case .rerun:
            path = .rerun
            step = .apps
        case .revisit(let target):
            path = recordedPath ?? .rerun
            step = target
        }
        // A first run carried on past its own commit keeps knowing whether
        // that commit had any apps. A rerun asks what is turned on now
        // instead (`transitionContext`), because turning an app on at Your
        // apps is what gives a rerun over an empty library something to read.
        switch entry {
        case .continueFirstRun, .resume:
            if let workspace {
                committedEmpty = workspace.device.managedClients.isEmpty && workspace.device.observations.isEmpty
            }
        case .firstRun, .finishJoin, .rerun, .revisit:
            break
        }
        visited = [step]
    }

    // MARK: What the stage reads

    /// The footer's step name and capsules, Back, and the transition group.
    var info: LaunchpadStepInfo {
        LaunchpadStepInfo.of(step, path: path, entry: entry, context: transitionContext, isDetour: isDetour)
    }

    /// Whether the library exists. This, not the entry, decides whether a
    /// read creates the library or updates it.
    var isPostCommit: Bool { workspace != nil }

    /// The setup record, once the library exists.
    var progress: WorkspaceSetupProgressSession? { workspace?.setupProgress }

    /// What the transition table reads.
    ///
    /// A first run has nothing to read, place or connect once it chose no
    /// apps (V01), and keeps that past its commit. A rerun has nothing to
    /// read only while no app is turned on: it is read from this Mac's
    /// choice as it stands, so an app turned on at Your apps is read.
    var transitionContext: LaunchpadTransitionContext {
        let managed: Set<ClientKind> =
            workspace.map { Set($0.device.managedClients) } ?? seedOverride?.chosen ?? []
        let observed = Set(workspace?.device.observations.compactMap(\.surface.client) ?? [])
        let startedEmpty =
            path == .rerun
            ? managed.isEmpty
            : committedEmpty || (!isPostCommit && managed.isEmpty && seedOverride != nil)
        return LaunchpadTransitionContext(
            managed: managed, observed: observed, startedEmpty: startedEmpty,
            managesAssistant: managed.contains(.claude) || managed.contains(.codex),
            hasEnrollment: workspace?.sync?.isConnected ?? false)
    }

    /// Whether work is under way, aggregated over the commit, the review and
    /// every model the steps hold: finishing wins over stoppable.
    var interruption: LaunchpadInterruption {
        if isCommitting {
            return .finishing(path == .rerun ? LaunchpadCopy.Footer.updatingLibrary : LaunchpadCopy.Footer.creatingLibrary)
        }
        let states = interruptibles.map(\.interruption)
        if let finishing = states.first(where: \.isFinishing) { return finishing }
        return states.contains(.stoppable) ? .stoppable : .idle
    }

    /// What FooterConfirm says now.
    var leaveMoment: LaunchpadLeaveMoment {
        if case .finishing(let sentence) = interruption { return .finishing(sentence) }
        guard isPostCommit else { return hasUnfinishedJoin ? .unfinishedJoin : .beforeCommit }
        switch entry {
        case .rerun, .revisit: return .rerun
        case .firstRun, .continueFirstRun, .finishJoin, .resume: return .afterCommit
        }
    }

    // MARK: Moving

    /// Welcome's fork: Start here or Join.
    func choosePath(_ chosen: LaunchpadPath) {
        guard step == .welcome, !isPostCommit, chosen != .rerun else { return }
        path = chosen
        advance()
    }

    /// The primary's move: the next step the table gives, or, from the
    /// review panel, where the review returns. A revisit hands off instead.
    func advance() {
        guard !isFinishing else { return }
        if presentedReview != nil {
            let target = reviewReturn
            presentedReview = nil
            reviewReturn = nil
            if case .revisit = entry {
                pendingHandOff = .overview
                return
            }
            if let target {
                go(to: target)
            } else {
                goNext()
            }
            return
        }
        if case .revisit = entry {
            pendingHandOff = .overview
            return
        }
        goNext()
    }

    /// An explicit jump: You joined to Let your apps ask, and back.
    func go(to target: LaunchpadStep) {
        guard !isFinishing else { return }
        if target == .ask, step == .arrivals {
            isDetour = true
        } else if target != .ask {
            isDetour = false
        }
        move(to: target)
    }

    /// ⌘[: where the registry gives Back.
    func goBack() {
        guard !isFinishing, presentedReview == nil, !isConfirmingLeave, let back = info.back else { return }
        if back == .arrivals { isDetour = false }
        move(to: back)
    }

    /// ⎋, layered: a popover, FooterConfirm, the review panel, then the
    /// footer's later slot. Nothing while something is finishing.
    func escape() {
        let footer = LaunchpadStageView.footer(for: self)
        let later: LaunchpadKeyRouter.LaterSlot =
            switch footer.later {
            case .setUpLater: .setUpLater
            case .stop: .stop
            case .none: .none
            }
        let action = LaunchpadKeyRouter.escape(
            .init(
                popoverOpen: openPopover != nil, confirmingLeave: isConfirmingLeave,
                reviewPresented: presentedReview != nil, reviewBusy: presentedReview?.isBusy ?? false, later: later,
                finishing: isFinishing))
        switch action {
        case .closePopover: openPopover = nil
        case .keepGoing: keepGoing()
        case .cancelReview: dismissReview()
        case .stop:
            if case .stop(let stop) = footer.later { stop() }
        case .confirmLeave: requestClose()
        case .ignore: break
        }
    }

    /// ⌘W and the close button: FooterConfirm, or, with the review panel up,
    /// the panel's Cancel first. While something finishes, FooterConfirm
    /// shows only what is finishing.
    func requestClose() {
        if let review = presentedReview {
            if !review.isBusy { dismissReview() }
            return
        }
        openPopover = nil
        isConfirmingLeave = true
    }

    /// FooterConfirm's Keep going.
    func keepGoing() {
        isConfirmingLeave = false
    }

    /// FooterConfirm's primary. Before the commit point it quits, writing
    /// nothing. After it, a first run is left for later at its cursor, a
    /// resumed one keeps its cursor, and a rerun or a revisit writes nothing;
    /// each then goes to Home.
    ///
    /// The cursor is the step on screen only once that step is past the
    /// commit point. The read's own step stays on screen after the library
    /// exists, until Continue; leaving there keeps the cursor the commit
    /// recorded (Your library), so coming back never reads again.
    func leave() {
        guard !isFinishing else { return }
        isConfirmingLeave = false
        guard isPostCommit else {
            quitRequested = true
            return
        }
        let now = environment.now()
        switch entry {
        case .firstRun, .continueFirstRun, .finishJoin: progress?.deferSetup(at: leaveCursor, now: now)
        case .resume: progress?.move(to: leaveCursor, now: now)
        case .rerun, .revisit: break
        }
        pendingHandOff = .overview
    }

    /// Where a first run left for later picks up: the step on screen when it
    /// is past the commit point, and otherwise the cursor the record holds.
    private var leaveCursor: LaunchpadStep {
        step.isPostCommit ? step : (progress?.record?.cursor ?? step)
    }

    /// Done's Go to Home or Open Checkup: the record is finished with
    /// `items`, `ticks` and, when given, the `evidence` Home's card needs
    /// (the findings left at hand-off among it), in the one write, then the
    /// main window opens on `section`.
    func finish(
        handOffTo section: AppSection, items: [FinishSetupItem] = FinishSetupItem.allCases,
        ticks: [SetupProgressRecord.Tick] = [], evidence: SetupProgressRecord.Evidence? = nil
    ) {
        guard !isFinishing, isPostCommit else { return }
        progress?.finish(items: items, ticks: ticks, evidence: evidence, seen: visited, now: environment.now())
        pendingHandOff = section
    }

    private func goNext() {
        if step == .ask, isDetour {
            isDetour = false
            move(to: .arrivals)
            return
        }
        let context = transitionContext
        guard let next = LaunchpadStep.next(after: step, path: path, context: context) else { return }
        recordSkips(between: step, and: next, context: context)
        move(to: next)
    }

    private func move(to target: LaunchpadStep) {
        isConfirmingLeave = false
        commandReturnHint = false
        openPopover = nil
        step = target
        visited.insert(target)
        // A first run, or a resumed one, records each step it reaches past
        // the commit point, so a quit or a crash resumes there. A rerun and a
        // revisit write nothing until Done.
        guard isPostCommit, target.isPostCommit else { return }
        switch entry {
        case .firstRun, .continueFirstRun, .finishJoin, .resume: progress?.move(to: target, now: environment.now())
        case .rerun, .revisit: break
        }
    }

    /// Each step the table passed over between two steps, with its screen's
    /// reason, for Done.
    private func recordSkips(between from: LaunchpadStep, and to: LaunchpadStep, context: LaunchpadTransitionContext) {
        guard let path else { return }
        let order = LaunchpadStep.sequence(for: path)
        guard let start = order.firstIndex(of: from), let end = order.firstIndex(of: to), start < end else { return }
        for skipped in order[(start + 1)..<end] {
            if let reason = LaunchpadStageView.skipReason(for: skipped, context: context) {
                outcomes.skipped[skipped] = reason
            }
        }
    }

    // MARK: The commit point

    /// Creates a library from the completed read, including device preferences and
    /// setup progress; writes the locator record last, then audits. Empty app choices
    /// use the same commit path. `beforeAudit` may seed completed sign-in readings but
    /// must not wait for outstanding ones; they trigger a later audit when they land.
    func commitStartHere(
        observations: [TargetObservation], seed: LaunchpadSeed,
        beforeAudit: @MainActor (WorkspaceLaunch.Workspace) async -> Void = { _ in }
    ) async throws {
        guard workspace == nil, !isCommitting else { return }
        isCommitting = true
        defer { endCommit() }
        let now = environment.now()
        let cursor: LaunchpadStep = seed.chosen.isEmpty ? .library : .found
        let record = SetupProgressRecord.started(path: .startHere, cursor: cursor, now: now)
        let store = environment.progressStore
        let created = try await WorkspaceLaunch.create(
            observations: observations, preferences: seed.preferences, supportRoot: environment.supportRoot,
            homeRoot: environment.homeURL,
            beforeRecord: { container in try store(container).save(record) },
            services: environment.sessions)
        workspace = created
        path = .startHere
        seedOverride = seed
        committedEmpty = observations.isEmpty && seed.chosen.isEmpty
        hasReadTheApps = true
        await beforeAudit(created)
        await runStageAudit()
    }

    /// A rerun's read, or a read after the commit point: what was read is
    /// recorded as this Mac's check and the library catches up with it.
    /// Nothing is created.
    func adoptRead(observations: [TargetObservation]) async {
        guard let workspace, !isCommitting else { return }
        isCommitting = true
        defer { endCommit() }
        await workspace.device.adopt(observations)
        hasReadTheApps = true
        await runStageAudit()
    }

    /// Join's hand-over: the joined library is the stage's from here, and You
    /// joined is next. Then the stage audit runs. `readTheApps` when the join
    /// read this Mac's apps in this walk and its store holds that read;
    /// Finish joining reads nothing.
    func didJoin(_ joined: WorkspaceLaunch.Workspace, readTheApps: Bool = false) async {
        guard workspace == nil else { return }
        workspace = joined
        path = .join
        hasReadTheApps = readTheApps
        move(to: .arrivals)
        await runStageAudit()
    }

    private func endCommit() {
        isCommitting = false
        let waiting = commitWaiters
        commitWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    // MARK: The stage audit

    /// The Checkup audit as the stage runs it: no scan, no login shell and no
    /// sign-in read, so it reads nothing the person was not shown. The
    /// sign-in the stage read joins it as the accounts already hold it.
    func runStageAudit() async {
        guard let workspace else { return }
        let folders = (seedOverride?.toolDirectories ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
        // An audit already under way (the review's after an install, a late
        // sign-in's, the shell's on a rerun) read what it read before now:
        // this one waits for it, then audits, so what Done and Home keep is
        // this audit's.
        repeat {
            await workspace.setup.waitUntilAuditEnds()
        } while !(await workspace.setup.audit(
            scansIfUnchecked: false, asksLoginShell: false, readsAccounts: false, extraFolders: folders))
        lastAudited = auditMark
    }

    /// The stage audit again, only if the library, this Mac's check or the
    /// sign-ins it knows moved since the last one: what Done runs as it
    /// appears, and what a sign-in read that lands after the commit calls
    /// once it has seeded the accounts.
    func runStageAuditIfChanged() async {
        guard auditMark != lastAudited else { return }
        await runStageAudit()
    }

    private struct AuditMark: Equatable {
        let head: WorkspaceObjectID?
        let checkedAt: Date?
        let signIns: [AccountProvider: AccountObservation]
    }

    private var auditMark: AuditMark? {
        workspace.map {
            AuditMark(
                head: $0.library.state?.snapshot.document.revision.id, checkedAt: $0.device.lastCheckedAt,
                signIns: $0.accounts.observations)
        }
    }

    // MARK: The review panel

    /// Puts a review over the stage. Its Continue goes to `returnTo`, or to
    /// the step after this one.
    func presentReview(_ review: ScopedPlanReview, returnTo: LaunchpadStep?) {
        presentedReview = review
        reviewReturn = returnTo
        isConfirmingLeave = false
        commandReturnHint = false
        openPopover = nil
    }

    /// The panel's Cancel: it closes and nothing is written. Ignored while it
    /// installs.
    func dismissReview() {
        guard let review = presentedReview, !review.isBusy else { return }
        presentedReview = nil
        reviewReturn = nil
        commandReturnHint = false
    }

    /// A plain ↩ where only ⌘↩ acts: the keycaps flash and the hint shows.
    func showCommandReturnHint() {
        commandReturnHint = true
        commandReturnFlash &+= 1
    }

    // MARK: Models that outlive their screens

    /// The model a step keeps while the stage is open: a read, a join, a
    /// publish. Made once, then handed back to every redraw.
    func model<Model: AnyObject>(for step: LaunchpadStep, make: () -> Model) -> Model {
        if let existing = models[step] as? Model { return existing }
        let made = make()
        models[step] = made
        return made
    }

    /// Before a quit: stops whatever can be stopped, keeping nothing, waiting
    /// at most `stopGrace` for it.
    func prepareToQuit() async {
        let stoppable = interruptibles.filter { $0.interruption == .stoppable }
        guard !stoppable.isEmpty else { return }
        // Whichever ends first resumes the quit: every model stopped, or the
        // grace ran out. A stop that takes longer carries on unwaited.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = ResumeOnce(continuation)
            let grace = Task { @MainActor in
                try? await Task.sleep(for: Self.stopGrace)
                resume.resume()
            }
            Task { @MainActor in
                for model in stoppable { await model.interrupt() }
                grace.cancel()
                resume.resume()
            }
        }
    }

    /// Before a quit, once nothing stoppable is left: waits out whatever is
    /// finishing, with no limit. A finishing window is short by design: one
    /// commit, one step, one publish.
    func finishPendingWork() async {
        if isCommitting { await withCheckedContinuation { commitWaiters.append($0) } }
        for model in interruptibles where model.interruption.isFinishing {
            await model.interrupt()
        }
    }

    /// Every model and the review that may have work under way.
    private var interruptibles: [any LaunchpadInterruptible] {
        var all = models.values.compactMap { $0 as? any LaunchpadInterruptible }
        if let review = presentedReview { all.append(review) }
        return all
    }

    private var isFinishing: Bool { interruption.isFinishing }

    /// Whether this Mac holds the store of a join that stopped before it
    /// finished, which J01 offers to finish: opened at launch to finish it,
    /// or after a join failed past its store this session.
    private var hasUnfinishedJoin: Bool {
        if case .finishJoin = entry { return true }
        if case .finish = (models[.join] as? LaunchpadJoin)?.mode { return true }
        return false
    }
}

extension LaunchpadInterruption {
    var isFinishing: Bool {
        if case .finishing = self { true } else { false }
    }
}

/// A continuation two racers share: the first to finish resumes it, and the
/// other finds nothing left to resume.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
