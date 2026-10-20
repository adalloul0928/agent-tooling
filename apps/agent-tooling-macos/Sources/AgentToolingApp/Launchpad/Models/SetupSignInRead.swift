import AgentToolingCore
import Foundation
import Observation

/// The sign-in reads the setup stage makes before a workspace exists.
///
/// Light reads only (`AccountSurfaceProbe.Depth.signInOnly`): how each app
/// signs in, never what an account holds. The login shell is asked once which
/// overriding variables it exports, and each provider's read is told.
protocol SetupSignInReading: Sendable {
    /// Asks the login shell, once, which overriding variables it exports. Nil
    /// when there is no shell to ask or it did not answer.
    func readShellOverrides() async -> [AccountShellOverride]?
    /// Reads one provider, told what the shell exports. Starts no shell.
    func read(_ provider: AccountProvider, shellOverrides: [AccountShellOverride]?, now: Date) async -> AccountObservation
}

/// The live reads: each app's own read-only commands, and the login shell.
struct LiveSetupSignInReader: SetupSignInReading {
    let probe: AccountSurfaceProbe

    func readShellOverrides() async -> [AccountShellOverride]? {
        await probe.readShellOverrides()
    }

    func read(_ provider: AccountProvider, shellOverrides: [AccountShellOverride]?, now: Date) async -> AccountObservation {
        await probe.read(provider, depth: .signInOnly, shellOverrides: shellOverrides, now: now)
    }
}

/// How the chosen apps sign in, read alongside the stage's read of the apps.
///
/// One login-shell probe, then one cancellable read per provider, so skipping
/// an app stops its provider's read and no other. Nothing waits on it: the
/// library is created when the apps' read finishes, and these reads join the
/// workspace's accounts when they land (`WorkspaceAccountsSession.seed`).
/// With no chosen app that has an account to read, nothing runs at all, not
/// even the login shell.
@MainActor @Observable
final class SetupSignInRead {
    /// What each provider's read found, once it landed.
    private(set) var observations: [AccountProvider: AccountObservation] = [:]
    /// The providers still being read.
    private(set) var reading: Set<AccountProvider> = []
    /// True once every read started has landed or been stopped, and before
    /// any was started.
    private(set) var isFinished = true

    @ObservationIgnored private let reader: any SetupSignInReading
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tasks: [AccountProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var shellTask: Task<Void, Never>?
    @ObservationIgnored private var cancelled: Set<AccountProvider> = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var generation: UInt64 = 0

    init(reader: any SetupSignInReading, now: @escaping () -> Date = { .now }) {
        self.reader = reader
        self.now = now
    }

    /// Starts reading how `apps` sign in. Starting again stops what an earlier
    /// start had under way and reads afresh.
    func start(apps: Set<ClientKind>) {
        stopAll()
        generation &+= 1
        let token = generation
        let providers = AccountProvider.allCases.filter { apps.contains($0.client) }
        observations = [:]
        cancelled = []
        guard !providers.isEmpty else {
            finish()
            return
        }
        reading = Set(providers)
        isFinished = false
        let reader = self.reader
        shellTask = Task { [weak self] in
            let overrides = await reader.readShellOverrides()
            guard let self, token == self.generation, !Task.isCancelled else { return }
            for provider in providers where !self.cancelled.contains(provider) {
                self.tasks[provider] = Task { [weak self] in
                    guard let self else { return }
                    let observation = await reader.read(provider, shellOverrides: overrides, now: self.now())
                    guard token == self.generation, !Task.isCancelled else { return }
                    self.observations[provider] = observation
                    self.land(provider)
                }
            }
            self.settleIfDone()
        }
    }

    /// Stops reading how `client` signs in, keeping nothing of it. The other
    /// providers' reads carry on.
    func cancel(_ client: ClientKind) {
        guard let provider = AccountProvider.provider(for: client), reading.contains(provider) else { return }
        cancelled.insert(provider)
        tasks.removeValue(forKey: provider)?.cancel()
        land(provider)
    }

    /// Returns once every read has landed or been stopped.
    func waitUntilFinished() async {
        guard !isFinished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The reads that landed, in provider order.
    var landed: [AccountObservation] {
        AccountProvider.allCases.compactMap { observations[$0] }
    }

    /// The line under an app's tile: "claude.ai · Max", "Not signed in",
    /// "Checking sign-in…" while its read runs, or "Can’t check sign-in yet"
    /// for an app whose sign-in this build cannot read. Nil before anything
    /// was started for it.
    func line(for client: ClientKind) -> String? {
        let copy = LaunchpadCopy.Found.SignIn.self
        guard let provider = AccountProvider.provider(for: client) else { return copy.cannotCheck }
        if let observation = observations[provider] { return Self.line(for: observation) }
        return reading.contains(provider) ? copy.checking : nil
    }

    /// How an observation reads as a line: the account and its plan for a
    /// subscription, "Not signed in" when signed out, and the sign-in's own
    /// words otherwise.
    static func line(for observation: AccountObservation) -> String {
        let copy = LaunchpadCopy.Found.SignIn.self
        guard let signIn = observation.signIn else { return copy.cannotCheck }
        switch signIn.method {
        case .subscription: return signIn.summary(for: observation.provider)
        case .signedOut: return copy.notSignedIn
        default: return signIn.summary(for: observation.provider).capitalizedFirst
        }
    }

    // MARK: Settling

    private func land(_ provider: AccountProvider) {
        reading.remove(provider)
        tasks.removeValue(forKey: provider)
        settleIfDone()
    }

    private func settleIfDone() {
        guard reading.isEmpty else { return }
        finish()
    }

    private func finish() {
        isFinished = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    private func stopAll() {
        shellTask?.cancel()
        shellTask = nil
        for task in tasks.values { task.cancel() }
        tasks = [:]
        reading = []
    }
}
