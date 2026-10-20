import AgentToolingCore
import AppKit
import Foundation
import Observation
import SwiftUI

/// The repository check a stage form runs while an address is typed: the
/// preflight, once the address and branch have stopped changing for a
/// moment, reading only the remote and a scratch folder of its own.
///
/// Each check is reported as it starts and ends, in order, so the form can
/// tick them off. Typing again cancels a check under way; a cancelled check
/// reports nothing more. Only one check runs at a time.
@MainActor @Observable
final class LaunchpadRemoteCheck {
    enum Phase: Equatable {
        /// Nothing to check: no address, or one the field itself refuses.
        case idle
        case checking
        case passed(GitRemotePreflightResult)
        case failed(GitRemoteProblem)
    }

    private(set) var phase = Phase.idle
    /// Where each of the four checks stands in the run under way or the last
    /// one; a check missing here has not been reached.
    private(set) var checks: [GitRemotePreflight.Check: GitRemotePreflight.CheckState] = [:]
    /// The address, branch and name the phase is about.
    private(set) var checked: Request?

    /// What one run is asked to check.
    struct Request: Equatable, Sendable {
        var remote: String
        var branch: String
        /// The name this Mac would register under, when the check is about
        /// one: S17's typed name, whose clash the check reports. Nil leaves
        /// the name out of the check, and out of what its result is matched
        /// to: Join works out the name from the Macs the check found.
        var deviceName: String?
    }

    /// The name a check that is about no name runs with. The preflight then
    /// suggests a name nobody reads, and never asks this Mac for its own,
    /// which can take seconds.
    static let unnamed = "Mac"

    /// How long the address and branch must stand still before a check runs.
    static let debounce: Duration = .milliseconds(600)

    @ObservationIgnored private let expectingWorkspace: WorkspaceObjectID?
    @ObservationIgnored private let thisDevice: WorkspaceObjectID?
    @ObservationIgnored private let runner: () -> any CommandRunning
    @ObservationIgnored private let scratch: URL
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    /// `expectingWorkspace` nil checks for a join; a workspace checks for a
    /// connect from that library, as `GitRemotePreflight.run` describes.
    init(
        expectingWorkspace: WorkspaceObjectID? = nil, thisDevice: WorkspaceObjectID? = nil,
        runner: @escaping () -> any CommandRunning, scratch: URL = FileManager.default.temporaryDirectory,
        delay: Duration = LaunchpadRemoteCheck.debounce
    ) {
        self.expectingWorkspace = expectingWorkspace
        self.thisDevice = thisDevice
        self.runner = runner
        self.scratch = scratch
        self.delay = delay
    }

    /// The result for `request`, when the last check was of it and passed.
    func result(for request: Request) -> GitRemotePreflightResult? {
        guard checked == request, case .passed(let result) = phase else { return nil }
        return result
    }

    /// Checks `request` once it has stood still for the debounce. An address
    /// the field refuses, or none, is not checked.
    func schedule(_ request: Request) {
        start(request, after: delay)
    }

    /// Checks `request` now, and returns once the check has ended.
    func checkNow(_ request: Request) async {
        start(request, after: .zero)
        await task?.value
    }

    /// Whether a check is running: it can be stopped, keeping nothing.
    var isChecking: Bool { phase == .checking }

    /// Stops a check under way or waiting, forgets the last one, and returns
    /// once its command has ended: what a quit waits for.
    func stop() async {
        let running = task
        reset()
        await running?.value
    }

    /// Stops a check under way or waiting, and forgets the last one.
    func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        phase = .idle
        checks = [:]
        checked = nil
    }

    private func start(_ request: Request, after wait: Duration) {
        generation &+= 1
        let token = generation
        task?.cancel()
        let remote = request.remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty, GitRemoteAddress.problem(remote) == nil else {
            task = nil
            phase = .idle
            checks = [:]
            checked = request
            return
        }
        let expecting = expectingWorkspace
        let device = thisDevice
        let runner = runner()
        let scratch = scratch
        task = Task { [weak self] in
            if wait > .zero {
                do { try await Task.sleep(for: wait) } catch { return }
            }
            guard let self, token == self.generation else { return }
            self.phase = .checking
            self.checks = [:]
            self.checked = request
            let (events, continuation) = AsyncStream.makeStream(of: CheckEvent.self)
            let watcher = Task { @MainActor [weak self] in
                for await event in events {
                    guard let self, token == self.generation else { continue }
                    self.checks[event.check] = event.state
                }
            }
            let outcome: Result<GitRemotePreflightResult, GitRemoteProblem>?
            do {
                outcome = try await GitRemotePreflight.run(
                    remote: remote, branch: request.branch, deviceName: request.deviceName ?? Self.unnamed,
                    expectingWorkspace: expecting, thisDevice: device, runner: runner, scratch: scratch,
                    progress: { check, state in continuation.yield(CheckEvent(check: check, state: state)) })
            } catch {
                outcome = nil
            }
            continuation.finish()
            await watcher.value
            guard token == self.generation, let outcome else { return }
            switch outcome {
            case .success(let result): self.phase = .passed(result)
            case .failure(let problem): self.phase = .failed(problem)
            }
        }
    }

    private struct CheckEvent: Sendable {
        let check: GitRemotePreflight.Check
        let state: GitRemotePreflight.CheckState
    }
}

/// Your other Macs (S17): connect a private repository and publish this
/// Mac's library there, so another Mac can join it.
///
/// The address, branch and this Mac's name are typed here; the checkout is
/// Agent Tooling's own, so no folder is chosen. While the repository is
/// checked a Stop keeps nothing; once Connect and share connects, it finishes
/// connecting and publishing as a whole, "Publishing…". A Mac that already
/// shares its library (a rerun) opens on the result.
@MainActor @Observable
final class LaunchpadSyncConnect: LaunchpadInterruptible {
    enum Phase: Equatable {
        /// The form: nothing is connected.
        case editing
        /// Connect and share is checking the repository; a Stop ends it.
        case checking
        /// Connecting this Mac and publishing: waited out, never stopped.
        case connecting
        case publishing
        /// Connected: the result card.
        case connected(Result)
    }

    /// What the result card says first.
    enum Result: Equatable {
        /// Published for the first time.
        case shared
        /// The repository held this library already: the first pass's words.
        case inStep(String)
        /// This Mac was connected to its repository before this setup.
        case alreadyConnected
        /// This Mac shares its library through the folder at this path,
        /// which a file-sync service keeps in step: connected before this
        /// setup, in Settings › Sync.
        case sharesThroughFolder(String)
    }

    /// Why Connect and share did not connect, as the card under the warning
    /// says it.
    struct Failure: Equatable {
        let title: String
        let message: String
    }

    private(set) var phase = Phase.editing
    private(set) var address = ""
    private(set) var branch = LaunchpadCopy.Macs.defaultBranch
    private(set) var name = ""
    private(set) var failure: Failure?
    /// The repository this Mac connected to, once it is connected.
    private(set) var connectedAddress: String?
    let check: LaunchpadRemoteCheck

    @ObservationIgnored private let workspace: WorkspaceLaunch.Workspace
    @ObservationIgnored private let environment: LaunchpadEnvironment
    @ObservationIgnored private let discardStaleCheckout: @Sendable (URL) throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// `checkDelay` is how long typing must pause before the repository is
    /// checked; `discardStaleCheckout` sets aside what an earlier attempt left
    /// in the app-owned checkout (the Trash, live).
    init(
        workspace: WorkspaceLaunch.Workspace, environment: LaunchpadEnvironment,
        checkDelay: Duration = LaunchpadRemoteCheck.debounce,
        discardStaleCheckout: @escaping @Sendable (URL) throws -> Void = GitWorkspaceTransport.moveToTrash
    ) {
        self.workspace = workspace
        self.environment = environment
        self.discardStaleCheckout = discardStaleCheckout
        let makeRunner = environment.makeRunner
        check = LaunchpadRemoteCheck(
            expectingWorkspace: workspace.store.workspaceID, thisDevice: workspace.store.deviceID,
            runner: { makeRunner(Self.gitTimeout) }, delay: checkDelay)
    }

    /// The Git commands' time limit: a fetch over a slow network, or a
    /// sign-in helper waiting on the Keychain, ends here at the latest.
    static let gitTimeout: Duration = .seconds(120)

    /// The home folder the library's paths are shown from.
    var homeURL: URL { workspace.homeRoot }

    /// Why other Macs cannot be offered on this Mac, when they cannot.
    var unavailableReason: String? {
        guard workspace.sync == nil else { return nil }
        return LaunchpadCopy.Macs.Failures.unavailable(workspace.syncUnavailableReason)
    }

    /// Reads this Mac's name and whether it is connected already. Once; a
    /// second call waits for the first.
    func load() async {
        if loading == nil {
            loading = Task { await self.firstLoad() }
        }
        await loading?.value
    }

    private func firstLoad() async {
        guard let sync = workspace.sync else { return }
        sync.load()
        sync.refreshDevices()
        if let registered = sync.thisDevice?.name {
            name = registered
        } else if name.isEmpty {
            let read = await environment.deviceName().trimmingCharacters(in: .whitespacesAndNewlines)
            // A name typed while this Mac's own was read is the person's,
            // and stays. An address typed meanwhile was checked without a
            // name: it is checked again with this one.
            if name.isEmpty {
                name = read
                if phase == .editing, !isEmpty { check.schedule(request) }
            }
        }
        guard let enrollment = sync.enrollment, phase == .editing else { return }
        switch enrollment.kind {
        case .git:
            address = enrollment.remote
            branch = enrollment.branch
            connectedAddress = enrollment.remote
            phase = .connected(.alreadyConnected)
        case .encryptedFolder:
            // A folder has no address: the fields stay empty, and the card
            // names the folder instead.
            phase = .connected(.sharesThroughFolder(enrollment.checkoutPath))
        }
    }

    // MARK: Editing

    func update(address: String) {
        guard phase == .editing else { return }
        self.address = address
        failure = nil
        check.schedule(request)
    }

    func update(branch: String) {
        guard phase == .editing else { return }
        self.branch = branch
        failure = nil
        check.schedule(request)
    }

    func update(name: String) {
        guard phase == .editing else { return }
        self.name = name
        check.schedule(request)
    }

    /// Puts the HTTPS form of the address in the field (V9's Use https://…).
    func useSuggestion() {
        guard case .invalidAddress(let suggestion?, _) = addressProblem else { return }
        update(address: suggestion)
    }

    /// What the check is asked about: the address, branch and name as typed.
    /// With no name typed, the check is about none.
    var request: LaunchpadRemoteCheck.Request {
        .init(remote: trimmedAddress, branch: trimmedBranch, deviceName: trimmedName.isEmpty ? nil : trimmedName)
    }

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBranch: String {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? LaunchpadCopy.Macs.defaultBranch : branch
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The address is empty: the primary is Skip for now.
    var isEmpty: Bool { trimmedAddress.isEmpty }

    /// Why the address cannot be used as typed, before anything runs.
    var addressProblem: GitRemoteProblem? {
        isEmpty ? nil : GitRemoteAddress.problem(trimmedAddress)
    }

    /// The name this Mac will be saved as, when another Mac uses the one
    /// typed: "Juniper 2".
    var numberedName: String? {
        guard !trimmedName.isEmpty, let result = check.result(for: request), result.suggestedName != trimmedName else {
            return nil
        }
        return result.suggestedName
    }

    /// The check found a problem with the repository as typed.
    var checkProblem: GitRemoteProblem? {
        guard check.checked == request, case .failed(let problem) = check.phase else { return nil }
        return problem
    }

    /// Connect and share can run: an address the field takes, a name, a
    /// sync session, and no problem the check found.
    var canConnect: Bool {
        phase == .editing && !isEmpty && addressProblem == nil && checkProblem == nil && !trimmedName.isEmpty
            && workspace.sync != nil
    }

    /// The check stopped at something put right outside the app, with
    /// nothing typed to change: the network, the sign-in, the Command Line
    /// Tools, a host that was slow. Try again ↩ checks afresh. A problem with
    /// what was typed, or with what the repository holds, needs another
    /// address instead, and Connect and share waits for it.
    var canTryAgain: Bool {
        phase == .editing && checkProblem.map(Self.isCuredByTryingAgain) == true
    }

    /// Try again ↩: checks the repository afresh, as typed. It reads only
    /// the remote, so it is ↩, not ⌘↩.
    func tryAgain() {
        guard canTryAgain else { return }
        let request = request
        Task { await check.checkNow(request) }
    }

    /// Whether checking again, with nothing typed changed, can pass.
    static func isCuredByTryingAgain(_ problem: GitRemoteProblem) -> Bool {
        switch problem {
        case .gitMissing, .unreachable, .signInFailed, .notFound, .timedOut, .unreadable: true
        case .invalidAddress, .invalidBranch, .emptyRemote, .noSuchBranch, .notALibrary, .newerFormat, .differentLibrary,
            .pushRefused:
            false
        }
    }

    // MARK: Connecting

    /// ⌘↩: connects, registers this Mac and publishes. The walk moves on with
    /// Continue once the result is in.
    func connect(flow: LaunchpadFlow) {
        guard canConnect, let sync = workspace.sync else { return }
        let remote = trimmedAddress
        let branch = trimmedBranch
        let name = trimmedName
        failure = nil
        phase = .checking
        workspace.installSyncStatusProvider()
        let environment = environment
        let discard = discardStaleCheckout
        task = Task { [weak self] in
            let outcome = await sync.connectAndShare(
                remote: remote, branch: branch, deviceName: name, runner: environment.makeRunner(Self.gitTimeout),
                discardStaleCheckout: discard, progress: { [weak self] step in self?.advance(to: step) })
            self?.settle(outcome, remote: remote, sync: sync, flow: flow)
        }
    }

    private func advance(to step: SyncConnectPhase) {
        switch step {
        case .checking: phase = .checking
        case .connecting: phase = .connecting
        case .publishing: phase = .publishing
        }
    }

    private func settle(_ outcome: SyncConnectOutcome, remote: String, sync: WorkspaceSyncSession, flow: LaunchpadFlow) {
        let copy = LaunchpadCopy.Macs.self
        switch outcome {
        case .shared, .upToDate:
            let result: Result = outcome == .shared ? .shared : .inStep(Self.passLine(sync.lastOutcome))
            connectedAddress = remote
            name = sync.thisDevice?.name ?? name
            phase = .connected(result)
            flow.outcomes.sync = .init(address: remote, publishedAt: environment.now(), upToDate: outcome != .shared)
            AccessibilityNotification.Announcement(copy.sharedAnnouncement(Self.line(for: result))).post()
        case .stopped:
            phase = .editing
        case .failed(let problem):
            phase = .editing
            failure = Failure(title: Self.title(for: problem), message: problem.errorDescription ?? copy.couldNotConnect)
        case .notSaved(let sentence):
            phase = .editing
            failure = Failure(title: copy.couldNotConnect, message: sentence)
        }
    }

    /// Not now and Skip for now: nothing is connected, and Home's checklist
    /// keeps Connect your other Macs.
    func skip(flow: LaunchpadFlow) {
        guard phase == .editing else { return }
        check.reset()
        flow.outcomes.sync = nil
        flow.advance()
    }

    /// Continue, from the result: the walk moves on. A Mac connected before
    /// this setup is recorded as connected for Done, as one connected here
    /// was when it connected.
    func proceed(flow: LaunchpadFlow) {
        guard case .connected(let result) = phase else { return }
        let lastSynced = workspace.sync?.lastSynced
        switch result {
        case .alreadyConnected:
            if let connectedAddress {
                flow.outcomes.sync = .init(address: connectedAddress, publishedAt: lastSynced, upToDate: true)
            }
        case .sharesThroughFolder(let folder):
            flow.outcomes.sync = .init(address: folder, publishedAt: lastSynced, upToDate: true)
        case .shared, .inStep:
            break
        }
        flow.advance()
    }

    /// Stop: the check under way ends, and nothing is kept.
    func stop() {
        guard phase == .checking else { return }
        task?.cancel()
    }

    /// Copies the repository's address, for the other Mac's Join.
    func copyAddress() {
        guard let connectedAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connectedAddress, forType: .string)
    }

    // MARK: Interruptible

    var interruption: LaunchpadInterruption {
        switch phase {
        case .checking: .stoppable
        case .connecting, .publishing: .finishing(LaunchpadCopy.Footer.publishing)
        // The check that runs as the address is typed reads the remote: a
        // quit stops it too.
        case .editing: check.isChecking ? .stoppable : .idle
        case .connected: .idle
        }
    }

    func interrupt() async {
        if phase == .checking { task?.cancel() }
        await check.stop()
        await task?.value
    }

    // MARK: Words

    /// The result card's first line.
    static func line(for result: Result) -> String {
        switch result {
        case .shared: LaunchpadCopy.Macs.sharedFirstTime
        case .inStep(let line): line
        case .alreadyConnected: LaunchpadCopy.Macs.alreadyConnected
        case .sharesThroughFolder: LaunchpadCopy.Macs.alreadySharesThroughFolder
        }
    }

    /// What a first pass into a repository that held this library did.
    static func passLine(_ outcome: WorkspaceSyncOutcome?) -> String {
        let copy = LaunchpadCopy.Macs.self
        switch outcome {
        case .published: return copy.sharedFirstTime
        case .merged: return copy.combined
        case .adopted: return copy.tookIn
        case .needsResolution: return copy.needsDecisions
        case .remoteMovedDuringSync: return copy.anotherMacPublished
        case .upToDate, nil: return copy.upToDate
        }
    }

    /// The failure card's title, by where the repository stopped it.
    static func title(for problem: GitRemoteProblem) -> String {
        let copy = LaunchpadCopy.Macs.self
        if case .pushRefused = problem { return copy.couldNotPublish }
        switch problem.failedCheck {
        case .gitInstalled: return copy.gitMissingTitle
        case .reachable: return copy.couldNotReach
        case .holdsLibrary: return copy.notThisLibrary
        case .readable: return copy.cannotRead
        case nil: return copy.couldNotConnect
        }
    }
}
