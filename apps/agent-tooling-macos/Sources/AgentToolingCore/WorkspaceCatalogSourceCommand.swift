import CryptoKit
import Foundation

/// Why a catalog could not be added to this workspace's list, or taken off it.
///
/// Every case carries the words a screen shows, because a refusal a person
/// cannot read is a disabled button with extra steps.
public enum WorkspaceCatalogSourceError: LocalizedError, Equatable, Sendable {
    /// Some catalog in the list already points where this one points, named.
    case alreadyRecorded(String)
    case identityCollision
    case missingSource
    case invalidLocation
    case invalidLocalFolder

    public var errorDescription: String? {
        switch self {
        case .alreadyRecorded(let name): "That catalog is already in your list, as \(name)."
        case .identityCollision: "That identity is already used in this workspace."
        case .missingSource: "That catalog is not one this workspace recorded, so there is nothing to remove."
        case .invalidLocation: "Enter a catalog address without a user name, password, query or fragment."
        case .invalidLocalFolder: "Choose a folder that exists on this Mac."
        }
    }
}

/// Whether the folder somebody chose is a folder this Mac can actually read.
///
/// Injected rather than called directly so that a test decides what exists: a
/// suite that asked the real filesystem would pass or fail on the machine it
/// happened to run on, and nothing about recording a catalog needs a real one.
public protocol CatalogSourceFolderProbing: Sendable {
    func isCatalogFolder(atPath path: String) -> Bool
}

/// This Mac, asked the same question `MarketplaceService.inspect` asks before
/// it reads a catalog folder: a directory, and not a symbolic link to one.
/// Recording a path that the reader will refuse would be a row that can only
/// ever report an error.
public struct LocalCatalogSourceFolders: CatalogSourceFolderProbing {
    public init() {}

    public func isCatalogFolder(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true
        else { return false }
        return FileManager.default.isReadableFile(atPath: path)
    }
}

/// Adds a catalog to the list this workspace records, or takes one off it.
///
/// A catalog source is two halves of one record. The portable half — its name,
/// its kind, and a credential-free address when it has one — travels between
/// Macs. This Mac's half holds where the folder actually is, because an
/// absolute path is a fact about one machine and the contract keeps those out
/// of portable bytes.
///
/// A record and its identity-map allocation move together, always: the document
/// refuses a source without an allocation and refuses an allocation whose
/// object is gone, so `WorkspaceCatalogSourceIdentity` is the only place either
/// is minted or withdrawn.
///
/// Removal writes **no tombstone**. A tombstone exists to stop something that
/// scans this Mac from silently resurrecting what a person deleted, and nothing
/// scans catalog sources: they are here because somebody typed one in, and
/// typing the same one in again is both intended and harmless. Deletion is
/// decided by ancestry in the merge instead, exactly as preset membership
/// already is.
///
/// Nothing here reads a catalog, fetches a package or installs anything. It
/// records where somebody said to look.
public struct WorkspaceCatalogSourceCommand: Sendable {
    public enum Change: Sendable, Equatable {
        case add(WorkspaceCatalogSourceRecord, localLocation: String?)
        case remove(WorkspaceObjectID)
    }

    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let change: Change

    /// What a person chose, refused here when this Mac cannot record it.
    ///
    /// Building the command is where an address or a folder is refused; applying
    /// it is where the list is. The record itself is kept exactly as it was
    /// handed over — a catalog source records what somebody chose and nothing
    /// more, so nothing here rewrites an address into a tidier one.
    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        adding source: WorkspaceCatalogSourceRecord,
        localLocation: String? = nil,
        folders: any CatalogSourceFolderProbing = LocalCatalogSourceFolders()
    ) throws {
        // A blank or control-laden name is the document's own rule rather than
        // this command's, so it is refused in the document's own words.
        try WorkspaceDomainValidation.requireText(source.name, field: "catalog source name", maximum: 4_096)
        if let remote = source.remoteLocation {
            guard Self.isRecordableAddress(remote) else { throw WorkspaceCatalogSourceError.invalidLocation }
        }
        if let localLocation {
            guard (try? WorkspaceDomainValidation.requireAbsolutePath(localLocation, field: "local catalog location")) != nil,
                folders.isCatalogFolder(atPath: localLocation)
            else { throw WorkspaceCatalogSourceError.invalidLocalFolder }
        }
        // A source that names nowhere lists nothing and can never be looked at.
        // Which refusal says so depends on where this build would have looked.
        if source.remoteLocation == nil, localLocation == nil {
            switch source.kind {
            case .localFolder, .gitRepository: throw WorkspaceCatalogSourceError.invalidLocalFolder
            default: throw WorkspaceCatalogSourceError.invalidLocation
            }
        }
        // A local-folder catalog is read from a folder on this Mac and from
        // nowhere else, so adding one without a folder here records a row this
        // Mac could never list anything from.
        if source.kind == .localFolder, localLocation == nil {
            throw WorkspaceCatalogSourceError.invalidLocalFolder
        }
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        change = .add(source, localLocation: localLocation)
    }

    /// Takes one recorded catalog off the list, with its allocation and this
    /// Mac's row for it. The five reference rows every build shows are not
    /// records, so this refuses them by name rather than pretending to remove
    /// something nobody added.
    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        removing sourceID: WorkspaceObjectID
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        change = .remove(sourceID)
    }

    /// The trust summary a catalog nobody has looked at yet deserves. The same
    /// words Discover falls back to, so adding a source does not put a verdict
    /// on a row before anything read it.
    static let unreviewed = "Not reviewed"

    func inputDigest() -> String {
        var fields = ["workspace.catalog-source.v1"]
        switch change {
        case .add(let source, let localLocation):
            fields += [
                "add", expectedRevisionID.rawValue.uuidString.lowercased(),
                idempotencyKey.rawValue.uuidString.lowercased(),
                source.id.rawValue.uuidString.lowercased(), source.name, source.kind.rawValue,
                source.remoteLocation ?? "", source.isOptionalBackup ? "1" : "0", localLocation ?? "",
            ]
        case .remove(let id):
            fields += [
                "remove", expectedRevisionID.rawValue.uuidString.lowercased(),
                idempotencyKey.rawValue.uuidString.lowercased(), id.rawValue.uuidString.lowercased(),
            ]
        }
        let framed = fields.map {
            let value = $0.precomposedStringWithCanonicalMapping
            return String(value.utf8.count) + ":" + value
        }.joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The portable half, and what this Mac's half needs to finish the same
    /// transaction without reading the document a second time.
    func apply(
        to document: inout PortableWorkspaceDocument, context: inout CatalogSourceCommandContext
    ) throws -> [ArtifactID] {
        var state = document.configurationState ?? .init()
        context.recordedNames = Dictionary(
            state.catalogSources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        switch change {
        case .add(let source, _):
            try requireUnusedIdentity(source.id, in: state, artifacts: document.artifacts)
            if let remote = source.remoteLocation, let key = Self.addressKey(remote),
                let existing = state.catalogSources.first(where: { $0.remoteLocation.flatMap(Self.addressKey) == key })
            {
                throw WorkspaceCatalogSourceError.alreadyRecorded(existing.name)
            }
            state.catalogSources.append(source)
            state.identityMap.append(WorkspaceCatalogSourceIdentity.entry(for: source.id))
        case .remove(let id):
            guard state.catalogSources.contains(where: { $0.id == id }) else {
                throw WorkspaceCatalogSourceError.missingSource
            }
            // Looked up by object rather than recomputed: a migrated source
            // keeps whatever identifier it was allocated under, and this Mac's
            // migration record is keyed by that identifier, not by the object.
            let allocation = WorkspaceCatalogSourceIdentity.entry(for: id, in: state)
            context.removedLegacyID = allocation.flatMap { UUID(uuidString: $0.legacy.identifier) }
            state.catalogSources.removeAll { $0.id == id }
            state.identityMap.removeAll { $0.legacy.domain == .catalogSource && $0.objectID == id }
        }
        document.configurationState = state
        // A catalog source is a workspace object, not an artifact. The receipt
        // must not name one that does not exist.
        return []
    }

    /// This Mac's half. A row is written only where there is something local to
    /// say: a remote catalog has no folder here, and an empty row would claim a
    /// verdict Discover already supplies when none was recorded.
    func bind(_ device: inout DeviceWorkspaceState, context: CatalogSourceCommandContext) throws {
        switch change {
        case .add(let source, let localLocation):
            guard let localLocation else { return }
            var state = device.configurationState ?? .init()
            if let existing = state.catalogSources.first(where: {
                $0.localLocation == localLocation && $0.catalogSourceID != source.id
            }) {
                throw WorkspaceCatalogSourceError.alreadyRecorded(
                    context.recordedNames[existing.catalogSourceID] ?? localLocation)
            }
            state.catalogSources.append(
                .init(catalogSourceID: source.id, localLocation: localLocation, trustSummary: Self.unreviewed))
            device.configurationState = state
        case .remove(let id):
            if var state = device.configurationState {
                state.catalogSources.removeAll { $0.catalogSourceID == id }
                device.configurationState = state
            }
            // The legacy migration record names the same source by the
            // identifier it was allocated under. Leaving it would leave this
            // Mac pointing at a catalog the document no longer has.
            if let legacyID = context.removedLegacyID, var application = device.applicationState {
                application.catalogSourceIDs.removeAll { $0 == legacyID }
                device.applicationState = application
            }
        }
    }

    /// Two addresses are the same catalog when they differ only in the parts a
    /// URL is allowed to differ in. The record itself keeps the person's own
    /// spelling; only the comparison is normalized.
    static func addressKey(_ value: String) -> String? {
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
            let host = parts.host?.lowercased(), !host.isEmpty
        else { return nil }
        var path = parts.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let port = parts.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(path)"
    }

    /// The document's own rule for a portable catalog address, asked before the
    /// document is asked, so a person reads this command's words rather than
    /// the validator's.
    private static func isRecordableAddress(_ value: String) -> Bool {
        guard value.count <= 4_096, let parts = URLComponents(string: value),
            let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
            parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil
        else { return false }
        return true
    }

    /// Every identity the document counts as taken. `validate` compares raw
    /// UUIDs across artifacts and workspace objects alike, so this does too.
    private func requireUnusedIdentity(
        _ id: WorkspaceObjectID, in state: WorkspaceConfigurationState, artifacts: [ArtifactRecord]
    ) throws {
        let taken =
            Set(state.catalogSources.map(\.id.rawValue))
            .union(state.configurations.map(\.id.rawValue))
            .union(state.managedPolicies.map(\.id.rawValue))
            .union(state.collections.map(\.id.rawValue))
            .union(state.identityMap.map(\.objectID.rawValue))
            .union(artifacts.map(\.identity.id.rawValue))
        guard !taken.contains(id.rawValue) else { throw WorkspaceCatalogSourceError.identityCollision }
    }
}

/// What the portable half of one catalog-source command decided, carried across
/// to this Mac's half inside the same transaction.
struct CatalogSourceCommandContext: Sendable {
    /// Every catalog recorded before this change, by object, so a duplicate
    /// folder can be refused by the name of the row that already holds it.
    var recordedNames: [WorkspaceObjectID: String] = [:]
    /// The identifier a removed source was allocated under, when it parses as a
    /// UUID. This Mac's legacy migration record is keyed by that.
    var removedLegacyID: UUID?
}
