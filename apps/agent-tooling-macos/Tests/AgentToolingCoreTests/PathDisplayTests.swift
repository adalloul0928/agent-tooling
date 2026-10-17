import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Path display · home abbreviation")
struct PathDisplayTests {
    let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    /// A directory URL's path keeps its trailing slash, so a copy that
    /// compared against it showed "~Projects/app".
    @Test func aHomeGivenAsAFolderStillAbbreviatesWithItsSlash() {
        #expect(home.path(percentEncoded: false) == "/Users/example/")
        #expect(PathDisplay.abbreviatingHome("/Users/example/Projects/app", home: home) == "~/Projects/app")
        #expect(PathDisplay.abbreviatingHome("/Users/example/Projects/app", home: URL(filePath: "/Users/example")) == "~/Projects/app")
    }

    @Test func theHomeItselfIsATilde() {
        #expect(PathDisplay.abbreviatingHome("/Users/example", home: home) == "~")
        #expect(PathDisplay.abbreviatingHome("/Users/example/", home: home) == "~")
    }

    @Test func onlyAWholeFolderMatches() {
        #expect(PathDisplay.abbreviatingHome("/Users/example2/notes", home: home) == "/Users/example2/notes")
        #expect(PathDisplay.abbreviatingHome("/Users/exampleish", home: home) == "/Users/exampleish")
    }

    @Test func pathsOutsideHomeAndRelativePathsAreLeftAlone() {
        #expect(PathDisplay.abbreviatingHome("/opt/homebrew/bin/codex", home: home) == "/opt/homebrew/bin/codex")
        #expect(PathDisplay.abbreviatingHome("skills/pdf", home: home) == "skills/pdf")
    }

    /// The temporary folder resolves through /private; either spelling of
    /// the home matches either spelling of the path.
    @Test func thePrivatePrefixIsFoldedOnBothSides() {
        let temporaryHome = URL(filePath: "/private/var/folders/x/home", directoryHint: .isDirectory)
        #expect(PathDisplay.abbreviatingHome("/var/folders/x/home/.claude/skills", home: temporaryHome) == "~/.claude/skills")
        #expect(
            PathDisplay.abbreviatingHome("/private/var/folders/x/home/.claude", home: URL(filePath: "/var/folders/x/home")) == "~/.claude")
    }
}
