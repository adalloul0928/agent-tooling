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

    /// A missing or unreadable ledger is treated as an empty one. Failing to
    /// read it must never be mistaken for proof that a destination is owned.
    public static func load(from store: WorkspaceStore) -> ManagedInstallLedger {
        ((try? store.load(storageKey, as: ManagedInstallLedger.self)) ?? nil) ?? ManagedInstallLedger()
    }

    public func save(to store: WorkspaceStore) throws {
        try store.save(self, for: Self.storageKey)
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

    public static func fromStore(_ store: WorkspaceStore) -> ManagedInstallAuthority {
        ManagedInstallAuthority(ledger: .load(from: store), receiptRecords: recordedInstalls(in: store))
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

    /// Rebuilds install records from approved plans whose matching receipt says
    /// the copy step actually succeeded. A plan alone proves nothing, and a
    /// receipt alone does not name a destination, so both halves are required —
    /// and they have to be halves of the same operation.
    static func recordedInstalls(in store: WorkspaceStore) -> [ManagedInstallRecord] {
        let plans = (try? store.listEntities(domain: .plans, as: OperationPlan.self)) ?? []
        let receipts = (try? store.listEntities(domain: .receipts, as: OperationReceipt.self)) ?? []
        var succeededAt: [PlanStepIdentity: Date] = [:]
        for receipt in receipts {
            for result in receipt.results where result.status == .succeeded {
                succeededAt[PlanStepIdentity(planID: receipt.planID, stepID: result.stepID)] = result.finishedAt
            }
        }
        var records: [ManagedInstallRecord] = []
        for plan in plans {
            for step in plan.steps where step.kind == .copyDirectory {
                guard let destinationPath = step.destinationPath,
                    let sourcePath = step.sourcePath,
                    let fingerprint = step.sourceFingerprint,
                    let finishedAt = succeededAt[PlanStepIdentity(planID: plan.id, stepID: step.id)]
                else { continue }
                records.append(
                    ManagedInstallRecord(
                        destinationPath: destinationPath,
                        sourcePath: sourcePath,
                        reviewedFingerprint: fingerprint,
                        reviewedAt: finishedAt,
                        planStepID: step.id
                    ))
            }
        }
        return records.sorted { $0.reviewedAt > $1.reviewedAt }
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
        store: WorkspaceStore,
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
