import AgentToolingCore
import Foundation
import Observation

/// One verdict per client from the last local check, so the sidebar and the
/// Home conduit say the same thing about the same Mac.
///
/// `text` is the short line a row shows; `detail` is the full plain-words
/// explanation of what that state means and what to do about it, so a tooltip
/// or an accessibility value can say more than the badge itself. `detail` has a
/// default so callers that only build a verdict for its state and text keep
/// compiling.
struct ClientVerdict: Equatable, Sendable {
    let state: HealthState
    let text: String
    let detail: String

    init(state: HealthState, text: String, detail: String = "") {
        self.state = state
        self.text = text
        self.detail = detail
    }
}

/// Reading what is on this Mac, and changing none of it.
///
/// A protocol rather than a call so a test can hand in a scan that returns
/// canned data and never runs a command, touches a real client, or depends on
/// what happens to be installed on the machine running it.
protocol DeviceObserving: Sendable {
    func observe(homeRoot: URL) async throws -> [TargetObservation]
}

/// The real scan: the same adapters, over the same runner, that a first run
/// uses to build a workspace out of nothing.
///
/// Nothing new is probed. Giving the sidebar its client block back does not get
/// to widen what this app looks at or how it looks for it.
struct LiveDeviceObserver: DeviceObserving {
    private let registry: ClientAdapterRegistry
    private let clients: Set<ClientKind>

    init(
        registry: ClientAdapterRegistry = ClientAdapterRegistry(),
        clients: Set<ClientKind> = Set(ClientKind.allCases)
    ) {
        self.registry = registry
        self.clients = clients
    }

    func observe(homeRoot: URL) async -> [TargetObservation] {
        await registry.scanAll(
            homeURL: homeRoot, runner: ProcessCommandRunner(homeURL: homeRoot), clients: clients)
    }
}

/// What this Mac's apps look like, and which of them this Mac manages.
///
/// Observation is not installation and never becomes it. This session runs a
/// read-only scan, keeps what it found, and turns it into one verdict per
/// client. Nothing here writes to a client, and unchecking a client removes
/// nothing from it — it only stops this Mac from managing it.
///
/// Checking is never automatic: the shell decides when. Opening a window cannot
/// start a scan, and a client that is slow to answer cannot hold up a screen.
@MainActor @Observable
final class WorkspaceDeviceSession {
    /// Everything the last check saw, for every client — including the ones
    /// this Mac is not managing, so re-checking one already has an answer.
    private(set) var observations: [TargetObservation] = []
    /// When the last check that succeeded finished. A failed check leaves it
    /// alone rather than claiming a check that did not happen.
    private(set) var lastCheckedAt: Date?
    private(set) var isChecking = false
    private(set) var errorMessage: String?
    /// Which apps this Mac manages. Local to this Mac, never portable bytes.
    private(set) var enabledClients: Set<ClientKind>
    /// Whether somebody has explicitly chosen which apps to manage. Without a
    /// choice, what a check finds decides what is shown; with one, it does not.
    private var hasExplicitClientChoice: Bool
    /// What the last "find missing tools" attempt said, for the screen to show.
    private(set) var smartFindMessage: String?
    /// What the last check added to the library, in a sentence, or nil when it
    /// added nothing. A check that finds a skill a client gained since the
    /// last one records it, and this is where that is said.
    private(set) var libraryUpdateMessage: String?
    private(set) var isFindingTools = false

    /// The managed apps whose tool the last check could not run. The one
    /// predicate both the screen's button and the finder itself use, so the
    /// button is offered exactly when the finder would have work to do.
    var missingManagedClients: [ClientKind] {
        guard !observations.isEmpty else { return [] }
        return managedClients.filter { verdict(for: $0).state == .attention }
    }
    /// Whether this Mac checks its apps on its own. Device-local, the same as
    /// `enabledClients`, and just as inert to read: nothing here starts a
    /// check by itself.
    private(set) var automaticallyCheckHealth: Bool
    /// How this Mac looks for updates to what it manages, and what it does
    /// with one: per kind, install it or wait to be asked. Kept on the device
    /// record, so another Mac sharing the library decides for itself.
    private(set) var updatePolicy: UpdatePolicy
    /// When this Mac last compared its managed items with their sources.
    private(set) var lastUpdateCheck: Date?
    /// Folders this Mac looks in for projects, besides where Claude Code ran.
    private(set) var projectScanRoots: [String] = []

    /// Every app this build knows how to speak to, in the registry's own order,
    /// so every list and picker offers them the same way round.
    let availableClients: [ClientKind] = ClientKind.allCases

    /// The apps this Mac actually manages, in the registry's own order — every
    /// available client this Mac has been left managing. This is the one set
    /// the sidebar's client marks, the palette's client results, the Apps
    /// tiles, and the plugin and skill destination pickers all draw from, so
    /// they never offer an app somebody switched off.
    var managedClients: [ClientKind] {
        availableClients.filter(isEnabled)
    }

    private let service: WorkspaceApplicationService
    /// Where every change to this Mac's own record goes: the service, unless a
    /// test hands in one that fails a chosen write.
    private let recorder: any DeviceStateRecording
    private let library: WorkspaceLibrarySession
    private let homeRoot: URL
    private let observer: any DeviceObserving
    /// Scripted by tests; live launches ask the login shell for real.
    private let toolProbeRunner: (any CommandRunning)?

    /// The last device write asked for, so the next one starts only after it
    /// has finished. Two quick toggle flips each start their own task; queued
    /// like this they reach the store in the order they were made, so the last
    /// flip is the one that stays. A check recording what it found joins the
    /// same queue, so it cannot get between a flip and its write either.
    @ObservationIgnored private var pendingDeviceWrite: Task<Result<DeviceWorkspaceState, any Error>, Never>?
    /// How many queued writes still have each setting to change. A setting is
    /// shown as recorded once the last of them has finished, so a write that
    /// fails puts back its own flip and never one made after it.
    @ObservationIgnored private var writesInFlight: [DeviceSetting: Int] = [:]
    /// This Mac's choices as the store holds them: read at launch, then taken
    /// from each write that lands.
    @ObservationIgnored private var recordedPreferences: DeviceWorkspacePreferences
    /// What was shown before the first explicit choice of apps, while that
    /// choice is on its way to the store. Every flip made meanwhile is written
    /// against it, so a flip that failed is not carried in by the next one.
    @ObservationIgnored private var shownBeforeChoice: Set<ClientKind>?
    /// The message a failed choice left on screen, so a later choice that
    /// saves can take that message down without taking down a check's.
    @ObservationIgnored private var writeFailureMessage: String?

    /// One setting a device write changes.
    private enum DeviceSetting: Hashable {
        case client(ClientKind)
        case automaticHealth
        case updatePolicy
        case scanRoots

        var isClient: Bool {
            if case .client = self { true } else { false }
        }
    }

    private static let choiceNotRecorded = "This Mac could not record that choice. Nothing was changed."

    /// Reads back which apps this Mac manages, and nothing else.
    ///
    /// One bounded local read: the choice lives in this device's own record, so
    /// it is read from there rather than inferred from the portable document.
    /// No record means every app, which is what a new Mac gets — and that
    /// default is never written back, so it stays a default rather than
    /// becoming a decision nobody made.
    init(
        service: WorkspaceApplicationService,
        library: WorkspaceLibrarySession,
        store: WorkspaceRevisionStore,
        homeRoot: URL,
        observer: any DeviceObserving = LiveDeviceObserver(),
        toolProbeRunner: (any CommandRunning)? = nil,
        recorder: (any DeviceStateRecording)? = nil
    ) {
        self.service = service
        self.recorder = recorder ?? service
        self.library = library
        self.homeRoot = homeRoot
        self.observer = observer
        self.toolProbeRunner = toolProbeRunner
        let device = (try? store.snapshot())?.device
        let preferences = device?.applicationState?.preferences
        // The visibility rule lives in one place: an explicit choice wins, and
        // without one the clients the last recorded check found are the ones
        // shown, so an app that is not installed stays out of the way until it
        // is set up or deliberately turned on.
        enabledClients = ClientVisibilityPolicy.effectiveEnabledClients(
            preferences: preferences, observations: device?.observations ?? [])
        hasExplicitClientChoice = preferences?.chosenClients != nil
        automaticallyCheckHealth = preferences?.automaticallyCheckHealth ?? true
        updatePolicy = preferences?.effectiveUpdatePolicy ?? UpdatePolicy()
        lastUpdateCheck = preferences?.lastUpdateCheck
        projectScanRoots = preferences?.projectScanRoots ?? []
        recordedPreferences = preferences ?? DeviceWorkspacePreferences()
        ClientExecutableLocator.registerAdditionalRoots(preferences?.customToolDirectories ?? [])
    }

    /// A surface with no client of its own is never hidden by the choice.
    func isEnabled(_ client: ClientKind?) -> Bool {
        client.map(enabledClients.contains) ?? true
    }

    /// Starts or stops managing one app on this Mac.
    ///
    /// The choice is recorded and nothing else happens: what is already
    /// installed stays installed, and what was already asked for stays asked
    /// for. Opting out is never an uninstall.
    func setEnabled(_ client: ClientKind, _ enabled: Bool) async {
        guard enabledClients.contains(client) != enabled else { return }
        // The first explicit choice is written against what was shown before
        // it, and so is every flip made while that choice is on its way: what
        // is on screen by then holds the earlier flips too, and one of those
        // that fails must not be written by this one.
        if !hasExplicitClientChoice { shownBeforeChoice = enabledClients }
        let shown = shownBeforeChoice ?? enabledClients
        if enabled { enabledClients.insert(client) } else { enabledClients.remove(client) }
        hasExplicitClientChoice = true
        errorMessage = nil
        do {
            // Written as a difference against what is recorded — or, for the
            // first explicit choice, against what was shown — so a choice made
            // somewhere else between reading and writing is not quietly
            // overwritten by this one. A write that fails puts this app back as
            // recorded and says so: a checkbox that did not save would be a lie
            // about what this Mac will do next.
            try await writePreferences(
                .client(client), failure: "This Mac could not record which apps it manages. Nothing was changed."
            ) { preferences in
                var clients = Set(preferences.chosenClients ?? Array(shown))
                if enabled { clients.insert(client) } else { clients.remove(client) }
                let sorted = clients.sorted { $0.rawValue < $1.rawValue }
                preferences.chosenClients = sorted
                // Mirrored so an older build of this app reads the same choice.
                preferences.enabledClients = sorted
            }
            // The choice is device state, but recording it advances the
            // workspace, so the library is read again rather than left holding
            // an older head.
            await library.refresh()
        } catch {
            // Already settled: the app is shown as recorded, with the reason.
        }
    }

    /// Looks for the tools of managed apps the last check could not find, by
    /// asking the login shell — the same deterministic answer the person's own
    /// terminal would give. A folder it finds is recorded on this Mac's own
    /// record and checked from then on; nothing is installed or executed
    /// beyond the shell's `command -v`.
    func smartFindTools() async {
        guard !isFindingTools, !isChecking else { return }
        isFindingTools = true
        defer { isFindingTools = false }
        smartFindMessage = nil
        let missing = missingManagedClients
        guard !missing.isEmpty else {
            smartFindMessage = "Every managed app's tool is already found."
            return
        }
        let findings = await SmartToolFinder.probe(
            clients: missing, runner: toolProbeRunner ?? ProcessCommandRunner(homeURL: homeRoot))
        guard !findings.isEmpty else {
            let names = missing.map(\.rawValue).joined(separator: ", ")
            smartFindMessage = "Your login shell does not know these tools either: \(names). Install them, or check their app's setup."
            return
        }
        // Only folders the locator does not already check are worth recording.
        let knownRoots = Set(
            findings.flatMap { finding in
                ClientExecutableLocator.candidates(for: finding.client, homeURL: homeRoot)
                    .map { $0.deletingLastPathComponent().path }
            })
        let newDirectories = Set(findings.map(\.directory.path)).subtracting(knownRoots).sorted()
        if !newDirectories.isEmpty {
            do {
                // Queued with the toggles, and merged with what is recorded
                // inside the write, so a flip made meanwhile neither races
                // this nor is raced by it.
                let device = try await writePreferences { preferences in
                    let existing = preferences.customToolDirectories ?? []
                    preferences.customToolDirectories = Set(existing).union(newDirectories).sorted()
                }
                let recorded = device.applicationState?.preferences.customToolDirectories ?? newDirectories
                // Process-wide registration is the live app's concern only. A
                // scripted probe (a test) asserts the recorded preference and
                // must not bleed roots into every other test's locator.
                if toolProbeRunner == nil { ClientExecutableLocator.registerAdditionalRoots(recorded) }
            } catch {
                smartFindMessage = "Tools were found, but where they live could not be recorded. Nothing was changed."
                return
            }
        }
        let summary = findings
            .map { "\($0.client.rawValue) at \($0.executableURL.path)" }
            .sorted().joined(separator: " · ")
        smartFindMessage = "Found \(summary). Checking again."
        await refresh()
    }

    /// Turns this Mac's own automatic check on or off.
    ///
    /// Recorded the same way `setEnabled` records which apps this Mac manages:
    /// device-local, read fresh inside the commit rather than overwritten from
    /// what this session last saw, so a choice made elsewhere between reading
    /// and writing is not quietly lost. The one difference is the shape of what
    /// changes — one flag rather than a set — not the care taken over it.
    func setAutomaticallyCheckHealth(_ enabled: Bool) async {
        guard automaticallyCheckHealth != enabled else { return }
        automaticallyCheckHealth = enabled
        errorMessage = nil
        do {
            // A write that fails puts the toggle back as recorded and says so:
            // a toggle that did not save would be a lie about what this Mac
            // will do next.
            try await writePreferences(.automaticHealth, failure: Self.choiceNotRecorded) {
                $0.automaticallyCheckHealth = enabled
            }
            await library.refresh()
        } catch {
            // Already settled: the toggle is shown as recorded, with the reason.
        }
    }

    /// Records how this Mac handles updates. Saved before it is shown as the
    /// rule, for the same reason the health toggle is.
    func setUpdatePolicy(_ policy: UpdatePolicy) async {
        guard updatePolicy != policy else { return }
        updatePolicy = policy
        errorMessage = nil
        do {
            try await writePreferences(.updatePolicy, failure: Self.choiceNotRecorded) { $0.updatePolicy = policy }
            await library.refresh()
        } catch {
            // Already settled: the policy is shown as recorded, with the reason.
        }
    }

    /// Records the folders this Mac looks in for projects. Saved before it is
    /// shown, like every device choice here; a write that fails shows them as
    /// recorded again before the error reaches the caller.
    func setProjectScanRoots(_ roots: [String]) async throws {
        projectScanRoots = roots
        try await writePreferences(.scanRoots) { $0.projectScanRoots = roots }
    }

    /// Stamps the time of a finished update check. A check that could not
    /// run is not stamped, so the next open tries again.
    func recordUpdateCheck(at date: Date = .now) async {
        lastUpdateCheck = date
        _ = try? await writePreferences { $0.lastUpdateCheck = date }
    }

    /// One change to this Mac's own preferences, queued with every other
    /// device write.
    @discardableResult
    private func writePreferences(
        _ setting: DeviceSetting? = nil, failure message: String? = nil,
        _ change: @escaping @Sendable (inout DeviceWorkspacePreferences) throws -> Void
    ) async throws -> DeviceWorkspaceState {
        try await serializeDeviceWrite(setting, failure: message) { device in
            guard var application = device.applicationState else {
                throw WorkspaceRevisionStoreError.notInitialized
            }
            try change(&application.preferences)
            device.applicationState = application
        }
    }

    /// Runs one change to this Mac's own record after every one asked for
    /// before it, so the writes reach the store in the order they were made
    /// and the last flip is the one that stays.
    ///
    /// The head is read in the same call that commits, so another device write
    /// landing in between cannot make this one stale. Each write is settled in
    /// that same order before the next one starts: `setting` names what it
    /// changes, and `message` is what a person is told if a choice of theirs
    /// did not save. A write that failed does not stop the next one, and its
    /// error still reaches its caller.
    @discardableResult
    private func serializeDeviceWrite(
        _ setting: DeviceSetting? = nil, failure message: String? = nil,
        _ change: @escaping @Sendable (inout DeviceWorkspaceState) throws -> Void
    ) async throws -> DeviceWorkspaceState {
        if let setting { writesInFlight[setting, default: 0] += 1 }
        let previous = pendingDeviceWrite
        // An unstructured task runs the change exactly once, after the one
        // before it, whatever happens to the caller waiting on it.
        let write = Task { @MainActor () -> Result<DeviceWorkspaceState, any Error> in
            _ = await previous?.value
            let result: Result<DeviceWorkspaceState, any Error>
            do {
                result = .success(try await recorder.recordDeviceChange(change))
            } catch {
                result = .failure(error)
            }
            settle(setting, failure: message, result)
            return result
        }
        pendingDeviceWrite = write
        return try await write.value.get()
    }

    /// Takes in what one write left behind: the record as written, or the
    /// reason it was not, and then — once no later write is left to change the
    /// same setting — that setting as the store holds it.
    private func settle(
        _ setting: DeviceSetting?, failure message: String?, _ result: Result<DeviceWorkspaceState, any Error>
    ) {
        switch result {
        case .success(let device):
            if let preferences = device.applicationState?.preferences { recordedPreferences = preferences }
            // A later choice that saved makes "Nothing was changed" untrue, so
            // the message an earlier one left comes down with it.
            if message != nil, let failure = writeFailureMessage {
                if errorMessage == failure { errorMessage = nil }
                writeFailureMessage = nil
            }
        case .failure:
            if let message {
                errorMessage = message
                writeFailureMessage = message
            }
        }
        guard let setting else { return }
        let remaining = (writesInFlight[setting] ?? 1) - 1
        writesInFlight[setting] = remaining > 0 ? remaining : nil
        // A later write to the same setting settles it when it lands.
        if remaining == 0 { showRecorded(setting) }
    }

    /// Shows one setting as the store holds it. For a flip that saved, that is
    /// what is already on screen. For one that failed it is the value before
    /// it — taken from the store, which already holds every flip that saved,
    /// so a flip made after the failed one is never undone with it.
    private func showRecorded(_ setting: DeviceSetting) {
        let recorded = recordedPreferences
        switch setting {
        case .client(let client):
            let clients = recorded.chosenClients.map { Set($0) } ?? shownBeforeChoice ?? enabledClients
            if clients.contains(client) { enabledClients.insert(client) } else { enabledClients.remove(client) }
            // Whether a choice was made at all is settled once no flip of any
            // app is left: with none recorded, the next check decides again.
            guard !writesInFlight.keys.contains(where: \.isClient) else { return }
            hasExplicitClientChoice = recorded.chosenClients != nil
            shownBeforeChoice = nil
        case .automaticHealth:
            automaticallyCheckHealth = recorded.automaticallyCheckHealth
        case .updatePolicy:
            updatePolicy = recorded.effectiveUpdatePolicy
        case .scanRoots:
            projectScanRoots = recorded.projectScanRoots ?? []
        }
    }

    /// Checks this Mac's apps. Reads only.
    ///
    /// Safe to call again while one is running: the second call joins the first
    /// rather than starting a scan beside it. The scan itself runs off this
    /// actor, so the screen that asked for it keeps drawing.
    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        errorMessage = nil
        let observed: [TargetObservation]
        do {
            observed = try await observer.observe(homeRoot: homeRoot)
        } catch {
            // The last check is still the truest thing known about this Mac,
            // so it stays on screen rather than being replaced by nothing. A
            // check that did not happen writes nothing down either.
            errorMessage =
                observations.isEmpty
                ? "This Mac's apps could not be checked."
                : "This Mac's apps could not be checked again. What is shown is the last check."
            return
        }
        observations = observed
        lastCheckedAt = .now
        // A find that has nothing left to find has said its piece: once every
        // managed tool answers, the message would only strand on screen.
        if smartFindMessage != nil, missingManagedClients.isEmpty { smartFindMessage = nil }
        // With no explicit choice recorded, what this check found is what the
        // app shows: a client that is not on this Mac drops out of the way, and
        // installing one brings it back on the next check.
        if !hasExplicitClientChoice {
            enabledClients = ClientVisibilityPolicy.effectiveEnabledClients(
                preferences: nil, observations: observed)
        }
        await record(observed)
    }

    /// Keeps what the check found, so the rest of the app reads this check
    /// rather than the one a first run did.
    ///
    /// Both halves are written together: what was seen, and what each client
    /// that answered can be asked to carry. The second is what admits a
    /// destination into an install plan, and deriving it anywhere else would
    /// leave a workspace able to record an assignment it could never plan.
    ///
    /// Recorded the way `setEnabled` records which apps this Mac manages: one
    /// device-only change under the same head check as everything else, with
    /// the portable document untouched, queued with the toggles so a flip made
    /// while a check records is neither raced nor rejected as stale. What was
    /// found stays on screen either way — a scan that ran is not undone by a
    /// store that would not take it.
    private func record(_ observed: [TargetObservation]) async {
        let evidence = TargetCapabilityEvidence.derive(from: observed)
        do {
            try await serializeDeviceWrite { device in
                device.observations = observed
                device.capabilityEvidence = evidence
            }
        } catch {
            errorMessage = "This Mac's apps were checked, but what was found could not be saved."
            return
        }
        await reconcileLibrary(with: observed)
        // Recording it advances the workspace, so the library is read again
        // rather than left holding an older head.
        await library.refresh()
    }

    /// Adds to the library what this check found and the library did not hold,
    /// under the rules a first run uses: a client's package stays the client's,
    /// its members belong to it, and everything else is only tracked. Rows
    /// already here are never changed, and nothing is taken away.
    ///
    /// The inventory is compiled off the main actor, because it reads every
    /// skill's definition to name it, and a Mac with a few hundred skills
    /// should not stall the screen while it does.
    private func reconcileLibrary(with observed: [TargetObservation]) async {
        let homeRoot = self.homeRoot
        let inventory = await Task.detached(priority: .userInitiated) {
            InventoryCompiler.compile(observations: observed, homeURL: homeRoot)
        }.value
        do {
            guard let document = try await service.snapshot()?.document else { return }
            let plan = WorkspaceObservationReconciliation.plan(
                document: document, observations: observed, inventory: inventory)
            guard !plan.isEmpty else {
                libraryUpdateMessage = nil
                return
            }
            _ = try await service.reconcileObservedInventory(
                .init(expectedRevisionID: document.revision.id, plan: plan))
            libraryUpdateMessage = Self.libraryUpdateSentence(for: plan)
        } catch {
            // The check itself stands: what was found is recorded and on
            // screen. Only the library's catch-up did not happen, and saying
            // so is better than a library that silently stays behind.
            errorMessage = "This Mac's apps were checked, but the new items found could not be added to the library."
        }
    }

    /// "Added 3 skills and 1 package to the library", in the words a person
    /// reads, or nil when nothing was added.
    static func libraryUpdateSentence(for plan: WorkspaceObservationReconciliation.Plan) -> String? {
        let parts: [String] = [
            (plan.count(of: .skill), "skill"),
            (plan.count(of: .nativePlugin), "package"),
            (plan.count(of: .mcpServer), "connection"),
        ].compactMap { count, noun in
            count == 0 ? nil : "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        guard !parts.isEmpty else { return nil }
        let list: String
        switch parts.count {
        case 1: list = parts[0]
        case 2: list = parts.joined(separator: " and ")
        default: list = parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
        return "Added \(list) this Mac's apps have that the library did not."
    }

    /// What the last check found for one client, in the words a person reads.
    ///
    /// Never checked is said as never checked rather than as absent. A client
    /// whose files are here but whose command is not is neither healthy nor
    /// missing, and says which of the two it is.
    ///
    /// Answering the command is not enough to be healthy: a command that ran
    /// but reported no version has not told this app what it accepts, so a tool
    /// asked for in it would wait rather than install. That is `.attention`, not
    /// health, and says so.
    func verdict(for client: ClientKind) -> ClientVerdict {
        let name = client.rawValue
        let matching = observations.filter { $0.surface.client == client }
        guard !matching.isEmpty else {
            return ClientVerdict(
                state: .pending, text: "Not checked yet", detail: "Run Check apps to look.")
        }
        // A command that answered AND reported a version is the only healthy
        // state: that pair is what lets an install know the client will accept
        // what it is given.
        let answered = matching.filter(\.isCommandAvailable)
        if let versioned = answered.first(where: { $0.version?.isEmpty == false }),
            let version = versioned.version
        {
            let checked = answered.map(\.lastScannedAt).max().map { "Checked \(SnapshotTime.compact($0))" }
            return ClientVerdict(
                state: .healthy,
                text: checked ?? "Available",
                detail: "\(name) answered and reported version \(version).")
        }
        if !answered.isEmpty {
            return ClientVerdict(
                state: .attention,
                text: "Found, version unknown",
                detail:
                    "\(name) is installed but did not answer --version, so Agent Tooling cannot confirm what it accepts; tools asked for in it wait until it does."
            )
        }
        if matching.contains(where: \.installed) {
            return ClientVerdict(
                state: .attention,
                text: "Command unavailable",
                detail:
                    "\(name)'s files were found on this Mac, but its command-line tool was not. Use Check apps or Find missing tools after installing it."
            )
        }
        return ClientVerdict(
            state: .attention,
            text: "Not found",
            detail: "Nothing from \(name) was found on this Mac.")
    }

    /// How many of the apps this Mac manages need looking at.
    ///
    /// An app this Mac is not managing is not a problem it has, so it is not
    /// counted. Neither is one that has not been checked yet: a badge for
    /// something nobody has looked at would send someone after nothing.
    var attentionCount: Int {
        managedClients.filter { verdict(for: $0).state == .attention }.count
    }
}
