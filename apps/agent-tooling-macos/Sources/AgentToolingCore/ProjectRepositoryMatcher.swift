import Foundation

/// Joins three facts about projects: the ones the workspace names, the folders
/// this Mac has bound to them, and the folders a scan found here. Each found
/// folder is one of three things, and an unattached project may have a folder
/// here waiting to be recognised.
///
/// Pure: given the facts, says what they add up to. Nothing is read or written.
public enum ProjectRepositoryMatcher {
    public enum Standing: Hashable, Sendable {
        /// This Mac already treats the folder as this project's.
        case tracked(projectID: ArtifactID)
        /// The folder is a checkout of a repository one of the workspace's
        /// projects names, and that project has no folder on this Mac. Binding
        /// it is a recognition, not a decision.
        case matches(projectID: ArtifactID)
        /// Nothing in the workspace knows this folder or its repository.
        case untracked
    }

    public struct Match: Hashable, Sendable, Identifiable {
        public let project: DiscoveredProject
        public let standing: Standing
        public var id: String { project.id }

        public var projectID: ArtifactID? {
            switch standing {
            case .tracked(let id), .matches(let id): id
            case .untracked: nil
            }
        }
    }

    public struct Project: Hashable, Sendable {
        public let id: ArtifactID
        public let name: String
        public let repositoryHints: [String]
        public init(id: ArtifactID, name: String, repositoryHints: [String]) {
            self.id = id
            self.name = name
            self.repositoryHints = repositoryHints
        }
    }

    /// Classifies every discovered folder. A folder bound to a project is that
    /// project's regardless of its remote; an unbound folder whose remote
    /// matches exactly one project without a folder here matches it; a remote
    /// two projects claim matches neither, because guessing would bind the
    /// wrong one silently.
    public static func classify(
        discovered: [DiscoveredProject],
        projects: [Project],
        bindings: [DeviceProjectRootBinding]
    ) -> [Match] {
        let boundByPath = Dictionary(
            bindings.map { (ProjectPath.canonical($0.rootPath), $0.projectID) }, uniquingKeysWith: { first, _ in first })
        let boundProjects = Set(bindings.map(\.projectID))
        return discovered.map { folder in
            if let projectID = boundByPath[ProjectPath.canonical(folder.path)] {
                return Match(project: folder, standing: .tracked(projectID: projectID))
            }
            guard let hint = folder.repositoryHint else { return Match(project: folder, standing: .untracked) }
            let claimants = projects.filter { project in
                !boundProjects.contains(project.id)
                    && project.repositoryHints.contains { RepositoryIdentity.matches($0, hint) }
            }
            guard claimants.count == 1, let only = claimants.first else {
                return Match(project: folder, standing: .untracked)
            }
            return Match(project: folder, standing: .matches(projectID: only.id))
        }
    }

    /// The folders on this Mac that are checkouts of a project's repository,
    /// for a project with no folder here. Several means the person chooses.
    public static func candidates(
        for project: Project,
        discovered: [DiscoveredProject],
        bindings: [DeviceProjectRootBinding]
    ) -> [DiscoveredProject] {
        guard !bindings.contains(where: { $0.projectID == project.id }) else { return [] }
        let bound = Set(bindings.map { ProjectPath.canonical($0.rootPath) })
        return discovered.filter { folder in
            guard !bound.contains(ProjectPath.canonical(folder.path)), let hint = folder.repositoryHint else { return false }
            return project.repositoryHints.contains { RepositoryIdentity.matches($0, hint) }
        }
    }
}
