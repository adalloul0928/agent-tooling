import AgentToolingCore
import Foundation

/// The project folders on this Mac, and what the workspace makes of them.
///
/// A scan looks where Claude Code has run (its own session index) and in the
/// folders this Mac was told to look in, reads each folder's agent
/// configuration and Git remote, and joins that with the workspace's projects:
/// a folder is one the workspace already tracks here, a checkout of a project
/// that has no folder here yet, or new. Nothing is written by a scan.
///
/// Two things write. *Track* makes a folder a project: a new shared project
/// named after the folder and carrying its repository, bound to the folder on
/// this Mac. *Attach* gives an existing project this folder; when the folder's
/// repository is one the project did not know, the project learns it, so the
/// next Mac recognises its clone without being told.
@MainActor @Observable
final class WorkspaceProjectDiscoverySession {
    typealias Match = ProjectRepositoryMatcher.Match

    private(set) var matches: [Match] = []
    private(set) var isScanning = false
    private(set) var isWriting = false
    private(set) var errorMessage: String?
    private(set) var lastScan: Date?

    private let library: WorkspaceLibrarySession
    private let device: WorkspaceDeviceSession
    private let service: WorkspaceApplicationService
    private let homeRoot: URL
    private let options: ProjectDiscoveryOptions
    private var scan: Task<Void, Never>?

    init(
        library: WorkspaceLibrarySession, device: WorkspaceDeviceSession,
        service: WorkspaceApplicationService, homeRoot: URL,
        options: ProjectDiscoveryOptions = ProjectDiscoveryOptions()
    ) {
        self.library = library
        self.device = device
        self.service = service
        self.homeRoot = homeRoot
        self.options = options
    }

    // MARK: Reading

    /// Folders the workspace does not track here, checkouts of a project first.
    var untrackedFolders: [Match] {
        matches.filter { if case .tracked = $0.standing { return false }; return true }
            .sorted { left, right in
                switch (left.standing, right.standing) {
                case (.matches, .untracked): return true
                case (.untracked, .matches): return false
                default: return left.project.name.localizedCaseInsensitiveCompare(right.project.name) == .orderedAscending
                }
            }
    }

    /// What the scan found in a project's bound folder, or `nil` before a scan
    /// or when the folder was not among the scanned ones.
    func folder(for projectID: ArtifactID) -> DiscoveredProject? {
        matches.first { $0.standing == .tracked(projectID: projectID) }?.project
    }

    /// Folders on this Mac that are checkouts of an unattached project's
    /// repository: what the detail offers as "use this folder".
    func candidates(for projectID: ArtifactID) -> [DiscoveredProject] {
        guard let project = projects.first(where: { $0.id == projectID }) else { return [] }
        return ProjectRepositoryMatcher.candidates(for: project, discovered: matches.map(\.project), bindings: bindings)
    }

    var scanRoots: [String] { device.projectScanRoots }

    var isBusy: Bool { isScanning || isWriting }

    // MARK: Scanning

    /// Reads this Mac's project folders. Safe to call again while one runs;
    /// the second call joins the first.
    func refresh() async {
        if let scan {
            await scan.value
            return
        }
        let task = Task { await self.performScan() }
        scan = task
        defer { scan = nil }
        await task.value
    }

    private func performScan() async {
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }
        if library.state == nil { await library.refresh() }
        let home = homeRoot
        let roots = scanRoots
        let bound = bindings.map(\.rootPath)
        let clients = Set(device.managedClients)
        let options = options
        // File reads, off the actor; every folder is read with bounded
        // accessors and no command runs.
        let discovered = await Task.detached(priority: .utility) {
            Self.discover(homeURL: home, scanRoots: roots, boundPaths: bound, clients: clients, options: options)
        }.value
        matches = ProjectRepositoryMatcher.classify(discovered: discovered, projects: projects, bindings: bindings)
        lastScan = .now
    }

    /// Where projects come from, in order: folders bound to a project (always
    /// inspected, so the detail can show what is in them), Claude Code's
    /// session index, and the chosen scan roots' children.
    nonisolated static func discover(
        homeURL: URL, scanRoots: [String], boundPaths: [String], clients: Set<ClientKind>,
        options: ProjectDiscoveryOptions, fileManager: FileManager = .default
    ) -> [DiscoveredProject] {
        var origins: [String: Set<ProjectDiscoveryOrigin>] = [:]
        var order: [String] = []
        func add(_ url: URL, _ origin: ProjectDiscoveryOrigin) {
            let key = ProjectPath.canonical(url)
            if origins[key] == nil { order.append(key) }
            origins[key, default: []].insert(origin)
        }
        for path in boundPaths { add(URL(fileURLWithPath: path, isDirectory: true), .pinned) }
        for root in ProjectDiscovery.sessionIndexRoots(homeURL: homeURL, fileManager: fileManager, options: options) {
            add(root, .sessionIndex)
        }
        for root in scanRoots {
            for found in ProjectDiscovery.scannedRoots(under: URL(fileURLWithPath: root, isDirectory: true), fileManager: fileManager, options: options)
            where ProjectDiscovery.isEligibleProjectRoot(found, homeURL: homeURL) {
                add(found, .scannedRoot)
            }
        }
        let clientsToRead = clients.isEmpty ? Set(ClientKind.allCases) : clients
        return order.prefix(options.maximumProjects).compactMap { path in
            ProjectDiscovery.inspect(
                root: URL(fileURLWithPath: path, isDirectory: true), origins: origins[path] ?? [],
                clients: clientsToRead, fileManager: fileManager)
        }
    }

    // MARK: Writing

    /// Makes a found folder a project of its own: a shared project named after
    /// the folder, carrying its repository, bound to the folder on this Mac.
    /// Returns the new project's id.
    @discardableResult
    func track(_ folder: DiscoveredProject, named name: String? = nil) async -> ArtifactID? {
        await write {
            let head = try await self.head()
            let receipt = try await self.service.createProject(.init(
                expectedRevisionID: head,
                name: (name ?? folder.name).trimmingCharacters(in: .whitespacesAndNewlines),
                repositoryHints: [folder.repositoryHint].compactMap { $0 }))
            guard let projectID = receipt.affectedArtifactIDs.first else { throw WorkspaceRevisionStoreError.notInitialized }
            try await self.service.bindProjectRoot(
                projectID: projectID, rootPath: folder.path, expectedRevisionID: receipt.committedRevisionID)
            return projectID
        }
    }

    /// Gives an existing project this folder on this Mac. A repository the
    /// project did not know is recorded on it, so the recognition carries to
    /// the next Mac.
    @discardableResult
    func attach(_ folder: DiscoveredProject, to projectID: ArtifactID) async -> Bool {
        let result: Bool? = await write {
            var head = try await self.head()
            if let hint = folder.repositoryHint,
               let project = self.projects.first(where: { $0.id == projectID }),
               !project.repositoryHints.contains(where: { RepositoryIdentity.matches($0, hint) }) {
                let receipt = try await self.service.addProjectRepositoryHint(.init(
                    expectedRevisionID: head, projectID: projectID, repository: hint))
                head = receipt.committedRevisionID
            }
            try await self.service.bindProjectRoot(projectID: projectID, rootPath: folder.path, expectedRevisionID: head)
            return true
        }
        return result ?? false
    }

    /// Adds a folder whose children this Mac should look through for projects.
    func addScanRoot(_ url: URL) async {
        let path = ProjectPath.canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "That folder is not on this Mac."
            return
        }
        guard !scanRoots.contains(path) else { return }
        guard scanRoots.count < Self.maximumScanRoots else {
            errorMessage = "Agent Tooling looks in at most \(Self.maximumScanRoots) folders. Remove one first."
            return
        }
        await setScanRoots((scanRoots + [path]).sorted())
    }

    func removeScanRoot(_ path: String) async {
        guard scanRoots.contains(path) else { return }
        await setScanRoots(scanRoots.filter { $0 != path })
    }

    static let maximumScanRoots = 12

    // MARK: Facts

    private var projects: [ProjectRepositoryMatcher.Project] {
        (library.state?.library.projects ?? []).map { .init(id: $0.id, name: $0.name, repositoryHints: $0.repositoryHints) }
    }

    private var bindings: [DeviceProjectRootBinding] {
        library.state?.snapshot.device.projectRoots ?? []
    }

    private func head() async throws -> WorkspaceObjectID {
        guard let head = try await service.snapshot()?.document.revision.id else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        return head
    }

    private func setScanRoots(_ roots: [String]) async {
        // Failure is reported through errorMessage; the screen re-reads either way.
        _ = await write {
            try await self.device.setProjectScanRoots(roots)
            return true
        }
        await refresh()
    }

    /// Runs one recorded change, then re-reads the library and re-classifies,
    /// so the screen shows the folder where it now belongs.
    private func write<T>(_ body: @escaping () async throws -> T) async -> T? {
        guard !isWriting else { return nil }
        isWriting = true
        errorMessage = nil
        defer { isWriting = false }
        do {
            let value = try await body()
            await library.refresh()
            matches = ProjectRepositoryMatcher.classify(discovered: matches.map(\.project), projects: projects, bindings: bindings)
            return value
        } catch let error as WorkspaceProjectRootError {
            errorMessage = error.localizedDescription
        } catch let error as WorkspaceDomainValidationError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = "This Mac could not record that. Nothing was changed. (\(error.localizedDescription))"
        }
        return nil
    }

    private static func message(for error: WorkspaceDomainValidationError) -> String {
        switch error {
        case .duplicate: "A project with that name already exists. Attach the folder to it instead, or choose another name."
        default: "That could not be recorded as a project. (\(error))"
        }
    }
}
