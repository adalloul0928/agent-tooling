import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// Checks the typed remote, then joins after explicit app-read consent and ⌘Return.
/// Cancellation before store creation retains only the checkout. Registration and
/// publication after that point must finish. Finish joining resumes an existing
/// store without reading the apps again.
@MainActor @Observable
final class LaunchpadJoin: LaunchpadInterruptible {
    enum Mode: Equatable {
        /// A join from the form.
        case join
        /// Finishing the join whose store for this library is on this Mac.
        case finish(WorkspaceObjectID)
    }

    enum Phase: Equatable {
        case editing
        /// Under way, before this Mac's store exists: a Stop keeps nothing.
        case joining
        /// From the store on, or finishing a join: waited out.
        case finishing
        /// Joined: the walk has moved on to You joined.
        case joined
    }

    /// Where one of the join's five steps is.
    enum StepState: Equatable {
        case waiting
        case running
        case done
        case failed
    }

    /// What the primary does now.
    enum Primary: Equatable {
        /// Join as `name` ⌘↩: the checks passed.
        case join(String)
        /// Join as `name`, not ready: the checks have not passed yet, or this
        /// Mac's name (nil) has not been read yet.
        case notReady(String?)
        /// Try again ↩: the checks or the join stopped at a problem.
        case tryAgain
        /// Finish joining ⌘↩.
        case finish
        /// Joining…: nothing to press.
        case busy
    }

    /// The card that says why the join is not going on: a problem the checks
    /// found (V08), a join that stopped after its store existed, or one that
    /// failed before.
    struct Banner: Equatable {
        let title: String
        let message: String
    }

    private(set) var mode: Mode
    private(set) var phase = Phase.editing
    private(set) var address = ""
    private(set) var branch = LaunchpadCopy.Macs.defaultBranch
    /// The apps the join reads, as the strip chooses them.
    private(set) var chosen: Set<ClientKind>
    /// The apps whose tool is on this Mac.
    let found: Set<ClientKind>
    /// This Mac's own name, which the join registers (numbered on a clash);
    /// empty until it has been read.
    private(set) var deviceName = ""
    private(set) var steps: [WorkspaceJoin.Step: StepState]
    /// The apps Checking this Mac's apps is reading, and those it has read.
    private(set) var reading: Set<ClientKind> = []
    private(set) var read: Set<ClientKind> = []
    private(set) var banner: Banner?
    /// The repository check, as the address is typed.
    let check: LaunchpadRemoteCheck
    /// How the chosen apps sign in, read while the join checks them.
    let signIn: SetupSignInRead

    @ObservationIgnored private let environment: LaunchpadEnvironment
    @ObservationIgnored private let discardStaleCheckout: @Sendable (URL) throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var readings: [FirstRead.Reading] = []
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// A join stopped at a problem before its store; Try again checks again.
    @ObservationIgnored private var needsRetry = false

    /// `checkDelay` is how long typing must pause before the repository is
    /// checked; `discardStaleCheckout` sets aside what an earlier attempt left
    /// in the app-owned checkout (the Trash, live).
    init(
        entry: SetupEntry, environment: LaunchpadEnvironment, checkDelay: Duration = LaunchpadRemoteCheck.debounce,
        discardStaleCheckout: @escaping @Sendable (URL) throws -> Void = GitWorkspaceTransport.moveToTrash
    ) {
        self.environment = environment
        self.discardStaleCheckout = discardStaleCheckout
        let found = Set(ClientKind.allCases.filter { environment.locate($0, environment.homeURL) != nil })
        self.found = found
        chosen = found
        let makeRunner = environment.makeRunner
        check = LaunchpadRemoteCheck(runner: { makeRunner(LaunchpadSyncConnect.gitTimeout) }, delay: checkDelay)
        signIn = SetupSignInRead(reader: environment.signInReader, now: environment.now)
        if case .finishJoin(let workspaceID) = entry {
            mode = .finish(workspaceID)
            steps = Self.stepsBeforeTheStore
            banner = Self.stoppedBanner
        } else {
            mode = .join
            steps = Self.notStarted
        }
    }

    private static let notStarted = Dictionary(uniqueKeysWithValues: WorkspaceJoin.Step.allCases.map { ($0, StepState.waiting) })
    /// A join that stopped after its store existed got this far.
    private static let stepsBeforeTheStore: [WorkspaceJoin.Step: StepState] = [
        .reachingRepository: .done, .readingLibrary: .done, .checkingApps: .done, .registering: .waiting, .sharing: .waiting,
    ]
    private static let stoppedBanner = Banner(
        title: LaunchpadCopy.Join.stoppedTitle, message: LaunchpadCopy.Join.stoppedMessage)

    /// Reads this Mac's name, and, when finishing a join, the repository it
    /// was joining. Once; a second call waits for the first.
    func load() async {
        if loading == nil {
            loading = Task { await self.firstLoad() }
        }
        await loading?.value
    }

    private func firstLoad() async {
        if deviceName.isEmpty { deviceName = Self.requestedName(await environment.deviceName()) }
        guard case .finish(let workspaceID) = mode else { return }
        let container = Self.container(of: workspaceID, environment: environment)
        if let enrollment = container.flatMap({ try? WorkspaceSyncEnrollmentStore(containerRoot: $0).read() }) {
            address = enrollment.remote
            branch = enrollment.branch
        }
    }

    // MARK: The form

    func update(address: String) {
        guard phase == .editing, mode == .join else { return }
        self.address = address
        edited()
    }

    func update(branch: String) {
        guard phase == .editing, mode == .join else { return }
        self.branch = branch
        edited()
    }

    /// ⌘1–⌘4, or a click on a tile: the join reads the app, or leaves it out.
    func toggle(_ client: ClientKind) {
        guard phase == .editing, mode == .join else { return }
        if chosen.contains(client) { chosen.remove(client) } else { chosen.insert(client) }
    }

    /// Puts the HTTPS form of the address in the field (V9).
    func useSuggestion() {
        guard case .invalidAddress(let suggestion?, _) = addressProblem else { return }
        update(address: suggestion)
    }

    private func edited() {
        banner = nil
        needsRetry = false
        steps = Self.notStarted
        check.schedule(request)
    }

    /// What the check is asked about: the address and branch as typed. This
    /// Mac's name is left out, so a name read after the address was typed
    /// never sets aside a check that passed; the name Join as shows is worked
    /// out from the Macs the check found (`joinName`).
    var request: LaunchpadRemoteCheck.Request {
        .init(remote: trimmedAddress, branch: trimmedBranch, deviceName: nil)
    }

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBranch: String {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? LaunchpadCopy.Macs.defaultBranch : branch
    }

    /// Why the address cannot be used as typed, before anything runs.
    var addressProblem: GitRemoteProblem? {
        trimmedAddress.isEmpty ? nil : GitRemoteAddress.problem(trimmedAddress)
    }

    /// What the checks found, once they all passed for the address as typed.
    var passed: GitRemotePreflightResult? { check.result(for: request) }

    /// Where the checks stopped, for the address as typed.
    var checkProblem: GitRemoteProblem? {
        guard check.checked == request, case .failed(let problem) = check.phase else { return nil }
        return problem
    }

    /// The name the join registers this Mac under: "Cedar", or "Cedar 2"
    /// when another Mac the check found already uses it. Nil until this
    /// Mac's name has been read.
    var joinName: String? {
        guard !deviceName.isEmpty else { return nil }
        guard let passed else { return deviceName }
        return Self.uniqueName(deviceName, among: passed.deviceNames)
    }

    /// The name a joining Mac registers under when another living Mac uses
    /// `name`: numbered by the join's own rule (`WorkspaceJoin.uniqueName`),
    /// so Join as names what Registering registers.
    static func uniqueName(_ name: String, among names: [String]) -> String {
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        return (2...99).lazy.map { "\(name) \($0)" }.first { !taken.contains($0.lowercased()) } ?? name
    }

    /// The name the join asks for: this Mac's own, without the spaces around
    /// it, or "Mac" when it has none, as the join itself falls back.
    static func requestedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    /// What the chosen apps' reads list, before anything is read.
    var manifest: FirstReadManifest {
        FirstReadManifest.build(chosen: chosen, homeURL: environment.homeURL, includeProjectHistory: false)
    }

    var primary: Primary {
        switch phase {
        case .joining, .finishing, .joined: return .busy
        case .editing: break
        }
        if case .finish = mode { return .finish }
        if checkProblem != nil || (needsRetry && addressProblem == nil && !trimmedAddress.isEmpty) { return .tryAgain }
        if passed != nil, let joinName { return .join(joinName) }
        return .notReady(joinName)
    }

    /// The keyboard and the strip work only before anything is read.
    var isEditable: Bool { phase == .editing && mode == .join }

    /// Try again ↩: checks the repository afresh. Read-only, so ↩.
    func tryAgain() {
        guard primary == .tryAgain else { return }
        banner = nil
        needsRetry = false
        steps = Self.notStarted
        Task { await check.checkNow(request) }
    }

    // MARK: Joining

    /// Join as Cedar ⌘↩.
    func join(flow: LaunchpadFlow) {
        guard phase == .editing, mode == .join, passed != nil, !deviceName.isEmpty else { return }
        let environment = environment
        let chosen = ClientKind.allCases.filter(self.chosen.contains)
        let manifest = manifest
        let remote = trimmedAddress
        let branch = trimmedBranch
        let name = deviceName
        let progressStore = environment.progressStore
        let started = environment.now()
        let discard = discardStaleCheckout
        banner = nil
        needsRetry = false
        steps = Self.notStarted
        reading = []
        read = []
        phase = .joining
        let (events, continuation) = AsyncStream.makeStream(of: JoinEvent.self)
        let watcher = Task { [weak self] in
            for await event in events { self?.apply(event) }
        }
        task = Task { [weak self] in
            do {
                let joined = try await WorkspaceLaunch.join(
                    remote: remote, branch: branch, supportRoot: environment.supportRoot, homeRoot: environment.homeURL,
                    deviceName: name, clients: Set(chosen), runner: environment.makeRunner(LaunchpadSyncConnect.gitTimeout),
                    observe: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await Self.observe(chosen, manifest: manifest, model: self, events: continuation)
                    },
                    devicePreferences: Self.preferences(chosen: chosen),
                    afterStoreCreated: { container in
                        // Marks the store as an unfinished join, so a launch
                        // that finds no library opens Finish joining.
                        try progressStore(container).save(.started(path: .join, cursor: .join, now: started))
                    },
                    discardStaleCheckout: discard, progress: { step, state in continuation.yield(.step(step, state)) },
                    services: environment.sessions)
                continuation.finish()
                await watcher.value
                // The library exists now. A Stop that came too late to stop
                // the join does not stop what follows either: it runs in a
                // task of its own.
                await Task { await self?.joined(joined, remote: remote, flow: flow) }.value
            } catch {
                continuation.finish()
                await watcher.value
                self?.stopped(by: error, wasCancelled: Task.isCancelled)
            }
        }
    }

    /// Finish joining ⌘↩: registers, shares and records the library a
    /// stopped join left, reading nothing from the apps.
    func finishJoining(flow: LaunchpadFlow) {
        guard phase == .editing, case .finish(let workspaceID) = mode else { return }
        let environment = environment
        let name = deviceName
        let chosen = ClientKind.allCases.filter(self.chosen.contains)
        let discard = discardStaleCheckout
        banner = nil
        steps = Self.stepsBeforeTheStore
        phase = .finishing
        let (events, continuation) = AsyncStream.makeStream(of: JoinEvent.self)
        let watcher = Task { [weak self] in
            for await event in events { self?.apply(event) }
        }
        task = Task { [weak self] in
            do {
                let joined = try await WorkspaceLaunch.finishJoin(
                    workspaceID: workspaceID, supportRoot: environment.supportRoot, homeRoot: environment.homeURL,
                    deviceName: name, devicePreferences: Self.preferences(chosen: chosen),
                    runner: environment.makeRunner(LaunchpadSyncConnect.gitTimeout), discardStaleCheckout: discard,
                    progress: { step, state in continuation.yield(.step(step, state)) }, services: environment.sessions)
                continuation.finish()
                await watcher.value
                guard let self else { return }
                await self.joined(joined, remote: self.address, flow: flow)
            } catch {
                continuation.finish()
                await watcher.value
                self?.stopped(by: error, wasCancelled: false)
            }
        }
    }

    /// J01 on a Mac that has joined already: a launch whose record still
    /// says Join, because the app ended between the library record and the
    /// record's cursor. What the join does once it has the library is done
    /// now, keeping the skills that were already yours and the repository
    /// for Done, and the walk goes on to You joined, where the cursor moves.
    /// Then the stage audit runs, as after a join.
    func carryOn(flow: LaunchpadFlow) async {
        guard let workspace = flow.workspace, flow.step == .join, phase == .editing else { return }
        phase = .joined
        Self.recordSkillsAlreadyYours(in: workspace)
        if let sync = workspace.sync {
            sync.load()
            if let enrollment = sync.enrollment, enrollment.kind == .git {
                flow.outcomes.sync = .init(address: enrollment.remote, publishedAt: sync.lastSynced, upToDate: false)
            }
        }
        flow.advance()
        await flow.runStageAudit()
    }

    /// Stop ⎋, Back, or leaving the screen while the join can still be
    /// stopped: it ends, keeping nothing but the checkout.
    func stop() {
        guard phase == .joining else { return }
        task?.cancel()
        let readings = readings
        Task {
            for reading in readings { await reading.stop() }
        }
    }

    // MARK: Interruptible

    var interruption: LaunchpadInterruption {
        switch phase {
        case .joining: .stoppable
        case .finishing: .finishing(LaunchpadCopy.Footer.finishingJoin)
        // The check that runs as the address is typed reads the remote: a
        // quit stops it too.
        case .editing: check.isChecking ? .stoppable : .idle
        // The sign-in reads the join started go on after it lands, until
        // they do: a quit stops them, so no command they started outlives
        // the app.
        case .joined: signIn.isFinished ? .idle : .stoppable
        }
    }

    func interrupt() async {
        if phase == .joining {
            task?.cancel()
            for reading in readings { await reading.stop() }
        }
        if phase == .joined, !signIn.isFinished { signIn.start(apps: []) }
        await check.stop()
        await task?.value
    }

    // MARK: Steps

    private enum JoinEvent: Sendable {
        case step(WorkspaceJoin.Step, WorkspaceJoin.StepState)
        case reading(ClientKind)
        case read(ClientKind)
    }

    private func apply(_ event: JoinEvent) {
        switch event {
        case .step(let step, .started):
            steps[step] = .running
            switch step {
            case .checkingApps:
                // Every chosen app is read in this step: each tile turns to a
                // spinner now, and to a check as its read lands. How the apps
                // sign in is read alongside them; nothing waits on it, and it
                // joins the library when it lands.
                reading = chosen
                signIn.start(apps: chosen)
            case .registering:
                phase = .finishing
            case .reachingRepository, .readingLibrary, .sharing:
                break
            }
        case .step(let step, .finished):
            steps[step] = .done
        case .reading(let client):
            reading.insert(client)
        case .read(let client):
            reading.remove(client)
            read.insert(client)
        }
    }

    /// Reads each chosen app with the stage's first read, in the app order,
    /// keeping each reading so a Stop or a quit can wait for its commands.
    nonisolated private static func observe(
        _ clients: [ClientKind], manifest: FirstReadManifest, model: LaunchpadJoin,
        events: AsyncStream<JoinEvent>.Continuation
    ) async throws -> [TargetObservation] {
        var observations: [TargetObservation] = []
        for client in clients {
            try Task.checkCancellation()
            events.yield(.reading(client))
            let reading = await model.begin(client, manifest: manifest)
            for await event in reading {
                if case .finished(let observation) = event { observations.append(observation) }
            }
            try Task.checkCancellation()
            events.yield(.read(client))
        }
        return observations
    }

    private func begin(_ client: ClientKind, manifest: FirstReadManifest) -> FirstRead.Reading {
        let reading = environment.firstRead(client, manifest)
        readings.append(reading)
        return reading
    }

    /// The choices a join records for this Mac (D16, D17): the apps chosen,
    /// every assistant run off until Let your assistant help turns one on,
    /// and projects not found from Claude Code's history.
    static func preferences(chosen: [ClientKind]) -> DeviceWorkspacePreferences {
        DeviceWorkspacePreferences(
            enabledClients: chosen, chosenClients: chosen, assistantRuns: .off, findsProjectsFromClaudeHistory: false)
    }

    // MARK: Ending

    private func joined(_ joined: WorkspaceLaunch.Joined, remote: String, flow: LaunchpadFlow) async {
        readings = []
        let workspace = joined.workspace
        // The library is this Mac's now. Before anything else, and with
        // nothing awaited between them, the record moves on to You joined
        // and keeps the skills that were already yours, so a crash or a
        // force quit from here reopens You joined, never a form that can no
        // longer join (D32). What came across never reads as made yours in
        // this setup.
        workspace.setupProgress.move(to: .arrivals, now: environment.now())
        Self.recordSkillsAlreadyYours(in: workspace)
        await workspace.library.refresh()
        flow.outcomes.sync = .init(address: remote, publishedAt: environment.now(), upToDate: false)
        // The sign-in read joins the library before the stage audit when it
        // has landed, and as soon as it lands otherwise.
        if signIn.isFinished { await workspace.accounts.seed(signIn.landed) }
        phase = .joined
        // You joined opens on what the join read of the other Macs, until its
        // own first pass reads them again.
        _ = flow.model(for: .arrivals) {
            LaunchpadArrivals(workspace: workspace, joinStatuses: joined.summary.deviceStatuses)
        }
        // A join from the form read the chosen apps and made the store with
        // that read; Finish joining read nothing, and a store a stopped join
        // never started holds no read at all.
        await flow.didJoin(workspace, readTheApps: mode == .join)
        guard !signIn.isFinished else { return }
        let signIn = signIn
        Task {
            await signIn.waitUntilFinished()
            await workspace.accounts.seed(signIn.landed)
            await flow.runStageAuditIfChanged()
        }
    }

    /// What a join, or a Finish joining, that ended in `error` leaves.
    enum Ending: Equatable {
        /// This Mac's store for the library exists: Finish joining completes
        /// it.
        case finishJoining(WorkspaceObjectID)
        /// Stopped before the store: nothing was kept.
        case stopped
        /// Finish joining found nothing to finish.
        case nothingToFinish
        /// It stopped at a problem, which the banner says.
        case failed
    }

    /// The store decides first: a join that failed after it existed is
    /// finished, whatever stopped it, a Stop that came after the join's last
    /// chance to stop included. Only before the store does a Stop keep
    /// nothing.
    static func ending(of error: any Error, wasCancelled: Bool) -> Ending {
        if case WorkspaceJoinError.lateFailure(let workspaceID) = error { return .finishJoining(workspaceID) }
        if wasCancelled || error is CancellationError { return .stopped }
        if case WorkspaceJoinError.nothingToFinish = error { return .nothingToFinish }
        return .failed
    }

    private func stopped(by error: any Error, wasCancelled: Bool) {
        readings = []
        reading = []
        read = []
        phase = .editing
        signIn.start(apps: [])
        switch Self.ending(of: error, wasCancelled: wasCancelled) {
        case .finishJoining(let workspaceID):
            mode = .finish(workspaceID)
            steps = Self.stepsBeforeTheStore
            banner = Self.stoppedBanner
        case .stopped:
            // Back to the form as it was, nothing kept.
            steps = Self.notStarted
        case .nothingToFinish:
            mode = .join
            steps = Self.notStarted
            banner = Banner(
                title: LaunchpadCopy.Join.nothingToFinishTitle,
                message: WorkspaceJoinError.nothingToFinish.errorDescription ?? "")
        case .failed:
            if let failed = steps.first(where: { $0.value == .running })?.key { steps[failed] = .failed }
            needsRetry = mode == .join
            banner = Self.banner(for: error)
        }
    }

    /// The card for a join that failed before its store, or a Finish joining
    /// that did not finish.
    static func banner(for error: any Error) -> Banner {
        let copy = LaunchpadCopy.Join.self
        if case WorkspaceJoinError.remote(let problem) = error {
            return Banner(title: title(for: problem), message: problem.errorDescription ?? "")
        }
        let described = (error as? any LocalizedError)?.errorDescription ?? "\(error)"
        let message = described.hasSuffix(nothingWasChanged) ? described : "\(described) \(nothingWasChanged)"
        if case WorkspaceJoinError.emptyRemote = error { return Banner(title: copy.noLibrary, message: message) }
        return Banner(title: copy.couldNotJoin, message: message)
    }

    private static let nothingWasChanged = "Nothing was changed."

    /// The banner's title, and the failed check's words, by where a problem
    /// stopped the checks.
    static func title(for problem: GitRemoteProblem) -> String {
        let copy = LaunchpadCopy.Join.self
        switch problem.failedCheck {
        case .gitInstalled: return copy.gitMissing
        case .reachable: return copy.couldNotReach
        case .holdsLibrary: return copy.noLibrary
        case .readable: return copy.cannotRead
        case nil: return copy.couldNotJoin
        }
    }

    /// Keeps the library's own skills, as the store has them now, as the ones
    /// that were already yours before this setup.
    static func recordSkillsAlreadyYours(in workspace: WorkspaceLaunch.Workspace) {
        guard let document = ((try? workspace.store.snapshot()) ?? nil)?.document else { return }
        let personal = personalSkills(in: document)
        workspace.setupProgress.recordEvidence { $0.personalSkillsBefore = personal }
    }

    /// The library's own skills: what a person made theirs on any Mac.
    static func personalSkills(in document: PortableWorkspaceDocument) -> [ArtifactID] {
        document.artifacts.filter {
            $0.identity.kind == .skill && $0.authority == .centralPersonal && $0.identity.parentPackageID == nil
        }.map(\.identity.id)
    }

    /// The folder the store for `workspaceID` lives in, in the stage's
    /// support folder.
    static func container(of workspaceID: WorkspaceObjectID, environment: LaunchpadEnvironment) -> URL? {
        guard let root = environment.supportRoot?.standardizedFileURL ?? (try? WorkspaceLocator.defaultRoot()) else {
            return nil
        }
        return root.appending(path: "workspaces-v1", directoryHint: .isDirectory)
            .appending(path: workspaceID.rawValue.uuidString.lowercased(), directoryHint: .isDirectory)
    }
}
