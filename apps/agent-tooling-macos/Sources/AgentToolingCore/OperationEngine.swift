import Foundation

public actor OperationExecutor {
    private let store: WorkspaceStore
    private let runner: any CommandRunning
    private let fileManager: FileManager
    private let homeURL: URL
    private let commandPolicy: OperationCommandPolicy
    /// Proof of which destinations this app installed, refreshed once per plan
    /// so every step in a batch is judged against the same recorded history.
    private var installAuthority = ManagedInstallAuthority()

    public init(
        store: WorkspaceStore,
        runner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.runner = runner
        self.fileManager = fileManager
        self.homeURL = homeURL
        self.commandPolicy = OperationCommandPolicy(
            libraryURL: store.libraryURL,
            gitBackupRoot: store.rootURL.appending(path: "exports/git-backup", directoryHint: .isDirectory).standardizedFileURL
        )
    }

    /// Executes a plan built by an adapter. Steps intentionally continue after
    /// a failure so multi-agent installs retain useful partial success.
    public func execute(_ plan: OperationPlan) async -> OperationReceipt {
        installAuthority = .fromStore(store)
        var results: [OperationStepResult] = []
        for (index, step) in plan.steps.enumerated() {
            let startedAt = Date.now
            do {
                try Task.checkCancellation()
                let result = try await execute(step)
                results.append(
                    OperationStepResult(
                        stepID: step.id,
                        status: result.status,
                        output: Self.persistableOutput(result.output),
                        startedAt: startedAt,
                        finishedAt: .now
                    )
                )
            } catch is CancellationError {
                results.append(
                    OperationStepResult(
                        stepID: step.id, status: .skipped, output: "Cancelled before this step ran.", startedAt: startedAt, finishedAt: .now
                    ))
                appendSkippedSteps(plan.steps.dropFirst(index + 1), reason: "Skipped because the operation was cancelled.", to: &results)
                break
            } catch {
                results.append(
                    OperationStepResult(
                        stepID: step.id, status: .failed, output: Self.persistableOutput(error.localizedDescription), startedAt: startedAt,
                        finishedAt: .now))
                if step.shouldStopOnFailure {
                    appendSkippedSteps(
                        plan.steps.dropFirst(index + 1), reason: "Skipped because a required preflight or integrity check failed.",
                        to: &results)
                    break
                }
            }
        }
        let state: HealthState
        if results.isEmpty {
            state = .attention
        } else if results.contains(where: { $0.status == .failed }) {
            state = .attention
        } else if results.contains(where: { $0.status == .manual || $0.status == .skipped }) {
            state = .pending
        } else {
            state = .healthy
        }
        let wasCancelled = results.contains { result in
            result.status == .skipped && result.output.localizedCaseInsensitiveContains("cancel")
        }
        let hasCompletedAutomaticStep = results.contains { $0.status == .succeeded }
        let guidance =
            results.isEmpty
            ? "No operation steps were provided. Nothing changed."
            : wasCancelled
                ? "The operation was stopped. Completed steps were kept; skipped steps did not run. Re-scan before retrying."
                : results.contains(where: { $0.status == .failed })
                    ? "Some steps failed. Re-scan the affected targets before retrying."
                    : results.contains(where: { $0.status == .manual })
                        ? hasCompletedAutomaticStep
                            ? "The reviewed local changes completed. Finish the remaining manual checks, then check setup again."
                            : "No local changes were made. Follow the manual guidance, then check setup again."
                        : "All requested local steps completed. A fresh scan is recorded after the operation."
        let outcomes = Self.itemOutcomes(for: plan, results: results)
        var receipt = OperationReceipt(
            planID: plan.id,
            kind: plan.kind,
            title: plan.title,
            state: state,
            targetSurfaces: plan.targetSurfaces,
            results: results,
            verificationSummary: guidance,
            itemOutcomes: outcomes
        )
        receipt.verificationSummary = Self.persistableOutput(Self.verificationSummary(for: receipt, guidance: guidance))
        do {
            try store.saveEntity(receipt, id: receipt.id.uuidString, domain: .receipts)
        } catch {
            receipt.state = .attention
            receipt.verificationSummary += " The operation completed, but its receipt could not be saved: \(error.localizedDescription)"
        }
        return receipt
    }

    /// Names every item in the batch with the reason it ended as it did. A step
    /// with no recorded result is reported explicitly rather than dropped, so
    /// the itemization always accounts for the whole plan.
    private static func itemOutcomes(for plan: OperationPlan, results: [OperationStepResult]) -> [OperationItemOutcome] {
        let byStep = Dictionary(results.map { ($0.stepID, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.steps.map { step in
            guard let result = byStep[step.id] else {
                return OperationItemOutcome(
                    id: step.id,
                    title: step.title,
                    status: .pending,
                    reason: "This step never started."
                )
            }
            // The itemization is a summary. `results` still holds each step's
            // complete output, so the reason is bounded to keep a long batch
            // from doubling the size of the stored receipt.
            let reason = Self.condensed(result.output, limit: maximumReasonCharacters)
            return OperationItemOutcome(
                id: step.id,
                title: step.title,
                status: result.status,
                reason: reason.isEmpty ? Self.defaultReason(for: result.status) : reason
            )
        }
    }

    private static func defaultReason(for status: OperationStepStatus) -> String {
        switch status {
        case .succeeded: "Completed."
        case .failed: "Failed without a recorded reason."
        case .skipped: "Skipped."
        case .manual: "Waiting for you to complete it."
        case .pending: "This step never started."
        }
    }

    /// Builds the itemized batch summary: a per-status tally followed by the
    /// name and reason for every item that did not simply succeed.
    private static func verificationSummary(for receipt: OperationReceipt, guidance: String) -> String {
        guard !receipt.itemOutcomes.isEmpty else { return guidance }
        var lines = ["\(receipt.outcomeTally)."]
        for status in [OperationStepStatus.failed, .skipped, .manual, .pending] {
            let items = receipt.itemOutcomes.filter { $0.status == status }
            guard !items.isEmpty else { continue }
            let label = status.displayName
            let named = items.prefix(maximumNamedItems).map { item in
                "\(item.title) — \(Self.condensed(item.reason))"
            }
            var line = "\(label): \(named.joined(separator: "; "))"
            if items.count > named.count { line += "; and \(items.count - named.count) more" }
            lines.append(Self.sentence(line))
        }
        lines.append(guidance)
        return lines.joined(separator: " ")
    }

    private static func condensed(_ reason: String, limit: Int = 180) -> String {
        let flattened = reason.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// Ends a line with exactly one terminator. Step reasons usually end in a
    /// full stop already, and a doubled one reads like a formatting bug.
    private static func sentence(_ line: String) -> String {
        let terminators: Set<Character> = [".", "!", "?", "…", ":"]
        guard let last = line.last, terminators.contains(last) else { return line + "." }
        return line
    }

    private static let maximumNamedItems = 12
    private static let maximumReasonCharacters = 2_000

    private func appendSkippedSteps(
        _ steps: ArraySlice<OperationStep>,
        reason: String,
        to results: inout [OperationStepResult]
    ) {
        for step in steps {
            let now = Date.now
            results.append(
                OperationStepResult(
                    stepID: step.id,
                    status: .skipped,
                    output: reason,
                    startedAt: now,
                    finishedAt: now
                )
            )
        }
    }

    private func execute(_ step: OperationStep) async throws -> (status: OperationStepStatus, output: String) {
        switch step.kind {
        case .createDirectory:
            guard let destinationPath = step.destinationPath else { throw OperationEngineError.malformedStep(step.title) }
            let destination = try backupDirectoryDestination(destinationPath)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            return (.succeeded, "Created \(destination.path(percentEncoded: false)).")

        case .verifyCleanGitRepository:
            guard let destinationPath = step.destinationPath else { throw OperationEngineError.malformedStep(step.title) }
            let destination = try backupRootDestination(destinationPath)
            let gitDirectory = destination.appending(path: ".git", directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: gitDirectory.path(percentEncoded: false)) else {
                return (.succeeded, "No existing Git repository needs a cleanliness check.")
            }
            let output = try await runner.run(
                executable: "git",
                arguments: ["-C", destination.path(percentEncoded: false), "status", "--porcelain=v1", "--untracked-files=all"],
                currentDirectory: nil
            )
            let combined = [output.standardOutput, output.standardError].filter { !$0.isEmpty }.joined(separator: "\n")
            guard output.status == 0 else { throw OperationEngineError.commandFailed("git", output.status, combined) }
            guard output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OperationEngineError.dirtyGitBackup(destination.path(percentEncoded: false))
            }
            return (.succeeded, "The existing local Git backup is clean.")

        case .writeFile:
            guard let destinationPath = step.destinationPath, let contents = step.contents else {
                throw OperationEngineError.malformedStep(step.title)
            }
            guard contents.utf8.count <= Self.maximumBackupMetadataBytes else { throw OperationEngineError.sourceTooLarge }
            let destination = try backupMetadataDestination(destinationPath)
            try replaceFile(at: destination, contents: Data(contents.utf8), planStepID: step.id) {
                _ = try self.backupMetadataDestination(destinationPath)
            }
            return (.succeeded, "Wrote \(destination.path(percentEncoded: false)).")

        case .writeEncryptedArchive:
            guard let destinationPath = step.destinationPath, let contents = step.contents else {
                throw OperationEngineError.malformedStep(step.title)
            }
            let destination = try encryptedArchiveDestination(destinationPath)
            try replaceFile(at: destination, contents: Data(contents.utf8), planStepID: step.id) {
                _ = try self.encryptedArchiveDestination(destinationPath)
            }
            return (.succeeded, "Wrote encrypted archive at \(destination.path(percentEncoded: false)).")

        case .copyDirectory:
            guard let sourcePath = step.sourcePath,
                let sourceFingerprint = step.sourceFingerprint,
                let destinationPath = step.destinationPath
            else { throw OperationEngineError.malformedStep(step.title) }
            let source = URL(fileURLWithPath: sourcePath)
            try validateSource(source)
            let destination = try copyDestination(destinationPath, projectRootPath: step.projectRootPath)
            try requireProvenOwnership(of: destination)
            let removals = removedEntryCount(replacing: destination, with: source)
            try replaceDirectory(
                at: destination,
                withCopyOf: source,
                expectedFingerprint: sourceFingerprint,
                projectRootPath: step.projectRootPath,
                planStepID: step.id
            )
            let ledgerNote = recordManagedInstall(
                destination: destination,
                source: source,
                reviewedFingerprint: sourceFingerprint,
                planStepID: step.id
            )
            let removalNote: String
            switch (removals.count, removals.isTruncated) {
            case (0, false):
                removalNote = ""
            case (0, true):
                removalNote = " This folder was too large to compare completely, so items it replaced may not be counted."
            case (let count, let isTruncated):
                let items = "\(count) item\(count == 1 ? "" : "s")"
                let wasWere = count == 1 ? "was" : "were"
                let isAre = count == 1 ? "is" : "are"
                removalNote =
                    isTruncated
                    ? " At least \(items) that \(wasWere) here before \(isAre) not part of this package; it was too large to compare completely."
                    : " \(items) that \(wasWere) here before \(isAre) not part of this package."
            }
            return (.succeeded, "Installed local package at \(destination.path(percentEncoded: false)).\(removalNote)\(ledgerNote)")

        case .replaceManagedLibrary:
            guard let destinationPath = step.destinationPath, let contents = step.contents else {
                throw OperationEngineError.malformedStep(step.title)
            }
            let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL
            guard destination.standardizedFileURL == store.libraryURL.standardizedFileURL else {
                throw OperationEngineError.unsafeDestination(destinationPath)
            }
            let files = try JSONDecoder().decode([EncryptedLibraryFile].self, from: Data(contents.utf8))
            try validateArchiveFiles(files)
            try replaceManagedLibrary(at: destination, files: files, planStepID: step.id)
            return (.succeeded, "Restored \(files.count) managed library file\(files.count == 1 ? "" : "s").")

        case .command:
            guard let executable = step.executable else { throw OperationEngineError.malformedStep(step.title) }
            try commandPolicy.validate(executable: executable, arguments: step.arguments)
            let workingDirectory = try commandWorkingDirectory(
                step.currentDirectoryPath,
                authorizedProjectRootPath: step.projectRootPath
            )
            let output = try await runner.run(executable: executable, arguments: step.arguments, currentDirectory: workingDirectory)
            let combined = [output.standardOutput, output.standardError].filter { !$0.isEmpty }.joined(separator: "\n")
            guard output.status == 0 else { throw OperationEngineError.commandFailed(executable, output.status, combined) }
            return (.succeeded, combined.isEmpty ? "\(executable) completed." : combined)

        case .scan:
            return (.succeeded, "A post-operation scan is queued by the control plane.")

        case .openURL:
            return (.manual, step.detail)

        case .manual:
            return (.manual, step.detail)
        }
    }

    // MARK: - Destination ownership

    /// Refuses to replace anything Agent Tooling cannot prove is empty, its own
    /// prior install, or an install recorded by a stored plan and receipt.
    ///
    /// Confining writes to known folders keeps a plan from writing somewhere
    /// unexpected. It does not keep a plan from overwriting somebody else's
    /// files inside an expected folder — a hand-written skill in
    /// `~/.claude/skills/<name>`, for example. This is that missing half, and
    /// it is checked again immediately before the swap so the answer cannot go
    /// stale between the check and the write.
    private func requireProvenOwnership(of destination: URL) throws {
        let ownership = DestinationOwnershipInspector.ownership(
            of: destination,
            managedRoots: managedRoots,
            authority: installAuthority,
            fileManager: fileManager
        )
        guard ownership.isProven else {
            throw OperationEngineError.unprovableDestination(destination.path(percentEncoded: false), ownership.summary)
        }
    }

    private var managedRoots: [URL] {
        [store.libraryURL.standardizedFileURL, gitBackupRoot.appending(path: "library", directoryHint: .isDirectory).standardizedFileURL]
    }

    /// Persists the reviewed fingerprint against the destination so a later
    /// setup check can tell whether the installed copy still matches the tree
    /// the operator approved.
    private func recordManagedInstall(
        destination: URL,
        source: URL,
        reviewedFingerprint: String,
        planStepID: UUID
    ) -> String {
        var ledger = ManagedInstallLedger.load(from: store)
        ledger.upsert(
            ManagedInstallRecord(
                destinationPath: destination.path(percentEncoded: false),
                sourcePath: source.standardizedFileURL.path(percentEncoded: false),
                reviewedFingerprint: reviewedFingerprint,
                reviewedAt: .now,
                planStepID: planStepID
            ))
        do {
            try ledger.save(to: store)
            installAuthority = ManagedInstallAuthority(ledger: ledger, receiptRecords: installAuthority.receiptRecords)
            return ""
        } catch {
            // The files are already in place. Say so plainly instead of
            // reporting a completed install as a failure.
            return
                " The install completed, but the reviewed fingerprint could not be recorded, so later checks cannot detect changes to it."
        }
    }

    /// Counts destination entries the incoming package does not contain, and
    /// says whether the comparison was complete. Used only to describe the
    /// completed replacement in the receipt; the plan review lists them by name
    /// before approval.
    private func removedEntryCount(replacing destination: URL, with source: URL) -> (count: Int, isTruncated: Bool) {
        let reviewer = OperationPlanSafetyReviewer(
            authority: installAuthority,
            managedRoots: managedRoots,
            fileManager: fileManager
        )
        return reviewer.replacementRemovalCount(replacing: destination, with: source)
    }

    private func backupRootDestination(_ rawPath: String) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard destination == gitBackupRoot else { throw OperationEngineError.unsafeDestination(rawPath) }
        try validateContainedPath(destination, within: store.rootURL)
        return destination
    }

    private func backupDirectoryDestination(_ rawPath: String) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        let allowed = [gitBackupRoot, gitBackupRoot.appending(path: "library", directoryHint: .isDirectory)]
            .map(\.standardizedFileURL)
        guard allowed.contains(destination) else { throw OperationEngineError.unsafeDestination(rawPath) }
        try validateContainedPath(destination, within: store.rootURL)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw OperationEngineError.unsafeDestination(rawPath)
            }
        }
        return destination
    }

    private func backupMetadataDestination(_ rawPath: String) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        let permitted = [
            gitBackupRoot.appending(path: "workspace.json", directoryHint: .notDirectory),
            gitBackupRoot.appending(path: "agent-tooling.lock.json", directoryHint: .notDirectory),
        ].map(\.standardizedFileURL)
        guard permitted.contains(destination) else { throw OperationEngineError.unsafeDestination(rawPath) }
        try validateContainedPath(destination.deletingLastPathComponent(), within: store.rootURL)
        return destination
    }

    private func copyDestination(_ rawPath: String, projectRootPath: String? = nil) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        let exactDestinations = [
            store.libraryURL,
            gitBackupRoot.appending(path: "library", directoryHint: .isDirectory),
        ].map(\.standardizedFileURL)
        if exactDestinations.contains(destination) {
            try validateContainedPath(destination, within: store.rootURL)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw OperationEngineError.unsafeDestination(rawPath)
                }
            }
            return destination
        }

        // One managed package is its own destination, so adopting three skills
        // reviews as three steps a person can read rather than a single rewrite
        // of the whole library. The package name is the only variable part and
        // it is checked the same way a skill folder name is.
        let managedPackages = store.libraryURL.appending(path: "packages", directoryHint: .isDirectory).standardizedFileURL
        if Self.samePath(destination.deletingLastPathComponent(), managedPackages),
            OperationCommandPolicy.isSafeMCPIdentifier(destination.lastPathComponent)
        {
            try validateContainedPath(destination, within: store.libraryURL)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw OperationEngineError.unsafeDestination(rawPath)
                }
            }
            return destination
        }

        var permittedSkillRoots: [(root: URL, anchor: URL)] = [
            (homeURL.appending(path: ".claude/skills", directoryHint: .isDirectory), homeURL),
            (homeURL.appending(path: ".agents/skills", directoryHint: .isDirectory), homeURL),
            (homeURL.appending(path: ".gemini/skills", directoryHint: .isDirectory), homeURL),
        ].map { ($0.0.standardizedFileURL, $0.1.standardizedFileURL) }

        if let projectRootPath {
            let projectRoot = URL(fileURLWithPath: projectRootPath).standardizedFileURL
            let directValues = try projectRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var isDirectory: ObjCBool = false
            guard directValues.isSymbolicLink != true,
                fileManager.fileExists(atPath: projectRoot.path(percentEncoded: false), isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw OperationEngineError.unsafeDestination(rawPath)
            }
            permittedSkillRoots.append(
                contentsOf: [
                    (projectRoot.appending(path: ".claude/skills", directoryHint: .isDirectory), projectRoot),
                    (projectRoot.appending(path: ".agents/skills", directoryHint: .isDirectory), projectRoot),
                    (projectRoot.appending(path: ".gemini/skills", directoryHint: .isDirectory), projectRoot),
                ].map { ($0.0.standardizedFileURL, $0.1.standardizedFileURL) })
        }

        guard OperationCommandPolicy.isSafeMCPIdentifier(destination.lastPathComponent),
            let permitted = permittedSkillRoots.first(where: {
                Self.samePath(destination.deletingLastPathComponent(), $0.root)
            })
        else {
            throw OperationEngineError.unsafeDestination(rawPath)
        }
        try validateContainedPath(permitted.root, within: permitted.anchor)
        return destination
    }

    private func commandWorkingDirectory(_ rawPath: String?, authorizedProjectRootPath: String?) throws -> URL? {
        guard let rawPath else {
            guard authorizedProjectRootPath == nil else {
                throw OperationEngineError.unsafeWorkingDirectory(authorizedProjectRootPath ?? "")
            }
            return nil
        }
        guard let authorizedProjectRootPath else { throw OperationEngineError.unsafeWorkingDirectory(rawPath) }
        let workingDirectory = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
        let authorizedRoot = URL(fileURLWithPath: authorizedProjectRootPath).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workingDirectory.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue,
            workingDirectory == authorizedRoot
        else {
            throw OperationEngineError.unsafeWorkingDirectory(rawPath)
        }
        return workingDirectory
    }

    private func encryptedArchiveDestination(_ rawPath: String) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard destination.lastPathComponent == EncryptedSyncService.archiveFileName,
            parentValues.isDirectory == true,
            parentValues.isSymbolicLink != true
        else {
            throw OperationEngineError.unsafeDestination(rawPath)
        }
        guard Self.samePath(parent.resolvingSymlinksInPath(), parent) else {
            throw OperationEngineError.unsafeDestination(rawPath)
        }
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw OperationEngineError.unsafeDestination(rawPath)
            }
        }
        return destination
    }

    private func validateSource(_ source: URL) throws {
        let directValues = try source.standardizedFileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directValues.isDirectory == true, directValues.isSymbolicLink != true else {
            throw OperationEngineError.unsafeSource(source.path(percentEncoded: false))
        }
        let normalized = source.standardizedFileURL.resolvingSymlinksInPath()
        let library = store.libraryURL.standardizedFileURL.resolvingSymlinksInPath()
        let isManagedLibrary = isContained(normalized, in: library)
        let backupRoot = normalized.deletingLastPathComponent()
        let isCompleteBackupLibrary =
            normalized.lastPathComponent == "library"
            && fileManager.fileExists(atPath: backupRoot.appending(path: "workspace.json").path(percentEncoded: false))
            && fileManager.fileExists(atPath: backupRoot.appending(path: "agent-tooling.lock.json").path(percentEncoded: false))
        guard isManagedLibrary || isCompleteBackupLibrary,
            fileManager.fileExists(atPath: normalized.path(percentEncoded: false))
        else {
            throw OperationEngineError.unsafeSource(source.path(percentEncoded: false))
        }
        try validateDirectoryTree(normalized)
    }

    private var gitBackupRoot: URL {
        store.rootURL.appending(path: "exports/git-backup", directoryHint: .isDirectory).standardizedFileURL
    }

    private func replaceFile(
        at destination: URL,
        contents: Data,
        planStepID: UUID,
        revalidateDestination: () throws -> Void
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appending(path: ".agent-tooling-file-\(UUID().uuidString)", directoryHint: .notDirectory)
        defer { removeStagingItemIfPresent(staged) }
        try contents.write(to: staged, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path(percentEncoded: false))
        try commitPreparedItem(
            staged,
            to: destination,
            planStepID: planStepID,
            revalidateDestination: revalidateDestination
        )
    }

    private func replaceDirectory(
        at destination: URL,
        withCopyOf source: URL,
        expectedFingerprint: String,
        projectRootPath: String?,
        planStepID: UUID
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appending(path: ".agent-tooling-directory-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { removeStagingItemIfPresent(staged) }
        try fileManager.copyItem(at: source, to: staged)
        try validateDirectoryTree(staged)
        try normalizePrivatePermissions(under: staged)
        let actualFingerprint = try DirectoryFingerprint.sha256(
            of: staged,
            fileManager: fileManager,
            maximumItems: Self.maximumTreeItems,
            maximumBytes: Self.maximumTreeBytes
        )
        guard actualFingerprint == expectedFingerprint else { throw OperationEngineError.sourceChangedAfterReview }
        try commitPreparedItem(staged, to: destination, planStepID: planStepID) {
            _ = try self.copyDestination(destination.path(percentEncoded: false), projectRootPath: projectRootPath)
            // Re-proved immediately before the swap so a destination that
            // gained unowned content while the copy was staged is still caught.
            try self.requireProvenOwnership(of: destination)
        }
    }

    private func replaceManagedLibrary(at destination: URL, files: [EncryptedLibraryFile], planStepID: UUID) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appending(path: ".agent-tooling-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { removeStagingItemIfPresent(staged) }
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path(percentEncoded: false))
        for file in files {
            let fileURL = staged.appending(path: file.relativePath, directoryHint: .notDirectory)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: file.isExecutable == true ? 0o700 : 0o600],
                ofItemAtPath: fileURL.path(percentEncoded: false)
            )
        }
        try normalizePrivatePermissions(under: staged)
        try commitPreparedItem(staged, to: destination, planStepID: planStepID) {
            let direct = destination.standardizedFileURL
            let values = try direct.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard direct == self.store.libraryURL.standardizedFileURL,
                values.isDirectory == true,
                values.isSymbolicLink != true
            else {
                throw OperationEngineError.unsafeDestination(destination.path(percentEncoded: false))
            }
            try self.validateContainedPath(direct, within: self.store.rootURL)
        }
    }

    private func commitPreparedItem(
        _ staged: URL,
        to destination: URL,
        planStepID: UUID,
        revalidateDestination: () throws -> Void
    ) throws {
        try revalidateDestination()
        let exists = fileManager.fileExists(atPath: destination.path(percentEncoded: false))
        if exists {
            let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            let stagedValues = try staged.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard destinationValues.isSymbolicLink != true,
                stagedValues.isSymbolicLink != true,
                destinationValues.isDirectory == stagedValues.isDirectory,
                destinationValues.isRegularFile == stagedValues.isRegularFile
            else {
                throw OperationEngineError.unsafeDestination(destination.path(percentEncoded: false))
            }
            try preserveRollbackCopy(of: destination, planStepID: planStepID)
        }
        try revalidateDestination()
        if exists {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    private func preserveRollbackCopy(of destination: URL, planStepID: UUID) throws {
        let rollback = store.receiptsURL
            .appending(path: "rollback", directoryHint: .isDirectory)
            .appending(path: planStepID.uuidString, directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: destination.lastPathComponent, directoryHint: .isDirectory)
        try validateContainedPath(rollback.deletingLastPathComponent(), within: store.receiptsURL)
        try fileManager.createDirectory(at: rollback.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: destination, to: rollback)
    }

    private func removeStagingItemIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            // A failed cleanup must not report the committed replacement as a
            // failed user operation. Hidden staging entries are ignored by the
            // inventory and export scanners and remain recoverable for manual
            // cleanup if the filesystem continues refusing deletion.
        }
    }

    private func validateDirectoryTree(_ root: URL) throws {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw OperationEngineError.unsafeSource(root.path(percentEncoded: false))
        }
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
        else { throw OperationEngineError.unsafeSource(root.path(percentEncoded: false)) }

        var itemCount = 0
        var byteCount = 0
        for case let item as URL in enumerator {
            itemCount += 1
            guard itemCount <= Self.maximumTreeItems else { throw OperationEngineError.sourceTooLarge }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true,
                values.isDirectory == true || values.isRegularFile == true
            else {
                throw OperationEngineError.unsupportedSourceItem(item.path(percentEncoded: false))
            }
            if values.isRegularFile == true {
                guard let size = values.fileSize, size >= 0 else {
                    throw OperationEngineError.unsupportedSourceItem(item.path(percentEncoded: false))
                }
                let (total, overflow) = byteCount.addingReportingOverflow(size)
                guard !overflow, total <= Self.maximumTreeBytes else { throw OperationEngineError.sourceTooLarge }
                byteCount = total
            }
        }
    }

    private func validateArchiveFiles(_ files: [EncryptedLibraryFile]) throws {
        guard files.count <= Self.maximumTreeItems else { throw OperationEngineError.invalidArchive }
        var paths = Set<String>()
        var byteCount = 0
        for file in files {
            guard Self.isSafeArchivePath(file.relativePath), paths.insert(file.relativePath).inserted else {
                throw OperationEngineError.invalidArchive
            }
            let (total, overflow) = byteCount.addingReportingOverflow(file.data.count)
            guard !overflow, total <= Self.maximumTreeBytes else { throw OperationEngineError.invalidArchive }
            byteCount = total
        }
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                guard !paths.contains(components.joined(separator: "/")) else {
                    throw OperationEngineError.invalidArchive
                }
            }
        }
    }

    private func validateContainedPath(_ candidate: URL, within anchor: URL) throws {
        let normalizedAnchor = anchor.standardizedFileURL
        let normalizedCandidate = candidate.standardizedFileURL
        guard Self.isLexicallyContained(normalizedCandidate, in: normalizedAnchor) else {
            throw OperationEngineError.unsafeDestination(candidate.path(percentEncoded: false))
        }
        let anchorValues = try normalizedAnchor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard anchorValues.isDirectory == true, anchorValues.isSymbolicLink != true else {
            throw OperationEngineError.unsafeDestination(candidate.path(percentEncoded: false))
        }

        let anchorPath = Self.normalizedPath(normalizedAnchor)
        let candidatePath = Self.normalizedPath(normalizedCandidate)
        let suffix = candidatePath == anchorPath ? "" : String(candidatePath.dropFirst(anchorPath.count + 1))
        var current = normalizedAnchor
        for component in suffix.split(separator: "/").map(String.init) {
            current.append(path: component)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) else {
                continue
            }
            guard values.isSymbolicLink != true else {
                throw OperationEngineError.unsafeDestination(candidate.path(percentEncoded: false))
            }
        }
        guard Self.isLexicallyContained(normalizedCandidate.resolvingSymlinksInPath(), in: normalizedAnchor.resolvingSymlinksInPath())
        else {
            throw OperationEngineError.unsafeDestination(candidate.path(percentEncoded: false))
        }
    }

    private func normalizePrivatePermissions(under root: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path(percentEncoded: false))
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else { throw OperationEngineError.unsafeSource(root.path(percentEncoded: false)) }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw OperationEngineError.unsupportedSourceItem(item.path(percentEncoded: false))
            }
            if values.isDirectory == true {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path(percentEncoded: false))
            } else if values.isRegularFile == true {
                let attributes = try fileManager.attributesOfItem(atPath: item.path(percentEncoded: false))
                let existing = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let permissions = existing & 0o111 == 0 ? 0o600 : 0o700
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: item.path(percentEncoded: false))
            }
        }
    }

    private func isContained(_ child: URL, in root: URL) -> Bool {
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private static let maximumTreeItems = 10_000
    private static let maximumTreeBytes = 384 * 1_024 * 1_024
    private static let maximumBackupMetadataBytes = 32 * 1_024 * 1_024

    private static func isSafeArchivePath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty
            && value.count <= 8_192
            && components.count <= 64
            && !value.hasPrefix("/")
            && !value.hasSuffix("/")
            && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedPath(lhs) == normalizedPath(rhs)
    }

    private static func isLexicallyContained(_ child: URL, in root: URL) -> Bool {
        let childPath = normalizedPath(child)
        let rootPath = normalizedPath(root)
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func persistableOutput(_ text: String) -> String {
        let redacted = SensitiveValueRedactor.redact(text)
        guard redacted.count > maximumPersistedOutputCharacters else { return redacted }
        return String(redacted.prefix(maximumPersistedOutputCharacters)) + "\n[output truncated]"
    }

    private static let maximumPersistedOutputCharacters = 60_000
}

public typealias OperationEngine = OperationExecutor

enum OperationEngineError: LocalizedError, Sendable {
    case malformedStep(String)
    case unsafeDestination(String)
    case unsafeSource(String)
    case commandNotAllowed(String)
    case commandArgumentsNotAllowed(String)
    case commandFailed(String, Int32, String)
    case dirtyGitBackup(String)
    case sourceTooLarge
    case unsupportedSourceItem(String)
    case invalidArchive
    case unsafeWorkingDirectory(String)
    case sourceChangedAfterReview
    case unprovableDestination(String, String)

    var errorDescription: String? {
        switch self {
        case .malformedStep(let title): "The operation step \"\(title)\" is incomplete."
        case .unsafeDestination(let path):
            "Agent Tooling refused to write outside its managed library or a supported client skill folder: \(path)"
        case .unsafeSource(let path): "Agent Tooling refused to copy content outside its managed local library: \(path)"
        case .commandNotAllowed(let command): "Agent Tooling refused to run an unapproved executable: \(command)"
        case .commandArgumentsNotAllowed(let command):
            "Agent Tooling refused unapproved arguments for \(command). Refresh the source or create a new reviewed plan."
        case .commandFailed(let command, let status, let output): "\(command) exited with status \(status). \(output)"
        case .dirtyGitBackup(let path):
            "The local Git backup at \(path) has uncommitted or untracked changes. Review, commit, or discard them before exporting again."
        case .sourceTooLarge: "The source contains too many files or exceeds Agent Tooling's safe copy limit."
        case .unsupportedSourceItem(let path):
            "The source contains a symbolic link or unsupported file at \(path). Agent Tooling copies only regular files and directories."
        case .invalidArchive: "Agent Tooling refused an invalid encrypted archive payload."
        case .unsafeWorkingDirectory(let path):
            "Agent Tooling refused to run a command from an unreviewed or unavailable project folder: \(path)"
        case .sourceChangedAfterReview:
            "The source changed after it was reviewed. Refresh the plan and inspect the new contents before trying again."
        case .unprovableDestination(let path, let reason):
            "Agent Tooling stopped rather than overwrite \(path), which it cannot prove it installed. \(reason)"
        }
    }
}
