import Foundation
import Testing

@testable import AgentToolingCore

/// The address help J01 and S17 give under the field (V9): which addresses
/// can be used, the HTTPS form of one that cannot, why it cannot, and the
/// host a message names.
@Suite("Git remote address")
struct GitRemoteAddressTests {
    /// The two sentences under the field: V9's for an address that names a
    /// user or a password, and the one for an address in another form.
    private static let signInHelp = "Enter a repository address without a user name or password in it."
    private static let formHelp = "Enter a repository address that starts with https://."

    @Test(arguments: [
        "https://github.com/you/agent-tooling-workspace.git",
        "https://gitlab.example.com:8443/team/library",
        "ssh://github.com/you/agent-tooling-workspace.git",
        "file:///Volumes/Shared/library.git",
        "/Volumes/Shared/library.git",
    ])
    func anAddressTheTransportTakesHasNoProblem(_ remote: String) {
        #expect(GitRemoteAddress.problem(remote) == nil)
        #expect(GitRemoteAddress.httpsSuggestion(for: remote) == nil)
        #expect(GitWorkspaceTransport.isValidRemote(remote))
    }

    @Test(arguments: [
        "  https://github.com/you/agent-tooling-workspace.git\n",
        " https://github.com/you/agent-tooling-workspace.git",
        "https://github.com/you/agent-tooling-workspace.git\t",
    ])
    func thePasteAroundAnAddressIsNotHeldAgainstIt(_ remote: String) {
        // A paste brings a space or a line break with it. The address in it
        // is fine, so there is nothing to say and nothing to suggest.
        #expect(GitRemoteAddress.problem(remote) == nil)
        #expect(GitRemoteAddress.httpsSuggestion(for: remote) == nil)
        #expect(GitRemoteAddress.host(of: remote) == "github.com")
    }

    @Test(arguments: [
        ("git@github.com:you/agent-tooling-workspace.git", "https://github.com/you/agent-tooling-workspace.git", true),
        ("  git@github.com:you/agent-tooling-workspace.git\n", "https://github.com/you/agent-tooling-workspace.git", true),
        ("ssh://git@github.com/you/agent-tooling-workspace.git", "https://github.com/you/agent-tooling-workspace.git", true),
        ("ssh://git@github.com:22/you/agent-tooling-workspace.git", "https://github.com/you/agent-tooling-workspace.git", true),
        ("https://you:hunter2@github.com/you/agent-tooling-workspace.git", "https://github.com/you/agent-tooling-workspace.git", true),
        ("https://you@github.com/you/agent-tooling-workspace.git", "https://github.com/you/agent-tooling-workspace.git", true),
        ("git@GitHub.com:you/library.git", "https://github.com/you/library.git", true),
        ("github.com:you/agent-tooling-workspace.git", "https://github.com/you/agent-tooling-workspace.git", false),
        ("http://github.com/you/agent-tooling-workspace.git", "https://github.com/you/agent-tooling-workspace.git", false),
        ("git://github.com/you/agent-tooling-workspace.git", "https://github.com/you/agent-tooling-workspace.git", false),
        ("github.com/you/agent-tooling-workspace.git", "https://github.com/you/agent-tooling-workspace.git", false),
        (" github.com/you/agent-tooling-workspace.git\n", "https://github.com/you/agent-tooling-workspace.git", false),
    ])
    func aRefusedAddressSuggestsItsHTTPSFormAndSaysWhy(_ remote: String, _ suggestion: String, _ carriesSignIn: Bool) {
        #expect(GitRemoteAddress.httpsSuggestion(for: remote) == suggestion)
        let problem = GitRemoteAddress.problem(remote)
        #expect(problem == .invalidAddress(suggestion: suggestion, carriesSignIn: carriesSignIn))
        // Only an address that names a user or a password is told so; one in
        // another form is told which form to use.
        #expect(problem?.errorDescription == (carriesSignIn ? Self.signInHelp : Self.formHelp))
        // The suggestion is itself an address the transport takes.
        #expect(GitWorkspaceTransport.isValidRemote(suggestion))
    }

    @Test(arguments: [
        ("", false),
        ("library", false),
        ("ftp://example.com/library.git", false),
        ("--upload-pack=/bin/sh", false),
        ("github-work:you/library.git", false),
        ("C:/library", false),
        // An SSH alias names nothing HTTPS can reach, so there is nothing to
        // offer; the user name in it is still why it is refused.
        ("git@github-work:you/library.git", true),
    ])
    func anAddressWithNothingToWorkFromHasNoSuggestion(_ remote: String, _ carriesSignIn: Bool) {
        #expect(GitRemoteAddress.httpsSuggestion(for: remote) == nil)
        let problem = GitRemoteAddress.problem(remote)
        #expect(problem == .invalidAddress(suggestion: nil, carriesSignIn: carriesSignIn))
        #expect(problem?.errorDescription == (carriesSignIn ? Self.signInHelp : Self.formHelp))
    }

    @Test func theHelpUnderTheFieldReadsAsTheFormsDo() {
        // The scp form (V9) keeps the shipped sentence; an address in another
        // form says what to type instead. Neither is a failure that wrote
        // nothing, so neither closes with "Nothing was changed."
        #expect(GitRemoteAddress.problem("git@github.com:you/agent-tooling-workspace.git")?.errorDescription == Self.signInHelp)
        #expect(GitRemoteAddress.problem("http://github.com/you/agent-tooling-workspace.git")?.errorDescription == Self.formHelp)
        #expect(GitRemoteAddress.problem("github.com/you/agent-tooling-workspace.git")?.errorDescription == Self.formHelp)
        #expect(GitRemoteAddress.problem("library")?.errorDescription == Self.formHelp)
        #expect(GitRemoteProblem.invalidBranch.errorDescription == "Enter a branch name with no spaces, such as main.")
    }

    @Test(arguments: [
        ("https://github.com/you/agent-tooling-workspace.git", "github.com"),
        ("https://GitLab.Example.com:8443/team/library", "gitlab.example.com"),
        ("git@github.com:you/agent-tooling-workspace.git", "github.com"),
        ("ssh://git@example.com/you/library.git", "example.com"),
        ("https://you:hunter2@github.com/you/library.git", "github.com"),
    ])
    func theHostIsTheOneAMessageNames(_ remote: String, _ host: String) {
        #expect(GitRemoteAddress.host(of: remote) == host)
    }

    @Test(arguments: ["/Volumes/Shared/library.git", "file:///Volumes/Shared/library.git", "", "library"])
    func aFolderOnThisMacHasNoHost(_ remote: String) {
        #expect(GitRemoteAddress.host(of: remote) == nil)
    }
}
