import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// Everything linking a skill to a repository does that leaves the window.
///
/// A protocol rather than three calls, so a test can hand in an implementation
/// that answers from memory and never runs `git`, reaches the network, or opens
/// a content store. Drawing the affordance must reach none of them either.
protocol SkillUpstreamLinking: Sendable {
    /// Fetches what a public repository publishes now. Runs a process.
    func fetch(_ binding: SkillRepositoryBinding, cachedIn cacheRoot: URL) async throws -> PreparedStandaloneSkill

    /// Records that the skill now follows the repository. Publishes nothing.
    func link(
        _ command: LinkSkillUpstreamCommand, prepared: PreparedStandaloneSkill,
        through service: WorkspaceApplicationService
    ) async throws

    /// Takes the repository's version as a reviewed personal update. The skill
    /// stays the person's own; only its content moves.
    func adopt(
        _ tree: CapturedPackageTree, of artifactID: ArtifactID, expecting digest: ContentDigest,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws
}

/// The real one: the workspace's own commands, and the same bounded Git fetch a
/// followed skill's update check already uses. It adds no path to either.
struct LiveSkillUpstreamLinker: SkillUpstreamLinking {
    func fetch(_ binding: SkillRepositoryBinding, cachedIn cacheRoot: URL) async throws -> PreparedStandaloneSkill {
        try await WorkspaceSkillPreparation.fetchUpstream(binding: binding, cacheURL: cacheRoot)
    }

    func link(
        _ command: LinkSkillUpstreamCommand, prepared: PreparedStandaloneSkill,
        through service: WorkspaceApplicationService
    ) async throws {
        _ = try await service.linkSkillUpstream(command, prepared: prepared)
    }

    func adopt(
        _ tree: CapturedPackageTree, of artifactID: ArtifactID, expecting digest: ContentDigest,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {
        // Prepared as a personal version on purpose: taking these bytes is a
        // content change, and it must not smuggle in an ownership change.
        let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
        _ = try await service.updateStandaloneSkill(
            .init(
                expectedRevisionID: revisionID, artifactID: artifactID,
                expectedContentDigest: digest, prepared: prepared), prepared: prepared)
    }
}

extension EnvironmentValues {
    @Entry var skillUpstreamLinker: any SkillUpstreamLinking = LiveSkillUpstreamLinker()
}

extension WorkspaceLaunch.Workspace {
    /// The bounded checkout cache inside this workspace's own container, which
    /// is the only place a fetch is allowed to write.
    var skillRepositoryCacheRoot: URL {
        store.databaseURL.deletingLastPathComponent()
            .appending(path: "cache", directoryHint: .isDirectory)
    }
}

/// Asking a repository what it publishes, and — only when that is already what
/// this library holds — recording that the skill follows it.
///
/// The digest every decision is taken against is read from the workspace rather
/// than from the row that opened this sheet, so a library that moved underneath
/// is compared against as it is now.
@MainActor @Observable
final class SkillUpstreamLinkSession: Identifiable {
    /// What one fetch found. Nothing here has changed anything.
    struct Checked: Equatable {
        let binding: SkillRepositoryBinding
        let revision: SourceRevision
        let publisherID: String
        /// Whether this library's bytes already are this repository's bytes.
        let matchesLibrary: Bool
    }

    let id = UUID()
    var repositoryURL = ""
    var ref = "main"
    var subdirectory = ""
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var checked: Checked?

    private let service: WorkspaceApplicationService
    private let library: WorkspaceLibrarySession
    private let cacheRoot: URL
    private let linker: any SkillUpstreamLinking
    private var fetched: PreparedStandaloneSkill?

    init(workspace: WorkspaceLaunch.Workspace, linker: any SkillUpstreamLinking) {
        self.service = workspace.service
        self.library = workspace.library
        self.cacheRoot = workspace.skillRepositoryCacheRoot
        self.linker = linker
    }

    var canWrite: Bool { library.access == .writable }

    /// Ready to fetch. The binding itself is validated by the fetch, which is
    /// where a malformed URL gets its own words rather than a silent disable.
    var canCheck: Bool {
        !isBusy && !repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canLink: Bool { canWrite && !isBusy && checked?.matchesLibrary == true && fetched != nil }

    /// Reads the repository and says what it found. Changes nothing.
    func check(for skill: SkillEntry) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        checked = nil
        fetched = nil
        defer { isBusy = false }
        do {
            let binding = try SkillRepositoryBinding(
                repositoryURL: repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines),
                ref: ref.trimmingCharacters(in: .whitespacesAndNewlines),
                subdirectory: subdirectory.trimmingCharacters(in: .whitespacesAndNewlines))
            let prepared = try await linker.fetch(binding, cachedIn: cacheRoot)
            guard let upstream = prepared.review.upstream else { throw LinkSkillUpstreamRefusal.reviewMismatch }
            fetched = prepared
            checked = .init(
                binding: binding, revision: upstream.revision, publisherID: upstream.publisherID,
                matchesLibrary: prepared.review.contentDigest == digest(of: skill))
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Records that the skill follows the repository the last check read.
    @discardableResult
    func link(_ skill: SkillEntry) async -> Bool {
        guard canLink, let prepared = fetched, let digest = digest(of: skill),
            let head = library.state?.snapshot.document.revision.id
        else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await linker.link(
                try .init(
                    expectedRevisionID: head, artifactID: skill.id, expectedContentDigest: digest,
                    prepared: prepared), prepared: prepared, through: service)
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
        await library.refresh()
        return true
    }

    /// The other honest route out of a mismatch: replace this library's copy
    /// with the repository's, as a reviewed content change, and stay personal.
    /// Every earlier version stays in this workspace's history.
    @discardableResult
    func takeRepositoryVersion(_ skill: SkillEntry) async -> Bool {
        guard canWrite, !isBusy, let prepared = fetched, let digest = digest(of: skill),
            let head = library.state?.snapshot.document.revision.id
        else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await linker.adopt(prepared.tree, of: skill.id, expecting: digest, at: head, through: service)
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
        await library.refresh()
        // The library now holds exactly what was fetched, so the same review
        // can be followed without asking the repository a second time.
        checked = checked.map {
            .init(binding: $0.binding, revision: $0.revision, publisherID: $0.publisherID, matchesLibrary: true)
        }
        return true
    }

    /// This workspace's own record of the skill, never the row that was passed
    /// in: a refresh may have moved it since the sheet opened.
    private func digest(of skill: SkillEntry) -> ContentDigest? {
        library.state?.snapshot.document.artifacts
            .first { $0.identity.id == skill.id }?.contentDigest ?? skill.contentDigest
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let refusal as LinkSkillUpstreamRefusal:
            refusal.reason
        case let error as SkillRepositoryError:
            error.errorDescription ?? "That repository could not be read. Nothing was changed."
        case WorkspaceSkillPreparationError.missingSkillDefinition:
            "That folder in the repository has no SKILL.md, so there is nothing to follow."
        case WorkspaceSkillPreparationError.invalidSkillDefinition:
            "The repository's definition does not say what the skill is called and what it does."
        case WorkspaceSkillPreparationError.pluginPackageRoot:
            "That folder is a whole plugin rather than one skill, so it follows its package instead."
        case WorkspaceSkillPreparationError.invalidUpstream:
            "This build follows public GitHub repositories only."
        case WorkspaceSkillCommandError.contentStoreUnavailable:
            "This workspace cannot reach its stored content, so nothing can be read or saved."
        case WorkspaceSkillCommandError.unsupportedAuthority:
            LinkSkillUpstreamRefusal.contentNotHeldHere.reason
        case WorkspaceSkillCommandError.missingContent:
            LinkSkillUpstreamRefusal.missingContent.reason
        case WorkspaceSkillCommandError.reviewMismatch, WorkspaceRevisionStoreError.staleRevision:
            "This workspace changed while you were deciding. Nothing was saved — check the repository again."
        default:
            "That could not be completed. Nothing was changed."
        }
    }
}

/// Choosing the repository a skill this library maintains should follow.
///
/// The sheet reads the repository first and says exactly what it found: the
/// commit, and whether those are the bytes this library already holds. Only
/// then can it be followed, because `centralUpstream` means the approved tree
/// is what gets deployed, and a lock over bytes this library does not hold
/// would make every later update diff against a version nobody has.
struct SkillUpstreamLinkSheet: View {
    let skill: SkillEntry
    @Bindable var session: SkillUpstreamLinkSession
    @Environment(\.dismiss) private var dismiss
    @State private var isReplacing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Follow a repository").font(.title3.weight(.semibold))
                    Text(skill.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isBusy { ProgressView().controlSize(.small) }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(
                        "Following a repository changes where this skill's next version comes from. It does not change the version you have now, and nothing is ever written into the repository."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    repository
                    if let message = session.errorMessage {
                        AttentionBanner(title: "That repository could not be followed", message: message)
                    }
                    if let checked = session.checked { result(checked) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if !session.canWrite {
                    Text("This workspace is open for reading only.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Keep this skill as your own") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Follow this repository") {
                    Task { if await session.link(skill) { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
                .tint(AgentTheme.selection)
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canLink)
            }
            .padding(.horizontal, 20)
            .frame(height: 68)
        }
        // Tall enough that a check which did not match shows its reason and the
        // other way out of it without anybody having to scroll for them.
        .frame(width: 660, height: 640)
        .background(AgentTheme.contentBackground)
    }

    @ViewBuilder private var repository: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Repository") {
                TextField("https://github.com/owner/repository", text: $session.repositoryURL)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    .accessibilityLabel("Repository address")
            }
            LabeledContent("Branch or tag") {
                TextField("main", text: $session.ref)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .accessibilityLabel("Branch or tag")
            }
            LabeledContent("Folder in the repository") {
                TextField("Repository root", text: $session.subdirectory)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    .accessibilityLabel("Folder in the repository")
            }
            HStack(spacing: 12) {
                Button("Check repository", systemImage: "arrow.clockwise") {
                    Task { await session.check(for: skill) }
                }
                .buttonStyle(.bordered)
                .disabled(!session.canCheck)
                Text("Reads the repository and reports what it publishes. Nothing is changed by checking.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).standardPanel(cornerRadius: 12)
    }

    @ViewBuilder private func result(_ checked: SkillUpstreamLinkSession.Checked) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                checked.matchesLibrary
                    ? "The repository publishes the version you have"
                    : "The repository publishes a different version",
                systemImage: checked.matchesLibrary ? "checkmark.seal" : "exclamationmark.triangle"
            )
            .font(.system(size: 14, weight: .medium))
            LabeledContent("Commit") {
                Text(checked.revision.value.prefix(12)).textSelection(.enabled).monospaced()
            }
            LabeledContent("Published by") { Text(checked.publisherID).textSelection(.enabled) }
            LabeledContent("Folder") {
                Text(checked.binding.subdirectory.isEmpty ? "Repository root" : checked.binding.subdirectory)
                    .textSelection(.enabled)
            }
            if checked.matchesLibrary {
                Text(
                    "Following it records where the next version comes from. The files in your library stay exactly as they are."
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                // The refusal's own words, because they name both ways out of
                // it and this screen must not paraphrase either one.
                Text(LinkSkillUpstreamRefusal.contentDiffersFromUpstream.reason)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use the repository's version…", systemImage: "arrow.down.circle") {
                    isReplacing = true
                }
                .buttonStyle(.bordered)
                .disabled(!session.canWrite || session.isBusy)
                .confirmationDialog(
                    "Replace this skill's files with the repository's?",
                    isPresented: $isReplacing, titleVisibility: .visible
                ) {
                    Button("Use the repository's version") {
                        Task { await session.takeRepositoryVersion(skill) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Your version is replaced by what this repository publishes, and stays in this workspace's history. The skill remains your own until you follow the repository."
                    )
                }
            }
        }
        .padding(16).standardPanel(cornerRadius: 12)
    }
}
