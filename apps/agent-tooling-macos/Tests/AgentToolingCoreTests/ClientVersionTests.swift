import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Versions compare by what a client's `--version` printed, in its own words.
///
/// Codex prints `codex-cli 0.164.0`, Claude Code `2.1.304 (Claude Code)` and
/// Kiro CLI `kiro-cli 2.32.0`, and those lines are what an observation
/// records. Comparing them once read as no version at all, which made Codex's
/// profile layout unknown and every release note look newer than the
/// installed release. Comparison reads the number now; the line recorded is
/// still the line printed.
@Suite("Client versions compared")
struct ClientVersionTests {
    @Test(arguments: [
        ("codex-cli 0.164.0", [0, 164, 0]),
        ("2.1.304 (Claude Code)", [2, 1, 304]),
        ("kiro-cli 2.32.0", [2, 32, 0]),
        ("0.38.2", [0, 38, 2]),
        ("v1.2.0", [1, 2, 0]),
        ("1.0.6408.0", [1, 0, 6_408, 0]),
        // A pre-release compares as the release it leads to.
        ("0.144.0-alpha.4", [0, 144, 0]),
        ("codex-cli 0.144.0-alpha.4", [0, 144, 0]),
    ])
    func aVersionLineComparesAsItsNumber(line: String, components: [Int]) throws {
        #expect(try #require(ClientVersion(line)).components == components)
    }

    @Test(arguments: ["nightly", "", "codex-cli", "unknown (Claude Code)"])
    func aLineWithNoNumberIsNoVersion(line: String) {
        #expect(ClientVersion(line) == nil)
    }

    @Test func noLineIsNoVersion() {
        #expect(ClientVersion(nil) == nil)
    }

    @Test func linesCompareByTheirNumbers() throws {
        let codex = try #require(ClientVersion("codex-cli 0.164.0"))
        #expect(codex > (try #require(ClientVersion("0.134.0"))))
        #expect(codex < (try #require(ClientVersion("codex-cli 0.165.0"))))
        let shorter = try #require(ClientVersion("0.164"))
        #expect(!(codex < shorter) && !(shorter < codex), "a missing part counts as 0")
        #expect(try #require(ClientVersion("0.9")) < (try #require(ClientVersion("0.134"))))
    }

    /// Codex's layout follows the line its `--version` printed.
    @Test func codexsProfileLayoutFollowsItsVersionLine() {
        #expect(CodexConfigurationAdapter(installedClientVersion: "codex-cli 0.164.0").usesSeparateProfileFiles)
        #expect(CodexConfigurationAdapter(installedClientVersion: "codex-cli 0.134.0").usesSeparateProfileFiles)
        #expect(!CodexConfigurationAdapter(installedClientVersion: "codex-cli 0.133.9").usesSeparateProfileFiles)
        #expect(!CodexConfigurationAdapter(installedClientVersion: "codex-cli nightly").usesSeparateProfileFiles)
    }

    /// Release notes are the ones newer than the installed release, read
    /// from the line its `--version` printed.
    @Test func releaseNotesAreTheOnesNewerThanTheVersionLine() async throws {
        let releases = """
            [
              {"tag_name":"rust-v0.160.0","prerelease":false,"body":"## New Features\\n- Big one","html_url":"https://x/a"},
              {"tag_name":"rust-v0.159.2","prerelease":false,"body":"## Bug Fixes\\n- Small","html_url":"https://x/b"},
              {"tag_name":"rust-v0.159.1","prerelease":false,"body":"older","html_url":"https://x/c"}
            ]
            """
        let changelog = "# Changelog\n\n## 2.1.287\n- Three\n\n## 2.1.286\n- Two\n\n## 2.1.285\n- One\n"
        let codexSource = try #require(ClientReleaseNotesService.sources(for: .codex, installedVersion: nil).first)
        let claudeSource = try #require(ClientReleaseNotesService.sources(for: .claude, installedVersion: nil).first)
        let service = ClientReleaseNotesService(
            fetcher: FixedReleaseNotes(pages: [codexSource: releases, claudeSource: changelog]))

        let codex = try await service.notes(for: .codex, installedVersion: "codex-cli 0.159.1")
        let claude = try await service.notes(for: .claude, installedVersion: "2.1.286 (Claude Code)")

        #expect(codex.map(\.version) == ["0.160.0", "0.159.2"])
        #expect(claude.map(\.version) == ["2.1.287"])
    }

    /// Display only: a read records the line as printed, and the evidence
    /// planners match against keeps it too.
    @Test func whatAReadRecordsIsTheLineAsPrinted() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        let read = await world.registry.scanAll(homeURL: world.url, runner: world.scriptedRunner(), clients: world.found)

        #expect(Set(read.compactMap(\.version)) == ["codex-cli 0.164.0", "2.1.304 (Claude Code)", "0.38.2"])
        let evidence = TargetCapabilityEvidence.derive(from: read)
        #expect(Set(evidence.compactMap(\.installedClientVersion)) == ["codex-cli 0.164.0", "2.1.304 (Claude Code)", "0.38.2"])
    }
}

/// Release pages answered from memory.
private struct FixedReleaseNotes: ReleaseNotesFetching {
    let pages: [URL: String]

    func fetch(_ url: URL) async throws -> Data {
        guard let page = pages[url] else { throw ClientReleaseNotesError.unreachable("no page for \(url)") }
        return Data(page.utf8)
    }
}
