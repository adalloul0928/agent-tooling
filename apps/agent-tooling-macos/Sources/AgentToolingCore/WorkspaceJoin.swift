import Foundation

public enum WorkspaceJoinError: Error, Equatable, Sendable, LocalizedError {
    /// The repository has no workspace to join: nothing was ever published.
    case emptyRemote
    /// This Mac already has a workspace. Two would be two sources of truth.
    case alreadyHasWorkspace
    case invalidRemote

    public var errorDescription: String? {
        switch self {
        case .emptyRemote: "That repository holds no workspace yet. Connect the Mac that has your library first, so it publishes one."
        case .alreadyHasWorkspace:
            "This Mac already has a workspace. Joining another would leave two sources of truth; disconnect or remove this one first."
        case .invalidRemote: "Enter a repository address without a user name or password in it."
        }
    }
}

/// A second Mac's first run: it joins the workspace another Mac published
/// instead of starting one of its own.
///
/// The remote document's workspace id becomes this store's; the device id is
/// fresh. This Mac is scanned for its own device state exactly as a first run
/// scans it, the device is registered in the shared document under the Mac's
/// name, and the result is published so every other Mac learns of it on their
/// next pass. Nothing on this Mac is written until the remote has been read and
/// found to hold a workspace; the dedicated checkout is the only thing created
/// before that point.
public enum WorkspaceJoin {
    public struct Result: Sendable {
        public let store: WorkspaceRevisionStore
        public let enrollment: WorkspaceSyncEnrollment
        public let deviceID: WorkspaceObjectID
        public let deviceName: String
        /// Items the shared document names that this Mac now has content for.
        public let importedContent: Int
    }

    /// `deviceName` defaults to this Mac's computer name.
    public static func join(
        remote: String,
        checkout: URL,
        branch: String = "main",
        containerRoot: URL,
        homeURL: URL,
        deviceName: String? = nil,
        runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(120)),
        registry: ClientAdapterRegistry = ClientAdapterRegistry(),
        clients: Set<ClientKind> = Set(ClientKind.allCases),
        contentStore: CentralPackageContentStore? = nil,
        locator: WorkspaceLocator? = nil
    ) async throws -> Result {
        if let locator, try locator.read() != nil { throw WorkspaceJoinError.alreadyHasWorkspace }
        guard GitWorkspaceTransport.isValidRemote(remote) else { throw WorkspaceJoinError.invalidRemote }

        // Read first; create nothing on this Mac until the remote proves out.
        let transport = try await GitWorkspaceTransport.enroll(remote: remote, checkout: checkout, branch: branch, runner: runner)
        let remoteState = try await transport.remoteState()
        guard let document = remoteState.document, remoteState.head != nil else {
            throw WorkspaceJoinError.emptyRemote
        }

        // This Mac, as a first run sees it, but under the shared workspace id.
        let observations = await registry.scanAll(homeURL: homeURL, runner: runner, clients: clients)
        var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        device.observations = observations.sorted { $0.surface.rawValue < $1.surface.rawValue }
        device.capabilityEvidence = TargetCapabilityEvidence.derive(from: observations)

        let store = try WorkspaceRevisionStore(
            containerRoot: containerRoot, workspaceID: document.workspaceID, deviceID: device.deviceID)
        guard try store.snapshot() == nil else { throw WorkspaceRevisionStoreError.alreadyInitialized }
        try store.initializeFromRemote(document: document, device: device)

        // Registered under this Mac's name, then published, so the other Macs
        // see a named device rather than an anonymous writer.
        let name = (deviceName ?? Host.current().localizedName ?? "Mac").trimmingCharacters(in: .whitespacesAndNewlines)
        let writerID = WorkspaceObjectID()
        let service = WorkspaceApplicationService(store: store, writerID: writerID, contentStore: contentStore)
        _ = try await service.registerDevice(
            .init(
                expectedRevisionID: document.revision.id, deviceID: device.deviceID,
                name: Self.uniqueName(name, among: document.deviceRegistry)))

        let enrollment = try WorkspaceSyncEnrollment(
            workspaceID: document.workspaceID, remote: remote,
            checkoutPath: checkout.standardizedFileURL.path, branch: branch)
        let coordinator = WorkspaceSyncCoordinator(
            store: store, transport: transport, writerID: writerID, contentStore: contentStore)
        _ = try await coordinator.sync()
        let imported = await coordinator.lastContentReport.imported.count

        try locator?.write(.init(workspaceID: document.workspaceID, deviceID: device.deviceID))
        return .init(
            store: store, enrollment: enrollment, deviceID: device.deviceID,
            deviceName: name, importedContent: imported)
    }

    /// A joining Mac whose name another living Mac already uses gets a numbered
    /// one, so registration never fails on a name clash nobody chose.
    static func uniqueName(_ name: String, among devices: [DeviceRecord]) -> String {
        let taken = Set(devices.filter { !$0.isRetired }.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        for n in 2...99 where !taken.contains("\(name) \(n)".lowercased()) { return "\(name) \(n)" }
        return "\(name) \(UUID().uuidString.prefix(4))"
    }
}
