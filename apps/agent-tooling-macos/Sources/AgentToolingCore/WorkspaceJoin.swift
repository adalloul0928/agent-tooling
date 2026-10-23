import Foundation

public enum WorkspaceJoinError: Error, Equatable, Sendable, LocalizedError {
    /// The repository has no workspace to join: nothing was ever published.
    case emptyRemote
    /// This Mac already has a workspace. Two would be two sources of truth.
    case alreadyHasWorkspace
    case invalidRemote
    /// The repository could not be joined, for this reason: its address
    /// cannot be used, it could not be reached, the sign-in did not open it,
    /// it has no such branch, it holds no library, or a library this build
    /// cannot read.
    case remote(GitRemoteProblem)
    /// The join stopped after this Mac's store for `workspaceID` was created:
    /// the store is there, but this Mac is not yet registered, shared or
    /// recorded. `WorkspaceJoin.finish` completes it, and so does joining the
    /// same library again.
    case lateFailure(workspaceID: WorkspaceObjectID)
    /// `finish` found nothing to finish: no store for that workspace, or one
    /// with no record of the repository it was joining.
    case nothingToFinish

    public var errorDescription: String? {
        switch self {
        case .emptyRemote: "That repository holds no workspace yet. Connect the Mac that has your library first, so it publishes one."
        case .alreadyHasWorkspace:
            "This Mac already has a workspace. Joining another would leave two sources of truth; disconnect or remove this one first."
        case .invalidRemote: "Enter a repository address without a user name or password in it."
        case .remote(let problem): problem.errorDescription
        case .lateFailure:
            "Joining stopped before it finished. Finish joining completes it; nothing in your apps changes."
        case .nothingToFinish:
            "There is no unfinished join on this Mac to complete. Join your library again. Nothing was changed."
        }
    }
}

/// Joins a published workspace with its existing workspace ID and a fresh
/// device ID. Scans this Mac, registers its name and publishes its device
/// entry. Only the dedicated checkout is created before the remote workspace
/// is read and validated; local workspace writes follow validation.
public enum WorkspaceJoin {
    /// The steps J01 lists, in order.
    public enum Step: Int, CaseIterable, Sendable {
        /// "Reaching the repository": a fresh checkout, cloned and fetched.
        case reachingRepository = 1
        /// "Reading your library": the published document.
        case readingLibrary
        /// "Checking this Mac’s apps": the observation of this Mac. The last
        /// step a Stop ends.
        case checkingApps
        /// "Registering": the store is created, then this Mac is registered.
        /// From here the join cannot be stopped.
        case registering
        /// "Sharing": the first sync, then the locator record.
        case sharing
    }

    /// Where a step is. A step that started and did not finish is the one a
    /// thrown error stopped.
    public enum StepState: Equatable, Sendable {
        case started
        case finished
    }

    public struct Result: Sendable {
        public let store: WorkspaceRevisionStore
        public let enrollment: WorkspaceSyncEnrollment
        public let deviceID: WorkspaceObjectID
        /// The name this Mac is registered under: the one asked for, numbered
        /// when another living Mac already uses it ("Cedar 2"). A Mac whose
        /// interrupted join already registered it keeps that name. The App
        /// reads it from the device registry instead.
        let registeredName: String
        /// Items the shared document names that this Mac now has content for.
        public let importedContent: Int
        /// What every other Mac last published about itself, as the join's
        /// sync pass read it.
        public let deviceStatuses: [PublishedDeviceStatus]
    }

    /// Joins or resumes the same library, preserving an interrupted store's device
    /// identity. `observe` can replace registry scans and cancel; supplied preferences
    /// apply from the first revision. `contentStoreAt` overrides `contentStore`; if
    /// creation fails, later sync imports content. `afterStoreCreated` records recovery
    /// state after enrollment and before registration. `discardStaleCheckout` moves
    /// an unenrolled checkout aside, normally to Trash. Reports progress per step.
    /// Trims the remote and defaults `deviceName` to this Mac's name.
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
        locator: WorkspaceLocator? = nil,
        observe: (@Sendable () async throws -> [TargetObservation])? = nil,
        devicePreferences: DeviceWorkspacePreferences? = nil,
        contentStoreAt: (@Sendable (URL) throws -> CentralPackageContentStore?)? = nil,
        afterStoreCreated: (@Sendable (URL) throws -> Void)? = nil,
        discardStaleCheckout: @escaping @Sendable (URL) throws -> Void = GitWorkspaceTransport.moveToTrash,
        progress: @escaping @Sendable (Step, StepState) -> Void = { _, _ in }
    ) async throws -> Result {
        let remote = GitRemoteAddress.trimmed(remote)
        if let locator, try locator.read() != nil { throw WorkspaceJoinError.alreadyHasWorkspace }
        if let problem = GitRemoteAddress.problem(remote) { throw WorkspaceJoinError.remote(problem) }

        // Read first; create nothing on this Mac until the remote proves out.
        // No enrollment uses the checkout yet, so it starts empty: a retry
        // never meets the address an earlier attempt cloned.
        progress(.reachingRepository, .started)
        let transport = try await readingRemote {
            try GitWorkspaceTransport.prepareFreshCheckout(at: checkout, discard: discardStaleCheckout)
            return try await GitWorkspaceTransport.enroll(remote: remote, checkout: checkout, branch: branch, runner: runner)
        }
        progress(.reachingRepository, .finished)

        progress(.readingLibrary, .started)
        let remoteState = try await readingRemote { try await transport.remoteState() }
        guard remoteState.head != nil else { throw try await missingBranch(branch, on: transport) }
        guard let document = remoteState.document else { throw WorkspaceJoinError.remote(.notALibrary) }
        _ = try WorkspaceRevisionArchive(document: document, ancestors: remoteState.ancestors)
        progress(.readingLibrary, .finished)

        // This Mac, as a first run sees it, but under the shared workspace id.
        progress(.checkingApps, .started)
        let observations: [TargetObservation]
        if let observe {
            observations = try await observe()
        } else {
            observations = await registry.scanAll(homeURL: homeURL, runner: runner, clients: clients)
        }
        // The last moment a Stop is honoured. A scan swallows its own
        // cancellation and comes back with apps missing, so it is checked
        // here, before anything could record them as missing.
        try Task.checkCancellation()
        progress(.checkingApps, .finished)
        var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        device.observations = observations.sorted { $0.surface.rawValue < $1.surface.rawValue }
        device.capabilityEvidence = TargetCapabilityEvidence.derive(from: observations)
        if let devicePreferences { device.applicationState?.preferences = devicePreferences }
        let joining = try WorkspaceSyncEnrollment(
            workspaceID: document.workspaceID, remote: remote, checkoutPath: checkout.standardizedFileURL.path, branch: branch)

        progress(.registering, .started)
        // From the store on, the join finishes or fails as a whole. A task of
        // its own is not cancelled with the caller's, so a Stop or a quit
        // that arrives now waits for it instead of leaving half a join.
        let completion = Task {
            do {
                let writerID = WorkspaceObjectID()
                let store = try await storeForJoin(
                    document: document, ancestors: remoteState.ancestors, device: device,
                    devicePreferences: devicePreferences, containerRoot: containerRoot,
                    writerID: writerID)
                return try await complete(
                    store: store, transport: transport, enrollment: joining, writerID: writerID, deviceName: deviceName,
                    contentStore: contentStore, contentStoreAt: contentStoreAt, afterStoreCreated: afterStoreCreated,
                    locator: locator, progress: progress)
            } catch {
                guard
                    (try? WorkspaceRevisionStore.recordedIdentity(containerRoot: containerRoot, workspaceID: document.workspaceID))
                        != nil
                else { throw error }
                throw WorkspaceJoinError.lateFailure(workspaceID: document.workspaceID)
            }
        }
        return try await completion.value
    }

    /// Resumes an interrupted join without reading or changing client apps. Reopens
    /// the original device store, registers and syncs it, then writes enrollment and
    /// locator last. Reuses only a checkout matching enrollment. Once started,
    /// completion ignores caller cancellation; failures remain retryable. Preferences
    /// seed only an unstarted store, defaulting assistant runs and history discovery
    /// to off.
    public static func finish(
        containerRoot: URL,
        workspaceID: WorkspaceObjectID,
        homeURL: URL,
        deviceName: String? = nil,
        devicePreferences: DeviceWorkspacePreferences? = nil,
        runner: (any CommandRunning)? = nil,
        contentStore: CentralPackageContentStore? = nil,
        locator: WorkspaceLocator? = nil,
        contentStoreAt: (@Sendable (URL) throws -> CentralPackageContentStore?)? = nil,
        discardStaleCheckout: @escaping @Sendable (URL) throws -> Void = GitWorkspaceTransport.moveToTrash,
        progress: @escaping @Sendable (Step, StepState) -> Void = { _, _ in }
    ) async throws -> Result {
        let runner = runner ?? ProcessCommandRunner(timeout: .seconds(120), homeURL: homeURL)
        let finishing = Task {
            guard
                let recorded = try WorkspaceRevisionStore.recordedIdentity(containerRoot: containerRoot, workspaceID: workspaceID)
            else { throw WorkspaceJoinError.nothingToFinish }
            if let locator, let existing = try locator.read(),
                existing != WorkspaceLocator.Record(workspaceID: workspaceID, deviceID: recorded.deviceID)
            {
                throw WorkspaceJoinError.alreadyHasWorkspace
            }
            let store = try WorkspaceRevisionStore(
                containerRoot: containerRoot, workspaceID: workspaceID, deviceID: recorded.deviceID)
            let container = store.databaseURL.deletingLastPathComponent()
            guard let enrollment = try WorkspaceSyncEnrollmentStore(containerRoot: container).read(),
                enrollment.kind == .git, enrollment.workspaceID == workspaceID
            else { throw WorkspaceJoinError.nothingToFinish }

            progress(.reachingRepository, .started)
            let checkout = URL(fileURLWithPath: enrollment.checkoutPath, isDirectory: true)
            let transport = try await readingRemote {
                do {
                    return try await GitWorkspaceTransport.enroll(
                        remote: enrollment.remote, checkout: checkout, branch: enrollment.branch, runner: runner)
                } catch GitWorkspaceTransportError.checkoutHasAnotherRemote, GitWorkspaceTransportError.commandFailed {
                    try GitWorkspaceTransport.prepareFreshCheckout(at: checkout, discard: discardStaleCheckout)
                    return try await GitWorkspaceTransport.enroll(
                        remote: enrollment.remote, checkout: checkout, branch: enrollment.branch, runner: runner)
                }
            }
            progress(.reachingRepository, .finished)

            if try store.snapshot() == nil {
                // Created but never started: it starts from the remote with
                // the join's choices and nothing observed yet, which the next
                // check of this Mac fills in.
                progress(.readingLibrary, .started)
                let remoteState = try await readingRemote { try await transport.remoteState() }
                guard remoteState.head != nil else { throw try await missingBranch(enrollment.branch, on: transport) }
                guard let document = remoteState.document else { throw WorkspaceJoinError.remote(.notALibrary) }
                guard document.workspaceID == workspaceID else { throw WorkspaceJoinError.remote(.differentLibrary) }
                var device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: recorded.deviceID)
                device.applicationState?.preferences = devicePreferences ?? Self.seededPreferences
                try store.initializeFromRemote(document: document, device: device, ancestors: remoteState.ancestors)
                progress(.readingLibrary, .finished)
            }

            progress(.registering, .started)
            return try await readingRemote {
                try await complete(
                    store: store, transport: transport, enrollment: enrollment, writerID: WorkspaceObjectID(),
                    deviceName: deviceName, contentStore: contentStore, contentStoreAt: contentStoreAt,
                    afterStoreCreated: nil, locator: locator, progress: progress)
            }
        }
        return try await finishing.value
    }

    /// The choices a join from setup seeds (D16, D17), for a store `finish`
    /// starts without being given the join's own: the assistant's own runs
    /// off, and projects not found from Claude Code's history.
    static let seededPreferences = DeviceWorkspacePreferences(assistantRuns: .off, findsProjectsFromClaudeHistory: false)

    /// A joining Mac whose name another living Mac already uses gets a numbered
    /// one, so registration never fails on a name clash nobody chose.
    static func uniqueName(_ name: String, among devices: [DeviceRecord]) -> String {
        let taken = Set(devices.filter { !$0.isRetired }.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        for n in 2...99 where !taken.contains("\(name) \(n)".lowercased()) { return "\(name) \(n)" }
        return "\(name) \(UUID().uuidString.prefix(4))"
    }

    /// The name a Mac asks to be registered under: what was typed, without
    /// the spaces around it, or else this Mac's computer name.
    static func requestedName(_ typed: String?) -> String {
        let trimmed = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty else { return trimmed }
        let computer = (Host.current().localizedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return computer.isEmpty ? "Mac" : computer
    }
}

extension WorkspaceJoin {
    /// The store a join writes into. A store an interrupted join left for
    /// this library is this Mac's, under the device it was made for: it is
    /// reopened as that device, and started from the remote if it never was.
    /// One that was started records this join's read of the Mac in place of
    /// the earlier attempt's: the apps observed, what they can do, and
    /// `devicePreferences` when given. Otherwise a new one is created.
    private static func storeForJoin(
        document: PortableWorkspaceDocument, ancestors: [PortableWorkspaceDocument],
        device: DeviceWorkspaceState, devicePreferences: DeviceWorkspacePreferences?,
        containerRoot: URL, writerID: WorkspaceObjectID
    ) async throws -> WorkspaceRevisionStore {
        let workspaceID = document.workspaceID
        guard let recorded = try WorkspaceRevisionStore.recordedIdentity(containerRoot: containerRoot, workspaceID: workspaceID)
        else {
            let store = try WorkspaceRevisionStore(containerRoot: containerRoot, workspaceID: workspaceID, deviceID: device.deviceID)
            guard try store.snapshot() == nil else { throw WorkspaceRevisionStoreError.alreadyInitialized }
            try store.initializeFromRemote(document: document, device: device, ancestors: ancestors)
            return store
        }
        let store = try WorkspaceRevisionStore(containerRoot: containerRoot, workspaceID: workspaceID, deviceID: recorded.deviceID)
        guard let snapshot = try store.snapshot() else {
            var resumed = device
            resumed.deviceID = recorded.deviceID
            try store.initializeFromRemote(document: document, device: resumed, ancestors: ancestors)
            return store
        }
        try store.importRemoteRevisions(document, ancestors: ancestors)
        let observations = device.observations
        let evidence = device.capabilityEvidence
        _ = try await WorkspaceApplicationService(store: store, writerID: writerID).commitDeviceChange(
            expectedRevisionID: snapshot.document.revision.id
        ) { state in
            state.observations = observations
            state.capabilityEvidence = evidence
            if let devicePreferences { state.applicationState?.preferences = devicePreferences }
        }
        return store
    }

    /// Everything after the store exists, shared by a join and by `finish`:
    /// the enrollment beside the store, `afterStoreCreated`, this Mac's
    /// registration, the first sync, then the locator record, last. The
    /// enrollment comes first, so a store marked as an unfinished join always
    /// says which repository it was joining.
    private static func complete(
        store: WorkspaceRevisionStore,
        transport: GitWorkspaceTransport,
        enrollment: WorkspaceSyncEnrollment,
        writerID: WorkspaceObjectID,
        deviceName: String?,
        contentStore: CentralPackageContentStore?,
        contentStoreAt: (@Sendable (URL) throws -> CentralPackageContentStore?)?,
        afterStoreCreated: (@Sendable (URL) throws -> Void)?,
        locator: WorkspaceLocator?,
        progress: @Sendable (Step, StepState) -> Void
    ) async throws -> Result {
        let container = store.databaseURL.deletingLastPathComponent()
        try WorkspaceSyncEnrollmentStore(containerRoot: container).write(enrollment)
        try afterStoreCreated?(container)
        var content = contentStore
        if let contentStoreAt { content = (try? contentStoreAt(container)) ?? nil }

        // Registered under this Mac's name, then published, so the other Macs
        // see a named device rather than an anonymous writer.
        let service = WorkspaceApplicationService(store: store, writerID: writerID, contentStore: content)
        let registeredName = try await register(store: store, service: service, deviceName: deviceName)
        progress(.registering, .finished)

        progress(.sharing, .started)
        let coordinator = WorkspaceSyncCoordinator(store: store, transport: transport, writerID: writerID, contentStore: content)
        _ = try await coordinator.sync()
        let imported = await coordinator.lastContentReport.imported.count
        // The other living Macs' statuses. A retired Mac's last one stays in
        // the repository, and is not another Mac's news.
        let others = Set(
            (try store.snapshot()?.document.deviceRegistry ?? []).filter { !$0.isRetired && $0.id != store.deviceID }.map(\.id))
        let statuses = await coordinator.deviceStatuses.filter { others.contains($0.deviceID) }
        if let locator {
            try writeRecord(.init(workspaceID: store.workspaceID, deviceID: store.deviceID), with: locator)
        }
        progress(.sharing, .finished)
        return .init(
            store: store, enrollment: enrollment, deviceID: store.deviceID, registeredName: registeredName,
            importedContent: imported, deviceStatuses: statuses)
    }

    /// Registers this Mac under the name asked for, numbered when another
    /// living Mac uses it. A Mac the store already registers keeps its name.
    private static func register(
        store: WorkspaceRevisionStore, service: WorkspaceApplicationService, deviceName: String?
    ) async throws -> String {
        guard let snapshot = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
        let registry = snapshot.document.deviceRegistry
        if let registered = registry.first(where: { $0.id == store.deviceID }), !registered.isRetired {
            return registered.name
        }
        let name = uniqueName(requestedName(deviceName), among: registry.filter { $0.id != store.deviceID })
        _ = try await service.registerDevice(
            .init(expectedRevisionID: snapshot.document.revision.id, deviceID: store.deviceID, name: name))
        return name
    }

    /// Writes the locator record only where there is none, never over one
    /// that appeared meanwhile. A record already naming this very store is a
    /// join finished before, and is left as it is.
    private static func writeRecord(_ record: WorkspaceLocator.Record, with locator: WorkspaceLocator) throws {
        if let existing = try locator.read() {
            guard existing == record else { throw WorkspaceJoinError.alreadyHasWorkspace }
            return
        }
        let bytes: Data
        do { bytes = try AgentToolingCoding.encoder().encode(record) } catch { throw WorkspaceLocatorError.unreadable }
        do {
            try WorkspaceLocator.place(bytes, at: locator.recordURL)
        } catch WorkspaceLocatorError.alreadyExists {
            throw WorkspaceJoinError.alreadyHasWorkspace
        }
    }

    /// Why a branch with no head cannot be joined. When the repository has
    /// other branches, a typo in its name; when it has none at all, nothing
    /// was published there yet (the shipped `emptyRemote`).
    private static func missingBranch(_ branch: String, on transport: GitWorkspaceTransport) async throws -> WorkspaceJoinError {
        let host = await transport.originHost()
        let hasBranches = try await readingRemote { try await transport.listsAnyBranch(on: "origin", host: host) }
        return hasBranches ? .remote(.noSuchBranch(branch)) : .emptyRemote
    }

    /// Runs a step that reads the remote, with its failures in the join's own
    /// terms: what could not be read, and why.
    private static func readingRemote<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch GitWorkspaceTransportError.remote(let problem) {
            throw WorkspaceJoinError.remote(problem)
        } catch GitWorkspaceTransportError.invalidDocument, GitWorkspaceTransportError.documentTooLarge,
            GitWorkspaceTransportError.outputLimitExceeded
        {
            throw WorkspaceJoinError.remote(.unreadable)
        }
    }
}
