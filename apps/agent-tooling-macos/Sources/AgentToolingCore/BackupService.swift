import Foundation

/// Git is a reviewed export target, not the operational database. Exports live
/// under Application Support until the user explicitly connects a remote.
public final class BackupService {
    private static let maximumSnapshotBytes = 32 * 1_024 * 1_024
    private static let maximumLockBytes = 4 * 1_024 * 1_024
    private let store: WorkspaceStore
    private let fileManager: FileManager

    public init(store: WorkspaceStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    public var exportURL: URL {
        store.rootURL.appending(path: "exports/git-backup", directoryHint: .isDirectory)
    }

    public func exportPlan(snapshot: WorkspaceSnapshot) throws -> OperationPlan {
        let portableSnapshot = snapshot.portableDesiredState()
        try WorkspaceSnapshotValidator.validate(portableSnapshot, mode: .portableImport)
        let profileData = try JSONEncoder.pretty().encode(portableSnapshot)
        let libraryFingerprint = try DirectoryFingerprint.sha256(of: store.libraryURL, fileManager: fileManager)
        let lock = BackupLock(
            exportedAt: .now,
            packageIDs: Array(Set(portableSnapshot.skills.map(\.bundle))).sorted(),
            sourceLocks: portableSnapshot.sources.map {
                BackupLock.SourceLock(name: $0.name, location: $0.location, revision: $0.lastRevision)
            }.sorted { $0.name < $1.name },
            libraryFingerprint: libraryFingerprint
        )
        let lockData = try JSONEncoder.pretty().encode(lock)
        let target = exportURL.path(percentEncoded: false)
        let hasLibraryItems = (try fileManager.contentsOfDirectory(atPath: store.libraryURL.path(percentEncoded: false))).isEmpty == false
        var steps: [OperationStep] = [
            OperationStep(
                kind: .createDirectory, title: "Create backup workspace",
                detail: "Create the local export folder under Application Support.", destinationPath: target, stopsOnFailure: true),
            OperationStep(
                kind: .verifyCleanGitRepository,
                title: "Verify existing backup",
                detail:
                    "If this export folder is already a Git repository, stop before writing when it contains uncommitted or untracked files.",
                destinationPath: target,
                isReversible: false,
                stopsOnFailure: true
            ),
        ]
        if hasLibraryItems {
            steps.append(
                OperationStep(
                    kind: .copyDirectory, title: "Export portable package library", detail: "Copy managed packages into the local backup.",
                    sourcePath: store.libraryURL.path(percentEncoded: false), sourceFingerprint: libraryFingerprint,
                    destinationPath: exportURL.appending(path: "library", directoryHint: .isDirectory).path(percentEncoded: false),
                    stopsOnFailure: true))
        } else {
            steps.append(
                OperationStep(
                    kind: .createDirectory, title: "Create empty package library",
                    detail: "Create the empty portable library required for a complete restore.",
                    destinationPath: exportURL.appending(path: "library", directoryHint: .isDirectory).path(percentEncoded: false),
                    stopsOnFailure: true))
        }
        steps.append(contentsOf: [
            OperationStep(
                kind: .writeFile, title: "Export desired state",
                detail: "Write profiles, source declarations, and receipts without credentials.",
                destinationPath: exportURL.appending(path: "workspace.json").path(percentEncoded: false),
                contents: String(decoding: profileData, as: UTF8.self), stopsOnFailure: true),
            OperationStep(
                kind: .writeFile, title: "Write version lock", detail: "Record package and source revisions for a reviewed restore.",
                destinationPath: exportURL.appending(path: "agent-tooling.lock.json").path(percentEncoded: false),
                contents: String(decoding: lockData, as: UTF8.self), stopsOnFailure: true),
            OperationStep(
                kind: .command, title: "Initialize local Git history", detail: "Initialize Git only in Agent Tooling's export folder.",
                executable: "git", arguments: ["-C", target, "init"], stopsOnFailure: true),
            OperationStep(
                kind: .command, title: "Inspect backup changes",
                detail: "Show the exact files that would be committed if you later choose to make a commit.", executable: "git",
                arguments: ["-C", target, "status", "--short"], stopsOnFailure: true),
            OperationStep(
                kind: .manual, title: "Optional: connect a remote",
                detail:
                    "Review the exported content, then explicitly add a GitHub, GitLab, self-hosted Git, or local remote. Credentials never enter the export.",
                requiresUserAction: true),
        ])
        return OperationPlan(
            kind: .exportBackup,
            title: "Prepare local Git backup",
            summary:
                "Exports portable packages, profiles, and source locks into a local Git repository. No GitHub account, remote, commit, or push is required.",
            steps: steps,
            requiresConfirmation: true
        )
    }

    public func conflictSummary(at path: URL) -> String {
        guard fileManager.fileExists(atPath: path.appending(path: ".git").path(percentEncoded: false)) else {
            return "Not a Git backup yet"
        }
        return "Existing Git backup. Agent Tooling checks that it is clean before replacing exported files."
    }

    /// Reads a backup without modifying either the selected repository or the
    /// current workspace. Conflicts are returned to the UI before a restore plan
    /// can be executed.
    public func importPreview(at backupURL: URL, current: WorkspaceSnapshot) throws -> BackupImportPreview {
        let root = backupURL.standardizedFileURL
        let snapshotURL = root.appending(path: "workspace.json", directoryHint: .notDirectory)
        let lockURL = root.appending(path: "agent-tooling.lock.json", directoryHint: .notDirectory)
        let libraryURL = root.appending(path: "library", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue,
            (try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
            fileManager.fileExists(atPath: snapshotURL.path(percentEncoded: false)),
            fileManager.fileExists(atPath: lockURL.path(percentEncoded: false)),
            fileManager.fileExists(atPath: libraryURL.path(percentEncoded: false))
        else {
            throw BackupError.incompleteBackup(root.path(percentEncoded: false))
        }
        try validateRegularFile(snapshotURL, maximumBytes: Self.maximumSnapshotBytes)
        try validateRegularFile(lockURL, maximumBytes: Self.maximumLockBytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(
            WorkspaceSnapshot.self,
            from: try boundedData(at: snapshotURL, maximumBytes: Self.maximumSnapshotBytes)
        )
        let lock = try decoder.decode(
            BackupLock.self,
            from: try boundedData(at: lockURL, maximumBytes: Self.maximumLockBytes)
        )
        guard lock.formatVersion == 2 else { throw BackupError.unsupportedFormat(lock.formatVersion) }
        guard lock.exportedAt.timeIntervalSinceReferenceDate.isFinite,
            lock.packageIDs.count <= 10_000,
            lock.sourceLocks.count <= 10_000,
            Set(lock.packageIDs).count == lock.packageIDs.count,
            Set(lock.sourceLocks).count == lock.sourceLocks.count,
            lock.libraryFingerprint?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else {
            throw BackupError.invalidLock
        }
        do {
            try WorkspaceSnapshotValidator.validate(snapshot, mode: .portableImport)
        } catch {
            throw BackupError.invalidSnapshot
        }
        let snapshotPackageIDs = Set(snapshot.skills.filter(\.owned).map(\.bundle))
        guard Set(lock.packageIDs) == snapshotPackageIDs,
            Set(lock.packageIDs).count == lock.packageIDs.count
        else { throw BackupError.invalidLock }
        let expectedSourceLocks = Set(
            snapshot.sources.map { BackupLock.SourceLock(name: $0.name, location: $0.location, revision: $0.lastRevision) })
        guard Set(lock.sourceLocks) == expectedSourceLocks,
            Set(lock.sourceLocks).count == lock.sourceLocks.count
        else { throw BackupError.invalidLock }
        let libraryFingerprint = try DirectoryFingerprint.sha256(of: libraryURL, fileManager: fileManager)
        guard lock.libraryFingerprint == libraryFingerprint else { throw BackupError.invalidLibraryFingerprint }
        let libraryPackageIDs = try packageIdentifiers(in: libraryURL)
        guard libraryPackageIDs == Set(lock.packageIDs) else { throw BackupError.invalidLock }
        let conflicts = conflicts(current: current, backup: snapshot)
        let plan = OperationPlan(
            kind: .restoreBackup,
            title: "Restore local Agent Tooling backup",
            summary:
                "Replace the managed local package library and desired-state snapshot from \(root.lastPathComponent). Existing library content is moved to Receipts/Rollback first. No remote is contacted.",
            steps: [
                OperationStep(
                    kind: .copyDirectory, title: "Restore portable package library",
                    detail:
                        "Replace only Agent Tooling's managed local library from the selected backup. The prior library is saved for rollback.",
                    sourcePath: libraryURL.path(percentEncoded: false), sourceFingerprint: libraryFingerprint,
                    destinationPath: store.libraryURL.path(percentEncoded: false)),
                OperationStep(
                    kind: .scan, title: "Re-scan local clients",
                    detail: "Compare the restored desired state against the actual local Claude, Codex, and Gemini configuration.",
                    isReversible: false),
            ],
            requiresConfirmation: true
        )
        return BackupImportPreview(backupURL: root, snapshot: snapshot, lock: lock, conflicts: conflicts, plan: plan)
    }

    private func conflicts(current: WorkspaceSnapshot, backup: WorkspaceSnapshot) -> [BackupConflict] {
        var conflicts: [BackupConflict] = []
        let localSkills = indexed(current.skills.filter(\.owned), by: \.id)
        let backupSkills = indexed(backup.skills.filter(\.owned), by: \.id)
        for skill in backup.skills.filter(\.owned) {
            guard let local = localSkills[skill.id], local != skill else { continue }
            conflicts.append(BackupConflict(kind: "Skill", identifier: skill.id, localSummary: local.summary, backupSummary: skill.summary))
        }
        for skill in current.skills.filter(\.owned) where backupSkills[skill.id] == nil {
            conflicts.append(
                BackupConflict(
                    kind: "Skill", identifier: skill.id, localSummary: skill.summary, backupSummary: "Not present; restore would remove it")
            )
        }
        let localProfiles = indexed(current.profiles, by: \.id)
        let backupProfiles = indexed(backup.profiles, by: \.id)
        for profile in backup.profiles {
            guard let local = localProfiles[profile.id], local != profile else { continue }
            conflicts.append(
                BackupConflict(kind: "Profile", identifier: profile.id, localSummary: local.summary, backupSummary: profile.summary))
        }
        for profile in current.profiles where backupProfiles[profile.id] == nil {
            conflicts.append(
                BackupConflict(
                    kind: "Profile", identifier: profile.id, localSummary: profile.summary,
                    backupSummary: "Not present; restore would remove it"))
        }
        let localSources = indexed(current.sources, by: \.name)
        let backupSources = indexed(backup.sources, by: \.name)
        for source in backup.sources {
            guard let local = localSources[source.name], local.location != source.location else { continue }
            conflicts.append(
                BackupConflict(kind: "Source", identifier: source.name, localSummary: local.location, backupSummary: source.location))
        }
        for source in current.sources where backupSources[source.name] == nil {
            conflicts.append(
                BackupConflict(
                    kind: "Source", identifier: source.name, localSummary: source.location,
                    backupSummary: "Not present; restore would remove it"))
        }
        return conflicts.sorted { $0.id < $1.id }
    }

    private func indexed<Element>(_ values: [Element], by keyPath: KeyPath<Element, String>) -> [String: Element] {
        var result: [String: Element] = [:]
        for value in values { result[value[keyPath: keyPath]] = value }
        return result
    }

    private func validateRegularFile(_ url: URL, maximumBytes: Int) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BackupError.unsafeItem(url.path(percentEncoded: false))
        }
        guard (values.fileSize ?? maximumBytes + 1) <= maximumBytes else {
            throw BackupError.fileTooLarge(url.lastPathComponent)
        }
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let initialValues = try url.resourceValues(forKeys: [
            .contentModificationDateKey, .fileResourceIdentifierKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard initialValues.isRegularFile == true,
            initialValues.isSymbolicLink != true,
            let initialSize = initialValues.fileSize,
            initialSize >= 0,
            initialSize <= maximumBytes
        else {
            throw BackupError.changedWhileReading(url.lastPathComponent)
        }
        let initialIdentifier = initialValues.fileResourceIdentifier.map { String(describing: $0) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, data.count == initialSize else {
            throw BackupError.changedWhileReading(url.lastPathComponent)
        }
        let finalValues = try url.resourceValues(forKeys: [
            .contentModificationDateKey, .fileResourceIdentifierKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard finalValues.isRegularFile == true,
            finalValues.isSymbolicLink != true,
            let finalSize = finalValues.fileSize,
            finalSize == initialSize,
            finalValues.contentModificationDate == initialValues.contentModificationDate,
            finalValues.fileResourceIdentifier.map({ String(describing: $0) }) == initialIdentifier
        else {
            throw BackupError.changedWhileReading(url.lastPathComponent)
        }
        return data
    }

    private func packageIdentifiers(in libraryURL: URL) throws -> Set<String> {
        let packages = libraryURL.appending(path: "packages", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: packages.path(percentEncoded: false)) else { return [] }
        let values = try packages.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BackupError.unsafeItem(packages.path(percentEncoded: false))
        }
        let children = try fileManager.contentsOfDirectory(
            at: packages,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        guard children.count <= 10_000 else { throw BackupError.invalidLock }
        var identifiers = Set<String>()
        for child in children {
            let childValues = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard childValues.isDirectory == true,
                childValues.isSymbolicLink != true,
                identifiers.insert(child.lastPathComponent).inserted
            else {
                throw BackupError.unsafeItem(child.path(percentEncoded: false))
            }
        }
        return identifiers
    }

}

public enum BackupError: LocalizedError, Sendable {
    case incompleteBackup(String)
    case unsupportedFormat(Int)
    case invalidLock
    case invalidLibraryFingerprint
    case invalidSnapshot
    case unsafeItem(String)
    case fileTooLarge(String)
    case changedWhileReading(String)

    public var errorDescription: String? {
        switch self {
        case .incompleteBackup(let path): "The selected folder is not a complete Agent Tooling backup: \(path)"
        case .unsupportedFormat(let version): "This backup uses unsupported format version \(version)."
        case .invalidLock: "The backup lock does not match the portable packages in workspace.json."
        case .invalidLibraryFingerprint: "The backup package library does not match the content fingerprint recorded when it was exported."
        case .invalidSnapshot: "The backup contains duplicate, unsafe, or inconsistent desired-state records."
        case .unsafeItem(let path): "The backup contains a symbolic link or unsupported file: \(path)"
        case .fileTooLarge(let name): "The backup file \(name) exceeds the supported size limit."
        case .changedWhileReading(let name): "The backup file \(name) changed while it was being inspected."
        }
    }
}

public struct BackupLock: Codable, Hashable, Sendable {
    public struct SourceLock: Codable, Hashable, Sendable {
        public var name: String
        public var location: String
        public var revision: String?
    }

    public var formatVersion = 2
    public var exportedAt: Date
    public var packageIDs: [String]
    public var sourceLocks: [SourceLock]
    public var libraryFingerprint: String?

    public init(
        formatVersion: Int = 2,
        exportedAt: Date,
        packageIDs: [String],
        sourceLocks: [SourceLock],
        libraryFingerprint: String?
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.packageIDs = packageIDs
        self.sourceLocks = sourceLocks
        self.libraryFingerprint = libraryFingerprint
    }
}

private extension JSONEncoder {
    static func pretty() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
