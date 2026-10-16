import Foundation

/// What replacing an existing folder would add and take away. Computed while a
/// plan is still being reviewed, because a person cannot consent to a deletion
/// they were only told about afterwards.
public struct DirectoryReplacementDiff: Codable, Hashable, Sendable {
    /// Paths present at the destination that the incoming package does not
    /// contain. Directories carry a trailing slash.
    public var removedPaths: [String]
    public var addedPaths: [String]
    public var keptCount: Int
    /// True when either tree was too large to compare completely, so the lists
    /// are a partial answer rather than a complete one.
    public var isTruncated: Bool

    public init(removedPaths: [String] = [], addedPaths: [String] = [], keptCount: Int = 0, isTruncated: Bool = false) {
        self.removedPaths = removedPaths
        self.addedPaths = addedPaths
        self.keptCount = keptCount
        self.isTruncated = isTruncated
    }

    public var removesContent: Bool { !removedPaths.isEmpty }

    public var removedFileCount: Int { removedPaths.count { !$0.hasSuffix("/") } }

    public var removedDirectoryCount: Int { removedPaths.count { $0.hasSuffix("/") } }

    /// The sentence the plan states before approval, for example
    /// "This update removes 3 files."
    public var removalHeadline: String? {
        guard removesContent else { return nil }
        let files = removedFileCount
        let directories = removedDirectoryCount
        var phrase = ""
        if files > 0 { phrase = "\(files) file\(files == 1 ? "" : "s")" }
        if directories > 0 {
            let folders = "\(directories) folder\(directories == 1 ? "" : "s")"
            phrase = phrase.isEmpty ? folders : "\(phrase) and \(folders)"
        }
        return "This update removes \(phrase)."
    }
}

/// Whether Agent Tooling can prove it is entitled to replace a destination.
///
/// The engine already confines writes to known folders. That stops a plan from
/// writing somewhere unexpected; it does not stop a plan from overwriting
/// somebody else's files inside an expected folder. This is that second half.
public enum DestinationOwnership: Codable, Hashable, Sendable {
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

    public var isProven: Bool {
        switch self {
        case .managedRoot, .absent, .empty, .ledgerInstall, .receiptInstall, .linkedInstallation: true
        case .unprovable: false
        }
    }

    public var summary: String {
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

/// Everything a person needs to know about one step before approving it.
public struct OperationStepSafetyReview: Identifiable, Codable, Hashable, Sendable {
    public var stepID: UUID
    public var stepTitle: String
    public var ownership: DestinationOwnership
    public var replacement: DirectoryReplacementDiff?
    public var contentRisk: ContentRiskReport?

    public init(
        stepID: UUID,
        stepTitle: String,
        ownership: DestinationOwnership,
        replacement: DirectoryReplacementDiff? = nil,
        contentRisk: ContentRiskReport? = nil
    ) {
        self.stepID = stepID
        self.stepTitle = stepTitle
        self.ownership = ownership
        self.replacement = replacement
        self.contentRisk = contentRisk
    }

    public var id: UUID { stepID }

    public var isBlocked: Bool {
        !ownership.isProven || replacement?.isTruncated == true || contentRisk?.isComplete == false
    }

    public var blockReason: String? {
        if !ownership.isProven { return ownership.summary }
        if replacement?.isTruncated == true {
            return
                "The existing and incoming folders could not be compared completely. Agent Tooling will not replace content until every removal can be shown for review."
        }
        if contentRisk?.isComplete == false {
            return
                "The package content scan was incomplete. Agent Tooling will not install files it could not inspect within the review limits."
        }
        return nil
    }

}

/// The plan-time answer to "what will this actually do to my Mac?".
public struct OperationPlanSafetyReview: Codable, Hashable, Sendable {
    public var planID: UUID
    public var steps: [OperationStepSafetyReview]

    public init(planID: UUID, steps: [OperationStepSafetyReview]) {
        self.planID = planID
        self.steps = steps
    }

    public func review(forStep id: UUID) -> OperationStepSafetyReview? {
        steps.first { $0.stepID == id }
    }

    public var blockedSteps: [OperationStepSafetyReview] { steps.filter(\.isBlocked) }

    public var removedPathCount: Int { steps.reduce(0) { $0 + ($1.replacement?.removedPaths.count ?? 0) } }

    public var contentFindings: [ContentRiskFinding] { steps.flatMap { $0.contentRisk?.findings ?? [] } }

    public var incompleteContentScans: [OperationStepSafetyReview] {
        steps.filter { $0.contentRisk?.isComplete == false }
    }

    public var incompleteReplacementDiffs: [OperationStepSafetyReview] {
        steps.filter { $0.replacement?.isTruncated == true }
    }

    public var hasBlockedSteps: Bool { !blockedSteps.isEmpty }

    /// A single honest line for the top of the review sheet. It states facts
    /// and never tells the operator what to decide.
    public var headline: String? {
        var parts: [String] = []
        let unverifiedDestinations = steps.count { !$0.ownership.isProven }
        if unverifiedDestinations > 0 {
            let count = unverifiedDestinations
            parts.append("\(count) step\(count == 1 ? "" : "s") blocked because the destination could not be verified")
        }
        if !incompleteContentScans.isEmpty {
            let count = incompleteContentScans.count
            parts.append("\(count) package scan\(count == 1 ? "" : "s") incomplete")
        }
        if !incompleteReplacementDiffs.isEmpty {
            let count = incompleteReplacementDiffs.count
            parts.append("\(count) folder comparison\(count == 1 ? "" : "s") incomplete")
        }
        if removedPathCount > 0 {
            parts.append("\(removedPathCount) existing item\(removedPathCount == 1 ? "" : "s") removed")
        }
        let malicious = contentFindings.count { $0.severity == .malicious }
        let risky = contentFindings.count { $0.severity == .risky }
        if malicious > 0 { parts.append("\(malicious) malicious content finding\(malicious == 1 ? "" : "s")") }
        if risky > 0 { parts.append("\(risky) risky content finding\(risky == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Produces the plan-time review. Reading is all it does: nothing here writes,
/// moves, or deletes anything.
public struct OperationPlanSafetyReviewer {
    private let authority: ManagedInstallAuthority
    private let managedRoots: [URL]
    private let fileManager: FileManager
    private let contentLimits: ContentRiskScanner.Limits
    private let maximumComparedItems: Int

    public init(
        authority: ManagedInstallAuthority,
        managedRoots: [URL] = [],
        fileManager: FileManager = .default,
        contentLimits: ContentRiskScanner.Limits = ContentRiskScanner.Limits(),
        maximumComparedItems: Int = 10_000
    ) {
        self.authority = authority
        self.managedRoots = managedRoots
        self.fileManager = fileManager
        self.contentLimits = contentLimits
        self.maximumComparedItems = maximumComparedItems
    }

    public static func fromStore(
        _ store: any ManagedOperationStore,
        fileManager: FileManager = .default
    ) -> OperationPlanSafetyReviewer {
        OperationPlanSafetyReviewer(
            authority: store.installAuthority(),
            managedRoots: OperationPlanSafetyReviewer.managedRoots(for: store),
            fileManager: fileManager
        )
    }

    /// The destinations Agent Tooling owns outright because it created them.
    public static func managedRoots(for store: any ManagedOperationStore) -> [URL] {
        [
            store.libraryURL.standardizedFileURL,
            store.rootURL
                .appending(path: "exports/git-backup/library", directoryHint: .isDirectory)
                .standardizedFileURL,
        ]
    }

    public func review(_ plan: OperationPlan) -> OperationPlanSafetyReview {
        let steps = plan.steps.filter { $0.kind == .copyDirectory }.map { step in
            review(step)
        }
        return OperationPlanSafetyReview(planID: plan.id, steps: steps)
    }

    private func review(_ step: OperationStep) -> OperationStepSafetyReview {
        let destination = step.destinationPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let ownership =
            destination.map {
                DestinationOwnershipInspector.ownership(
                    of: $0,
                    managedRoots: managedRoots,
                    authority: authority,
                    expectedFingerprint: step.destinationFingerprint,
                    fileManager: fileManager
                )
            } ?? .unprovable("This step does not name a destination, so nothing about it can be verified.")
        let source = step.sourcePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let replacement = destination.flatMap { target in
            source.flatMap { origin in
                self.replacementDiff(replacing: target, with: origin)
            }
        }
        let contentRisk = source.map { ContentRiskScanner.scan(directory: $0, fileManager: fileManager, limits: contentLimits) }
        return OperationStepSafetyReview(
            stepID: step.id,
            stepTitle: step.title,
            ownership: ownership,
            replacement: replacement,
            contentRisk: contentRisk
        )
    }

    /// How many existing entries a replacement would take away, and whether the
    /// comparison was cut short at `maximumComparedItems`. Used for the short
    /// after-the-fact note in a receipt; the plan review lists them by name
    /// before anything is approved.
    ///
    /// The second half matters: a truncated comparison under-counts, so a
    /// receipt that printed the bare number would understate what it removed
    /// exactly when the folder was too big to check.
    public func replacementRemovalCount(replacing destination: URL, with source: URL) -> (count: Int, isTruncated: Bool) {
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
        let removed = existing.entries.subtracting(incoming.entries).sorted()
        let added = incoming.entries.subtracting(existing.entries).sorted()
        return DirectoryReplacementDiff(
            removedPaths: removed,
            addedPaths: added,
            keptCount: existing.entries.intersection(incoming.entries).count,
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
        let rootPath = root.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var entries = Set<String>()
        var isTruncated = false
        while let item = enumerator.nextObject() as? URL {
            guard entries.count < limit else {
                isTruncated = true
                break
            }
            let itemPath = item.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard itemPath.hasPrefix(rootPath + "/") else { continue }
            let relative = String(itemPath.dropFirst(rootPath.count + 1))
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
