import Darwin
import Foundation

public enum WorkspaceMigrationReviewError: Error, Equatable, LocalizedError, Sendable {
    case invalidLocation
    case locationTooLarge
    case unsupportedVersion
    case nonCanonicalLocation
    case missingAttempt
    case wrongBinding

    public var errorDescription: String? {
        switch self {
        case .invalidLocation: "The migration review location is invalid."
        case .locationTooLarge: "The migration review location exceeds its supported size."
        case .unsupportedVersion: "This migration review location requires a different app version."
        case .nonCanonicalLocation: "The migration review location contains unsupported or noncanonical data."
        case .missingAttempt: "The reviewed migration attempt is unavailable."
        case .wrongBinding: "The reviewed migration does not match this workspace location."
        }
    }
}

/// Explicit locations supplied by a trusted local caller. This value never
/// discovers a default root and decoding it does not open or initialize stores.
public struct WorkspaceMigrationReviewLocation: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 16 * 1_024

    public let legacyRoot: URL
    public let containerRoot: URL
    public let checkpointRoot: URL
    public let contentRoot: URL
    public let workspaceID: WorkspaceObjectID
    public let deviceID: WorkspaceObjectID
    public let attemptID: WorkspaceObjectID

    public init(
        legacyRoot: URL,
        containerRoot: URL,
        checkpointRoot: URL,
        contentRoot: URL,
        workspaceID: WorkspaceObjectID,
        deviceID: WorkspaceObjectID,
        attemptID: WorkspaceObjectID
    ) {
        self.legacyRoot = legacyRoot
        self.containerRoot = containerRoot
        self.checkpointRoot = checkpointRoot
        self.contentRoot = contentRoot
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.attemptID = attemptID
    }

    public func validate() throws {
        try Self.validatePath(legacyRoot)
        try Self.validatePath(containerRoot)
        try Self.validatePath(checkpointRoot)
        try Self.validatePath(contentRoot)
        guard Set([workspaceID, deviceID, attemptID]).count == 3 else {
            throw WorkspaceMigrationReviewError.invalidLocation
        }
    }

    public func encode() throws -> Data {
        try validate()
        let data = try Self.encoder().encode(Envelope(schemaVersion: 1, location: self))
        guard data.count <= Self.maximumEncodedBytes else {
            throw WorkspaceMigrationReviewError.locationTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw WorkspaceMigrationReviewError.locationTooLarge }
        let envelope: Envelope
        do { envelope = try decoder().decode(Envelope.self, from: data) }
        catch { throw WorkspaceMigrationReviewError.nonCanonicalLocation }
        guard envelope.schemaVersion == 1 else { throw WorkspaceMigrationReviewError.unsupportedVersion }
        try envelope.location.validate()
        guard try envelope.location.encode() == data else {
            throw WorkspaceMigrationReviewError.nonCanonicalLocation
        }
        return envelope.location
    }

    private static func validatePath(_ url: URL) throws {
        let path = url.path
        guard url.isFileURL, url.host == nil || url.host?.isEmpty == true,
              path.hasPrefix("/"), path != "/", path.utf8.count <= 4_096,
              path.precomposedStringWithCanonicalMapping == path,
              URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw WorkspaceMigrationReviewError.invalidLocation
        }
    }

    private struct Envelope: Codable {
        let schemaVersion: UInt
        let location: WorkspaceMigrationReviewLocation
    }

    private static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return value
    }

    private static func decoder() -> JSONDecoder { JSONDecoder() }
}

public struct WorkspaceMigrationReviewSummary: Equatable, Sendable {
    public let centralPersonalCount: Int
    public let centralUpstreamCount: Int
    public let nativeOwnedCount: Int
    public let attachedAuthoringCount: Int
    public let trackedOnlyCount: Int
    public let assignmentCount: Int
    public let wholePluginChildCount: Int

    public init(
        centralPersonalCount: Int,
        centralUpstreamCount: Int,
        nativeOwnedCount: Int,
        attachedAuthoringCount: Int,
        trackedOnlyCount: Int,
        assignmentCount: Int,
        wholePluginChildCount: Int
    ) {
        self.centralPersonalCount = centralPersonalCount
        self.centralUpstreamCount = centralUpstreamCount
        self.nativeOwnedCount = nativeOwnedCount
        self.attachedAuthoringCount = attachedAuthoringCount
        self.trackedOnlyCount = trackedOnlyCount
        self.assignmentCount = assignmentCount
        self.wholePluginChildCount = wholePluginChildCount
    }
}

public struct WorkspaceMigrationReviewState: Equatable, Sendable {
    public let journalEntry: WorkspaceMigrationJournalEntry
    public let currentRevisionID: WorkspaceObjectID?
    public let authoritySelection: WorkspaceAuthoritySelection?
    public let reviewedSummary: WorkspaceMigrationReviewSummary
    public let reviewedLibrary: WorkspaceLibraryReadModel

    public init(
        journalEntry: WorkspaceMigrationJournalEntry,
        currentRevisionID: WorkspaceObjectID?,
        authoritySelection: WorkspaceAuthoritySelection?,
        reviewedSummary: WorkspaceMigrationReviewSummary
    ) throws {
        self.journalEntry = journalEntry
        self.currentRevisionID = currentRevisionID
        self.authoritySelection = authoritySelection
        self.reviewedSummary = reviewedSummary
        self.reviewedLibrary = try WorkspaceLibraryReadModel(snapshot: .init(
            document: journalEntry.record.document, device: journalEntry.record.device))
    }
}

public protocol WorkspaceMigrationReviewServing: Sendable {
    func state() async throws -> WorkspaceMigrationReviewState
    func initializeReviewed(record: WorkspaceMigrationRecord) async throws -> WorkspaceMigrationJournalEntry
    func prepareActivation() async throws -> WorkspaceAuthoritySelection
    func prepareRollback() async throws -> WorkspaceAuthoritySelection
    func apply(selection: WorkspaceAuthoritySelection) async throws -> WorkspaceAuthoritySelection
}

/// Trusted local review and authority actions over one explicitly supplied
/// migration location. This service is not exposed through the MCP operator.
public actor WorkspaceMigrationReviewService: WorkspaceMigrationReviewServing {
    public let location: WorkspaceMigrationReviewLocation

    public init(location: WorkspaceMigrationReviewLocation) throws {
        try location.validate()
        self.location = location
    }

    public func state() async throws -> WorkspaceMigrationReviewState {
        let store = try readOnlyStore()
        guard let entry = try store.migration(location.attemptID) else {
            throw WorkspaceMigrationReviewError.missingAttempt
        }
        try validate(entry)
        let snapshot = try store.snapshot()
        if entry.phase == .initialized, snapshot == nil {
            throw WorkspaceMigrationReviewError.wrongBinding
        }
        if entry.phase == .prepared, snapshot != nil {
            throw WorkspaceMigrationReviewError.wrongBinding
        }
        let authority = try WorkspaceAuthorityStore.readIfPresent(legacyRoot: location.legacyRoot)
        if let authority { try validate(authority) }
        return try WorkspaceMigrationReviewState(
            journalEntry: entry,
            currentRevisionID: snapshot?.document.revision.id,
            authoritySelection: authority,
            reviewedSummary: summary(entry.record.document)
        )
    }

    public func initializeReviewed(record: WorkspaceMigrationRecord) async throws -> WorkspaceMigrationJournalEntry {
        try Task.checkCancellation()
        let current = try await state()
        guard (current.journalEntry.phase == .prepared || current.journalEntry.phase == .initialized),
              current.authoritySelection == nil,
              current.journalEntry.record == record else {
            throw WorkspaceMigrationReviewError.wrongBinding
        }
        try validate(record: record)
        let service = try migrationService()
        let result = try await service.initialize(attemptID: location.attemptID, inputDigest: record.inputDigest)
        try validate(result)
        return result
    }

    public func prepareActivation() async throws -> WorkspaceAuthoritySelection {
        try Task.checkCancellation()
        let current = try await state()
        guard current.journalEntry.phase == .initialized, current.authoritySelection == nil else {
            throw WorkspaceMigrationReviewError.wrongBinding
        }
        let selection = try await authorityService().prepareActivation(attemptID: location.attemptID)
        try validate(selection)
        return selection
    }

    public func prepareRollback() async throws -> WorkspaceAuthoritySelection {
        try Task.checkCancellation()
        let current = try await state()
        guard current.journalEntry.phase == .initialized,
              current.authoritySelection?.choice == .versioned else {
            throw WorkspaceMigrationReviewError.wrongBinding
        }
        let selection = try await authorityService().prepareRollback()
        try validate(selection)
        return selection
    }

    public func apply(selection: WorkspaceAuthoritySelection) async throws -> WorkspaceAuthoritySelection {
        try Task.checkCancellation()
        _ = try await state()
        try validate(selection)
        let result = try await authorityService().apply(selection)
        try validate(result)
        return result
    }

    private func readOnlyStore() throws -> WorkspaceRevisionStore {
        try WorkspaceRevisionStore(
            containerRoot: location.containerRoot,
            workspaceID: location.workspaceID,
            deviceID: location.deviceID,
            access: .existingReadOnly
        )
    }

    private func writableStore() throws -> WorkspaceRevisionStore {
        try WorkspaceRevisionStore(
            containerRoot: location.containerRoot,
            workspaceID: location.workspaceID,
            deviceID: location.deviceID,
            access: .existingReadWrite
        )
    }

    private func migrationService() throws -> WorkspaceMigrationService {
        try WorkspaceMigrationService(
            store: writableStore(),
            checkpoints: WorkspaceLegacyCheckpointStore(directory: location.checkpointRoot, initializeIfEmpty: false),
            content: CentralPackageContentStore(directory: location.contentRoot, initializeIfEmpty: false)
        )
    }

    private func authorityService() throws -> WorkspaceAuthorityService {
        try WorkspaceAuthorityService(
            legacyRoot: location.legacyRoot,
            store: writableStore(),
            checkpoints: WorkspaceLegacyCheckpointStore(directory: location.checkpointRoot, initializeIfEmpty: false),
            content: CentralPackageContentStore(directory: location.contentRoot, initializeIfEmpty: false)
        )
    }

    private func validate(record: WorkspaceMigrationRecord) throws {
        try record.validate()
        guard record.manifest.attemptID == location.attemptID,
              record.manifest.workspaceID == location.workspaceID,
              record.manifest.deviceID == location.deviceID,
              Self.sameExistingPath(URL(fileURLWithPath: record.manifest.legacyDatabasePath), legacyDatabaseURL) else {
            throw WorkspaceMigrationReviewError.wrongBinding
        }
    }

    private func validate(_ entry: WorkspaceMigrationJournalEntry) throws {
        try validate(record: entry.record)
    }

    private func validate(_ selection: WorkspaceAuthoritySelection) throws {
        guard selection.target.workspaceID == location.workspaceID,
              selection.target.deviceID == location.deviceID,
              selection.target.attemptID == location.attemptID,
              Self.sameExistingPath(URL(fileURLWithPath: selection.target.containerRootPath), location.containerRoot) else {
            throw WorkspaceMigrationReviewError.wrongBinding
        }
    }

    private var legacyDatabaseURL: URL { location.legacyRoot.appending(path: "agent-tooling.sqlite") }

    private func summary(_ document: PortableWorkspaceDocument) -> WorkspaceMigrationReviewSummary {
        var personal = 0, upstream = 0, native = 0, attached = 0, tracked = 0
        for artifact in document.artifacts {
            guard artifact.identity.parentPackageID == nil,
                  Self.isLibraryArtifact(artifact.identity.kind) else { continue }
            switch artifact.authority {
            case .centralPersonal: personal += 1
            case .centralUpstream: upstream += 1
            case .nativeOwned: native += 1
            case .attachedAuthoring: attached += 1
            case .trackedOnly: tracked += 1
            }
        }
        return WorkspaceMigrationReviewSummary(
            centralPersonalCount: personal,
            centralUpstreamCount: upstream,
            nativeOwnedCount: native,
            attachedAuthoringCount: attached,
            trackedOnlyCount: tracked,
            assignmentCount: document.assignments.count,
            wholePluginChildCount: document.artifacts.count {
                $0.identity.parentPackageID != nil && Self.isLibraryArtifact($0.identity.kind)
            }
        )
    }

    private static func isLibraryArtifact(_ kind: ArtifactKind) -> Bool {
        switch kind {
        case .package, .skill, .mcpServer, .nativePlugin: true
        case .preset, .logicalProject: false
        }
    }

    private static func sameExistingPath(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.isFileURL, rhs.isFileURL, let left = realpath(lhs.path, nil) else { return false }
        defer { free(left) }
        guard let right = realpath(rhs.path, nil) else { return false }
        defer { free(right) }
        return strcmp(left, right) == 0
    }
}
