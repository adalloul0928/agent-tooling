import AgentToolingCore
import Foundation

/// Adopts all selected skills in one revision. Tracked records are matched by
/// observed folder, not the name declared in SKILL.md; conflicting names are
/// refused rather than mistaken for untracked skills.
extension WorkspaceSetupSession {
    /// The steps `applyAll` runs for `actions`, in order: one per action, so
    /// its progress and its "2 of 3 done." count each action. The skills to
    /// make yours share one batch: the first of their steps writes it, and
    /// each step then reports its own skill.
    func work(for actions: [SetupAction]) -> [() async throws -> String] {
        let paths = actions.compactMap { action -> String? in
            guard case .adoptSkill(let path, _) = action else { return nil }
            return path
        }
        let batch = SetupAdoptionBatch(session: self, paths: paths)
        return actions.map { action in
            if case .adoptSkill(let path, _) = action {
                return { try await batch.result(for: path) }
            }
            return { try await self.perform(action) }
        }
    }

    /// Adopts the tracked skill whose folder is at `path`: its files are
    /// copied into the library, and the record becomes yours.
    func adopt(path: String) async throws -> String {
        guard let result = await adopt(paths: [path])[path] else { throw SetupApplyError.nothingRan }
        return try result.get()
    }

    /// Makes the skill at each of `paths` yours, all in one revision, and says
    /// what happened to each: the sentence it lands with, or why it did not.
    /// Two folders holding one tracked skill make it yours once, from the
    /// first.
    func adopt(paths: [String]) async -> [String: Result<String, any Error>] {
        var results: [String: Result<String, any Error>] = [:]
        guard let snapshot = library.state?.snapshot else {
            for path in paths { results[path] = .failure(SetupApplyError.libraryUnread) }
            return results
        }
        var adoptions: [WorkspaceLibraryAdditionBatch.Adoption] = []
        var prepared: [ArtifactID: PreparedStandaloneSkill] = [:]
        var sharing: [ArtifactID: [String]] = [:]
        var names: [ArtifactID: String] = [:]
        for path in paths where results[path] == nil {
            guard let artifact = Self.trackedSkill(at: path, in: snapshot) else {
                results[path] = .failure(SetupApplyError.notTracked(URL(filePath: path).lastPathComponent))
                continue
            }
            let id = artifact.identity.id
            names[id] = artifact.declaredName ?? artifact.identity.displayName
            if sharing[id] != nil {
                sharing[id, default: []].append(path)
                continue
            }
            do {
                prepared[id] = try await WorkspaceSkillPreparation.capturePersonal(
                    directory: URL(filePath: path, directoryHint: .isDirectory))
            } catch {
                results[path] = .failure(error)
                continue
            }
            adoptions.append(.init(artifactID: id, sourcePath: path))
            sharing[id] = [path]
        }
        guard !adoptions.isEmpty else { return results }

        func settle(_ id: ArtifactID, _ result: Result<String, any Error>) {
            for path in sharing[id] ?? [] { results[path] = result }
        }
        func refuse(_ refusal: LibraryAdditionRefusal) {
            settle(refusal.artifactID, .failure(SetupAdoptionRefusal(refusal: refusal, name: names[refusal.artifactID])))
        }
        let batch = WorkspaceLibraryAdditionBatch(expectedRevisionID: snapshot.document.revision.id, adoptions: adoptions)
        do {
            let refusals = try await service.previewLibraryAdditions(batch, prepared: prepared)
            for refusal in refusals { refuse(refusal) }
            let rest = batch.excluding(Set(refusals.map(\.artifactID)))
            guard !rest.isEmpty else { return results }
            let receipt = try await service.applyLibraryAdditions(rest, prepared: prepared)
            let landed = Set(receipt.affectedArtifactIDs)
            for adoption in rest.adoptions {
                guard landed.contains(adoption.artifactID), let skill = prepared[adoption.artifactID] else {
                    settle(adoption.artifactID, .failure(SetupApplyError.nothingRan))
                    continue
                }
                settle(adoption.artifactID, .success("\(skill.frontmatter.name) is in the library now. Install it from its details."))
            }
        } catch LibraryAdditionError.nothingToAdd(let refusals) {
            for refusal in refusals { refuse(refusal) }
        } catch {
            for adoption in adoptions where sharing[adoption.artifactID]?.allSatisfy({ results[$0] == nil }) == true {
                settle(adoption.artifactID, .failure(error))
            }
        }
        return results
    }

    /// The tracked loose skill the check found in the folder at `path`: the
    /// record its observation was filed under, which is the folder's name the
    /// check read, whatever its SKILL.md says.
    nonisolated static func trackedSkill(at path: String, in snapshot: WorkspaceApplicationSnapshot) -> ArtifactRecord? {
        let folder = ProjectPath.canonical(URL(filePath: path, directoryHint: .isDirectory))
        let observed = snapshot.device.observations.lazy.compactMap { observation in
            observation.skillMetadata.first { _, metadata in
                metadata.providerPluginID == nil
                    && ProjectPath.canonical(URL(filePath: metadata.path, directoryHint: .isDirectory)) == folder
            }?.key
        }.first
        let name = observed ?? URL(filePath: folder).lastPathComponent
        return snapshot.document.artifacts.first {
            $0.identity.kind == .skill && $0.authority == .trackedOnly && $0.identity.parentPackageID == nil
                && $0.declaredName == name
        }
    }
}

/// Why one skill was not made yours, in the words Start your library uses,
/// led by the skill's name: Checkup's message ("2 did not go through. First:
/// …") has no row beside it to say which skill it means.
struct SetupAdoptionRefusal: LocalizedError, Equatable {
    let refusal: LibraryAdditionRefusal
    /// The skill as Checkup names it: the name its finding was filed under,
    /// which is the record's.
    let name: String?

    var errorDescription: String? { LaunchpadCopy.Library.sentence(for: refusal, naming: name) }
}

/// The skills one apply makes yours: adopted together the first time any of
/// their steps runs, then answered one step at a time.
@MainActor
private final class SetupAdoptionBatch {
    private let session: WorkspaceSetupSession
    private let paths: [String]
    private var results: [String: Result<String, any Error>]?

    init(session: WorkspaceSetupSession, paths: [String]) {
        self.session = session
        self.paths = paths
    }

    func result(for path: String) async throws -> String {
        if results == nil { results = await session.adopt(paths: paths) }
        guard let result = results?[path] else { throw SetupApplyError.nothingRan }
        return try result.get()
    }
}
