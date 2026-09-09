import Foundation

/// What Agent Tooling knows about one destination it has installed into: where
/// the content came from, and the fingerprint of the tree the operator actually
/// reviewed at the time.
public struct ManagedInstallRecord: Identifiable, Codable, Hashable, Sendable {
    public var destinationPath: String
    public var sourcePath: String
    /// SHA-256 of the reviewed source tree, carried from the approved plan.
    public var reviewedFingerprint: String
    public var reviewedAt: Date
    public var planStepID: UUID?

    public init(
        destinationPath: String,
        sourcePath: String,
        reviewedFingerprint: String,
        reviewedAt: Date,
        planStepID: UUID? = nil
    ) {
        self.destinationPath = destinationPath
        self.sourcePath = sourcePath
        self.reviewedFingerprint = reviewedFingerprint
        self.reviewedAt = reviewedAt
        self.planStepID = planStepID
    }

    public var id: String { ManagedInstallPath.normalized(destinationPath) }

    public var packageName: String { URL(fileURLWithPath: destinationPath).lastPathComponent }
}

/// Path comparison shared by every ownership and drift check. Symbolic links
/// are compared as well as literal paths so `/var` and `/private/var` cannot be
/// used to make a known destination look unknown.
enum ManagedInstallPath {
    static func normalized(_ path: String) -> String {
        let value = URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
        guard value.count > 1, value.hasSuffix("/") else { return value }
        return String(value.dropLast())
    }

    static func resolved(_ path: String) -> String {
        normalized(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false))
    }

    static func sameLocation(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs) || resolved(lhs) == resolved(rhs)
    }
}

/// The app's own record of what it installed and where. Ownership proof and
/// drift detection both read from here.
public struct ManagedInstallLedger: Codable, Hashable, Sendable {
    public static let storageKey = "managed-install-ledger"
    public static let maximumRecords = 512

    public var records: [ManagedInstallRecord]

    public init(records: [ManagedInstallRecord] = []) {
        self.records = records
    }

    public func record(forDestination path: String) -> ManagedInstallRecord? {
        records.first { ManagedInstallPath.sameLocation($0.destinationPath, path) }
    }

    public mutating func upsert(_ record: ManagedInstallRecord) {
        records.removeAll { ManagedInstallPath.sameLocation($0.destinationPath, record.destinationPath) }
        records.insert(record, at: 0)
        if records.count > Self.maximumRecords { records = Array(records.prefix(Self.maximumRecords)) }
    }

    /// Forgets one destination, for a removal this app performed itself.
    public mutating func remove(destinationPath: String) {
        records.removeAll { ManagedInstallPath.sameLocation($0.destinationPath, destinationPath) }
    }

    public static func load(from store: WorkspaceRevisionStore) -> ManagedInstallLedger {
        (try? store.managedInstallLedger()) ?? ManagedInstallLedger()
    }

    public func save(to store: WorkspaceRevisionStore) throws {
        try store.saveManagedInstallLedger(self)
    }

}

/// Where a proof of ownership came from. Both sources are equally strong; they
/// differ only in whether the ledger has caught up with stored receipts.
public enum ManagedInstallProofSource: String, Codable, Hashable, Sendable {
    case ledger
    case receipt
}

public struct ManagedInstallProof: Hashable, Sendable {
    public var record: ManagedInstallRecord
    public var source: ManagedInstallProofSource

    public init(record: ManagedInstallRecord, source: ManagedInstallProofSource) {
        self.record = record
        self.source = source
    }
}

/// Answers "did this app put that there?" from the ledger first and from
/// stored plan/receipt pairs second, so installs made before the ledger existed
/// still carry proof.
public struct ManagedInstallAuthority: Sendable {
    public let ledger: ManagedInstallLedger
    public let receiptRecords: [ManagedInstallRecord]

    public init(ledger: ManagedInstallLedger = ManagedInstallLedger(), receiptRecords: [ManagedInstallRecord] = []) {
        self.ledger = ledger
        self.receiptRecords = receiptRecords
    }

    /// Ownership proof read from the versioned store.
    ///
    /// The ledger alone, and deliberately. The executor writes a ledger entry
    /// every time it installs something, so in a workspace that started empty
    /// the ledger is the complete record. Rebuilding records from approved plans
    /// and their receipts exists for installs that predate the ledger, and a
    /// versioned workspace has none — offering that path here would be
    /// reconstructing evidence for events that cannot exist.
    public static func fromStore(_ store: WorkspaceRevisionStore) -> ManagedInstallAuthority {
        .init(ledger: ManagedInstallLedger.load(from: store))
    }

    public func proof(forDestination path: String) -> ManagedInstallProof? {
        if let record = ledger.record(forDestination: path) {
            return ManagedInstallProof(record: record, source: .ledger)
        }
        guard let record = receiptRecords.first(where: { ManagedInstallPath.sameLocation($0.destinationPath, path) }) else { return nil }
        return ManagedInstallProof(record: record, source: .receipt)
    }

    /// Every destination this app can still prove it installed, newest first.
    public var provenInstalls: [ManagedInstallRecord] {
        var seen = Set<String>()
        var result: [ManagedInstallRecord] = []
        for record in (ledger.records + receiptRecords).sorted(by: { $0.reviewedAt > $1.reviewedAt }) {
            guard seen.insert(record.id).inserted else { continue }
            result.append(record)
        }
        return result
    }

    /// Identifies a step by the plan it belongs to as well as by itself. Step
    /// identifiers are decoded from plan files, so they are attacker-chosen;
    /// pairing on the identifier alone would let a receipt for one plan vouch
    /// for a step in another that simply reused it.
    private struct PlanStepIdentity: Hashable {
        var planID: UUID
        var stepID: UUID
    }

}

/// Honest states for an installed copy, compared against the tree the operator
/// reviewed. Drift is information, not an accusation.
public enum InstalledPackageDriftState: String, Codable, Hashable, CaseIterable, Sendable {
    case matchesReview
    case modifiedSinceReview
    case removed
    case unreadable
}

public struct InstalledPackageDrift: Identifiable, Codable, Hashable, Sendable {
    public var destinationPath: String
    public var packageName: String
    public var state: InstalledPackageDriftState
    public var reviewedFingerprint: String
    public var currentFingerprint: String?
    public var reviewedAt: Date

    public init(
        destinationPath: String,
        packageName: String,
        state: InstalledPackageDriftState,
        reviewedFingerprint: String,
        currentFingerprint: String? = nil,
        reviewedAt: Date
    ) {
        self.destinationPath = destinationPath
        self.packageName = packageName
        self.state = state
        self.reviewedFingerprint = reviewedFingerprint
        self.currentFingerprint = currentFingerprint
        self.reviewedAt = reviewedAt
    }

    public var id: String { ManagedInstallPath.normalized(destinationPath) }

    public var hasDrifted: Bool { state == .modifiedSinceReview }

    public var headline: String {
        switch state {
        case .matchesReview: "Installed and unchanged since you reviewed it."
        case .modifiedSinceReview: "Installed but modified since you reviewed it."
        case .removed: "No longer present at the location Agent Tooling installed."
        case .unreadable: "Installed, but Agent Tooling could not read it to compare."
        }
    }

    public var explanation: String {
        switch state {
        case .matchesReview:
            "The files on disk still match the fingerprint recorded when you approved the install."
        case .modifiedSinceReview:
            "Editing an installed skill in place is normal. Re-install it from the library whenever you want Agent Tooling's "
                + "record to match the files again."
        case .removed:
            "Something outside Agent Tooling removed or moved it. Install it again if you still want it here."
        case .unreadable:
            "The contents could not be read, so no comparison was possible. Nothing was changed."
        }
    }
}

/// Compares each proven install against its recorded review fingerprint.
enum InstalledPackageDriftInspector {
    static func inspect(
        _ authority: ManagedInstallAuthority,
        fileManager: FileManager = .default,
        maximumRecords: Int = ManagedInstallLedger.maximumRecords,
        clients: Set<ClientKind> = Set(ClientKind.allCases)
    ) -> [InstalledPackageDrift] {
        authority.provenInstalls.filter { ClientSelection.includes(path: $0.destinationPath, clients: clients) }.prefix(maximumRecords).map
        { record in
            drift(for: record, fileManager: fileManager)
        }
    }

    /// Reads the recorded installs and re-hashes each installed tree away from
    /// the caller's actor. Comparing many packages is file-system work, and the
    /// setup check should not make the window wait on it.
    static func inspect(
        store: WorkspaceRevisionStore,
        maximumRecords: Int = ManagedInstallLedger.maximumRecords,
        clients: Set<ClientKind> = Set(ClientKind.allCases)
    ) async -> [InstalledPackageDrift] {
        await Task.detached { inspect(.fromStore(store), maximumRecords: maximumRecords, clients: clients) }.value
    }

    static func drift(for record: ManagedInstallRecord, fileManager: FileManager = .default) -> InstalledPackageDrift {
        let destination = URL(fileURLWithPath: record.destinationPath).standardizedFileURL
        guard fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
            return InstalledPackageDrift(
                destinationPath: record.destinationPath,
                packageName: record.packageName,
                state: .removed,
                reviewedFingerprint: record.reviewedFingerprint,
                reviewedAt: record.reviewedAt
            )
        }
        guard let current = try? DirectoryFingerprint.sha256(of: destination, fileManager: fileManager) else {
            return InstalledPackageDrift(
                destinationPath: record.destinationPath,
                packageName: record.packageName,
                state: .unreadable,
                reviewedFingerprint: record.reviewedFingerprint,
                reviewedAt: record.reviewedAt
            )
        }
        return InstalledPackageDrift(
            destinationPath: record.destinationPath,
            packageName: record.packageName,
            state: current == record.reviewedFingerprint ? .matchesReview : .modifiedSinceReview,
            reviewedFingerprint: record.reviewedFingerprint,
            currentFingerprint: current,
            reviewedAt: record.reviewedAt
        )
    }

    /// One calm sentence for the setup check. Drift is reported as a fact.
    ///
    /// A package the app cannot read is reported too. Staying silent about it
    /// would be the most useful outcome for anyone tampering with an installed
    /// copy: a single symlink inside the folder makes the fingerprint
    /// unreadable, and "no news" would then read as "unchanged".
    static func summary(for reports: [InstalledPackageDrift]) -> String? {
        let drifted = reports.filter(\.hasDrifted)
        let removed = reports.filter { $0.state == .removed }
        let unreadable = reports.filter { $0.state == .unreadable }
        var parts: [String] = []
        if !drifted.isEmpty {
            let names = drifted.map(\.packageName).sorted().joined(separator: ", ")
            parts.append(
                "\(drifted.count) installed package\(drifted.count == 1 ? " is" : "s are") modified since you reviewed \(drifted.count == 1 ? "it" : "them"): \(names)."
            )
        }
        if !removed.isEmpty {
            let names = removed.map(\.packageName).sorted().joined(separator: ", ")
            parts.append(
                "\(removed.count) previously installed package\(removed.count == 1 ? " is" : "s are") no longer present: \(names).")
        }
        if !unreadable.isEmpty {
            let names = unreadable.map(\.packageName).sorted().joined(separator: ", ")
            parts.append(
                "\(unreadable.count) installed package\(unreadable.count == 1 ? "" : "s") could not be read to compare against \(unreadable.count == 1 ? "its" : "their") review: \(names)."
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The managed locations an operation writes into, and where its receipt goes.
///
/// A seam rather than a concrete store, so the executor's containment rules —
/// which are the thing that stops a deployment writing outside this app's own
/// folders — are written once against a shape, not twice against two stores.
public protocol ManagedOperationStore: Sendable {
    /// This app's own record of what it installed and where.
    func managedInstallLedger() throws -> ManagedInstallLedger
    func saveManagedInstallLedger(_ ledger: ManagedInstallLedger) throws
    /// Ownership proof, however this store establishes it.
    func installAuthority() -> ManagedInstallAuthority

    /// The root every managed destination must stay inside.
    var rootURL: URL { get }
    /// Where this app keeps content it owns. The executor refuses to copy from
    /// anywhere else.
    var libraryURL: URL { get }
    /// Where receipts and their rollback material live.
    var receiptsURL: URL { get }
    func recordOperationReceipt(_ receipt: OperationReceipt) throws
}

extension WorkspaceRevisionStore: ManagedOperationStore {
    public var rootURL: URL { managedRootURL }
    public func installAuthority() -> ManagedInstallAuthority { .fromStore(self) }
}

/// Which client a destination folder belongs to, read from the path itself.
///
/// Path-shaped rather than recorded, because a folder this app installed into
/// carries the client's own directory name and nothing else identifies it. A
/// path under none of them is not attributed to one: `nil` means unknown, and
/// callers treat unknown as "include", never as a guess.
enum ClientSelection {
    static func includes(path: String, clients: Set<ClientKind>) -> Bool {
        client(for: path).map(clients.contains) ?? true
    }

    static func client(for path: String) -> ClientKind? {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if parts.contains(".claude") { return .claude }
        if parts.contains(".codex") || parts.contains(".agents") { return .codex }
        if parts.contains(".gemini") { return .gemini }
        return nil
    }
}

/// One file inside an archive the executor restores a managed library from.
///
/// Kept beside the executor rather than beside a transport, because what the
/// executor guarantees about it — that every path stays inside the library and
/// that a missing execute bit restores as non-executable — is a property of
/// restoring, not of however the archive arrived.
struct EncryptedLibraryFile: Codable, Hashable, Sendable {
    var relativePath: String
    var data: Data
    /// Optional for archives written before execution metadata was retained. A
    /// missing value restores conservatively as a non-executable file, because
    /// guessing the other way makes something runnable that may not have been.
    var isExecutable: Bool?

    init(relativePath: String, data: Data, isExecutable: Bool? = nil) {
        self.relativePath = relativePath
        self.data = data
        self.isExecutable = isExecutable
    }
}
