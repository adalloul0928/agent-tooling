import Testing

@testable import AgentToolingCore

/// One repository, however the remote is spelled, becomes one hint.
@Suite("Repository identity")
struct RepositoryIdentityTests {
    @Test func everySpellingOfOneRemoteBecomesTheSameHint() {
        let expected = "https://github.com/acme/project"
        for remote in [
            "https://github.com/acme/project.git",
            "https://github.com/acme/project",
            "https://github.com/acme/project/",
            "http://github.com/acme/project.git",
            "git@github.com:acme/project.git",
            "git@github.com:acme/project",
            "ssh://git@github.com/acme/project.git",
            "ssh://git@github.com:22/acme/project.git",
            "git://github.com/acme/project.git",
            "https://user:token@github.com/acme/project.git",
            "https://GitHub.com/acme/project.git",
            "  https://github.com/acme/project.git\n",
        ] {
            #expect(RepositoryIdentity.hint(fromRemote: remote) == expected, "\(remote)")
        }
    }

    @Test func pathCaseIsKeptBecauseSomeHostsCareAboutIt() {
        #expect(RepositoryIdentity.hint(fromRemote: "git@github.com:Acme/Project.git") == "https://github.com/Acme/Project")
        #expect(RepositoryIdentity.matches("git@github.com:Acme/Project.git", "https://github.com/acme/project"))
    }

    @Test func nestedGroupsAndInternalHostsAreKept() {
        #expect(
            RepositoryIdentity.hint(fromRemote: "ssh://git.amazon.com:2222/pkg/AgentTooling") == "https://git.amazon.com/pkg/AgentTooling")
        #expect(
            RepositoryIdentity.hint(fromRemote: "git@gitlab.example.com:group/subgroup/repo.git")
                == "https://gitlab.example.com/group/subgroup/repo")
    }

    @Test func thingsThatAreNotRepositoriesGiveNoHint() {
        for remote in [
            "", "   ", "/Users/me/src/project", "../sibling", "file:///tmp/repo", "https://", "https:///acme/project", "github.com",
            "git@github.com:",
        ] {
            #expect(RepositoryIdentity.hint(fromRemote: remote) == nil, "\(remote)")
        }
    }

    @Test func differentRepositoriesDoNotMatch() {
        #expect(!RepositoryIdentity.matches("https://github.com/acme/project", "https://github.com/acme/other"))
        #expect(!RepositoryIdentity.matches("https://github.com/acme/project", "https://gitlab.com/acme/project"))
        #expect(!RepositoryIdentity.matches("not a remote", "https://github.com/acme/project"))
    }
}
