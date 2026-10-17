import Testing

@testable import AgentToolingCore

/// A folder found on this Mac is the project's, a project's waiting to be
/// recognised, or nobody's. The matcher never guesses between two projects.
@Suite("Project repository matcher")
struct ProjectRepositoryMatcherTests {
    private let order = ArtifactID()
    private let web = ArtifactID()

    private func folder(_ path: String, remote: String?) -> DiscoveredProject {
        DiscoveredProject(
            path: path, name: String(path.split(separator: "/").last ?? ""),
            repositoryHint: remote.flatMap(RepositoryIdentity.hint(fromRemote:)))
    }

    private var projects: [ProjectRepositoryMatcher.Project] {
        [
            .init(id: order, name: "Order", repositoryHints: ["https://github.com/acme/order-history"]),
            .init(id: web, name: "Web", repositoryHints: ["https://github.com/acme/web"]),
        ]
    }

    @Test func aBoundFolderIsTrackedWhateverItsRemoteSays() {
        let matches = ProjectRepositoryMatcher.classify(
            discovered: [folder("/Users/me/src/order", remote: "git@github.com:acme/web.git")],
            projects: projects,
            bindings: [.init(projectID: order, rootPath: "/Users/me/src/order")])
        #expect(matches.map(\.standing) == [.tracked(projectID: order)])
    }

    @Test func anUnboundCheckoutOfAProjectsRepositoryMatchesIt() {
        let matches = ProjectRepositoryMatcher.classify(
            discovered: [folder("/Users/me/src/order", remote: "git@github.com:acme/order-history.git")],
            projects: projects, bindings: [])
        #expect(matches.map(\.standing) == [.matches(projectID: order)])
        #expect(matches.first?.projectID == order)
    }

    @Test func aProjectThatAlreadyHasAFolderHereDoesNotClaimASecondOne() {
        let matches = ProjectRepositoryMatcher.classify(
            discovered: [folder("/Users/me/src/order-copy", remote: "https://github.com/acme/order-history")],
            projects: projects,
            bindings: [.init(projectID: order, rootPath: "/Users/me/src/order")])
        #expect(matches.map(\.standing) == [.untracked])
    }

    @Test func aRemoteTwoProjectsClaimMatchesNeither() {
        let twins: [ProjectRepositoryMatcher.Project] = [
            .init(id: order, name: "Order", repositoryHints: ["https://github.com/acme/mono"]),
            .init(id: web, name: "Web", repositoryHints: ["https://github.com/acme/mono"]),
        ]
        let matches = ProjectRepositoryMatcher.classify(
            discovered: [folder("/Users/me/src/mono", remote: "https://github.com/acme/mono.git")],
            projects: twins, bindings: [])
        #expect(matches.map(\.standing) == [.untracked])
    }

    @Test func foldersWithoutARemoteOrWithAnUnknownOneAreUntracked() {
        let matches = ProjectRepositoryMatcher.classify(
            discovered: [
                folder("/Users/me/src/scratch", remote: nil),
                folder("/Users/me/src/elsewhere", remote: "https://github.com/someone/else"),
            ],
            projects: projects, bindings: [])
        #expect(matches.map(\.standing) == [.untracked, .untracked])
    }

    @Test func candidatesAreTheUnboundCheckoutsOfAnUnattachedProjectsRepository() {
        let discovered = [
            folder("/Users/me/src/order", remote: "git@github.com:acme/order-history.git"),
            folder("/Users/me/src/order-wt", remote: "https://github.com/acme/order-history"),
            folder("/Users/me/src/web", remote: "https://github.com/acme/web"),
        ]
        let candidates = ProjectRepositoryMatcher.candidates(for: projects[0], discovered: discovered, bindings: [])
        #expect(candidates.map(\.path) == ["/Users/me/src/order", "/Users/me/src/order-wt"])

        let attached = ProjectRepositoryMatcher.candidates(
            for: projects[0], discovered: discovered,
            bindings: [.init(projectID: order, rootPath: "/Users/me/src/order")])
        #expect(attached.isEmpty)
    }
}
