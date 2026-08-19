import Foundation

public struct CreatedSkill: Sendable {
    public var skill: Skill
    public var packageURL: URL
    public var skillURL: URL
    var rollbackPackageURL: URL?

    public init(
        skill: Skill,
        packageURL: URL,
        skillURL: URL,
        rollbackPackageURL: URL? = nil
    ) {
        self.skill = skill
        self.packageURL = packageURL
        self.skillURL = skillURL
        self.rollbackPackageURL = rollbackPackageURL
    }
}

/// Owns only the app's managed package library. Imports and native client
/// locations remain separate so a user can work entirely without Git.
public final class WorkspaceLibrary {
    public static let maximumIdentifierLength = 64
    public static let maximumPurposeLength = 4_096
    public static let maximumTriggerCount = 20
    public static let maximumTriggerLength = 512
    public static let maximumNegativeTriggerLength = 4_096
    public static let maximumProjectPathLength = 4_096

    public let store: WorkspaceStore
    private let fileManager: FileManager

    public init(store: WorkspaceStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    public var packagesURL: URL {
        store.libraryURL.appending(path: "packages", directoryHint: .isDirectory)
    }

    public func createSkill(from draft: SkillDraft) throws -> CreatedSkill {
        try validate(draft)
        let packagesURL = try managedPackagesURL()
        let id = try Self.normalizedIdentifier(draft.name)
        let projectRoot = try normalizedProjectRoot(for: draft)
        let packageID = "local-\(id)"
        let packageURL = packagesURL.appending(path: packageID, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: packageURL.path(percentEncoded: false)) else {
            throw WorkspaceLibraryError.alreadyExists(id)
        }

        let stagingURL = packagesURL.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { removeTransientItemIfPresent(stagingURL) }
        let stagedSkillURL =
            stagingURL
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)

        try fileManager.createDirectory(at: stagedSkillURL, withIntermediateDirectories: true)
        try write(skillMarkdown(id: id, draft: draft), to: stagedSkillURL.appending(path: "SKILL.md", directoryHint: .notDirectory))

        if draft.includeScript {
            let scripts = stagedSkillURL.appending(path: "scripts", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
            try writeExecutableScript(
                "#!/bin/sh\nset -eu\nprintf '%s\\n' 'helper.sh has not been implemented for this skill.' >&2\nexit 64\n",
                to: scripts.appending(path: "helper.sh", directoryHint: .notDirectory)
            )
        }
        if draft.includeReference {
            let references = stagedSkillURL.appending(path: "references", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: references, withIntermediateDirectories: true)
            try write(
                "# Reference\n\nAdd long-form, on-demand guidance here.\n",
                to: references.appending(path: "reference.md", directoryHint: .notDirectory))
        }

        try writePortablePackageManifest(manifestName: id, displayName: displayName(for: id), packageURL: stagingURL)
        try validateStagedPackage(stagingURL, skillID: id)
        try fileManager.moveItem(at: stagingURL, to: packageURL)

        let clients = draft.selectedTargets.sorted { $0.rawValue < $1.rawValue }.map {
            ClientState(client: $0, state: .pending, detail: "Created locally · ready to install")
        }
        let skill = Skill(
            id: id,
            name: id,
            displayName: displayName(for: id),
            summary: draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines),
            bundle: packageID,
            scope: draft.scope.displayName,
            owned: true,
            triggers: draft.triggers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            negativeTrigger: draft.negativeTrigger.trimmingCharacters(in: .whitespacesAndNewlines),
            files: try relativeFiles(in: packageURL.appending(path: "skills/\(id)", directoryHint: .isDirectory)),
            clients: clients,
            validationCount: 0,
            projectRoot: projectRoot
        )
        return CreatedSkill(
            skill: skill,
            packageURL: packageURL,
            skillURL: packageURL.appending(path: "skills/\(id)", directoryHint: .isDirectory)
        )
    }

    public func updateSkill(_ existing: Skill, from draft: SkillDraft) throws -> CreatedSkill {
        guard existing.owned else { throw WorkspaceLibraryError.notManaged(existing.id) }
        try validate(draft)
        let packagesURL = try managedPackagesURL()
        let id = try Self.normalizedIdentifier(draft.name)
        let projectRoot = try normalizedProjectRoot(for: draft)
        guard id == existing.id else { throw WorkspaceLibraryError.cannotRename(existing.id) }
        let packageURL = packagesURL.appending(path: existing.bundle, directoryHint: .isDirectory)
        let originalSkillURL = packageURL.appending(path: "skills/\(id)", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: originalSkillURL.path(percentEncoded: false)) else {
            throw WorkspaceLibraryError.missingSkillSource(existing.id)
        }

        _ = try DirectoryFingerprint.sha256(
            of: packageURL, fileManager: fileManager, maximumItems: 10_000, maximumBytes: 64 * 1_024 * 1_024)
        let stagingURL = packagesURL.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { removeTransientItemIfPresent(stagingURL) }
        try fileManager.copyItem(at: packageURL, to: stagingURL)
        let stagedSkillURL = stagingURL.appending(path: "skills/\(id)", directoryHint: .isDirectory)

        try write(skillMarkdown(id: id, draft: draft), to: stagedSkillURL.appending(path: "SKILL.md", directoryHint: .notDirectory))
        if draft.includeScript {
            let script = stagedSkillURL.appending(path: "scripts/helper.sh")
            if !fileManager.fileExists(atPath: script.path(percentEncoded: false)) {
                try fileManager.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writeExecutableScript(
                    "#!/bin/sh\nset -eu\nprintf '%s\\n' 'helper.sh has not been implemented for this skill.' >&2\nexit 64\n", to: script)
            } else {
                try ensureOwnerExecutable(at: script)
            }
        } else {
            try removeIfPresent(stagedSkillURL.appending(path: "scripts", directoryHint: .isDirectory))
        }
        if draft.includeReference {
            let reference = stagedSkillURL.appending(path: "references/reference.md")
            if !fileManager.fileExists(atPath: reference.path(percentEncoded: false)) {
                try fileManager.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
                try write("# Reference\n\nAdd long-form, on-demand guidance here.\n", to: reference)
            }
        } else {
            try removeIfPresent(stagedSkillURL.appending(path: "references", directoryHint: .isDirectory))
        }
        try writePortablePackageManifest(manifestName: id, displayName: displayName(for: id), packageURL: stagingURL)
        try removeIfPresent(stagingURL.appending(path: "gemini-extension.json", directoryHint: .notDirectory))
        try removeIfPresent(stagingURL.appending(path: "GEMINI.md", directoryHint: .notDirectory))
        try removeIfPresent(stagingURL.appending(path: "extensions", directoryHint: .isDirectory))

        var updated = existing
        updated.summary = draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.scope = draft.scope.displayName
        updated.triggers = draft.triggers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        updated.negativeTrigger = draft.negativeTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.projectRoot = projectRoot
        try validateStagedPackage(stagingURL, skillID: id)
        updated.files = try relativeFiles(in: stagedSkillURL)
        updated.clients = draft.selectedTargets.sorted { $0.rawValue < $1.rawValue }.map { client in
            existing.clients.first(where: { $0.client == client })
                ?? ClientState(client: client, state: .pending, detail: "Edited locally · ready to install")
        }
        let rollbackPackageURL = try replacePackage(at: packageURL, with: stagingURL)
        return CreatedSkill(
            skill: updated,
            packageURL: packageURL,
            skillURL: originalSkillURL,
            rollbackPackageURL: rollbackPackageURL
        )
    }

    /// Completes an update after the matching desired-state snapshot has been
    /// saved. A cleanup failure does not invalidate the installed new package;
    /// the retained private copy is reported so the caller can surface it.
    public func commitUpdate(_ result: CreatedSkill) -> String? {
        guard let backup = result.rollbackPackageURL else { return nil }
        do {
            try validateTransactionURL(backup)
            try fileManager.removeItem(at: backup)
            return nil
        } catch {
            return
                "The skill was updated, but its previous managed copy could not be removed from \(backup.path(percentEncoded: false)): \(error.localizedDescription)"
        }
    }

    /// Restores the previous package when desired-state persistence fails after
    /// an update. Both paths are constrained to the private packages folder.
    @discardableResult
    public func rollbackUpdate(_ result: CreatedSkill) throws -> String? {
        guard let backup = result.rollbackPackageURL else { return nil }
        try validateTransactionURL(result.packageURL)
        try validateTransactionURL(backup)
        guard fileManager.fileExists(atPath: backup.path(percentEncoded: false)) else {
            throw WorkspaceLibraryError.missingRollbackCopy(backup.path(percentEncoded: false))
        }
        let failedReplacement = packagesURL.appending(path: ".failed-(UUID().uuidString)", directoryHint: .isDirectory)
        try validateTransactionURL(failedReplacement)
        if fileManager.fileExists(atPath: result.packageURL.path(percentEncoded: false)) {
            do {
                try fileManager.moveItem(at: result.packageURL, to: failedReplacement)
            } catch {
                throw WorkspaceLibraryError.replacementRollbackFailed(
                    result.packageURL.path(percentEncoded: false),
                    "The desired-state snapshot could not be saved.",
                    "The replacement could not be preserved before restoring the previous copy: \(error.localizedDescription)"
                )
            }
        }
        do {
            try fileManager.moveItem(at: backup, to: result.packageURL)
        } catch let restoreError {
            var recoveryDescription = ""
            if fileManager.fileExists(atPath: failedReplacement.path(percentEncoded: false)),
                !fileManager.fileExists(atPath: result.packageURL.path(percentEncoded: false))
            {
                do {
                    try fileManager.moveItem(at: failedReplacement, to: result.packageURL)
                    recoveryDescription =
                        " The edited package was returned to its original location; the previous copy remains at \(backup.path(percentEncoded: false))."
                } catch {
                    recoveryDescription =
                        " The edited package also could not be returned from \(failedReplacement.path(percentEncoded: false)): \(error.localizedDescription)"
                }
            }
            throw WorkspaceLibraryError.replacementRollbackFailed(
                result.packageURL.path(percentEncoded: false),
                "The desired-state snapshot could not be saved.",
                restoreError.localizedDescription + recoveryDescription
            )
        }
        guard fileManager.fileExists(atPath: failedReplacement.path(percentEncoded: false)) else { return nil }
        do {
            try fileManager.removeItem(at: failedReplacement)
            return nil
        } catch {
            return
                "The previous skill was restored, but the rejected edited copy remains at \(failedReplacement.path(percentEncoded: false)): \(error.localizedDescription)"
        }
    }

    /// Removes a newly authored package if its desired-state record cannot be
    /// committed. This never accepts a path outside the private package root.
    public func rollbackCreation(_ result: CreatedSkill) throws {
        try validateTransactionURL(result.packageURL)
        guard fileManager.fileExists(atPath: result.packageURL.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: result.packageURL)
    }

    public func skillURL(for skill: Skill) -> URL {
        packagesURL
            .appending(path: skill.bundle, directoryHint: .isDirectory)
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: skill.id, directoryHint: .isDirectory)
    }

    public func installPlan(for skill: Skill, targets: Set<ClientKind>, homeURL: URL, includeFreshSessionCanary: Bool = false) throws
        -> OperationPlan
    {
        let source = skillURL(for: skill)
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw WorkspaceLibraryError.missingSkillSource(skill.id)
        }
        guard !targets.isEmpty else { throw WorkspaceLibraryError.noInstallTargets }
        let sourceFingerprint = try DirectoryFingerprint.sha256(of: source, fileManager: fileManager)
        let scope = ToolingScope.allCases.first(where: { $0.displayName == skill.scope }) ?? .user
        guard [.user, .project].contains(scope) else { throw WorkspaceLibraryError.unsupportedSkillScope(skill.scope) }
        let projectRoot: URL?
        if scope == .project {
            guard let rawRoot = skill.projectRoot?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                throw WorkspaceLibraryError.missingProjectRoot
            }
            let directRoot = URL(fileURLWithPath: rawRoot).standardizedFileURL
            let values = try? directRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else {
                throw WorkspaceLibraryError.invalidProjectRoot(rawRoot)
            }
            let root = directRoot.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else {
                throw WorkspaceLibraryError.invalidProjectRoot(rawRoot)
            }
            projectRoot = root
        } else {
            projectRoot = nil
        }
        let selected = targets
        let steps = selected.sorted { $0.rawValue < $1.rawValue }.flatMap { client -> [OperationStep] in
            [
                OperationStep(
                    kind: .copyDirectory,
                    title: "Install \(skill.displayName) in \(client.rawValue)",
                    detail:
                        "Copies the portable skill from Agent Tooling's managed library into \(scope == .project ? "the selected project's" : "this Mac's") native \(client.rawValue) skill folder.",
                    sourcePath: source.path(percentEncoded: false),
                    sourceFingerprint: sourceFingerprint,
                    destinationPath: clientSkillURL(
                        client,
                        skillID: skill.id,
                        scope: scope,
                        projectRoot: projectRoot,
                        homeURL: homeURL
                    ).path(percentEncoded: false),
                    projectRootPath: projectRoot?.path(percentEncoded: false)
                )
            ]
        }
        let surfaces = selected.compactMap { client in
            switch client {
            case .claude: TargetSurface.claudeCode
            case .codex: TargetSurface.codexCLI
            case .gemini: TargetSurface.geminiCLI
            }
        }
        var planSteps = steps
        if includeFreshSessionCanary {
            for client in selected.sorted(by: { $0.rawValue < $1.rawValue }) {
                let detail: String
                switch client {
                case .claude: detail = "Start a fresh Claude Code session and confirm the skill is discoverable."
                case .codex: detail = "Start a fresh Codex session and confirm the skill is discoverable."
                case .gemini: detail = "Start or reload Gemini CLI and use /skills list to confirm the skill before invoking it."
                }
                planSteps.append(
                    OperationStep(
                        kind: .manual, title: "Fresh-session canary for \(client.rawValue)", detail: detail, requiresUserAction: true))
            }
        }
        return OperationPlan(
            kind: .installSkill,
            title: "Install \(skill.displayName)",
            summary:
                "Install a locally authored skill into \(selected.count) selected target\(selected.count == 1 ? "" : "s") without GitHub.",
            targetSurfaces: surfaces,
            scope: scope,
            steps: planSteps,
            requiresConfirmation: true
        )
    }

    private func clientSkillURL(
        _ client: ClientKind,
        skillID: String,
        scope: ToolingScope = .user,
        projectRoot: URL? = nil,
        homeURL: URL
    ) -> URL {
        let root = scope == .project ? (projectRoot ?? homeURL) : homeURL
        switch client {
        case .claude:
            return root.appending(path: ".claude/skills/\(skillID)", directoryHint: .isDirectory)
        case .codex:
            return root.appending(path: ".agents/skills/\(skillID)", directoryHint: .isDirectory)
        case .gemini:
            return root.appending(path: ".gemini/skills/\(skillID)", directoryHint: .isDirectory)
        }
    }

    public func importRepositorySource(at url: URL) throws -> ToolingSource {
        let directURL = url.standardizedFileURL
        let directValues = try? directURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard directValues?.isSymbolicLink != true else {
            throw WorkspaceLibraryError.unsafeSource(directURL.path(percentEncoded: false))
        }
        let resolvedURL = directURL.resolvingSymlinksInPath().standardizedFileURL
        let path = resolvedURL.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        let homePath = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        guard path.count <= Self.maximumProjectPathLength,
            path != "/",
            path != homePath,
            fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw WorkspaceLibraryError.missingSource(path)
        }
        let name = resolvedURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
            name.count <= 128,
            !Self.containsUnsafeControlCharacter(name)
        else {
            throw WorkspaceLibraryError.unsafeSource(path)
        }
        let isGit = fileManager.fileExists(atPath: resolvedURL.appending(path: ".git").path(percentEncoded: false))
        return ToolingSource(
            name: name,
            kind: isGit ? .gitRepository : .localFolder,
            location: path,
            isOptionalBackup: isGit,
            trustSummary: "Local source — review its packages before installing"
        )
    }

    public func validateSkill(_ skill: Skill) throws -> Int {
        let file = skillURL(for: skill).appending(path: "SKILL.md", directoryHint: .notDirectory)
        let contents = try BoundedFileAccess.readUTF8(at: file, allowSymbolicLink: false)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            let closingDelimiter = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
            closingDelimiter > 1
        else {
            throw WorkspaceLibraryError.invalidSkillDefinition(skill.id)
        }
        let frontmatter = lines[1..<closingDelimiter]
        guard frontmatter.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "name: \(skill.id)" }),
            frontmatter.contains(where: {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.hasPrefix("description:") && line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces).count > 2
            })
        else { throw WorkspaceLibraryError.invalidSkillDefinition(skill.id) }
        return 3
    }

    public static func normalizedIdentifier(_ rawValue: String) throws -> String {
        let lowered =
            rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !lowered.isEmpty,
            lowered.count <= maximumIdentifierLength,
            lowered.unicodeScalars.allSatisfy({ allowed.contains($0) }),
            !lowered.hasPrefix("-"),
            !lowered.hasSuffix("-"),
            !lowered.contains("--")
        else {
            throw WorkspaceLibraryError.invalidIdentifier(rawValue)
        }
        return lowered
    }

    private func writePortablePackageManifest(manifestName: String, displayName: String, packageURL: URL) throws {
        let manifest: [String: Any] = [
            "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
            "name": manifestName,
            "description": "\(displayName), managed locally by Agent Tooling.",
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let destination = packageURL.appending(path: "plugin.json", directoryHint: .notDirectory)
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path(percentEncoded: false))
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func writeExecutableScript(_ contents: String, to url: URL) throws {
        try write(contents, to: url)
        try ensureOwnerExecutable(at: url)
    }

    private func ensureOwnerExecutable(at url: URL) throws {
        let path = url.path(percentEncoded: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    private func skillMarkdown(id: String, draft: SkillDraft) -> String {
        let triggerLines = draft.triggers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
            .joined(separator: "\n")
        return """
            ---
            name: \(id)
            description: \(yamlQuoted(draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines)))
            ---

            # \(displayName(for: id))

            ## When to use this skill

            \(triggerLines.isEmpty ? "Use this skill when the user asks for this reusable workflow." : triggerLines)

            ## When not to use this skill

            \(draft.negativeTrigger.trimmingCharacters(in: .whitespacesAndNewlines))

            ## Workflow

            1. Confirm the goal and the applicable scope.
            2. Inspect the relevant local state before making a change.
            3. Complete the requested workflow and report the verifiable result.
            """
    }

    private func relativeFiles(in root: URL) throws -> [String] {
        let files = BoundedFileAccess.relativeRegularFiles(under: root, fileManager: fileManager)
        guard files.contains("SKILL.md") else {
            throw WorkspaceLibraryError.invalidSkillDefinition(root.lastPathComponent)
        }
        return files
    }

    private func validateStagedPackage(_ packageURL: URL, skillID: String) throws {
        _ = try DirectoryFingerprint.sha256(
            of: packageURL,
            fileManager: fileManager,
            maximumItems: 10_000,
            maximumBytes: 64 * 1_024 * 1_024
        )
        let definition =
            packageURL
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: skillID, directoryHint: .isDirectory)
            .appending(path: "SKILL.md", directoryHint: .notDirectory)
        let values = try definition.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WorkspaceLibraryError.invalidSkillDefinition(skillID)
        }
    }

    private func displayName(for identifier: String) -> String {
        identifier.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private func yamlQuoted(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private func validate(_ draft: SkillDraft) throws {
        let purpose = draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggers = draft.triggers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let negativeTrigger = draft.negativeTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try Self.normalizedIdentifier(draft.name)
        guard !purpose.isEmpty else { throw WorkspaceLibraryError.missingPurpose }
        guard purpose.count <= Self.maximumPurposeLength else {
            throw WorkspaceLibraryError.fieldTooLong("Purpose", Self.maximumPurposeLength)
        }
        guard !triggers.isEmpty else { throw WorkspaceLibraryError.missingTrigger }
        guard triggers.count <= Self.maximumTriggerCount else {
            throw WorkspaceLibraryError.tooManyTriggers(Self.maximumTriggerCount)
        }
        guard triggers.allSatisfy({ $0.count <= Self.maximumTriggerLength }) else {
            throw WorkspaceLibraryError.fieldTooLong("Each trigger", Self.maximumTriggerLength)
        }
        guard !negativeTrigger.isEmpty else { throw WorkspaceLibraryError.missingNegativeTrigger }
        guard negativeTrigger.count <= Self.maximumNegativeTriggerLength else {
            throw WorkspaceLibraryError.fieldTooLong("The negative trigger", Self.maximumNegativeTriggerLength)
        }
        guard !([purpose, negativeTrigger] + triggers).contains(where: Self.containsUnsafeControlCharacter) else {
            throw WorkspaceLibraryError.unsupportedControlCharacter
        }
        guard !draft.syncClients || !draft.selectedTargets.isEmpty else { throw WorkspaceLibraryError.noInstallTargets }
        guard [.user, .project].contains(draft.scope) else { throw WorkspaceLibraryError.unsupportedSkillScope(draft.scope.displayName) }
        _ = try normalizedProjectRoot(for: draft)
    }

    private func normalizedProjectRoot(for draft: SkillDraft) throws -> String? {
        guard draft.scope == .project else { return nil }
        let rawRoot = draft.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawRoot.isEmpty else { throw WorkspaceLibraryError.missingProjectRoot }
        guard rawRoot.count <= Self.maximumProjectPathLength,
            rawRoot.hasPrefix("/"),
            !Self.containsUnsafeControlCharacter(rawRoot)
        else {
            throw WorkspaceLibraryError.invalidProjectRoot(rawRoot)
        }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL
        let directValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard directValues?.isSymbolicLink != true else { throw WorkspaceLibraryError.invalidProjectRoot(rawRoot) }
        let resolvedRoot = root.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedRoot.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw WorkspaceLibraryError.invalidProjectRoot(rawRoot)
        }
        return resolvedRoot.path(percentEncoded: false)
    }

    private static func containsUnsafeControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: url)
    }

    private func replacePackage(at destination: URL, with stagedPackage: URL) throws -> URL {
        let backup = packagesURL.appending(path: ".replaced-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: stagedPackage, to: destination)
        } catch {
            if !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                do {
                    try fileManager.moveItem(at: backup, to: destination)
                } catch let rollbackError {
                    throw WorkspaceLibraryError.replacementRollbackFailed(
                        destination.path(percentEncoded: false),
                        error.localizedDescription,
                        rollbackError.localizedDescription
                    )
                }
            }
            throw error
        }
        return backup
    }

    private func validateTransactionURL(_ url: URL) throws {
        let direct = url.standardizedFileURL
        let root = try managedPackagesURL().standardizedFileURL
        let parent = direct.deletingLastPathComponent().standardizedFileURL
        guard parent == root,
            !direct.lastPathComponent.isEmpty,
            direct.lastPathComponent != ".",
            direct.lastPathComponent != ".."
        else {
            throw WorkspaceLibraryError.unsafeManagedLibrary(direct.path(percentEncoded: false))
        }
        if fileManager.fileExists(atPath: direct.path(percentEncoded: false)) {
            let values = try direct.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw WorkspaceLibraryError.unsafeManagedLibrary(direct.path(percentEncoded: false))
            }
        }
    }

    private func managedPackagesURL() throws -> URL {
        let root = packagesURL.standardizedFileURL
        let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw WorkspaceLibraryError.unsafeManagedLibrary(root.path(percentEncoded: false))
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let createdValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard createdValues.isDirectory == true, createdValues.isSymbolicLink != true else {
            throw WorkspaceLibraryError.unsafeManagedLibrary(root.path(percentEncoded: false))
        }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let libraryRoot = normalizedPath(store.libraryURL.resolvingSymlinksInPath().standardizedFileURL)
        let resolvedPath = normalizedPath(resolved)
        var isDirectory: ObjCBool = false
        guard resolvedPath.hasPrefix(libraryRoot + "/"),
            fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw WorkspaceLibraryError.unsafeManagedLibrary(resolvedPath)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resolvedPath)
        return resolved
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func removeTransientItemIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            // A failed operation remains failed for its original reason. The
            // hidden staging directory is inside the private managed library
            // and will never be treated as an installable package.
        }
    }
}

public enum WorkspaceLibraryError: LocalizedError, Sendable {
    case invalidIdentifier(String)
    case alreadyExists(String)
    case missingSkillSource(String)
    case missingSource(String)
    case invalidSkillDefinition(String)
    case notManaged(String)
    case cannotRename(String)
    case noInstallTargets
    case missingPurpose
    case missingTrigger
    case missingNegativeTrigger
    case fieldTooLong(String, Int)
    case tooManyTriggers(Int)
    case unsupportedControlCharacter
    case missingProjectRoot
    case invalidProjectRoot(String)
    case unsupportedSkillScope(String)
    case unsafeSource(String)
    case unsafeManagedLibrary(String)
    case replacementRollbackFailed(String, String, String)
    case missingRollbackCopy(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            "\"\(value)\" is not a valid skill identifier. Use lowercase letters, numbers, and single hyphens."
        case .alreadyExists(let identifier): "The local library already contains a skill named \(identifier)."
        case .missingSkillSource(let identifier): "The managed local source for \(identifier) is missing."
        case .missingSource(let path): "The source folder at \(path) no longer exists."
        case .invalidSkillDefinition(let identifier): "The managed skill \(identifier) is missing required frontmatter."
        case .notManaged(let identifier): "\(identifier) is installed from another source and cannot be edited as a managed skill."
        case .cannotRename(let identifier): "Renaming \(identifier) is not supported. Create a new skill instead."
        case .noInstallTargets: "Choose at least one app before reviewing an installation."
        case .missingPurpose: "Describe what the skill should do before saving it."
        case .missingTrigger: "Add at least one example request that should activate the skill."
        case .missingNegativeTrigger: "Describe when the skill should not be used."
        case .fieldTooLong(let field, let maximum): "\(field) must be \(maximum) characters or fewer."
        case .tooManyTriggers(let maximum): "Add no more than \(maximum) example requests."
        case .unsupportedControlCharacter: "Skill text contains an unsupported control character."
        case .missingProjectRoot: "Choose a project folder for this project-scoped skill."
        case .invalidProjectRoot(let path): "The project folder at \(path) is unavailable."
        case .unsupportedSkillScope(let scope): "\(scope) is not a supported skill scope. Choose This Mac or Project."
        case .unsafeSource(let path): "The selected source is a symbolic link or unsafe folder: \(path)"
        case .unsafeManagedLibrary(let path): "The managed skill library is not a safe direct folder: \(path)"
        case .replacementRollbackFailed(let path, let replacement, let rollback):
            "Updating the managed package at \(path) failed, and restoring its previous copy also failed. Replacement error: \(replacement). Restore error: \(rollback)."
        case .missingRollbackCopy(let path): "The previous managed package needed for rollback is missing at \(path)."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
