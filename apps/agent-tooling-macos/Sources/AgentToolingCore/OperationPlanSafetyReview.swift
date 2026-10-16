import Foundation

/// What replacing an existing folder takes away: the entries at the destination
/// that the incoming package does not contain. The executor works it out just
/// before it replaces the folder, and only for the count in the receipt; no
/// plan review lists these entries before approval.
struct DirectoryReplacementDiff: Codable, Hashable, Sendable {
    /// Paths present at the destination that the incoming package does not
    /// contain. Directories carry a trailing slash.
    var removedPaths: [String] = []
    /// True when either tree was too large to compare completely, so the list
    /// is a partial answer rather than a complete one.
    var isTruncated = false
}

/// Whether Agent Tooling can prove it is entitled to replace a destination.
///
/// The engine already confines writes to known folders. That stops a plan from
/// writing somewhere unexpected; it does not stop a plan from overwriting
/// somebody else's files inside an expected folder. This is that second half.
enum DestinationOwnership: Codable, Hashable, Sendable {
    /// Agent Tooling's own managed library or local backup library.
    case managedRoot
    /// Nothing exists at the destination yet.
    case absent
    /// An empty directory. Replacing it destroys nothing.
    case empty
    /// This app installed here and still holds the record.
    case ledgerInstall(Date)
    /// This app installed here according to a stored plan and its receipt.
    case receiptInstall(Date)
    /// Explicit repository link recorded these exact installed bytes.
    case linkedInstallation
    /// Ownership could not be established. The reason is shown to the operator.
    case unprovable(String)

    var isProven: Bool {
        switch self {
        case .managedRoot, .absent, .empty, .ledgerInstall, .receiptInstall, .linkedInstallation: true
        case .unprovable: false
        }
    }

    var summary: String {
        switch self {
        case .managedRoot: "Agent Tooling's own managed library."
        case .absent: "Nothing exists here yet."
        case .empty: "The folder here is empty."
        case .ledgerInstall(let date):
            "Agent Tooling installed here on \(date.formatted(date: .abbreviated, time: .shortened))."
        case .receiptInstall(let date):
            "A stored receipt records that Agent Tooling installed here on \(date.formatted(date: .abbreviated, time: .shortened))."
        case .linkedInstallation: "The installed files match the version recorded for this repository link."
        case .unprovable(let reason): reason
        }
    }
}

/// Establishes ownership of one specific destination.
enum DestinationOwnershipInspector {
    static func ownership(
        of destination: URL,
        managedRoots: [URL],
        authority: ManagedInstallAuthority,
        expectedFingerprint: String? = nil,
        fileManager: FileManager = .default
    ) -> DestinationOwnership {
        let path = destination.path(percentEncoded: false)
        // A supplied baseline is mandatory even for an app-owned install: local
        // edits after linking must never be authorized by an older receipt.
        if let expectedFingerprint {
            guard expectedFingerprint.count == 64, expectedFingerprint.allSatisfy({ $0.isHexDigit }),
                let actual = try? DirectoryFingerprint.sha256(of: destination, fileManager: fileManager),
                actual == expectedFingerprint
            else {
                return .unprovable(
                    "The installed files changed since this repository was linked or updated. Review your local changes before updating.")
            }
            return .linkedInstallation
        }
        if managedRoots.contains(where: { ManagedInstallPath.sameLocation($0.path(percentEncoded: false), path) }) {
            return .managedRoot
        }
        guard fileManager.fileExists(atPath: ManagedInstallPath.normalized(path)) else { return .absent }
        let values = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            return .unprovable(
                "This location is a symbolic link, so the files that would be replaced are somewhere Agent Tooling never reviewed.")
        }
        guard values?.isDirectory == true else {
            return .unprovable("A file already exists here. Agent Tooling has no record of creating it and will not replace it.")
        }
        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: ManagedInstallPath.normalized(path))
        } catch {
            return .unprovable(
                "Agent Tooling could not list this folder to prove that it is empty. Nothing will be replaced until the folder can be inspected."
            )
        }
        if contents.isEmpty { return .empty }
        guard let proof = authority.proof(forDestination: path) else {
            return .unprovable(
                "This folder already contains files and Agent Tooling has no record of installing them. Move or delete them yourself, "
                    + "then run the install again.")
        }
        switch proof.source {
        case .ledger: return .ledgerInstall(proof.record.reviewedAt)
        case .receipt: return .receiptInstall(proof.record.reviewedAt)
        }
    }
}

/// Counts what a replacement takes away, for the receipt the executor writes
/// afterwards. Reading is all it does: nothing here writes, moves, or deletes
/// anything.
struct OperationPlanSafetyReviewer {
    private let fileManager: FileManager
    private let maximumComparedItems: Int

    init(
        fileManager: FileManager = .default,
        maximumComparedItems: Int = 10_000
    ) {
        self.fileManager = fileManager
        self.maximumComparedItems = maximumComparedItems
    }

    /// How many existing entries a replacement would take away, and whether the
    /// comparison was cut short at `maximumComparedItems`. Used for the short
    /// after-the-fact note in a receipt; nothing lists the entries by name
    /// before approval.
    ///
    /// The second half matters: a truncated comparison under-counts, so a
    /// receipt that printed the bare number would understate what it removed
    /// exactly when the folder was too big to check.
    func replacementRemovalCount(replacing destination: URL, with source: URL) -> (count: Int, isTruncated: Bool) {
        guard let diff = replacementDiff(replacing: destination, with: source) else { return (0, false) }
        return (diff.removedPaths.count, diff.isTruncated)
    }

    /// Diffs the folder that is about to be replaced against the folder that
    /// would replace it. Returns `nil` when nothing is being replaced.
    private func replacementDiff(replacing destination: URL, with source: URL) -> DirectoryReplacementDiff? {
        guard fileManager.fileExists(atPath: ManagedInstallPath.normalized(destination.path(percentEncoded: false))) else { return nil }
        let existing = Self.relativeEntries(of: destination, fileManager: fileManager, limit: maximumComparedItems)
        let incoming = Self.relativeEntries(of: source, fileManager: fileManager, limit: maximumComparedItems)
        guard let existing, let incoming else {
            return DirectoryReplacementDiff(isTruncated: true)
        }
        return DirectoryReplacementDiff(
            removedPaths: existing.entries.subtracting(incoming.entries).sorted(),
            isTruncated: existing.isTruncated || incoming.isTruncated
        )
    }

    private static func relativeEntries(
        of root: URL,
        fileManager: FileManager,
        limit: Int
    ) -> (entries: Set<String>, isTruncated: Bool)? {
        var encounteredEnumerationError = false
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in
                    encounteredEnumerationError = true
                    return true
                }
            )
        else { return nil }
        // Standardized like each item below, so a root spelled with `..` or a
        // leading `/private` still matches the items found under it.
        let normalizedRoot = root.standardizedFileURL
        var entries = Set<String>()
        var isTruncated = false
        while let item = enumerator.nextObject() as? URL {
            guard entries.count < limit else {
                isTruncated = true
                break
            }
            guard let relative = PathContainment.relativePath(of: item, under: normalizedRoot) else { continue }
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                isTruncated = true
                continue
            }
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
            entries.insert(isDirectory ? relative + "/" : relative)
        }
        return (entries, isTruncated || encounteredEnumerationError)
    }
}
