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

/// One discovered skill offered for adoption, paired with the on-disk source a
/// setup check actually observed. Adoption never guesses a location: a skill
/// the scan could not place is reported and skipped rather than searched for.
public struct SkillAdoptionCandidate: Sendable {
    public var skill: Skill
    public var sourcePath: String?

    public init(skill: Skill, sourcePath: String?) {
        self.skill = skill
        self.sourcePath = sourcePath
    }
}

/// A candidate left out of an adoption plan, with the reason a person can act
/// on. One unusable skill never cancels the rest of the batch.
public struct SkillAdoptionRejection: Identifiable, Hashable, Sendable {
    public let id: String
    public var displayName: String
    public var reason: String

    public init(id: String, displayName: String, reason: String) {
        self.id = id
        self.displayName = displayName
        self.reason = reason
    }
}

/// A prepared adoption. Nothing has entered the managed library yet: the
/// reviewed copy waits in a hidden staging folder until the plan is approved,
/// and `discardAdoption` removes it when it is not.
public struct SkillAdoption: Sendable {
    public var plan: OperationPlan
    public var skills: [Skill]
    public var rejections: [SkillAdoptionRejection]
    var stagedLibraryURL: URL
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
    public static let maximumAdoptionBatch = 500

    /// Mirrors the operation engine's copy limits so an oversized batch fails
    /// while it is still only a plan instead of part-way through execution.
    private static let maximumStagedLibraryItems = 10_000
    private static let maximumStagedLibraryBytes = 384 * 1_024 * 1_024
    private static let maximumAdoptedSkillItems = 2_000
    private static let maximumAdoptedSkillBytes = 32 * 1_024 * 1_024
    private static let adoptionStagingPrefix = ".adoption-"

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

    /// Adopts a Codex-generated package only after the person has reviewed it.
    /// The staged bytes are fingerprinted again immediately before copying so
    /// the review cannot silently diverge from the package saved to the local
    /// library.
    public func adoptCodexDraft(_ result: CodexSkillDraftResult) throws -> CreatedSkill {
        let source = result.packageURL.standardizedFileURL
        let draftsRoot = store.cacheURL.appending(path: "skill-drafts", directoryHint: .isDirectory).standardizedFileURL
        let sourcePath = normalizedPath(source)
        let requestDirectory = source.deletingLastPathComponent().standardizedFileURL
        let requestIDText = String(requestDirectory.lastPathComponent.dropFirst("request-".count))
        guard requestDirectory.deletingLastPathComponent().standardizedFileURL == draftsRoot,
            requestDirectory.lastPathComponent.hasPrefix("request-"),
            UUID(uuidString: requestIDText) == result.request.id,
            source.lastPathComponent == "draft",
            result.skillURL.standardizedFileURL
                == source.appending(path: "skills/\(result.skillName)", directoryHint: .isDirectory).standardizedFileURL
        else { throw WorkspaceLibraryError.unsafeGeneratedDraft(sourcePath) }

        let currentFingerprint = try DirectoryFingerprint.sha256(
            of: source,
            fileManager: fileManager,
            maximumItems: 256,
            maximumBytes: 8 * 1_024 * 1_024
        )
        guard currentFingerprint == result.fingerprint else { throw WorkspaceLibraryError.generatedDraftChanged }

        let id = try Self.normalizedIdentifier(result.skillName)
        guard id == result.skillName, result.manifest.name == id else {
            throw WorkspaceLibraryError.invalidSkillDefinition(id)
        }
        let definition = source.appending(path: "skills/\(id)/SKILL.md", directoryHint: .notDirectory)
        let definitionText = try BoundedFileAccess.readUTF8(
            at: definition,
            maximumBytes: 512 * 1_024,
            allowSymbolicLink: false
        )
        guard definitionText == result.skillMarkdown else { throw WorkspaceLibraryError.generatedDraftChanged }

        let selectedTargets = Set(result.request.targets)
        guard !selectedTargets.isEmpty else { throw WorkspaceLibraryError.noInstallTargets }
        guard [.user, .project].contains(result.request.scope) else {
            throw WorkspaceLibraryError.unsupportedSkillScope(result.request.scope.displayName)
        }
        var placement = SkillDraft()
        placement.scope = result.request.scope
        placement.projectRoot = result.request.projectRoot ?? ""
        let projectRoot = try normalizedProjectRoot(for: placement)

        let managedRoot = try managedPackagesURL()
        let packageID = "local-\(id)"
        let destination = managedRoot.appending(path: packageID, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw WorkspaceLibraryError.alreadyExists(id)
        }
        let staging = managedRoot.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { removeTransientItemIfPresent(staging) }
        try fileManager.copyItem(at: source, to: staging)
        try validateStagedPackage(staging, skillID: id)
        let copiedFingerprint = try DirectoryFingerprint.sha256(
            of: staging,
            fileManager: fileManager,
            maximumItems: 256,
            maximumBytes: 8 * 1_024 * 1_024
        )
        guard copiedFingerprint == result.fingerprint else { throw WorkspaceLibraryError.generatedDraftChanged }
        try fileManager.moveItem(at: staging, to: destination)

        let installedClients = selectedTargets.sorted { $0.rawValue < $1.rawValue }.map {
            ClientState(client: $0, state: .pending, detail: "Generated locally · ready to install")
        }
        let skillURL = destination.appending(path: "skills/\(id)", directoryHint: .isDirectory)
        let skill = Skill(
            id: id,
            name: id,
            displayName: displayName(for: id),
            summary: result.description,
            bundle: packageID,
            scope: result.request.scope.displayName,
            owned: true,
            triggers: [],
            negativeTrigger: "",
            files: try relativeFiles(in: skillURL),
            clients: installedClients,
            validationCount: 0,
            projectRoot: projectRoot,
            authoringOrigin: .codexGenerated
        )
        return CreatedSkill(skill: skill, packageURL: destination, skillURL: skillURL)
    }

    /// Prepares one reviewable plan that copies discovered skills into the
    /// managed library. A client's own copy is never moved or removed: the
    /// library gains a managed package that then becomes the canonical source
    /// for installing, editing, and backing that skill up.
    ///
    /// The operation engine only accepts a copy whose source already sits
    /// inside the managed library, so the reviewed bytes are staged there first
    /// and the plan replaces the library with that exact fingerprinted copy.
    /// Every existing package is carried forward unchanged.
    ///
    /// `reservedIdentifiers` are the names other records outside this batch
    /// already answer to. A plugin-provided skill loses its namespace when it
    /// becomes portable, and two different skills must never end up sharing the
    /// resulting name.
    public func adoptionPlan(
        for candidates: [SkillAdoptionCandidate],
        reservedIdentifiers: Set<String> = []
    ) throws -> SkillAdoption {
        guard !candidates.isEmpty else {
            throw WorkspaceLibraryError.noAdoptableSkills("Select at least one discovered skill.")
        }
        guard candidates.count <= Self.maximumAdoptionBatch else {
            throw WorkspaceLibraryError.adoptionBatchTooLarge(Self.maximumAdoptionBatch)
        }
        let libraryRoot = try managedLibraryURL()
        _ = try managedPackagesURL()
        removeAbandonedAdoptionStaging(in: libraryRoot)
        let staging = libraryRoot.appending(path: "\(Self.adoptionStagingPrefix)\(UUID().uuidString)", directoryHint: .isDirectory)
        var isPrepared = false
        defer { if !isPrepared { removeTransientItemIfPresent(staging) } }
        try stageCurrentLibrary(from: libraryRoot, to: staging)

        let stagedPackages = staging.appending(path: "packages", directoryHint: .isDirectory)
        var adopted: [Skill] = []
        var rejections: [SkillAdoptionRejection] = []
        for candidate in candidates {
            do {
                adopted.append(
                    try stageAdoptedPackage(for: candidate, in: stagedPackages, reservedIdentifiers: reservedIdentifiers))
            } catch {
                rejections.append(
                    SkillAdoptionRejection(
                        id: candidate.skill.id,
                        displayName: candidate.skill.displayName,
                        reason: error.localizedDescription
                    ))
            }
        }
        guard !adopted.isEmpty else { throw WorkspaceLibraryError.noAdoptableSkills(Self.skippedSummary(rejections)) }

        try normalizePrivatePermissions(under: staging)
        let fingerprint = try DirectoryFingerprint.sha256(
            of: staging,
            fileManager: fileManager,
            maximumItems: Self.maximumStagedLibraryItems,
            maximumBytes: Self.maximumStagedLibraryBytes
        )
        let plan = OperationPlan(
            kind: .createSkill,
            title: adopted.count == 1 ? "Adopt \(adopted.first?.displayName ?? "")" : "Adopt \(adopted.count) skills",
            summary: Self.adoptionSummary(adopted: adopted, rejections: rejections),
            scope: .user,
            steps: [
                OperationStep(
                    kind: .copyDirectory,
                    title: "Add \(adopted.count) skill\(adopted.count == 1 ? "" : "s") to the managed library",
                    detail:
                        "Replaces the managed package library with the reviewed copy prepared here. It carries every existing managed package forward unchanged and adds \(Self.nameList(adopted.map(\.displayName))). The previous library is kept as a rollback copy.",
                    sourcePath: staging.path(percentEncoded: false),
                    sourceFingerprint: fingerprint,
                    destinationPath: store.libraryURL.path(percentEncoded: false),
                    stopsOnFailure: true
                )
            ],
            requiresConfirmation: true
        )
        isPrepared = true
        return SkillAdoption(plan: plan, skills: adopted, rejections: rejections, stagedLibraryURL: staging)
    }

    /// Removes the staged copy an unapproved adoption prepared. An approved
    /// adoption already replaced the library, so a missing folder is expected.
    public func discardAdoption(_ adoption: SkillAdoption) {
        removeTransientItemIfPresent(adoption.stagedLibraryURL)
    }

    /// Copies the library's current visible contents into the replacement.
    /// Hidden entries are another operation's transient staging or rollback
    /// copies, so they are left behind rather than promoted.
    private func stageCurrentLibrary(from libraryRoot: URL, to staging: URL) throws {
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: libraryRoot,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw WorkspaceLibraryError.unsafeManagedLibrary(item.path(percentEncoded: false))
            }
            try fileManager.copyItem(at: item, to: staging.appending(path: item.lastPathComponent))
        }
        try fileManager.createDirectory(
            at: staging.appending(path: "packages", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    /// Stages one discovered skill as a portable package inside the replacement
    /// library. Anything the operation engine would later refuse — a symbolic
    /// link, a missing source, a definition the managed-library checker rejects
    /// — is refused here so the rest of the batch can continue.
    private func stageAdoptedPackage(
        for candidate: SkillAdoptionCandidate,
        in stagedPackages: URL,
        reservedIdentifiers: Set<String>
    ) throws -> Skill {
        guard !candidate.skill.owned else { throw WorkspaceLibraryError.adoptionAlreadyManaged(candidate.skill.id) }
        guard let rawPath = candidate.sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            throw WorkspaceLibraryError.adoptionSourceUnknown
        }
        let source = URL(fileURLWithPath: rawPath).standardizedFileURL
        let sourceValues = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues?.isSymbolicLink != true else { throw WorkspaceLibraryError.adoptionSourceLinked(rawPath) }
        guard sourceValues?.isDirectory == true else { throw WorkspaceLibraryError.adoptionSourceMissing(rawPath) }

        let id = try adoptedIdentifier(for: candidate.skill)
        guard !reservedIdentifiers.contains(id) else { throw WorkspaceLibraryError.adoptionIdentifierTaken(id) }
        let packageID = "local-\(id)"
        let packageURL = stagedPackages.appending(path: packageID, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: packageURL.path(percentEncoded: false)) else {
            throw WorkspaceLibraryError.alreadyExists(id)
        }
        // Fingerprinting the client's folder before copying is the symbolic
        // link and size gate: it refuses exactly what the engine would refuse
        // at execution, while the source is still only being inspected.
        _ = try DirectoryFingerprint.sha256(
            of: source,
            fileManager: fileManager,
            maximumItems: Self.maximumAdoptedSkillItems,
            maximumBytes: Self.maximumAdoptedSkillBytes
        )

        var isStaged = false
        defer { if !isStaged { removeTransientItemIfPresent(packageURL) } }
        let skillURL =
            packageURL
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: skillURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: skillURL)
        try writePortablePackageManifest(manifestName: id, displayName: displayName(for: id), packageURL: packageURL)
        try validateStagedPackage(packageURL, skillID: id)
        _ = try validateSkillDefinition(at: skillURL.appending(path: "SKILL.md", directoryHint: .notDirectory), id: id)
        let files = try relativeFiles(in: skillURL)
        isStaged = true

        // Adoption inherits the clients that already report the skill, so a
        // later install refreshes those copies from the managed source instead
        // of claiming targets the skill was never present in.
        let presentClients = candidate.skill.clients.filter(\.reportsLocalPresence)
        return Skill(
            id: id,
            name: id,
            displayName: displayName(for: id),
            summary: candidate.skill.summary,
            bundle: packageID,
            scope: ToolingScope.user.displayName,
            owned: true,
            triggers: [],
            negativeTrigger: "",
            files: files,
            clients: presentClients.isEmpty ? candidate.skill.clients : presentClients,
            validationCount: 0
        )
    }

    /// A discovered skill can be namespaced by the plugin that provides it
    /// (`plugin:skill`). The managed library is portable, so adoption keeps
    /// only the skill's own portable name.
    private func adoptedIdentifier(for skill: Skill) throws -> String {
        let raw = skill.id.split(separator: ":").last.map(String.init) ?? skill.id
        return try Self.normalizedIdentifier(raw)
    }

    /// An adoption that was prepared but never approved leaves its staged copy
    /// behind when the app quits. Only one plan can await review at a time, so
    /// any staging folder still present belongs to an abandoned review.
    private func removeAbandonedAdoptionStaging(in libraryRoot: URL) {
        let names = (try? fileManager.contentsOfDirectory(atPath: libraryRoot.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(Self.adoptionStagingPrefix) {
            removeTransientItemIfPresent(libraryRoot.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// Applies the same private permissions the operation engine applies to a
    /// staged copy. Doing it before the fingerprint is taken keeps the reviewed
    /// value equal to the one the engine recomputes at execution.
    private func normalizePrivatePermissions(under root: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path(percentEncoded: false))
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else { throw WorkspaceLibraryError.unsafeManagedLibrary(root.path(percentEncoded: false)) }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw WorkspaceLibraryError.unsafeManagedLibrary(item.path(percentEncoded: false))
            }
            let path = item.path(percentEncoded: false)
            if values.isDirectory == true {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            } else if values.isRegularFile == true {
                let existing = (try fileManager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                try fileManager.setAttributes([.posixPermissions: existing & 0o111 == 0 ? 0o600 : 0o700], ofItemAtPath: path)
            }
        }
    }

    private static func adoptionSummary(adopted: [Skill], rejections: [SkillAdoptionRejection]) -> String {
        let base =
            "Copy \(adopted.count) discovered skill\(adopted.count == 1 ? "" : "s") into Agent Tooling's managed library. Each client keeps its own files; the library copy becomes the one Agent Tooling installs, edits, and backs up."
        guard !rejections.isEmpty else { return base }
        return "\(base) \(skippedSummary(rejections))"
    }

    private static func skippedSummary(_ rejections: [SkillAdoptionRejection]) -> String {
        guard !rejections.isEmpty else { return "" }
        let listed = rejections.prefix(3).map { "\($0.displayName) — \($0.reason)" }.joined(separator: " ")
        let remaining = rejections.count - min(3, rejections.count)
        let suffix = remaining > 0 ? " \(remaining) more \(remaining == 1 ? "was" : "were") skipped." : ""
        return "Skipped \(rejections.count) skill\(rejections.count == 1 ? "" : "s"): \(listed)\(suffix)"
    }

    private static func nameList(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names.first ?? ""
        case 2: names.joined(separator: " and ")
        default: "\(names.prefix(2).joined(separator: ", ")), and \(names.count - 2) more"
        }
    }

    public func updateSkill(_ existing: Skill, from draft: SkillDraft) throws -> CreatedSkill {
        guard existing.owned else { throw WorkspaceLibraryError.notManaged(existing.id) }
        guard existing.authoringOrigin != .codexGenerated else {
            throw WorkspaceLibraryError.generatedSkillRequiresSourceEdit(existing.id)
        }
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
        try validateSkillDefinition(
            at: skillURL(for: skill).appending(path: "SKILL.md", directoryHint: .notDirectory),
            id: skill.id
        )
    }

    /// The managed-library checker addressed by file rather than by record, so
    /// a staged package can be held to the same rule before a plan offers it.
    private func validateSkillDefinition(at file: URL, id: String) throws -> Int {
        let contents = try BoundedFileAccess.readUTF8(at: file, allowSymbolicLink: false)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            let closingDelimiter = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
            closingDelimiter > 1
        else {
            throw WorkspaceLibraryError.invalidSkillDefinition(id)
        }
        let frontmatter = lines[1..<closingDelimiter]
        guard frontmatter.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "name: \(id)" }),
            frontmatter.contains(where: {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.hasPrefix("description:") && line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces).count > 2
            })
        else { throw WorkspaceLibraryError.invalidSkillDefinition(id) }
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

    /// The managed library root, checked the way the packages folder is.
    /// Adoption replaces this whole folder through a reviewed plan, so it must
    /// never be a symbolic link or a file.
    private func managedLibraryURL() throws -> URL {
        let root = store.libraryURL.standardizedFileURL
        let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw WorkspaceLibraryError.unsafeManagedLibrary(root.path(percentEncoded: false))
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let createdValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard createdValues.isDirectory == true, createdValues.isSymbolicLink != true else {
            throw WorkspaceLibraryError.unsafeManagedLibrary(root.path(percentEncoded: false))
        }
        return root
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
    case unsafeGeneratedDraft(String)
    case generatedDraftChanged
    case generatedSkillRequiresSourceEdit(String)
    case replacementRollbackFailed(String, String, String)
    case missingRollbackCopy(String)
    case adoptionSourceUnknown
    case adoptionSourceLinked(String)
    case adoptionSourceMissing(String)
    case adoptionAlreadyManaged(String)
    case adoptionIdentifierTaken(String)
    case adoptionBatchTooLarge(Int)
    case noAdoptableSkills(String)

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
        case .unsafeGeneratedDraft(let path): "The generated skill draft is outside Agent Tooling's private staging folder: \(path)"
        case .generatedDraftChanged: "The generated skill changed after review. Generate and review a fresh draft before saving it."
        case .generatedSkillRequiresSourceEdit(let identifier):
            "\(identifier) contains Codex-authored source files. Edit its source directly so the template editor cannot discard them."
        case .replacementRollbackFailed(let path, let replacement, let rollback):
            "Updating the managed package at \(path) failed, and restoring its previous copy also failed. Replacement error: \(replacement). Restore error: \(rollback)."
        case .missingRollbackCopy(let path): "The previous managed package needed for rollback is missing at \(path)."
        case .adoptionSourceUnknown: "The last setup check did not record where its files are. Check setup again, then adopt it."
        case .adoptionSourceLinked(let path): "Its source at \(path) is a symbolic link. Adopt the folder it points to instead."
        case .adoptionSourceMissing(let path): "Its source folder at \(path) is no longer on this Mac."
        case .adoptionAlreadyManaged(let identifier): "\(identifier) is already managed by Agent Tooling."
        case .adoptionIdentifierTaken(let identifier):
            "Another skill on this Mac already uses the portable name \(identifier). Adopt that one instead, or rename this one first."
        case .adoptionBatchTooLarge(let maximum): "Adopt at most \(maximum) skills at a time."
        case .noAdoptableSkills(let detail): "No selected skill could be adopted. \(detail)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
