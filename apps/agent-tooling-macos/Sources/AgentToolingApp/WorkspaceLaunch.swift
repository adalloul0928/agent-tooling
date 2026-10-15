import AgentToolingCore
import Foundation

/// Opens this Mac's workspace, creating one on a first run.
///
/// There is one store and one place to find it, so there is nothing to choose
/// between and nothing to validate a choice against. What used to be an
/// authority selection with a migration behind it is now a locator and, when it
/// finds nothing, a scan.
@MainActor
struct WorkspaceLaunch {
    /// Every session the app's screens are built from. They share one store and
    /// one library, so what one of them changes the others see.
    struct Workspace {
        let library: WorkspaceLibrarySession
        let sync: WorkspaceSyncSession?
        let settings: WorkspaceSettingsSession
        let deployment: WorkspaceDeploymentSession
        /// This Mac's own apps: what the last check found, and which of them
        /// this Mac manages. It has checked nothing until something asks it to.
        let device: WorkspaceDeviceSession
        /// The connection Health screen's state: what each managed client's
        /// last connection check found, and the reviewed re-authentication a
        /// person can start from a row. Checked only when asked.
        let health: WorkspaceHealthSession
        let history: WorkspaceHistorySession
        let authoring: WorkspaceAuthoringSession
        let export: WorkspacePackageExportSession
        /// What the catalogs published. Home, Discover and every plugin update
        /// verdict read the same answer, so asking a registry once is what the
        /// whole app has asked it.
        let marketplace: WorkspaceMarketplaceSession
        /// Updates to what this Mac manages: found on the policy's cadence,
        /// installed by policy or by a press. Home counts them, Settings sets
        /// the policy, and the Library rows wear the badges.
        let updates: WorkspaceUpdateSession
        /// The report the last scan kept. Home reports it and Insights produces
        /// it; a scan started on one is finished on both.
        let insights: WorkspaceInsightsSession
        /// The project folders on this Mac and what the workspace makes of
        /// them. The Projects screen scans and tracks through it.
        let projectDiscovery: WorkspaceProjectDiscoverySession
        /// What other Macs asked for here, installed by policy or waiting on
        /// Home. Runs after a sync pass brings anything in.
        let incoming: WorkspaceIncomingSession
        /// The review queue. Home counts it and Apps decides it, and a request
        /// decided on one is gone from the other without a second read.
        let requests: WorkspaceRequestSession
        /// The audit of this Mac's tooling and the assistant's reading of it.
        /// The setup wizard, the weekly checkup, and a client review all run it.
        let setup: WorkspaceSetupSession
        /// What the claude.ai and ChatGPT accounts put in front of this Mac's
        /// clients, the choices every Mac shares about them, and the reviewed
        /// plan that makes this Mac follow them. Reads nothing until asked.
        let accounts: WorkspaceAccountsSession
        /// Absent when this Mac's linked-preset file could not be prepared. The
        /// workspace still opens; only following a preset is unavailable.
        let presets: WorkspacePresetsSession?
        /// Why `presets`, `sync`, or the content store is absent, when it is —
        /// the caught error's own description, so the pane that stands in for
        /// the missing feature can say what actually went wrong rather than only
        /// that something did. Nil when the feature opened normally.
        let presetsUnavailableReason: String?
        let syncUnavailableReason: String?
        let contentStoreUnavailableReason: String?
        let declarations: WorkspaceProjectDeclarationSession
        /// True when this launch created the workspace by scanning.
        let isFirstRun: Bool
        /// The one store and the one application service every session writes
        /// through. A screen that needs a command no session exposes goes through
        /// these rather than opening the store a second time.
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let contentStore: CentralPackageContentStore?
        /// The home directory this workspace was opened against; tests point it
        /// at a scratch folder so nothing reads the real one.
        let homeRoot: URL
    }

    /// Whether this Mac has a workspace record. A first launch without one is
    /// where the person chooses between starting here and joining another Mac.
    static func hasWorkspace(supportRoot: URL? = nil) -> Bool {
        let root: URL
        if let supportRoot {
            root = supportRoot.standardizedFileURL
        } else if let defaultRoot = try? WorkspaceLocator.defaultRoot() {
            root = defaultRoot
        } else {
            return false
        }
        guard let locator = try? WorkspaceLocator(root: root) else { return false }
        // An unreadable record is treated as present: starting a second
        // workspace beside one this build cannot read would be the worse error,
        // and open() will say what is wrong with it.
        guard let record = try? locator.read() else { return true }
        return record != nil
    }

    /// The second Mac's first run: joins the workspace another Mac published,
    /// and opens it. The store, locator and enrollment are written by the
    /// join itself; this only wires the sessions on top.
    static func join(
        remote: String,
        branch: String = "main",
        supportRoot: URL? = nil,
        homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
        deviceObserver: any DeviceObserving = LiveDeviceObserver(),
        marketplaceProviders: (MarketplaceCatalogContext) -> [any MarketplaceProvider] =
            MarketplaceCatalogs.live,
        insightsServices: (URL) -> any InsightsServicing = { LiveInsightsServices(container: $0) },
        requestQueue: any PendingRequestQueuing = LivePendingRequestQueue(),
        setupServices: (URL) -> any SetupServicing = { LiveSetupServices(container: $0) },
        accountReader: (URL) -> any AccountSurfaceReading = { WorkspaceLaunch.liveAccountReader(homeRoot: $0) }
    ) async throws -> Workspace {
        let root = try supportRoot?.standardizedFileURL ?? WorkspaceLocator.defaultRoot()
        let locator = try WorkspaceLocator(root: root)
        // The content store the joined workspace will use, so the join can
        // bring the other Mac's skill bytes across in the same pass.
        let contentDirectory = root.appending(path: "content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: contentDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let contentStore = try? CentralPackageContentStore(directory: contentDirectory)
        let joined = try await WorkspaceJoin.join(
            remote: remote, checkout: root.appending(path: "sync-checkout", directoryHint: .isDirectory),
            branch: branch, containerRoot: root, homeURL: homeRoot,
            runner: ProcessCommandRunner(timeout: .seconds(120), homeURL: homeRoot),
            contentStore: contentStore, locator: locator)
        // The enrollment lives beside the store, where the sync session reads it.
        let container = joined.store.databaseURL.deletingLastPathComponent()
        try WorkspaceSyncEnrollmentStore(containerRoot: container).write(joined.enrollment)
        return sessions(
            store: joined.store, homeRoot: homeRoot, isFirstRun: false, deviceObserver: deviceObserver,
            marketplaceProviders: marketplaceProviders, insightsServices: insightsServices,
            requestQueue: requestQueue, setupServices: setupServices, accountReader: accountReader)
    }

    static func open(
        supportRoot: URL? = nil,
        homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
        deviceObserver: any DeviceObserving = LiveDeviceObserver(),
        marketplaceProviders: (MarketplaceCatalogContext) -> [any MarketplaceProvider] =
            MarketplaceCatalogs.live,
        insightsServices: (URL) -> any InsightsServicing = { LiveInsightsServices(container: $0) },
        requestQueue: any PendingRequestQueuing = LivePendingRequestQueue(),
        setupServices: (URL) -> any SetupServicing = { LiveSetupServices(container: $0) },
        accountReader: (URL) -> any AccountSurfaceReading = { WorkspaceLaunch.liveAccountReader(homeRoot: $0) }
    ) async throws -> Workspace {
        let locator = try WorkspaceLocator(
            root: supportRoot?.standardizedFileURL ?? (try WorkspaceLocator.defaultRoot()))
        if let existing = try locator.open() {
            return sessions(
                store: existing, homeRoot: homeRoot, isFirstRun: false, deviceObserver: deviceObserver,
                marketplaceProviders: marketplaceProviders, insightsServices: insightsServices,
                requestQueue: requestQueue, setupServices: setupServices, accountReader: accountReader)
        }
        let created = try await locator.openOrCreate(
            homeURL: homeRoot, runner: ProcessCommandRunner(homeURL: homeRoot))
        return sessions(
            store: created, homeRoot: homeRoot, isFirstRun: true, deviceObserver: deviceObserver,
            marketplaceProviders: marketplaceProviders, insightsServices: insightsServices,
            requestQueue: requestQueue, setupServices: setupServices, accountReader: accountReader)
    }

    /// Everything that reaches outside this app is a parameter with a live
    /// default, so a test opens the same wiring the app does while a catalog is
    /// a list in memory, a scan is a canned report and the review queue is an
    /// array. There is no second door: a screen cannot reach past what is
    /// handed in here, because no screen builds one of these itself any more.
    static func sessions(
        store: WorkspaceRevisionStore,
        homeRoot: URL,
        isFirstRun: Bool,
        deviceObserver: any DeviceObserving = LiveDeviceObserver(),
        marketplaceProviders: (MarketplaceCatalogContext) -> [any MarketplaceProvider] =
            MarketplaceCatalogs.live,
        insightsServices: (URL) -> any InsightsServicing = { LiveInsightsServices(container: $0) },
        requestQueue: any PendingRequestQueuing = LivePendingRequestQueue(),
        setupServices: (URL) -> any SetupServicing = { LiveSetupServices(container: $0) },
        accountReader: (URL) -> any AccountSurfaceReading = { WorkspaceLaunch.liveAccountReader(homeRoot: $0) }
    ) -> Workspace {
        let container = store.databaseURL.deletingLastPathComponent()
        let writerID = WorkspaceObjectID()
        // The content store requires its private directory to exist, and a
        // first launch has not made one. Without it every skill intake reports
        // that the workspace cannot reach its stored content.
        let contentDirectory = container.appending(path: "content")
        try? FileManager.default.createDirectory(
            at: contentDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Each optional store keeps the reason it failed, so the pane that
        // stands in for the missing feature can name the cause instead of only
        // reporting that something could not be prepared.
        var contentStoreUnavailableReason: String?
        let contentStore: CentralPackageContentStore?
        do {
            contentStore = try CentralPackageContentStore(directory: contentDirectory)
        } catch {
            contentStore = nil
            contentStoreUnavailableReason = error.localizedDescription
        }
        let service = WorkspaceApplicationService(store: store, writerID: writerID,
                                                  contentStore: contentStore)
        let library = WorkspaceLibrarySession(
            service: service, workspaceID: store.workspaceID, deviceID: store.deviceID,
            access: .writable)
        // Sync is optional: a workspace whose enrollment file cannot be prepared
        // still opens its library rather than failing to start.
        var syncUnavailableReason: String?
        let sync: WorkspaceSyncSession?
        do {
            let enrollmentStore = try WorkspaceSyncEnrollmentStore(containerRoot: container)
            sync = WorkspaceSyncSession(
                store: store, enrollmentStore: enrollmentStore,
                workspaceID: store.workspaceID, writerID: writerID,
                keyStore: try? WorkspaceFolderKeyStore(containerRoot: container),
                contentStore: contentStore)
        } catch {
            sync = nil
            syncUnavailableReason = error.localizedDescription
        }
        // Following a preset is optional the same way: the linked-preset file
        // that cannot be prepared leaves the rest of the workspace intact.
        var presetsUnavailableReason: String?
        let presets: WorkspacePresetsSession?
        do {
            let presetStore = try WorkspaceLinkedPresetStore(containerRoot: container)
            presets = WorkspacePresetsSession(service: service, library: library, store: presetStore)
        } catch {
            presets = nil
            presetsUnavailableReason = error.localizedDescription
        }
        // Named rather than built in place: the review queue refuses a request
        // naming an app this Mac does not manage, and the answer to that has to
        // be the same one the sidebar and every screen is reading.
        let device = WorkspaceDeviceSession(
            service: service, library: library, store: store,
            homeRoot: homeRoot, observer: deviceObserver)
        let health = WorkspaceHealthSession(device: device, homeRoot: homeRoot)
        let deployment = WorkspaceDeploymentSession(
            service: service, library: library, store: store,
            homeRoot: homeRoot, contentStore: contentStore)
        let marketplace = WorkspaceMarketplaceSession(
            providers: marketplaceProviders(
                MarketplaceCatalogContext(homeRoot: homeRoot, store: store)),
            service: service, library: library, store: store)
        let insights = WorkspaceInsightsSession(library: library, homeRoot: homeRoot, services: insightsServices(container))
        let accounts = WorkspaceAccountsSession(
            library: library, device: device, service: service, store: store, sync: sync,
            homeRoot: homeRoot, reader: accountReader(homeRoot))
        return .init(
            library: library, sync: sync,
            settings: WorkspaceSettingsSession(homeRoot: homeRoot, library: library),
            deployment: deployment,
            device: device,
            health: health,
            history: WorkspaceHistorySession(store: store, library: library,
                                             writerID: writerID, access: .writable),
            authoring: WorkspaceAuthoringSession(service: service, library: library),
            export: WorkspacePackageExportSession(library: library, contentStore: contentStore),
            marketplace: marketplace,
            updates: WorkspaceUpdateSession(
                library: library, deployment: deployment, device: device, marketplace: marketplace,
                service: service, store: store, homeRoot: homeRoot),
            insights: insights,
            projectDiscovery: WorkspaceProjectDiscoverySession(
                library: library, device: device, service: service, homeRoot: homeRoot),
            incoming: WorkspaceIncomingSession(
                library: library, deployment: deployment, device: device, service: service, sync: sync),
            requests: WorkspaceRequestSession(
                store: store, library: library, device: device, queue: requestQueue),
            setup: WorkspaceSetupSession(
                service: service, library: library, device: device, insights: insights, store: store,
                homeRoot: homeRoot, services: setupServices(container), accounts: accounts),
            accounts: accounts,
            presets: presets,
            presetsUnavailableReason: presetsUnavailableReason,
            syncUnavailableReason: syncUnavailableReason,
            contentStoreUnavailableReason: contentStoreUnavailableReason,
            declarations: WorkspaceProjectDeclarationSession(library: library),
            isFirstRun: isFirstRun,
            store: store, service: service, contentStore: contentStore, homeRoot: homeRoot)
    }

    /// The reader the app uses: each client's own tool, plus the login shell
    /// asked once which overriding variables it exports.
    nonisolated static func liveAccountReader(homeRoot: URL) -> any AccountSurfaceReading {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return AccountSurfaceProbe.live(homeURL: homeRoot, appVersion: version)
    }
}
