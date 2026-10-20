import AgentToolingCore
import Foundation

/// Opens this Mac's workspace, and builds every session over it.
///
/// There is one store and one place to find it, so there is nothing to choose
/// between and nothing to validate a choice against. What used to be an
/// authority selection with a migration behind it is now a locator. A first
/// run's library is created by the setup stage (`create`, `join`), from what
/// the person saw read; opening never creates one.
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
        /// The setup stage, Checkup and its weekly run, and a client review
        /// all run it.
        let setup: WorkspaceSetupSession
        /// What the claude.ai and ChatGPT accounts put in front of this Mac's
        /// clients, the choices every Mac shares about them, and the reviewed
        /// plan that makes this Mac follow them. Reads nothing until asked.
        let accounts: WorkspaceAccountsSession
        /// How far this Mac's setup has got: the record beside the store that
        /// the setup stage writes and Home's Finish setting up card reads. A
        /// workspace made before the stage existed has none.
        let setupProgress: WorkspaceSetupProgressSession
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

    /// What this Mac's workspace record says, read without opening the store:
    /// the launch decides from it before any window is drawn.
    enum RecordState: Equatable, Sendable {
        /// No record: a first run.
        case none
        /// A record this build reads, and the folder its store lives in.
        case present(WorkspaceLocator.Record, container: URL)
        /// A record a newer Agent Tooling wrote.
        case newerFormat
        /// A record that is not one any Agent Tooling writes.
        case damaged
        /// A record that could not be read from disk, with the reason.
        case unreadable(String)
    }

    /// The record's state under `supportRoot`, or the default support folder.
    /// A support folder that cannot be used at all has no record in it.
    nonisolated static func recordState(supportRoot: URL? = nil) -> RecordState {
        let root: URL
        if let supportRoot {
            root = supportRoot.standardizedFileURL
        } else if let defaultRoot = try? WorkspaceLocator.defaultRoot() {
            root = defaultRoot
        } else {
            return .none
        }
        guard let locator = try? WorkspaceLocator(root: root) else { return .none }
        // read() returns nil only when there is no record, and throws when one
        // exists but this build cannot read it. The two are kept apart:
        // folding the throw into the same nil as the absence would report a
        // first run on a Mac that already has an unreadable workspace.
        do {
            guard let record = try locator.read() else { return .none }
            return .present(record, container: locator.containerDirectory(for: record))
        } catch WorkspaceLocatorError.newerFormat {
            return .newerFormat
        } catch WorkspaceLocatorError.damaged {
            return .damaged
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Every service the session graph reaches outside the app through, each
    /// with its live default. The shell's launch and the setup stage build the
    /// graph from one of these, and a test hands in one with every service
    /// scripted, so no screen can reach past what it was given.
    struct Services {
        var deviceObserver: any DeviceObserving = LiveDeviceObserver()
        var marketplaceProviders: (MarketplaceCatalogContext) -> [any MarketplaceProvider] = MarketplaceCatalogs.live
        var insightsServices: (URL) -> any InsightsServicing = { LiveInsightsServices(container: $0) }
        var requestQueue: any PendingRequestQueuing = LivePendingRequestQueue()
        var setupServices: (URL) -> any SetupServicing = { LiveSetupServices(container: $0) }
        var accountReader: (URL) -> any AccountSurfaceReading = { WorkspaceLaunch.liveAccountReader(homeRoot: $0) }
        /// Where a workspace's setup record is kept, from its container.
        var setupProgressStore: @Sendable (URL) -> any SetupProgressStoring = { LiveSetupProgressStore(container: $0) }
        /// Applies the tool folders this Mac recorded to every lookup in the
        /// process. A fixture passes one that does nothing, so a test cannot
        /// change where another test's tools are found.
        var registerToolRoots: @Sendable ([String]) -> Void = { ClientExecutableLocator.registerAdditionalRoots($0) }
    }

    /// A first run's commit: creates this Mac's workspace from what the stage
    /// already read, and opens it.
    ///
    /// Nothing is read or run here. The observations are replayed, and the
    /// runner refuses every command, so the library is made from exactly
    /// what the person saw read. In order: revision 1, with `preferences` in
    /// it; then `beforeRecord`, with the workspace's own folder, for the files
    /// that belong beside the store (the setup record); then the locator
    /// record, last. A Mac that already has a record refuses the creation.
    static func create(
        observations: [TargetObservation],
        preferences: DeviceWorkspacePreferences,
        supportRoot: URL?,
        homeRoot: URL,
        beforeRecord: @escaping @Sendable (URL) throws -> Void,
        services: Services = Services()
    ) async throws -> Workspace {
        let root = try supportRoot?.standardizedFileURL ?? WorkspaceLocator.defaultRoot()
        let locator = try WorkspaceLocator(root: root)
        let store = try await locator.create(
            homeURL: homeRoot, runner: RefusingRunner(), registry: .replaying(observations), preferences: preferences,
            beforeRecord: beforeRecord)
        return sessions(store: store, homeRoot: homeRoot, isFirstRun: true, services: services)
    }

    /// The runner a replayed creation is given: nothing may run, so every
    /// command answers as a tool that is not there.
    private struct RefusingRunner: CommandRunning {
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            CommandOutput(status: 127, standardOutput: "", standardError: "Nothing runs while a library is created.")
        }
    }

    /// What a join hands on besides the workspace: how many items' files came
    /// across, and what every other Mac last published about itself. The name
    /// this Mac was registered under is the registry's.
    struct JoinSummary: Equatable, Sendable {
        let importedContent: Int
        let deviceStatuses: [PublishedDeviceStatus]

        init(_ result: WorkspaceJoin.Result) {
            importedContent = result.importedContent
            deviceStatuses = result.deviceStatuses
        }
    }

    /// A joined library, opened, and what the join said about it.
    struct Joined {
        let workspace: Workspace
        let summary: JoinSummary
    }

    /// Joins through an app-owned checkout and opens sessions over the imported files.
    /// `observe` supplies local app readings; initial preferences are saved in the
    /// first revision. `afterStoreCreated` records resumable setup before registration.
    /// Cancellation before store creation retains only the checkout; afterward the
    /// join must complete or report `WorkspaceJoinError.lateFailure`.
    static func join(
        remote: String,
        branch: String = "main",
        supportRoot: URL?,
        homeRoot: URL,
        deviceName: String? = nil,
        clients: Set<ClientKind> = Set(ClientKind.allCases),
        runner: (any CommandRunning)? = nil,
        observe: (@Sendable () async throws -> [TargetObservation])? = nil,
        devicePreferences: DeviceWorkspacePreferences? = nil,
        afterStoreCreated: (@Sendable (URL) throws -> Void)? = nil,
        discardStaleCheckout: @escaping @Sendable (URL) throws -> Void = GitWorkspaceTransport.moveToTrash,
        progress: @escaping @Sendable (WorkspaceJoin.Step, WorkspaceJoin.StepState) -> Void = { _, _ in },
        services: Services
    ) async throws -> Joined {
        let root = try supportRoot?.standardizedFileURL ?? WorkspaceLocator.defaultRoot()
        let joined = try await WorkspaceJoin.join(
            remote: remote, checkout: WorkspaceSyncSession.appOwnedCheckout(supportRoot: root), branch: branch,
            containerRoot: root, homeURL: homeRoot, deviceName: deviceName,
            runner: runner ?? ProcessCommandRunner(timeout: .seconds(120), homeURL: homeRoot), clients: clients,
            locator: try WorkspaceLocator(root: root), observe: observe, devicePreferences: devicePreferences,
            contentStoreAt: { try contentStore(inContainer: $0) }, afterStoreCreated: afterStoreCreated,
            discardStaleCheckout: discardStaleCheckout, progress: progress)
        return Joined(
            workspace: sessions(store: joined.store, homeRoot: homeRoot, isFirstRun: false, services: services),
            summary: JoinSummary(joined))
    }

    /// Finishes a join that stopped after this Mac's store for `workspaceID`
    /// was created (J01's Finish joining), then opens the library with
    /// `services`. Nothing in this Mac's apps changes, and nothing is read
    /// from them. `deviceName` and `devicePreferences` are the join's own,
    /// used only for a store that was created and never started.
    static func finishJoin(
        workspaceID: WorkspaceObjectID,
        supportRoot: URL?,
        homeRoot: URL,
        deviceName: String? = nil,
        devicePreferences: DeviceWorkspacePreferences? = nil,
        runner: (any CommandRunning)? = nil,
        discardStaleCheckout: @escaping @Sendable (URL) throws -> Void = GitWorkspaceTransport.moveToTrash,
        progress: @escaping @Sendable (WorkspaceJoin.Step, WorkspaceJoin.StepState) -> Void = { _, _ in },
        services: Services
    ) async throws -> Joined {
        let root = try supportRoot?.standardizedFileURL ?? WorkspaceLocator.defaultRoot()
        let finished = try await WorkspaceJoin.finish(
            containerRoot: root, workspaceID: workspaceID, homeURL: homeRoot, deviceName: deviceName,
            devicePreferences: devicePreferences,
            runner: runner ?? ProcessCommandRunner(timeout: .seconds(120), homeURL: homeRoot),
            locator: try WorkspaceLocator(root: root), contentStoreAt: { try contentStore(inContainer: $0) },
            discardStaleCheckout: discardStaleCheckout, progress: progress)
        return Joined(
            workspace: sessions(store: finished.store, homeRoot: homeRoot, isFirstRun: false, services: services),
            summary: JoinSummary(finished))
    }

    /// The content store a joined workspace's sessions read, made in its own
    /// folder: `<container>/content`, private to this user.
    nonisolated private static func contentStore(inContainer container: URL) throws -> CentralPackageContentStore? {
        let directory = container.appending(path: "content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try CentralPackageContentStore(directory: directory)
    }

    /// Why the library could not be opened, where the cause is not the
    /// store's own.
    enum OpenError: LocalizedError, Equatable {
        /// There is no library record: this Mac has not been set up yet.
        case noLibrary

        var errorDescription: String? {
            switch self {
            case .noLibrary:
                "This Mac has no library to open yet. Quit Agent Tooling and open it again to set one up."
            }
        }
    }

    /// Opens the library this Mac already has. Never creates one: a Mac with
    /// no library is the setup stage's to set up, from a read the person saw,
    /// so a launch, a Try again or a menu-bar item can never start a second
    /// library beside one that is being made.
    static func open(
        supportRoot: URL? = nil,
        homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
        services: Services = Services()
    ) async throws -> Workspace {
        let locator = try WorkspaceLocator(
            root: supportRoot?.standardizedFileURL ?? (try WorkspaceLocator.defaultRoot()))
        guard let existing = try locator.open() else { throw OpenError.noLibrary }
        return sessions(store: existing, homeRoot: homeRoot, isFirstRun: false, services: services)
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
        marketplaceProviders: @escaping (MarketplaceCatalogContext) -> [any MarketplaceProvider] =
            MarketplaceCatalogs.live,
        insightsServices: @escaping (URL) -> any InsightsServicing = { LiveInsightsServices(container: $0) },
        requestQueue: any PendingRequestQueuing = LivePendingRequestQueue(),
        setupServices: @escaping (URL) -> any SetupServicing = { LiveSetupServices(container: $0) },
        accountReader: @escaping (URL) -> any AccountSurfaceReading = { WorkspaceLaunch.liveAccountReader(homeRoot: $0) },
        setupProgressStore: @escaping @Sendable (URL) -> any SetupProgressStoring = { LiveSetupProgressStore(container: $0) },
        registerToolRoots: @escaping @Sendable ([String]) -> Void = { ClientExecutableLocator.registerAdditionalRoots($0) }
    ) -> Workspace {
        sessions(
            store: store, homeRoot: homeRoot, isFirstRun: isFirstRun,
            services: Services(
                deviceObserver: deviceObserver, marketplaceProviders: marketplaceProviders,
                insightsServices: insightsServices, requestQueue: requestQueue, setupServices: setupServices,
                accountReader: accountReader, setupProgressStore: setupProgressStore, registerToolRoots: registerToolRoots))
    }

    /// The same wiring, from one value holding every service.
    static func sessions(
        store: WorkspaceRevisionStore, homeRoot: URL, isFirstRun: Bool, services: Services
    ) -> Workspace {
        let deviceObserver = services.deviceObserver
        let marketplaceProviders = services.marketplaceProviders
        let insightsServices = services.insightsServices
        let requestQueue = services.requestQueue
        let setupServices = services.setupServices
        let accountReader = services.accountReader
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
        let service = WorkspaceApplicationService(
            store: store, writerID: writerID,
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
            homeRoot: homeRoot, observer: deviceObserver, registerToolRoots: services.registerToolRoots)
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
        let setupProgress = WorkspaceSetupProgressSession(store: services.setupProgressStore(container))
        return .init(
            library: library, sync: sync,
            settings: WorkspaceSettingsSession(homeRoot: homeRoot, library: library),
            deployment: deployment,
            device: device,
            health: health,
            history: WorkspaceHistorySession(
                store: store, library: library,
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
            // This Mac's own placements, from its setup record and the list
            // every walk keeps, are never arrivals from another Mac.
            incoming: WorkspaceIncomingSession(
                library: library, deployment: deployment, device: device, service: service, sync: sync,
                excludedContributionIDs: { [weak setupProgress] in setupProgress?.ownPlacements ?? [] }),
            requests: WorkspaceRequestSession(
                store: store, library: library, device: device, queue: requestQueue),
            setup: WorkspaceSetupSession(
                service: service, library: library, device: device, insights: insights, store: store,
                homeRoot: homeRoot, services: setupServices(container), accounts: accounts),
            accounts: accounts,
            setupProgress: setupProgress,
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
