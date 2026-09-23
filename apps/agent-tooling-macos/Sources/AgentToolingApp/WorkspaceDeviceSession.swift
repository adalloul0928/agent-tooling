import AgentToolingCore
import Foundation
import Observation

/// One verdict per client from the last local check, so the sidebar and the
/// Home conduit say the same thing about the same Mac.
struct ClientVerdict: Equatable, Sendable {
    let state: HealthState
    let text: String
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
    private(set) var isFindingTools = false
    /// Whether this Mac checks its apps on its own. Device-local, the same as
    /// `enabledClients`, and just as inert to read: nothing here starts a
    /// check by itself.
    private(set) var automaticallyCheckHealth: Bool

    /// Every app this build knows how to speak to, in the registry's own order,
    /// so every list and picker offers them the same way round.
    let availableClients: [ClientKind] = ClientKind.allCases

    private let service: WorkspaceApplicationService
    private let library: WorkspaceLibrarySession
    private let homeRoot: URL
    private let observer: any DeviceObserving

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
        observer: any DeviceObserving = LiveDeviceObserver()
    ) {
        self.service = service
        self.library = library
        self.homeRoot = homeRoot
        self.observer = observer
        let device = (try? store.snapshot())?.device
        let preferences = device?.applicationState?.preferences
        // The visibility rule lives in one place: an explicit choice wins, and
        // without one the clients the last recorded check found are the ones
        // shown, so an app that is not installed stays out of the way until it
        // is set up or deliberately turned on.
        enabledClients = ClientVisibilityPolicy.effectiveEnabledClients(
            preferences: preferences, observations: device?.observations ?? [])
        hasExplicitClientChoice =
            preferences?.chosenClients != nil
            || preferences.map { Set($0.enabledClients) != Set(ClientKind.allCases) } ?? false
        automaticallyCheckHealth = preferences?.automaticallyCheckHealth ?? true
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
        let previous = enabledClients
        let previousChoice = hasExplicitClientChoice
        if enabled { enabledClients.insert(client) } else { enabledClients.remove(client) }
        hasExplicitClientChoice = true
        errorMessage = nil
        do {
            guard let head = try await service.snapshot()?.document.revision.id else {
                throw WorkspaceRevisionStoreError.notInitialized
            }
            // Written as a difference against what is recorded — or, for the
            // first explicit choice, against what was effectively shown — so a
            // choice made somewhere else between reading and writing is not
            // quietly overwritten by this one.
            _ = try await service.commitDeviceChange(expectedRevisionID: head) { device in
                guard var application = device.applicationState else {
                    throw WorkspaceRevisionStoreError.notInitialized
                }
                var clients = Set(application.preferences.chosenClients ?? Array(previous))
                if enabled { clients.insert(client) } else { clients.remove(client) }
                let sorted = clients.sorted { $0.rawValue < $1.rawValue }
                application.preferences.chosenClients = sorted
                // Mirrored so an older build of this app reads the same choice.
                application.preferences.enabledClients = sorted
                device.applicationState = application
            }
        } catch {
            // Showing a checkbox that did not save would be a lie about what
            // this Mac will do next.
            enabledClients = previous
            hasExplicitClientChoice = previousChoice
            errorMessage = "This Mac could not record which apps it manages. Nothing was changed."
            return
        }
        // The choice is device state, but recording it advances the workspace,
        // so the library is read again rather than left holding an older head.
        await library.refresh()
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
        let missing = availableClients.filter {
            enabledClients.contains($0) && verdict(for: $0).state != .healthy
        }
        guard !missing.isEmpty else {
            smartFindMessage = "Every managed app's tool is already found."
            return
        }
        let findings = await SmartToolFinder.probe(
            clients: missing, runner: ProcessCommandRunner(homeURL: homeRoot))
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
                let snapshot = try await service.snapshot()
                guard let head = snapshot?.document.revision.id else {
                    throw WorkspaceRevisionStoreError.notInitialized
                }
                let existing = snapshot?.device.applicationState?.preferences.customToolDirectories ?? []
                let recorded = Set(existing).union(newDirectories).sorted()
                _ = try await service.commitDeviceChange(expectedRevisionID: head) { device in
                    guard var application = device.applicationState else {
                        throw WorkspaceRevisionStoreError.notInitialized
                    }
                    application.preferences.customToolDirectories = recorded
                    device.applicationState = application
                }
                ClientExecutableLocator.registerAdditionalRoots(recorded)
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
        let previous = automaticallyCheckHealth
        automaticallyCheckHealth = enabled
        errorMessage = nil
        do {
            guard let head = try await service.snapshot()?.document.revision.id else {
                throw WorkspaceRevisionStoreError.notInitialized
            }
            _ = try await service.commitDeviceChange(expectedRevisionID: head) { device in
                guard var application = device.applicationState else {
                    throw WorkspaceRevisionStoreError.notInitialized
                }
                application.preferences.automaticallyCheckHealth = enabled
                device.applicationState = application
            }
        } catch {
            // Showing a toggle that did not save would be a lie about what
            // this Mac will do next.
            automaticallyCheckHealth = previous
            errorMessage = "This Mac could not record that choice. Nothing was changed."
            return
        }
        await library.refresh()
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
    /// the portable document untouched. What was found stays on screen either
    /// way — a scan that ran is not undone by a store that would not take it.
    private func record(_ observed: [TargetObservation]) async {
        let evidence = TargetCapabilityEvidence.derive(from: observed)
        do {
            guard let head = try await service.snapshot()?.document.revision.id else {
                throw WorkspaceRevisionStoreError.notInitialized
            }
            _ = try await service.commitDeviceChange(expectedRevisionID: head) { device in
                device.observations = observed
                device.capabilityEvidence = evidence
            }
        } catch {
            errorMessage = "This Mac's apps were checked, but what was found could not be saved."
            return
        }
        // Recording it advances the workspace, so the library is read again
        // rather than left holding an older head.
        await library.refresh()
    }

    /// What the last check found for one client, in the words a person reads.
    ///
    /// Never checked is said as never checked rather than as absent. A client
    /// whose files are here but whose command is not is neither healthy nor
    /// missing, and says which of the two it is.
    func verdict(for client: ClientKind) -> ClientVerdict {
        let matching = observations.filter { $0.surface.client == client }
        guard !matching.isEmpty else { return ClientVerdict(state: .pending, text: "Not checked yet") }
        if matching.contains(where: \.isCommandAvailable) {
            let checked = matching.map(\.lastScannedAt).max().map { "Checked \(SnapshotTime.compact($0))" }
            return ClientVerdict(state: .healthy, text: checked ?? "Available")
        }
        return ClientVerdict(
            state: .attention,
            text: matching.contains(where: \.installed) ? "Command unavailable" : "Not found")
    }

    /// How many of the apps this Mac manages need looking at.
    ///
    /// An app this Mac is not managing is not a problem it has, so it is not
    /// counted. Neither is one that has not been checked yet: a badge for
    /// something nobody has looked at would send someone after nothing.
    var attentionCount: Int {
        availableClients.filter { isEnabled($0) && verdict(for: $0).state == .attention }.count
    }
}
