import AgentToolingCore
import Foundation
import Observation

/// The reviewed plan shared by setup and the install sheet. Only runnable steps
/// count toward installation; unowned replacements and unsupported commands remain
/// visible with reasons. Already-present items are omitted.
/// Applying uses exactly this plan and its captured library revision. A changed
/// revision refuses the apply as stale. Clients whose native commands ran are
/// checked again before preparing another plan.
@MainActor @Observable
final class ScopedPlanReview: LaunchpadInterruptible {
    /// Which part of the plan is reviewed.
    enum Scope: Equatable {
        /// The steps for these items: what a setup step decided.
        case artifacts(Set<ArtifactID>)
        /// Everything the plan holds: the shared review sheet.
        case wholePlan
    }

    enum Phase: Equatable {
        case preparing
        case ready
        /// The library moved since the plan was read: review it again first.
        case stale
        case running(done: Int, of: Int)
        case finished(DeploymentOutcome)
        /// Nothing ran, and why.
        case notRun(String)
        case failed(String)
    }

    enum StepState: Equatable {
        case waiting
        case running
        case done
        case failed(String)
        /// Drawn in place and not run.
        case leftAlone
        /// Listed, but no command can be built for it; the reason says why.
        case willNotRun(String)
    }

    /// What a step does, which decides its symbol and its well.
    enum Action: Equatable, Sendable {
        case copy
        case update
        case remove
        case plugin
        case connection
        /// A connection taken out of its app (D10).
        case disconnect

        /// Whether the step runs an app's own tool, so the app is checked
        /// again once it has run (D29).
        var runsAppsOwnTool: Bool {
            switch self {
            case .plugin, .connection, .disconnect: true
            case .copy, .update, .remove: false
            }
        }

        /// Whether the step takes something out of its app.
        var isRemoval: Bool { self == .remove || self == .disconnect }
    }

    /// The well under a step's title: where a copy goes, or every command
    /// the step runs, in order.
    enum Well: Equatable, Sendable {
        case path(String)
        case commands([String])
    }

    /// One step in an app.
    struct Step: Identifiable, Equatable {
        let id: WorkspaceDeploymentInstallKey
        let client: ClientKind
        /// "Copy Release Notes into Codex", "Ask Claude Code to install
        /// Supabase", "Frontend Design in Codex".
        let title: String
        var state: StepState
        /// The step's place in the run, counted across the apps; nil for a
        /// step that does not run.
        var number: Int?
        var action: Action = .copy
        var well: Well?
        /// The line under the step: why it is left alone, why it will not
        /// run, or what a replacement replaces and risks.
        var note: String?
        /// What the content read found in what the step copies.
        var contentRead: ContentRiskReport?

        /// The content read, when it found something or could not finish: a
        /// finding a person decides with in front of them.
        var risk: ContentRiskReport? { contentRead.flatMap { $0.isClean ? nil : $0 } }

        /// Whether the install ran the step, whatever came of it.
        var ran: Bool {
            switch state {
            case .done, .failed: true
            case .waiting, .running, .leftAlone, .willNotRun: false
            }
        }

        /// Whether the step is one of the changes the install makes.
        var isChange: Bool {
            switch state {
            case .leftAlone, .willNotRun: false
            case .waiting, .running, .done, .failed: true
            }
        }
    }

    /// One app's steps, in the app order.
    struct Group: Identifiable, Equatable {
        let client: ClientKind
        var id: ClientKind { client }
        var steps: [Step]

        /// "2 changes · 1 left alone".
        var summary: String {
            LaunchpadCopy.Review.groupSummary(
                changes: steps.count(where: \.isChange), leftAlone: steps.count { $0.state == .leftAlone },
                cannotRun: steps.count { if case .willNotRun = $0.state { true } else { false } })
        }
    }

    private(set) var phase: Phase = .preparing
    private(set) var groups: [Group] = []
    /// Whether the library row's decisions are open (Space or a click).
    var isLibraryExpanded = false
    /// Whether `prepare()` has been called, so a panel drawn over a review
    /// someone already read does not read it again.
    @ObservationIgnored private(set) var hasBegunReading = false
    /// The clock an install's result is stamped with.
    @ObservationIgnored var now: @MainActor () -> Date = { .now }
    /// Hears an install's result as soon as its steps have run, before the
    /// apps it touched are checked again and before the review shows it, so
    /// whoever keeps it (the stage's outcomes) has it even if a quit cuts
    /// the check short.
    @ObservationIgnored var whenInstalled: (@MainActor (DeploymentOutcome) -> Void)?
    /// What the plan names but cannot carry out, with why, as the shared
    /// sheet lists them. Has it is never one of them.
    private(set) var exclusions: [WorkspaceDeploymentExclusion] = []
    /// Where the listed steps land, in the scopes' own order: what the
    /// shared sheet's "Applies to" names first.
    private(set) var scopes: [ToolingScope] = []

    let scope: Scope
    let includingRemovals: Bool
    /// The items whose removals the review lists whatever
    /// `includingRemovals` says: Let your apps ask names Agent Tooling's own
    /// connection, whose removal it decided (D10).
    let includingRemovalsOf: Set<ArtifactID>
    /// This Mac's name, for the panel's chip.
    let deviceName: String?
    /// What the setup decided in the library, for the panel's first row; nil
    /// where there is no such row (You joined's review, the shared sheet).
    let libraryDecisions: LaunchpadLibraryDecisions?

    @ObservationIgnored private let workspace: WorkspaceLaunch.Workspace
    @ObservationIgnored private var installTask: Task<Void, Never>?
    /// The check of the apps an install touched, which a quit cancels.
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    /// Whether the install was stopped for a quit (⌘Q, §2.6), rather than by
    /// the person's Stop: only a quit skips checking the apps again. While
    /// the step under way finishes, the panel's progress says so.
    private var isQuitting = false
    /// What each registration a left-alone connection step would have
    /// replaced starts now, when its app's configuration says.
    @ObservationIgnored private var heldRegistrations: [WorkspaceDeploymentInstallKey: String] = [:]
    /// The plan the review was handed to show first, instead of reading one.
    @ObservationIgnored private var handedPlan: WorkspaceDeploymentPlan?
    /// The library revision the handed plan was read at, taken when it was
    /// handed over: a plan read again in the meantime must not lend the
    /// handed one its newer revision.
    @ObservationIgnored private var handedRevision: WorkspaceObjectID?
    @ObservationIgnored private var heldBack: Set<WorkspaceDeploymentInstallKey> = []
    /// The steps that run, as the install applies them.
    @ObservationIgnored private var runnable: WorkspaceDeploymentPlan?
    @ObservationIgnored private var contentReview: DeploymentPlanReview?
    /// The revision the plan was read at.
    @ObservationIgnored private var basedOn: WorkspaceObjectID?

    init(
        workspace: WorkspaceLaunch.Workspace, scope: Scope, includingRemovals: Bool = false,
        includingRemovalsOf: Set<ArtifactID> = [], deviceName: String? = nil, libraryDecisions: LaunchpadLibraryDecisions? = nil
    ) {
        self.workspace = workspace
        self.scope = scope
        self.includingRemovals = includingRemovals
        self.includingRemovalsOf = includingRemovalsOf
        self.deviceName = deviceName
        self.libraryDecisions = libraryDecisions
    }

    /// A review of `plan`, a plan the caller already holds: the Apps screen
    /// hands the shared sheet the whole plan it prepared a moment before. The
    /// first read shows exactly that plan and installs exactly what it lists;
    /// reviewing again reads the whole plan afresh.
    ///
    /// Its steps are listed at once, before the read that adds what each runs,
    /// so a sheet opened on it never stands empty.
    convenience init(workspace: WorkspaceLaunch.Workspace, reviewing plan: WorkspaceDeploymentPlan, includingRemovals: Bool = true) {
        self.init(workspace: workspace, scope: .wholePlan, includingRemovals: includingRemovals)
        handedPlan = plan
        handedRevision = workspace.deployment.planRevision
        if let snapshot = workspace.library.state?.snapshot {
            heldBack = Set(workspace.deployment.heldBack(in: plan).map(WorkspaceDeploymentSession.installKey))
            exclusions = plan.exclusions.filter { $0.reason != .alreadyPresent }
            scopes = Self.scopes(of: plan)
            groups = buildGroups(of: plan, review: DeploymentPlanReview(), snapshot: snapshot)
        }
    }

    // MARK: What the review says

    /// The steps that run when Install is pressed.
    var runnableCount: Int { groups.reduce(0) { $0 + $1.steps.count(where: \.isChange) } }

    var listedCount: Int { groups.reduce(0) { $0 + $1.steps.count } }

    /// Whether a step that runs takes something out, so the plan is applied,
    /// not installed.
    var hasRemoval: Bool {
        groups.contains { $0.steps.contains { $0.isChange && $0.action.isRemoval } }
    }

    /// "Install 4 changes".
    var title: String {
        PlanReviewLabels.title(
            listedCount: listedCount, runnableCount: runnableCount, hasRemoval: hasRemoval,
            hasExclusions: !exclusions.isEmpty)
    }

    /// "Into 2 apps on this Mac. Each step shows what it runs; Cancel writes
    /// nothing."
    var subtitle: String {
        LaunchpadCopy.Review.subtitle(apps: groups.count { $0.steps.contains(where: \.isChange) })
    }

    /// "This Mac · Juniper".
    var chip: String? { deviceName.map(LaunchpadCopy.Review.chip(deviceName:)) }

    /// The eyebrow over the steps: "In your apps · 4 changes".
    var appsLabel: String { LaunchpadCopy.Review.inYourApps(changes: runnableCount) }

    /// The line after "Before you approve": what runs a command, what is left
    /// alone, and what was read for risky content. "3 steps run a command · 1
    /// step is left alone. Release Notes was checked for risky content;
    /// nothing was flagged."
    var beforeYouApprove: String? {
        guard listedCount > 0 else { return nil }
        let alone = groups.reduce(0) { $0 + $1.steps.count { $0.state == .leftAlone } }
        let facts = [contentReview?.headline, alone > 0 ? LaunchpadCopy.Review.leftAlone(steps: alone) : nil].compactMap(\.self)
        let checked = cleanlyChecked
        let sentences = [
            facts.isEmpty ? nil : facts.joined(separator: " · ") + ".",
            checked.isEmpty ? nil : LaunchpadCopy.Review.checkedClean(checked),
        ]
        let line = sentences.compactMap(\.self).joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// The names of what runs and was read for risky content, completely and
    /// with nothing found, each once, in the order the steps run.
    private var cleanlyChecked: [String] {
        var names: [String] = []
        for step in groups.flatMap(\.steps) where step.isChange {
            guard let report = step.contentRead, report.isClean, let name = displayNames[step.id],
                !names.contains(name)
            else { continue }
            names.append(name)
        }
        return names
    }

    @ObservationIgnored private var displayNames: [WorkspaceDeploymentInstallKey: String] = [:]

    /// Whether a step that runs copies something the content read could not
    /// finish reading. Such a step is never installed on somebody's behalf.
    var isBlocked: Bool {
        groups.contains { $0.steps.contains { $0.isChange && $0.contentRead?.isComplete == false } }
    }

    /// Ready, with something to run, read completely, and not stale.
    var canInstall: Bool { phase == .ready && runnableCount > 0 && !isBlocked }

    /// Read, with nothing in it that can run: nothing listed, or only steps
    /// left alone or that will not run. There is nothing to approve, so the
    /// review offers Continue, which writes nothing.
    var hasNothingToRun: Bool { phase == .ready && runnableCount == 0 }

    /// Installing: Cancel, ⎋ and the close button wait.
    var isBusy: Bool {
        if case .running = phase { true } else { false }
    }

    /// "Installing 2 of 4…" while the install runs; "Applying 1 of 2…" when
    /// a step takes something out, as the title says Apply.
    /// Once ⌘Q has asked the install to stop, "Stopping after this step…"
    /// (§6) until the step under way has finished.
    var progressLine: String? {
        guard case .running(let done, let total) = phase else { return nil }
        if isQuitting { return LaunchpadCopy.Footer.stoppingAfterStep }
        return LaunchpadCopy.Review.installing(min(done + 1, total), of: total, hasRemoval: hasRemoval)
    }

    /// What VoiceOver announces as the install moves on: "Installing 2 of 4.",
    /// and "Stopping after this step…" once a quit has asked it to stop.
    var progressAnnouncement: String? {
        guard case .running(let done, let total) = phase else { return nil }
        if isQuitting { return LaunchpadCopy.Footer.stoppingAfterStep }
        return LaunchpadCopy.Review.installingSpoken(min(done + 1, total), of: total, hasRemoval: hasRemoval)
    }

    /// The library row's second half: "· 7 decisions · these touch no app".
    var libraryLine: String? {
        guard let libraryDecisions, libraryDecisions.count > 0 else { return nil }
        return LaunchpadCopy.Review.libraryDecisions(libraryDecisions.count)
    }

    /// What VoiceOver adds after the library row's name and value ("In your
    /// library", "collapsed, 7 decisions"): "These touch no app".
    var libraryHint: String { LaunchpadCopy.Review.libraryHint }

    /// What VoiceOver says the library row's disclosure is: "collapsed, 7
    /// decisions".
    func libraryDisclosureValue(expanded: Bool) -> String {
        LaunchpadCopy.Review.libraryDisclosure(expanded: expanded, decisions: libraryDecisions?.count ?? 0)
    }

    /// What VoiceOver reads for a step: its number, what it does, what it
    /// runs or where it copies to, and how it stands.
    func accessibilityLabel(for step: Step) -> String {
        let copy = LaunchpadCopy.Review.self
        var parts: [String] = []
        if let number = step.number { parts.append(copy.stepNumber(number, of: runnableCount)) }
        parts.append(step.title)
        switch step.well {
        case .path(let path): parts.append(path)
        case .commands(let lines): parts.append(contentsOf: lines)
        case nil: break
        }
        switch step.state {
        case .running: parts.append(copy.stepInstalling)
        case .done: parts.append(copy.stepDone)
        case .failed(let reason): parts.append(copy.stepFailed(reason))
        // A note that says "Left alone: …" already says it.
        case .leftAlone where step.note?.hasPrefix(copy.leftAloneState) != true: parts.append(copy.leftAloneState)
        case .waiting, .willNotRun, .leftAlone: break
        }
        if let note = step.note { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    /// An install is never cut short: it finishes the step it is on.
    var interruption: LaunchpadInterruption {
        isBusy ? .finishing(LaunchpadCopy.Footer.stoppingAfterStep) : .idle
    }

    // MARK: Reading

    /// Reads the library and the plan again, then lists the steps, with what
    /// each runs and what was found in what it copies.
    func prepare() async {
        hasBegunReading = true
        phase = .preparing
        let deployment = workspace.deployment
        let plan: WorkspaceDeploymentPlan?
        if let handed = handedPlan {
            handedPlan = nil
            plan = handed
            basedOn = handedRevision ?? workspace.library.state?.snapshot.document.revision.id
        } else {
            await workspace.library.refresh()
            await deployment.prepare()
            plan = scopedPlan()
            basedOn = deployment.planRevision
        }
        guard let plan, basedOn != nil else {
            clear()
            phase = .failed(deployment.errorMessage ?? LaunchpadCopy.Review.Failures.notChecked)
            return
        }
        guard let contentStore = workspace.contentStore else {
            clear()
            phase = .failed(LaunchpadCopy.Review.Failures.noContentStore)
            return
        }
        guard let snapshot = workspace.library.state?.snapshot else {
            clear()
            phase = .failed(LaunchpadCopy.Review.Failures.notRead)
            return
        }
        let held = Set(deployment.heldBack(in: plan).map(WorkspaceDeploymentSession.installKey))
        let running = Self.plan(plan, keeping: plan.items.filter { !held.contains(WorkspaceDeploymentSession.installKey($0)) })
        // Only what runs is read: a step left alone copies nothing, so it can
        // neither block the install nor be called checked.
        let reviewed = await DeploymentPlanReviewer.review(
            plan: running, snapshot: snapshot, contentStore: contentStore, homeRoot: workspace.homeRoot,
            locate: deployment.commandServices.locate, provenConnections: deployment.provenConnections)
        heldRegistrations = await Self.registrations(
            replacedBy: plan.items.filter { held.contains(WorkspaceDeploymentSession.installKey($0)) }, snapshot: snapshot)
        heldBack = held
        contentReview = reviewed
        exclusions = plan.exclusions.filter { $0.reason != .alreadyPresent }
        scopes = Self.scopes(of: plan)
        runnable = Self.plan(plan, keeping: reviewed.runnableSteps(of: running.items))
        displayNames = Dictionary(
            plan.items.map { (WorkspaceDeploymentSession.installKey($0), $0.displayName) }, uniquingKeysWith: { first, _ in first })
        groups = buildGroups(of: plan, review: reviewed, snapshot: snapshot)
        phase = .ready
    }

    /// Reads the plan again after it went stale, or after nothing ran.
    func reviewAgain() async {
        guard !isBusy else { return }
        await prepare()
    }

    // MARK: Installing

    /// Installs what runs, leaving the held-back steps alone, and returns
    /// once the install has ended (`begin()`).
    func install() async {
        await begin()?.value
    }

    /// Starts installing what runs, leaving the held-back steps alone, and
    /// returns the install's task; nil when there is nothing to install now.
    ///
    /// The review is running from the moment this returns, before anything
    /// suspends, so a second ⌘↩, a click or a ⎋ handled before the install's
    /// own work begins finds it busy: nothing installs twice, and Cancel
    /// cannot close a review whose install is about to begin.
    @discardableResult
    func begin() -> Task<Void, Never>? {
        guard canInstall, let runnable, let basedOn else { return nil }
        isQuitting = false
        phase = .running(done: 0, of: runnableCount)
        let task = Task {
            await self.run(runnable, basedOn: basedOn)
            self.installTask = nil
        }
        installTask = task
        return task
    }

    /// Asks a running install to stop after the step it is on. Every receipt
    /// is still written, and the apps whose own tool ran are still checked
    /// again (D29), so nothing that ran is offered again.
    func stop() {
        installTask?.cancel()
    }

    /// Stops a running install after the step it is on, and returns once it
    /// has (⌘Q while installing, §2.6). What ran is receipted; the apps are
    /// not checked again, which would only hold the quit up.
    func interrupt() async {
        guard let installTask else { return }
        isQuitting = true
        installTask.cancel()
        recheckTask?.cancel()
        await installTask.value
    }

    private func run(_ plan: WorkspaceDeploymentPlan, basedOn revision: WorkspaceObjectID) async {
        let deployment = workspace.deployment
        let outcome = await deployment.applyReviewed(plan, basedOn: revision) { [weak self] key, progress in
            self?.take(progress, for: key)
        }
        switch outcome {
        case .stale:
            setRunnable(.waiting)
            phase = .stale
        case .notRun(let reason):
            setRunnable(.waiting)
            phase = .notRun(reason)
        case .applied(var result):
            result.leftAlone = Array(heldBack)
            result.finishedAt = now()
            result.hasRemoval = hasRemoval
            // What the stage keeps of the install, as soon as it has run.
            whenInstalled?(result)
            if !isQuitting {
                // The apps an app's own tool ran in are checked again, so the
                // plan read next sees what the install left there (D29). A
                // copy needs no check: the plan measures the folder itself.
                // The check is a task of its own: after a Stop this task is
                // cancelled, and a check in a cancelled task records nothing.
                // A quit cancels it.
                let asked = Set(groups.flatMap(\.steps).filter { $0.action.runsAppsOwnTool && $0.ran }.map(\.client))
                let recheck = Task { await self.recheck(asked) }
                recheckTask = recheck
                await recheck.value
                recheckTask = nil
            }
            phase = .finished(result)
        }
    }

    /// Checks `clients` again, then reads the plan again over what they hold.
    private func recheck(_ clients: Set<ClientKind>) async {
        await workspace.device.refresh(only: clients)
        guard !Task.isCancelled else { return }
        await workspace.deployment.prepare()
    }

    /// One step's progress, as the install reports it.
    private func take(_ progress: ReviewedStepProgress, for key: WorkspaceDeploymentInstallKey) {
        guard case .running(let done, let total) = phase else { return }
        switch progress {
        case .started:
            update(key) { $0.state = .running }
        case .succeeded:
            update(key) { $0.state = .done }
            phase = .running(done: min(done + 1, total), of: total)
        case .failed(let reason):
            update(key) { $0.state = .failed(reason) }
            phase = .running(done: min(done + 1, total), of: total)
        case .notRun:
            update(key) { $0.state = .waiting }
        }
    }

    // MARK: Building

    private func scopedPlan() -> WorkspaceDeploymentPlan? {
        let deployment = workspace.deployment
        switch scope {
        case .artifacts(let ids):
            return deployment.plan(for: ids, includingRemovals: includingRemovals, includingRemovalsOf: includingRemovalsOf)
        case .wholePlan:
            // Every step and every reason something is not being installed,
            // even one whose item has no step: the shared sheet lists them.
            guard let plan = deployment.plan else { return nil }
            guard !includingRemovals else { return plan }
            return WorkspaceDeploymentPlan(
                items: plan.items.filter { !$0.isRemoval }, exclusions: plan.exclusions, requirements: plan.requirements,
                resolvedTargets: plan.resolvedTargets)
        }
    }

    /// The scopes `plan`'s steps land in, in the scopes' own order.
    private static func scopes(of plan: WorkspaceDeploymentPlan) -> [ToolingScope] {
        let used = Set(plan.items.map(\.scope))
        return ToolingScope.allCases.filter(used.contains)
    }

    /// What each registration a step in `items` would replace starts now, by
    /// step, as each app's own configuration registers it for the person.
    /// The files are read away from the main actor: one of them can be
    /// large.
    private static func registrations(
        replacedBy items: [WorkspaceDeploymentItem], snapshot: WorkspaceApplicationSnapshot
    ) async -> [WorkspaceDeploymentInstallKey: String] {
        let names = Dictionary(
            snapshot.document.artifacts.map { ($0.identity.id, $0.declaredName) }, uniquingKeysWith: { first, _ in first })
        let asked = items.filter(WorkspaceDeploymentSession.replacesRegistration).compactMap {
            item -> (WorkspaceDeploymentInstallKey, String, TargetObservation)? in
            guard let name = names[item.artifactID] ?? nil, !name.isEmpty,
                let observation = snapshot.device.observations.first(where: { $0.surface == item.surface })
            else { return nil }
            return (WorkspaceDeploymentSession.installKey(item), name, observation)
        }
        guard !asked.isEmpty else { return [:] }
        return await Task.detached {
            var commands: [WorkspaceDeploymentInstallKey: String] = [:]
            for (key, name, observation) in asked {
                commands[key] = WorkspaceManagedMCPCommandPlanning.registeredCommand(named: name, in: observation)
            }
            return commands
        }.value
    }

    /// Each app's steps, the apps in the app order. In a group the steps that
    /// run come first, numbered in the order they run (what is copied, then
    /// what the app installs, then connections; `runsBefore`), then the steps
    /// no command can be built for, then the steps left alone, each in the
    /// same order. The planner's own order is never shown, so the same plan
    /// always reads the same way.
    private func buildGroups(
        of plan: WorkspaceDeploymentPlan, review: DeploymentPlanReview, snapshot: WorkspaceApplicationSnapshot
    ) -> [Group] {
        let deployment = workspace.deployment
        let sorted = plan.items.sorted(by: WorkspaceDeploymentSession.runsBefore)
        var number = 0
        var numbers: [WorkspaceDeploymentInstallKey: Int] = [:]
        for item in sorted where !heldBack.contains(WorkspaceDeploymentSession.installKey(item)) {
            guard review.reasonNothingRuns(for: item) == nil else { continue }
            number += 1
            numbers[WorkspaceDeploymentSession.installKey(item)] = number
        }
        return ClientKind.allCases.compactMap { client in
            let items = sorted.filter { $0.surface.client == client }
            guard !items.isEmpty else { return nil }
            let steps = items.map { item in
                step(
                    for: item, number: numbers[WorkspaceDeploymentSession.installKey(item)], review: review,
                    snapshot: snapshot, editedSinceInstall: deployment.editedSinceInstall(item))
            }
            // What runs, then what will not, then what is left alone, each
            // band keeping the run order.
            let bands = (0...2).flatMap { band in steps.filter { Self.band($0) == band } }
            return Group(client: client, steps: bands)
        }
    }

    /// Where a step falls in its group: what runs, then what will not, then
    /// what is left alone.
    private static func band(_ step: Step) -> Int {
        switch step.state {
        case .leftAlone: 2
        case .willNotRun: 1
        case .waiting, .running, .done, .failed: 0
        }
    }

    private func step(
        for item: WorkspaceDeploymentItem, number: Int?, review: DeploymentPlanReview, snapshot: WorkspaceApplicationSnapshot,
        editedSinceInstall: Bool
    ) -> Step {
        let copy = LaunchpadCopy.Review.self
        let key = WorkspaceDeploymentSession.installKey(item)
        let app = item.appName
        let action = Self.action(of: item)
        let home = workspace.homeRoot
        // The name the connection goes by in its app, which a replacement's
        // notes name.
        let server =
            snapshot.document.artifacts.first { $0.identity.id == item.artifactID }?.declaredName ?? item.displayName
        if heldBack.contains(key) {
            let note: String
            if action == .connection {
                // A registration Agent Tooling cannot prove it made (§6, S11).
                let now = copy.registeredNow(
                    server: server, app: app, path: heldRegistrations[key].map { PathDisplay.abbreviatingHome($0, home: home) })
                note = "\(now) \(copy.notOurs)"
            } else {
                note = editedSinceInstall ? copy.leftAloneEdited(app: app) : copy.leftAloneNotOurs(app: app)
            }
            return Step(
                id: key, client: item.surface.client ?? .codex, title: item.leftAloneTitle(app: app), state: .leftAlone,
                action: action, note: note)
        }
        var step = Step(
            id: key, client: item.surface.client ?? .codex, title: item.reviewTitle(app: app), state: .waiting, number: number,
            action: action)
        if let reason = review.reasonNothingRuns(for: item) {
            step.state = .willNotRun(reason)
            step.note = copy.willNotRun(reason)
            return step
        }
        switch action {
        case .copy, .update, .remove:
            step.well = destination(of: item, snapshot: snapshot).map(Well.path)
            step.contentRead = review.contentRisk(for: item)
            step.note = item.planActionNote
        case .plugin, .connection, .disconnect:
            let lines = review.commandLines(for: item)
            step.well = lines.isEmpty ? nil : .commands(lines)
            if review.replacesRegistration(item) {
                // What the old registration starts, then what a failed add
                // leaves (D30).
                let now = copy.registeredNow(
                    server: server, app: app,
                    path: review.replacedCommand(for: item).map { PathDisplay.abbreviatingHome($0, home: home) })
                step.note = "\(now) \(copy.replaceNote(server: server, app: app))"
            }
        }
        return step
    }

    /// Where a copy lands, or the copy a removal takes away, as a person
    /// reads a path: the folder this Mac pointed the destination at, or the
    /// app's own folder for it.
    private func destination(of item: WorkspaceDeploymentItem, snapshot: WorkspaceApplicationSnapshot) -> String? {
        guard
            let name = snapshot.document.artifacts.first(where: { $0.identity.id == item.artifactID })?.declaredName,
            !name.isEmpty, let client = item.surface.client
        else { return nil }
        let home = workspace.homeRoot
        if let linked = WorkspaceLinkedDestinations.binding(
            for: .init(surface: item.surface, scope: item.scope, logicalProjectID: item.logicalProjectID), in: snapshot.device)
        {
            return PathDisplay.abbreviatingHome(
                URL(fileURLWithPath: linked.resolvedPath).appending(path: name).path(percentEncoded: false), home: home)
        }
        let projectRoot = item.logicalProjectID.flatMap { id in
            snapshot.device.projectRoots?.first { $0.projectID == id }.map { URL(fileURLWithPath: $0.rootPath) }
        }
        guard
            let url = try? NativeSkillDestination.skillURL(
                client: client, skillID: name, homeURL: home, scope: item.scope, projectRoot: projectRoot)
        else { return nil }
        return PathDisplay.abbreviatingHome(url.path(percentEncoded: false), home: home)
    }

    private static func action(of item: WorkspaceDeploymentItem) -> Action {
        switch item.action {
        case .installContent: .copy
        case .updateContent: .update
        case .removeContent: .remove
        case .installNativePackage: .plugin
        case .configureManagedConnection: .connection
        case .removeManagedConnection: .disconnect
        }
    }

    /// `plan` narrowed to `items`, with its requirements and targets, which
    /// the command bridges check each step against.
    private static func plan(_ plan: WorkspaceDeploymentPlan, keeping items: [WorkspaceDeploymentItem]) -> WorkspaceDeploymentPlan {
        WorkspaceDeploymentPlan(
            items: items, exclusions: [], requirements: plan.requirements, resolvedTargets: plan.resolvedTargets)
    }

    private func clear() {
        groups = []
        exclusions = []
        scopes = []
        runnable = nil
        contentReview = nil
        heldBack = []
        heldRegistrations = [:]
    }

    private func update(_ key: WorkspaceDeploymentInstallKey, _ change: (inout Step) -> Void) {
        for groupIndex in groups.indices {
            for stepIndex in groups[groupIndex].steps.indices where groups[groupIndex].steps[stepIndex].id == key {
                change(&groups[groupIndex].steps[stepIndex])
            }
        }
    }

    private func setRunnable(_ state: StepState) {
        for groupIndex in groups.indices {
            for stepIndex in groups[groupIndex].steps.indices where groups[groupIndex].steps[stepIndex].isChange {
                groups[groupIndex].steps[stepIndex].state = state
            }
        }
    }
}
