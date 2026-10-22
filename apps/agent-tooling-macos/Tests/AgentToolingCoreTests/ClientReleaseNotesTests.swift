import Foundation
import Testing

@testable import AgentToolingCore

/// What each client publishes, read into bounded notes that name their source
/// and cover only what is newer than the installed version.
@Suite("Client release notes")
struct ClientReleaseNotesTests {
    private struct ScriptedFetcher: ReleaseNotesFetching {
        let answers: [String: Result<String, any Error>]
        func fetch(_ url: URL) async throws -> Data {
            guard let answer = answers[url.absoluteString] else { throw ClientReleaseNotesError.unreachable("no script for \(url)") }
            return Data(try answer.get().utf8)
        }
    }

    private let claudeChangelog = """
        # Changelog

        ## 2.1.287
        - Added thing three

        ## 2.1.286
        - Added thing two
        - Fixed thing

        ## 2.1.285
        - Added thing one

        ## 2.1.284
        - Old
        """

    @Test func claudeNotesAreTheSectionsNewerThanTheInstalledVersion() async throws {
        let source = ClientReleaseNotesService.sources(for: .claude, installedVersion: "2.1.285")[0].absoluteString
        let service = ClientReleaseNotesService(fetcher: ScriptedFetcher(answers: [source: .success(claudeChangelog)]))

        let notes = try await service.notes(for: .claude, installedVersion: "2.1.285")

        #expect(notes.map(\.version) == ["2.1.287", "2.1.286"], "newest first, nothing at or below the installed version")
        #expect(notes[1].body == "- Added thing two\n- Fixed thing")
        #expect(notes.allSatisfy { $0.source == source })
        #expect(notes[0].rendered.hasPrefix("## Claude Code 2.1.287\nsource: https://"))
    }

    @Test func anUnreadableInstalledVersionKeepsTheNewestFewRatherThanHidingEverything() async throws {
        let source = ClientReleaseNotesService.sources(for: .claude, installedVersion: nil)[0].absoluteString
        let service = ClientReleaseNotesService(fetcher: ScriptedFetcher(answers: [source: .success(claudeChangelog)]))
        // The ASBX build reports "1.0.6408.0", which is older than everything.
        let notes = try await service.notes(for: .claude, installedVersion: "1.0.6408.0")
        #expect(notes.count == 4, "every note is newer than a version that is older than all of them")
        let unknown = try await service.notes(for: .claude, installedVersion: nil)
        #expect(unknown.count == 4)
    }

    @Test func codexNotesAreStableGitHubReleasesOnly() async throws {
        let releases = """
            [
              {"tag_name":"rust-v0.161.0-alpha.5","prerelease":true,"body":"Release","html_url":"https://x/a"},
              {"tag_name":"rust-v0.160.0","prerelease":false,"body":"## New Features\\n- Big one","html_url":"https://github.com/openai/codex/releases/tag/rust-v0.160.0"},
              {"tag_name":"rust-v0.159.2","prerelease":false,"body":"## Bug Fixes\\n- Small","html_url":"https://github.com/openai/codex/releases/tag/rust-v0.159.2"},
              {"tag_name":"rust-v0.159.1","prerelease":false,"body":"older","html_url":"https://x/c"},
              {"tag_name":"rust-v0.159.0","prerelease":false,"draft":true,"body":"draft","html_url":"https://x/d"}
            ]
            """
        let source = ClientReleaseNotesService.sources(for: .codex, installedVersion: "0.159.1")[0].absoluteString
        let service = ClientReleaseNotesService(fetcher: ScriptedFetcher(answers: [source: .success(releases)]))

        let notes = try await service.notes(for: .codex, installedVersion: "0.159.1.602")

        #expect(notes.map(\.version) == ["0.160.0", "0.159.2"])
        #expect(notes[0].source == "https://github.com/openai/codex/releases/tag/rust-v0.160.0", "each note names its own release page")
        #expect(notes[0].body.contains("Big one"))
    }

    @Test func kiroNotesComeFromOnePagePerMinorAndKeepTheArticleText() async throws {
        let sources = ClientReleaseNotesService.sources(for: .kiro, installedVersion: "2.26.0")
        #expect(
            sources.map(\.absoluteString) == [
                "https://kiro.dev/changelog/cli/2-26/", "https://kiro.dev/changelog/cli/2-27/",
                "https://kiro.dev/changelog/cli/2-28/", "https://kiro.dev/changelog/cli/2-29/",
            ])
        let page = """
            <html><head><script>ignored()</script><style>.x{}</style></head><body><nav>Menu</nav>
            <main><h1>Kiro CLI 2.27</h1><p>Highlights &amp; notes</p><ul><li>Faster <b>startup</b></li><li>New skills folder</li></ul></main>
            </body></html>
            """
        let fetcher = ScriptedFetcher(answers: [
            sources[0].absoluteString: .success("<main><h1>2.26</h1><p>a</p><p>b</p><p>c</p></main>"),
            sources[1].absoluteString: .success(page),
            sources[2].absoluteString: .failure(ClientReleaseNotesError.unreachable("404")),
            sources[3].absoluteString: .failure(ClientReleaseNotesError.unreachable("404")),
        ])
        let notes = try await ClientReleaseNotesService(fetcher: fetcher).notes(for: .kiro, installedVersion: "2.26.0")

        #expect(notes.map(\.version) == ["2.27"], "the installed minor is not news; the missing pages are not failures")
        #expect(notes[0].body.contains("- Faster startup"))
        #expect(notes[0].body.contains("Highlights & notes"))
        #expect(!notes[0].body.contains("ignored()") && !notes[0].body.contains("Menu"))
    }

    @Test func notesAreBoundedAndAnUnreachableSourceIsReportedInItsOwnWords() async throws {
        let big = (0..<20).map { "## 9.\($0)\n" + String(repeating: "x", count: 10_000) }.reversed().joined(separator: "\n")
        let source = ClientReleaseNotesService.sources(for: .claude, installedVersion: nil)[0].absoluteString
        let notes = try await ClientReleaseNotesService(fetcher: ScriptedFetcher(answers: [source: .success(big)])).notes(
            for: .claude, installedVersion: "1.0")
        #expect(notes.count <= ClientReleaseNotesService.maximumNotes)
        #expect(notes.allSatisfy { $0.body.count <= ClientReleaseNotesService.maximumBodyCharacters + 2 })
        #expect(notes.reduce(0) { $0 + $1.body.count } <= ClientReleaseNotesService.maximumTotalCharacters + 40)

        let down = ClientReleaseNotesService(
            fetcher: ScriptedFetcher(answers: [
                source: .failure(ClientReleaseNotesError.unreachable("raw.githubusercontent.com answered 503."))
            ]))
        await #expect(throws: ClientReleaseNotesError.self) { try await down.notes(for: .claude, installedVersion: nil) }
        await #expect(throws: ClientReleaseNotesError.self) { try await down.notes(for: .gemini, installedVersion: nil) }
    }
}
