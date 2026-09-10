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
        let history: WorkspaceHistorySession
        let authoring: WorkspaceAuthoringSession
        let export: WorkspacePackageExportSession
        /// Absent when this Mac's linked-preset file could not be prepared. The
        /// workspace still opens; only following a preset is unavailable.
        let presets: WorkspacePresetsSession?
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

    static func open(
        supportRoot: URL? = nil,
        homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
        deviceObserver: any DeviceObserving = LiveDeviceObserver()
    ) async throws -> Workspace {
        let locator = try WorkspaceLocator(
            root: supportRoot?.standardizedFileURL ?? (try WorkspaceLocator.defaultRoot()))
        if let existing = try locator.open() {
            return sessions(store: existing, homeRoot: homeRoot, isFirstRun: false, deviceObserver: deviceObserver)
        }
        let created = try await locator.openOrCreate(
            homeURL: homeRoot, runner: ProcessCommandRunner(homeURL: homeRoot))
        return sessions(store: created, homeRoot: homeRoot, isFirstRun: true, deviceObserver: deviceObserver)
    }

    static func sessions(
        store: WorkspaceRevisionStore,
        homeRoot: URL,
        isFirstRun: Bool,
        deviceObserver: any DeviceObserving = LiveDeviceObserver()
    ) -> Workspace {
        let container = store.databaseURL.deletingLastPathComponent()
        let writerID = WorkspaceObjectID()
        let contentStore = try? CentralPackageContentStore(
            directory: container.appending(path: "content"))
        let service = WorkspaceApplicationService(store: store, writerID: writerID,
                                                  contentStore: contentStore)
        let library = WorkspaceLibrarySession(
            service: service, workspaceID: store.workspaceID, deviceID: store.deviceID,
            access: .writable)
        // Sync is optional: a workspace whose enrollment file cannot be prepared
        // still opens its library rather than failing to start.
        let sync = (try? WorkspaceSyncEnrollmentStore(containerRoot: container)).map {
            WorkspaceSyncSession(store: store, enrollmentStore: $0,
                                 workspaceID: store.workspaceID, writerID: writerID,
                                 keyStore: try? WorkspaceFolderKeyStore(containerRoot: container))
        }
        return .init(
            library: library, sync: sync,
            settings: WorkspaceSettingsSession(homeRoot: homeRoot, library: library),
            deployment: WorkspaceDeploymentSession(
                service: service, library: library, store: store,
                homeRoot: homeRoot, contentStore: contentStore),
            device: WorkspaceDeviceSession(
                service: service, library: library, store: store,
                homeRoot: homeRoot, observer: deviceObserver),
            history: WorkspaceHistorySession(store: store, library: library,
                                             writerID: writerID, access: .writable),
            authoring: WorkspaceAuthoringSession(service: service, library: library),
            export: WorkspacePackageExportSession(library: library, contentStore: contentStore),
            presets: (try? WorkspaceLinkedPresetStore(containerRoot: container)).map {
                WorkspacePresetsSession(service: service, library: library, store: $0)
            },
            declarations: WorkspaceProjectDeclarationSession(library: library),
            isFirstRun: isFirstRun,
            store: store, service: service, contentStore: contentStore, homeRoot: homeRoot)
    }
}
