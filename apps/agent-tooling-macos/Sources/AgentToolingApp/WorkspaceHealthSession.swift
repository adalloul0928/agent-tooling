import AgentToolingCore
import AppKit
import Foundation
import Observation

/// The Health screen's state: what the last connection check found, and the
/// reviewed re-authentication a person can start from a row.
///
/// Checking is a read: it runs each managed client's own list command through
/// the injected runner and parses it, touching nothing. Re-authenticating is
/// the one thing here that changes anything, and it changes it in the client,
/// not in this app: `<cli> mcp login <name>` opens the client's own browser
/// flow, and this session only captures the redacted last lines to show as a
/// result. No token is ever stored or logged, and nothing runs without a click.
@MainActor @Observable
final class WorkspaceHealthSession {
    /// Per-client results from the last check, in managed-client order. A
    /// client whose tool could not run keeps its reason here so the screen can
    /// say so rather than showing it as having no connections.
    private(set) var results: [ConnectionHealthClientResult] = []
    private(set) var isChecking = false
    /// When the last check that ran finished. A check that never ran leaves it
    /// nil so the screen can say nothing has been checked yet.
    private(set) var lastCheckedAt: Date?
    private(set) var errorMessage: String?
    /// Per-entry action progress, keyed by entry id, so a row shows its own
    /// login running or its own result without disturbing the others.
    private(set) var actionState: [String: ActionState] = [:]
    /// A running tally while re-authenticating several at once, for the toolbar
    /// button to show progress; nil when no bulk run is in flight.
    private(set) var bulkProgress: BulkProgress?

    /// Where one row's re-authentication is in its life.
    enum ActionState: Equatable {
        case idle
        case running
        case finished(message: String)
        case failed(message: String)
    }

    struct BulkProgress: Equatable {
        var completed: Int
        var total: Int
    }

    private let device: WorkspaceDeviceSession
    private let homeRoot: URL
    private let probe: ConnectionHealthProbe
    private let login: ConnectionHealthLoginRunner
    private let openURL: @Sendable (URL) -> Void
    /// The authorization page the running sign-in sent the person to, keyed by
    /// entry id, so the row can offer to open it again if the browser tab was
    /// closed before the flow finished.
    private(set) var authorizationURLs: [String: URL] = [:]

    /// The live session runs each client's real tool through a bounded runner
    /// and opens URLs with the system opener; a test hands in a scripted runner,
    /// a scripted locator, a scripted sign-in, and a URL sink so nothing real is
    /// launched.
    init(
        device: WorkspaceDeviceSession,
        homeRoot: URL,
        runner: (any CommandRunning)? = nil,
        locate: @escaping @Sendable (ClientKind, URL) -> URL? = { ClientExecutableLocator.locate($0, homeURL: $1) },
        loginRun: InteractiveLoginRun? = nil,
        openURL: @escaping @Sendable (URL) -> Void = { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
    ) {
        self.device = device
        self.homeRoot = homeRoot
        let runner = runner ?? ProcessCommandRunner(homeURL: homeRoot)
        self.probe = ConnectionHealthProbe(runner: runner, homeURL: homeRoot, locate: locate)
        // The login runner lives in Core beside the policy it must satisfy, so
        // the guarantee that every executable this app runs is admitted by the
        // allowlist is enforced there rather than restated here.
        self.login = ConnectionHealthLoginRunner(homeURL: homeRoot, locate: locate, run: loginRun)
        self.openURL = openURL
    }

    /// Every entry from the last check, across all clients, flattened for the
    /// screen's own grouping and filtering.
    var entries: [ConnectionHealthEntry] { results.flatMap(\.entries) }

    /// How many listed connections are in a state worth looking at.
    var attentionCount: Int { entries.filter { $0.status.needsAttention }.count }

    /// The entries a bulk re-authentication would sign in to: those whose one
    /// honest offer is a login this app can run. This is the same predicate the
    /// button's count and the confirmation list read, so the button is enabled
    /// exactly when there is something to run and names exactly what will run.
    var reauthenticatableEntries: [ConnectionHealthEntry] {
        entries.filter { entry in
            guard case .reauthenticate = ConnectionHealthActionClassifier.action(for: entry) else { return false }
            return login.canLogIn(client: entry.client)
        }
    }

    /// Reads each managed client's connections again. Reads only.
    ///
    /// Safe to call while one is running: the second call is ignored rather
    /// than starting a probe beside the first.
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        errorMessage = nil
        let clients = device.managedClients
        let probed = await probe.probe(clients)
        results = probed
        lastCheckedAt = .now
        // Clear the progress of rows that no longer exist, so a stale result
        // from a server that has gone away does not linger on the screen.
        let liveIDs = Set(entries.map(\.id))
        actionState = actionState.filter { liveIDs.contains($0.key) }
    }

    /// Signs in to one server again through the client's own OAuth flow.
    ///
    /// The command is shown before it runs — the screen puts it in the button's
    /// help and confirmation — and the client opens its own browser. This
    /// session captures only the last lines of the redacted output as the row's
    /// result, then re-checks so the row reflects the new state. A login whose
    /// command this app cannot build, or that the policy refuses, fails the row
    /// with a plain reason rather than running anything.
    func reauthenticate(_ entry: ConnectionHealthEntry) async {
        guard actionState[entry.id] != .running else { return }
        _ = await runLogin(entry)
        await check()
    }

    /// Re-authenticates every eligible entry, one after another.
    ///
    /// Sequential on purpose: each login opens the browser, and two OAuth flows
    /// racing for the same browser is how a person ends up signing in to the
    /// wrong one. Reports a tally at the end and re-checks once, rather than
    /// after each, so the screen settles on the final state.
    func reauthenticateAll() async {
        let eligible = reauthenticatableEntries
        guard !eligible.isEmpty, bulkProgress == nil else { return }
        bulkProgress = BulkProgress(completed: 0, total: eligible.count)
        defer { bulkProgress = nil }
        var succeeded = 0
        for (index, entry) in eligible.enumerated() {
            if await runLogin(entry) { succeeded += 1 }
            bulkProgress = BulkProgress(completed: index + 1, total: eligible.count)
        }
        await check()
        let failed = eligible.count - succeeded
        errorMessage =
            failed == 0
            ? nil
            : "Signed in to \(succeeded) of \(CountNoun.connection.phrase(eligible.count)). "
                + "\(failed) still \(failed == 1 ? "needs" : "need") attention."
    }

    /// Opens the claude.ai connectors page, for a hosted connector that cannot
    /// sign in locally. Opening a page changes nothing on this Mac.
    func openConnectorsPage() {
        guard let url = ConnectionHealthAction.claudeAIConnectorsURL else { return }
        openURL(url)
    }

    /// Opens the authorization page a running sign-in printed, again. Useful
    /// when the browser tab was closed before the flow finished; the tool is
    /// still waiting on its callback.
    func reopenAuthorizationPage(for entry: ConnectionHealthEntry) {
        guard let url = authorizationURLs[entry.id] else { return }
        openURL(url)
    }

    /// The one offer for an entry, so the screen and the session agree on what
    /// a row can do.
    func action(for entry: ConnectionHealthEntry) -> ConnectionHealthAction {
        ConnectionHealthActionClassifier.action(for: entry)
    }

    /// The exact command a re-authentication would run, for the button's help
    /// and the confirmation popover, so a person sees what will run before it
    /// runs. Nil when there is no login command for that client.
    func loginCommandText(for entry: ConnectionHealthEntry) -> String? {
        login.commandText(client: entry.client, serverID: entry.name)
    }

    // MARK: - Private

    /// Runs one login, records the row's result, and reports whether it
    /// succeeded. Kept apart from the two public entry points so the single and
    /// bulk paths share exactly the same running, redaction and recording. The
    /// building, policy check and running all happen in Core; this only reflects
    /// the redacted result onto the row.
    private func runLogin(_ entry: ConnectionHealthEntry) async -> Bool {
        actionState[entry.id] = .running
        authorizationURLs[entry.id] = nil
        let entryID = entry.id
        let openURL = openURL
        let result = await login.logIn(client: entry.client, serverID: entry.name) { url in
            // The tool printed where to sign in; open it and remember it so the
            // row can show and reopen it while the tool waits for the callback.
            Task { @MainActor [weak self] in self?.authorizationURLs[entryID] = url }
            openURL(url)
        }
        actionState[entry.id] =
            result.succeeded
            ? .finished(message: result.message)
            : .failed(message: result.message)
        return result.succeeded
    }
}
