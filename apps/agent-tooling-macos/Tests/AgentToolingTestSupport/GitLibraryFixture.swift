import AgentToolingCore
import Foundation

/// A library one Mac published into a private repository on this Mac: what a
/// second Mac joins, and what a connect finds already there. Real Git against
/// a local bare repository; nothing reaches the network.
///
/// The publishing Mac is made with the public Core API alone, the way a first
/// Mac makes and shares its library: a workspace created with no apps, the
/// Mac registered under its name, personal skills with their files, a
/// checkout connected to the repository, and one sync pass that publishes the
/// library, the skills' files and the Mac's status.
public struct GitLibraryFixture: Sendable {
    /// The Mac that published, still connected to the repository.
    public struct PublishingMac: Sendable {
        public let name: String
        public let home: URL
        /// Its support folder, holding its locator record and its store.
        public let support: URL
        public let store: WorkspaceRevisionStore
        public let service: WorkspaceApplicationService
        public let contentStore: CentralPackageContentStore
        public let coordinator: WorkspaceSyncCoordinator
        /// Its personal skills, in the order they were given.
        public let skillIDs: [ArtifactID]

        public var workspaceID: WorkspaceObjectID { store.workspaceID }
        public var deviceID: WorkspaceObjectID { store.deviceID }
    }

    /// The temporary folder holding everything, removed by `remove()`.
    public let root: URL
    /// The bare repository. Its path is an address the transport takes.
    public let remote: URL

    /// An empty bare repository whose branch is `main`.
    public init(_ prefix: String) throws {
        let root = try TemporaryFolder(prefix).url
        let remote = root.appending(path: "remote.git", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try GitTestFixture.git(["init", "--quiet", "--bare", "--initial-branch", "main", remote.path], in: root, checkingStatus: true)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        self.root = root
        self.remote = remote
    }

    /// A Mac's home with a Git identity, so commits have an author the way a
    /// person's Mac would.
    public func home(_ name: String) throws -> URL {
        let home = root.appending(path: "\(name)/home", directoryHint: .isDirectory)
        try write(home.appending(path: ".gitconfig"), "[user]\n\tname = \(name)\n\temail = \(name)@example.com\n")
        return home
    }

    /// A runner for `home`'s Git, with time enough for a busy Mac.
    public func runner(for home: URL) -> ProcessCommandRunner {
        ProcessCommandRunner(timeout: .seconds(60), homeURL: home)
    }

    /// The first Mac: a library of its own holding a personal skill for each
    /// of `skills`, registered as `name`, connected to `remote`, and
    /// published once with a status file listing `statusApps`.
    public func publishLibrary(
        from name: String, skills: [String] = [], statusApps: [PublishedDeviceStatus.AppSummary] = []
    ) async throws -> PublishingMac {
        let home = try home(name)
        let support = root.appending(path: "\(name)/support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try await WorkspaceLocator(root: support).create(
            homeURL: home, runner: RefusingCommandRunner(), registry: ClientAdapterRegistry(adapters: []), preferences: nil)
        let contentFolder = store.databaseURL.deletingLastPathComponent().appending(path: "content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: contentFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let contentStore = try CentralPackageContentStore(directory: contentFolder)
        let writerID = WorkspaceObjectID()
        let service = WorkspaceApplicationService(store: store, writerID: writerID, contentStore: contentStore)
        _ = try await service.registerDevice(
            .init(expectedRevisionID: try Self.head(of: store), deviceID: store.deviceID, name: name))
        var skillIDs: [ArtifactID] = []
        for skill in skills {
            let tree = try CapturedPackageTree(entries: [
                .init(
                    relativePath: "SKILL.md",
                    kind: .file(bytes: Data("---\nname: \(skill)\ndescription: d\n---\nWritten on \(name).\n".utf8), executable: false))
            ])
            let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
            let id = ArtifactID()
            _ = try await service.intakeStandaloneSkill(
                .init(expectedRevisionID: try Self.head(of: store), artifactID: id, displayName: skill, prepared: prepared),
                prepared: prepared)
            skillIDs.append(id)
        }
        let transport = try await GitWorkspaceTransport.enroll(
            remote: remote.path, checkout: root.appending(path: "\(name)/checkout", directoryHint: .isDirectory),
            runner: runner(for: home))
        let coordinator = WorkspaceSyncCoordinator(
            store: store, transport: transport, writerID: writerID, contentStore: contentStore,
            status: {
                PublishedDeviceStatus(
                    deviceID: store.deviceID, name: name, lastScan: nil, apps: statusApps, pending: [],
                    revisionID: (try? store.snapshot())?.document.revision.id ?? WorkspaceObjectID())
            })
        guard case .published = try await coordinator.sync() else { throw FixtureError.notPublished }
        return .init(
            name: name, home: home, support: support, store: store, service: service, contentStore: contentStore,
            coordinator: coordinator, skillIDs: skillIDs)
    }

    /// A Mac that used `publisher`'s library and was then retired: registered
    /// as `name`, its status published to the repository, then retired from
    /// `publisher`, which publishes that. Its last status stays in the
    /// repository, as a retired Mac's does. Returns its device ID.
    public func retiredMac(_ name: String, in publisher: PublishingMac) async throws -> WorkspaceObjectID {
        let id = WorkspaceObjectID()
        _ = try await publisher.service.registerDevice(
            .init(expectedRevisionID: try Self.head(of: publisher.store), deviceID: id, name: name))
        let transport = try await GitWorkspaceTransport.enroll(
            remote: remote.path, checkout: root.appending(path: "\(name)/checkout", directoryHint: .isDirectory),
            runner: runner(for: try home(name)))
        let reporting = WorkspaceSyncCoordinator(
            store: publisher.store, transport: transport, writerID: WorkspaceObjectID(),
            status: {
                PublishedDeviceStatus(deviceID: id, name: name, lastScan: nil, apps: [], pending: [], revisionID: WorkspaceObjectID())
            })
        _ = try await reporting.sync()
        _ = try await publisher.service.updateDevice(
            .init(expectedRevisionID: try Self.head(of: publisher.store), deviceID: id, change: .retire))
        _ = try await publisher.coordinator.sync()
        return id
    }

    /// A repository with one commit on `main` holding `files` (path to text):
    /// a remote with something other than a library in it, or a library file
    /// written by hand. Its path is the address.
    public func repository(_ name: String, holding files: [String: String]) throws -> URL {
        let repository = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try GitTestFixture.git(["init", "--quiet", "--initial-branch", "main"], in: repository, checkingStatus: true)
        for (path, text) in files { try write(repository.appending(path: path), text) }
        try GitTestFixture.git(["add", "--all"], in: repository, checkingStatus: true)
        // Whatever hooks or signing this Mac's own Git configuration asks
        // for are left out, as the transport leaves them out.
        try GitTestFixture.git(
            [
                "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-c", "user.name=Fixture",
                "-c", "user.email=fixture@example.com", "commit", "--quiet", "--message", "Files",
            ],
            in: repository, checkingStatus: true)
        return repository
    }

    /// A `workspace.json` in the format a newer Agent Tooling writes, for
    /// `workspace`: one version past what this build reads.
    public static func newerLibraryFile(for workspace: WorkspaceObjectID) -> String {
        let newer = PortableWorkspaceDocument.currentSchemaVersion + 1
        return "{\"schemaVersion\": \(newer), \"minimumReaderVersion\": \(newer), "
            + "\"workspaceID\": \"\(workspace.rawValue.uuidString.lowercased())\"}"
    }

    public func remove() { try? FileManager.default.removeItem(at: root) }

    private enum FixtureError: Error {
        case notPublished
    }

    private static func head(of store: WorkspaceRevisionStore) throws -> WorkspaceObjectID {
        guard let snapshot = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
        return snapshot.document.revision.id
    }
}
