import AgentToolingCore
import Foundation
import Observation

/// Attaching a folder you already author in, and letting one go.
///
/// The folder stays where it is and stays the only editable copy. Nothing is
/// copied into the library, no content is recorded, and detaching removes a
/// registration rather than someone's files — so neither action here can lose
/// work, which is why neither needs a warning it would be reasonable to ignore.
@MainActor @Observable
final class WorkspaceAuthoringSession {
    /// What attaching this folder would register, read before anything is
    /// committed so a person sees the name before agreeing to it.
    struct Candidate: Sendable {
        let directory: URL
        let declaredName: String
        let displayName: String
        let fileCount: Int
    }

    private(set) var candidate: Candidate?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var lastAttachedName: String?
    private(set) var lastDetachedName: String?

    private let service: WorkspaceApplicationService
    private let library: WorkspaceLibrarySession
    private var prepared: PreparedStandaloneSkill?

    init(service: WorkspaceApplicationService, library: WorkspaceLibrarySession) {
        self.service = service
        self.library = library
    }

    var canWrite: Bool { library.access == .writable }

    /// Reads the folder without changing it or the workspace.
    func inspect(_ directory: URL) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        candidate = nil
        prepared = nil
        defer { isBusy = false }
        do {
            let value = try await WorkspaceSkillPreparation.capturePersonal(directory: directory)
            prepared = value
            candidate = .init(
                directory: directory,
                declaredName: value.frontmatter.name,
                displayName: value.frontmatter.name,
                fileCount: value.tree.entries.count)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func discard() {
        guard !isBusy else { return }
        candidate = nil
        prepared = nil
        errorMessage = nil
    }

    /// Registers the folder as the editable source for one skill.
    func attach(displayName: String) async {
        guard canWrite, !isBusy, let prepared, let candidate else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let head = try await service.snapshot()?.document.revision.id else {
                errorMessage = "This workspace could not be read. Nothing was attached."
                return
            }
            _ = try await service.attachAuthoringRoot(.init(
                expectedRevisionID: head,
                displayName: name.isEmpty ? candidate.displayName : name,
                prepared: prepared, directory: candidate.directory))
            lastAttachedName = name.isEmpty ? candidate.displayName : name
            lastDetachedName = nil
            self.candidate = nil
            self.prepared = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
        await library.refresh()
    }

    /// Stops managing an attached item. The folder is untouched.
    func detach(_ artifactID: ArtifactID, named name: String) async {
        guard canWrite, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let head = try await service.snapshot()?.document.revision.id else {
                errorMessage = "This workspace could not be read. Nothing was changed."
                return
            }
            _ = try await service.detachAuthoringRoot(.init(
                expectedRevisionID: head, artifactID: artifactID))
            lastDetachedName = name
            lastAttachedName = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
        await library.refresh()
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case WorkspaceAttachedAuthoringError.invalidDirectory:
            "Choose a folder on this Mac that holds the skill you author."
        case WorkspaceAttachedAuthoringError.notAStandaloneSkill:
            "That folder tracks a publisher's version, so it is not yours to edit here. Attach a folder you author yourself."
        case WorkspaceAttachedAuthoringError.alreadyAttached,
             WorkspaceAttachedAuthoringError.sourceIdentityConflict:
            "That folder is already the editable copy for something in your library."
        case WorkspaceAttachedAuthoringError.identityCollision:
            "Your library already has something with that name. Rename one of them first."
        case WorkspaceAttachedAuthoringError.detachedItemMissing,
             WorkspaceAttachedAuthoringError.notAttached:
            "That item is not an attached folder, so there is nothing to let go of."
        case WorkspaceSkillPreparationError.missingSkillDefinition:
            "That folder has no SKILL.md, so there is no skill in it to attach."
        case WorkspaceSkillPreparationError.invalidSkillDefinition:
            "That folder's SKILL.md does not say what the skill is called or what it does."
        case WorkspaceSkillPreparationError.pluginPackageRoot:
            "That folder is a whole plugin, not a single skill. Attach the skill's own folder inside it."
        default:
            "That folder could not be read as a skill. Nothing was changed."
        }
    }
}
