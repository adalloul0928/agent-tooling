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
        let preferences = (try? store.snapshot())?.device.applicationState?.preferences
        enabledClients = preferences.map { Set($0.enabledClients) } ?? Set(ClientKind.allCases)
        automaticallyCheckHealth = preferences?.automaticallyCheckHealth ?? true
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
        if enabled { enabledClients.insert(client) } else { enabledClients.remove(client) }
        errorMessage = nil
        do {
            guard let head = try await service.snapshot()?.document.revision.id else {
                throw WorkspaceRevisionStoreError.notInitialized
            }
            // Written as a difference rather than as the whole set, so a choice
            // made somewhere else between reading and writing is not quietly
            // overwritten by this one.
            _ = try await service.commitDeviceChange(expectedRevisionID: head) { device in
                guard var application = device.applicationState else {
                    throw WorkspaceRevisionStoreError.notInitialized
                }
                var clients = Set(application.preferences.enabledClients)
                if enabled { clients.insert(client) } else { clients.remove(client) }
                application.preferences.enabledClients = clients.sorted { $0.rawValue < $1.rawValue }
                device.applicationState = application
            }
        } catch {
            // Showing a checkbox that did not save would be a lie about what
            // this Mac will do next.
            enabledClients = previous
            errorMessage = "This Mac could not record which apps it manages. Nothing was changed."
            return
        }
        // The choice is device state, but recording it advances the workspace,
        // so the library is read again rather than left holding an older head.
        await library.refresh()
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
