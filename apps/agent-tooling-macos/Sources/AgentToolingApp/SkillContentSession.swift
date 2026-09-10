import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// Everything the Skills screen does that leaves the window: reading a skill's
/// stored files, writing an edited one back, admitting a new one, and asking a
/// public repository whether the skill it publishes has moved on.
///
/// A protocol rather than four calls, so a test can hand in an implementation
/// that answers from memory and never reads a content store, runs `git`, or
/// reaches the network.
protocol SkillContentServing: Sendable {
    /// Reads one revision's complete content for one skill. Reads only.
    func read(
        artifactID: ArtifactID, revisionID: WorkspaceObjectID,
        through service: WorkspaceApplicationService
    ) async throws -> WorkspaceSkillContentSnapshot

    /// Replaces the stored content of a skill this library maintains.
    func replace(
        _ tree: CapturedPackageTree, of artifactID: ArtifactID, expecting digest: ContentDigest,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws

    /// Admits a new standalone skill. Nothing is assigned and nothing installed.
    func admit(
        _ tree: CapturedPackageTree, named displayName: String,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws

    /// Fetches what a public repository publishes now. Network.
    func upstream(_ binding: SkillRepositoryBinding, cachedIn cacheRoot: URL) async throws -> PreparedStandaloneSkill
}

/// The real one: the workspace's own commands, and the same bounded Git fetch a
/// first run would use. It adds no path of its own to either.
struct LiveSkillContentService: SkillContentServing {
    func read(
        artifactID: ArtifactID, revisionID: WorkspaceObjectID,
        through service: WorkspaceApplicationService
    ) async throws -> WorkspaceSkillContentSnapshot {
        try await service.skillContent(artifactID: artifactID, revisionID: revisionID)
    }

    func replace(
        _ tree: CapturedPackageTree, of artifactID: ArtifactID, expecting digest: ContentDigest,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {
        let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
        _ = try await service.updateStandaloneSkill(
            .init(
                expectedRevisionID: revisionID, artifactID: artifactID,
                expectedContentDigest: digest, prepared: prepared),
            prepared: prepared)
    }

    func admit(
        _ tree: CapturedPackageTree, named displayName: String,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {
        let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
        _ = try await service.intakeStandaloneSkill(
            .init(expectedRevisionID: revisionID, displayName: displayName, prepared: prepared),
            prepared: prepared)
    }

    func upstream(_ binding: SkillRepositoryBinding, cachedIn cacheRoot: URL) async throws -> PreparedStandaloneSkill {
        try await WorkspaceSkillPreparation.fetchUpstream(binding: binding, cacheURL: cacheRoot)
    }
}

extension EnvironmentValues {
    @Entry var skillContentService: any SkillContentServing = LiveSkillContentService()
}

/// One skill's stored files, and the three things a person can do to them.
///
/// Reading is never automatic and never blocks the list: the pane asks for a
/// skill's source when a person opens it, the work happens off this actor, and
/// a skill whose bytes this workspace does not hold says so instead of showing
/// somebody else's.
@MainActor @Observable
final class SkillContentSession {
    /// What a check of a followed repository concluded, in the words a person
    /// reads. Nothing here changes a file; applying is a separate decision.
    struct UpstreamStatus: Equatable {
        let title: String
        let detail: String
        let isUpToDate: Bool
        let checkedAt: Date
    }

    private(set) var loadedID: ArtifactID?
    private(set) var source: String?
    private(set) var files: [String] = []
    private(set) var isLoading = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var upstreamStatus: UpstreamStatus?
    private(set) var lastCreatedName: String?

    private let service: WorkspaceApplicationService
    private let library: WorkspaceLibrarySession
    private let content: any SkillContentServing
    private let cacheRoot: URL
    private var tree: CapturedPackageTree?
    private var fetched: PreparedStandaloneSkill?
    /// The skill a read is currently for, so a slower one that lands after it
    /// can be discarded rather than shown against the wrong row.
    private var requestedID: ArtifactID?

    init(
        service: WorkspaceApplicationService,
        library: WorkspaceLibrarySession,
        cacheRoot: URL,
        content: any SkillContentServing
    ) {
        self.service = service
        self.library = library
        self.cacheRoot = cacheRoot
        self.content = content
    }

    var canWrite: Bool { library.access == .writable }

    /// The whole SKILL.md as stored, for the editor to show beside its own copy.
    func storedSource(for skill: SkillEntry) -> String? {
        loadedID == skill.id ? source : nil
    }

    /// Puts away everything that belonged to the last skill, including a
    /// repository check: a conclusion about one skill's source must never be
    /// read as a conclusion about the next one's.
    func forget() {
        guard !isBusy else { return }
        requestedID = nil
        isLoading = false
        forgetLoaded()
        fetched = nil
        upstreamStatus = nil
    }

    private func forgetLoaded() {
        loadedID = nil
        source = nil
        files = []
        tree = nil
        errorMessage = nil
    }

    /// Reads one skill's stored files. Safe to call again for the same skill;
    /// it returns without re-reading.
    ///
    /// Moving to another skill while a read is still running is ordinary — a
    /// person clicks down a list faster than a content store answers — so the
    /// answer that arrives is kept only while it is still the one being asked
    /// for. Otherwise a slow read lands on the row somebody has already left.
    func load(_ skill: SkillEntry) async {
        guard loadedID != skill.id else { return }
        forgetLoaded()
        guard skill.hasCentralContent, let head = library.state?.snapshot.document.revision.id else { return }
        requestedID = skill.id
        isLoading = true
        defer { if requestedID == skill.id { isLoading = false } }
        do {
            let snapshot = try await content.read(
                artifactID: skill.id, revisionID: head, through: service)
            guard requestedID == skill.id else { return }
            loadedID = skill.id
            tree = snapshot.tree
            files = snapshot.tree.entries.compactMap { entry in
                guard case .file = entry.kind else { return nil }
                return entry.relativePath
            }
            source = Self.definition(in: snapshot.tree)
        } catch {
            // The stored bytes are the only version of this skill the library
            // has. Saying nothing about them is better than showing a file
            // from a client that may have been changed since.
            guard requestedID == skill.id else { return }
            errorMessage = Self.message(for: error)
        }
    }

    /// Saves an edited SKILL.md over the stored one. Every other file in the
    /// package is carried through untouched.
    @discardableResult
    func saveSource(_ markdown: String, for skill: SkillEntry) async -> Bool {
        guard canWrite, !isBusy, skill.ownership == .centralPersonal,
            let stored = tree, loadedID == skill.id, let digest = skill.contentDigest,
            let head = library.state?.snapshot.document.revision.id
        else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let replaced = try Self.replacingDefinition(in: stored, with: markdown)
            try await content.replace(
                replaced, of: skill.id, expecting: digest, at: head, through: service)
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
        loadedID = nil
        await library.refresh()
        return true
    }

    /// Creates one skill from the five-step form. It is admitted to the library
    /// and nothing else: where it is used stays a separate, reviewed choice.
    @discardableResult
    func create(from draft: SkillDraft) async -> Bool {
        guard canWrite, !isBusy, let head = library.state?.snapshot.document.revision.id else { return false }
        isBusy = true
        errorMessage = nil
        lastCreatedName = nil
        defer { isBusy = false }
        do {
            let identifier = try WorkspaceLibrary.normalizedIdentifier(draft.name)
            let tree = try SkillTemplate.tree(identifier: identifier, draft: draft)
            let name = SkillTemplate.displayName(for: identifier)
            try await content.admit(tree, named: name, at: head, through: service)
            lastCreatedName = name
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
        await library.refresh()
        return true
    }

    /// Asks the repository a followed skill came from what it publishes now.
    /// Reads only: nothing in the library changes until the update is applied.
    func checkUpstream(for skill: SkillEntry, binding: SkillRepositoryBinding) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let prepared = try await content.upstream(binding, cachedIn: cacheRoot)
            fetched = prepared
            let same = prepared.review.contentDigest == skill.contentDigest
            upstreamStatus = .init(
                title: same ? "Up to date" : "An update is available",
                detail: same
                    ? "The repository publishes the same content this library approved."
                    : "The repository publishes different content. Review it before it replaces what you have.",
                isUpToDate: same, checkedAt: .now)
        } catch {
            fetched = nil
            upstreamStatus = nil
            errorMessage = Self.message(for: error)
        }
    }

    /// Approves exactly the content the last check fetched.
    @discardableResult
    func applyUpstream(for skill: SkillEntry) async -> Bool {
        guard canWrite, !isBusy, let prepared = fetched, let digest = skill.contentDigest,
            let head = library.state?.snapshot.document.revision.id
        else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await service.updateStandaloneSkill(
                .init(
                    expectedRevisionID: head, artifactID: skill.id,
                    expectedContentDigest: digest, prepared: prepared),
                prepared: prepared)
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
        fetched = nil
        upstreamStatus = nil
        loadedID = nil
        await library.refresh()
        return true
    }

    // MARK: - Reading a package

    static func definition(in tree: CapturedPackageTree) -> String? {
        for entry in tree.entries where entry.relativePath == "SKILL.md" {
            guard case .file(let bytes, _) = entry.kind else { continue }
            return String(data: bytes, encoding: .utf8)
        }
        return nil
    }

    private static func replacingDefinition(in tree: CapturedPackageTree, with markdown: String) throws -> CapturedPackageTree {
        var entries = tree.entries.filter { $0.relativePath != "SKILL.md" }
        entries.append(.init(relativePath: "SKILL.md", kind: .file(bytes: Data(markdown.utf8), executable: false)))
        return try CapturedPackageTree(entries: entries, excludedRootGitMetadata: tree.excludedRootGitMetadata)
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case WorkspaceSkillCommandError.contentStoreUnavailable:
            "This workspace cannot reach its stored content, so nothing can be read or saved."
        case WorkspaceSkillCommandError.missingContent:
            "This library does not hold this skill's files, so there is nothing here to show."
        case WorkspaceSkillCommandError.unsupportedAuthority:
            "This skill is maintained somewhere else, so it cannot be changed from here."
        case WorkspaceSkillCommandError.identityCollision:
            "Your library already has something with that name. Choose a different one."
        case WorkspaceSkillCommandError.reviewMismatch, WorkspaceRevisionStoreError.staleRevision:
            "This workspace changed while you were editing. Nothing was saved — open it again and redo the change."
        case WorkspaceSkillPreparationError.invalidSkillDefinition:
            "The definition does not say what the skill is called and what it does. Nothing was saved."
        case WorkspaceSkillPreparationError.missingSkillDefinition:
            "A skill needs a SKILL.md. Nothing was saved."
        case let error as SkillFrontmatter.ParseError:
            error.errorDescription ?? "That definition could not be read. Nothing was saved."
        case let error as SkillRepositoryError:
            error.errorDescription ?? "That repository could not be read. Nothing was changed."
        case WorkspaceIdentifierError.invalidIdentifier:
            "Use lowercase letters, numbers, and single hyphens for the name."
        default:
            "That could not be completed. Nothing was changed."
        }
    }
}

/// The package a new skill starts life as.
///
/// One definition, and only the extra files that were asked for. The shape is
/// the one the library has always written: a `SKILL.md` beside optional
/// `scripts/` and `references/` folders.
enum SkillTemplate {
    static func displayName(for identifier: String) -> String {
        identifier.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    static func tree(identifier: String, draft: SkillDraft) throws -> CapturedPackageTree {
        let definition = Data(markdown(identifier: identifier, draft: draft).utf8)
        var entries: [PackageTreeEntry] = [
            .init(relativePath: "SKILL.md", kind: .file(bytes: definition, executable: false))
        ]
        if draft.includeScript {
            entries.append(.init(relativePath: "scripts", kind: .directory))
            entries.append(
                .init(
                    relativePath: "scripts/helper.sh",
                    kind: .file(bytes: Data(helperScript.utf8), executable: true)))
        }
        if draft.includeReference {
            entries.append(.init(relativePath: "references", kind: .directory))
            entries.append(
                .init(
                    relativePath: "references/reference.md",
                    kind: .file(bytes: Data(reference.utf8), executable: false)))
        }
        return try CapturedPackageTree(entries: entries)
    }

    static func markdown(identifier: String, draft: SkillDraft) -> String {
        let triggerLines = draft.triggers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
            .joined(separator: "\n")
        return """
            ---
            name: \(identifier)
            description: \(yamlQuoted(draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines)))
            ---

            # \(displayName(for: identifier))

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

    private static let helperScript =
        "#!/bin/sh\nset -eu\nprintf '%s\\n' 'helper.sh has not been implemented for this skill.' >&2\nexit 64\n"
    private static let reference = "# Reference\n\nAdd long-form, on-demand guidance here.\n"

    private static func yamlQuoted(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
