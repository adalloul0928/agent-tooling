import Foundation
import Testing

@testable import AgentToolingCore

/// A token hides after an address's path as easily as in its user part, and
/// whatever is in the address is stored where every Mac reads it and sent on
/// every fetch: an address with a query or a fragment is refused like one
/// with a password, and its suggestion leaves them out.
@Suite("Git remote address · after the path")
struct GitRemoteAddressQueryTests {
    @Test(arguments: [
        "https://github.com/you/lib.git?access_token=ghp_example",
        "https://gitlab.example.com/you/lib.git?private_token=glpat-example",
        "https://github.com/you/lib.git#ghp_example",
        "https://github.com/you/lib.git?",
        "ssh://github.com/you/lib.git?key=value",
        "file:///Volumes/Shared/library.git#main",
    ])
    func anAddressWithAQueryOrAFragmentIsRefused(_ remote: String) {
        #expect(!GitWorkspaceTransport.isValidRemote(remote))
        guard case .invalidAddress(let suggestion, let carriesSignIn) = GitRemoteAddress.problem(remote) else {
            Issue.record("\(remote) was not refused")
            return
        }
        #expect(carriesSignIn, "\(remote) is refused for what it may carry")
        #expect(GitRemoteAddress.problem(remote)?.errorDescription == "Enter a repository address without a user name or password in it.")
        if let suggestion {
            #expect(
                !suggestion.contains("?") && !suggestion.contains("#") && !suggestion.contains("ghp_") && !suggestion.contains("glpat"),
                "\(suggestion)")
            #expect(GitWorkspaceTransport.isValidRemote(suggestion))
        }
    }

    @Test func anHTTPSAddressLosesWhatFollowsItsPathInTheSuggestion() {
        #expect(
            GitRemoteAddress.httpsSuggestion(for: "https://github.com/you/lib.git?access_token=ghp_example")
                == "https://github.com/you/lib.git")
        #expect(GitRemoteAddress.httpsSuggestion(for: "https://github.com/you/lib.git#ghp_example") == "https://github.com/you/lib.git")
    }
}
