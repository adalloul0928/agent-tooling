import Foundation
import Testing

@testable import AgentToolingCore

/// The number inside what an app's `--version` printed, for a person to read.
/// Display only: the raw line is what observations keep and planners compare.
@Suite("Client version text")
struct ClientVersionTextTests {
    @Test(arguments: [
        ("codex-cli 0.164.0", "0.164.0"),
        ("2.1.304 (Claude Code)", "2.1.304"),
        ("kiro-cli 2.32.0", "2.32.0"),
        ("0.38.2", "0.38.2"),
        ("v1.2.3", "1.2.3"),
        ("0.144.0-alpha.4", "0.144.0-alpha.4"),
        ("codex-cli 0.164.0\nupdate available: 9.9", "0.164.0"),
        ("Claude Code version 2.1.300.", "2.1.300"),
        ("tool/3.4.5 darwin-arm64", "3.4.5"),
        ("(4.0.1)", "4.0.1"),
    ])
    func theNumberIsFoundInAnAppsOwnWords(line: String, number: String) {
        #expect(ClientVersionText.number(in: line) == number)
    }

    @Test(arguments: ["nightly", "", "version unknown", "Claude Code", "vNext", "-v"])
    func aLineWithNoNumberHasNone(line: String) {
        #expect(ClientVersionText.number(in: line) == nil)
    }

    @Test func noLineHasNoNumber() {
        #expect(ClientVersionText.number(in: nil) == nil)
    }

    /// A pre-release compares as the release it leads to, so a minimum
    /// written as one is never failed by the release itself.
    @Test func componentsStopAtTheFirstSuffix() {
        #expect(ClientVersionText.numericComponents(of: "0.144.0-alpha.4") == [0, 144, 0])
        #expect(ClientVersionText.numericComponents(of: "2.1.304") == [2, 1, 304])
        #expect(ClientVersionText.numericComponents(of: "1.2.x") == [1, 2])
        #expect(ClientVersionText.numericComponents(of: "nightly") == nil)
        #expect(ClientVersionText.compare("0.9", "0.134") == .orderedAscending)
        #expect(ClientVersionText.compare("1.0", "1") == .orderedSame)
        #expect(ClientVersionText.compare("0.164.0", "0.144.0-alpha.4") == .orderedDescending)
        #expect(ClientVersionText.compare("nightly", "1.0") == nil)
    }
}

/// The minimums the release gate and the account readers were checked against,
/// from docs/compatibility.md. Too old is a finding only on a version that was
/// read and compared; anything unknown is never too old.
@Suite("Client compatibility minimums")
struct ClientCompatibilityTests {
    @Test func theTableIsTheCompatibilityMatrix() throws {
        #expect(ClientCompatibility.minimum(.releaseGate, for: .claude) == "2.1.207")
        #expect(ClientCompatibility.minimum(.accountReader, for: .claude) == "2.1.300")
        #expect(ClientCompatibility.minimum(.accountSync, for: .claude) == "2.1.273")
        #expect(ClientCompatibility.minimum(.releaseGate, for: .codex) == "0.144.0-alpha.4")
        #expect(ClientCompatibility.minimum(.accountReader, for: .codex) == "0.162.1")
        #expect(ClientCompatibility.minimum(.accountSync, for: .codex) == nil)
        for feature in ClientCompatibility.Feature.allCases {
            #expect(ClientCompatibility.minimum(feature, for: .gemini) == nil, "\(feature)")
            #expect(ClientCompatibility.minimum(feature, for: .kiro) == nil, "\(feature)")
        }
    }

    /// The table cites the document; if a row there changes, this fails and
    /// says which one, so the two cannot drift apart.
    @Test func theDocumentStillRecordsTheseMinimums() throws {
        let document = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/compatibility.md")
        let rows = try String(contentsOf: document, encoding: .utf8)
            .components(separatedBy: "\n").filter { $0.hasPrefix("| ") }
        func row(_ surface: String) -> String? { rows.first { $0.hasPrefix("| \(surface) |") } }

        #expect(row("Claude Code CLI")?.contains("| 2.1.207 |") == true)
        #expect(row("Codex CLI")?.contains("| 0.144.0-alpha.4 |") == true)
        #expect(row("Claude Code account reader")?.contains("| 2.1.300; account skill and plugin sync needs 2.1.273 |") == true)
        #expect(row("Codex account reader")?.contains("| 0.162.1 (`codex app-server`) |") == true)
        #expect(!rows.contains { $0.contains("Gemini") || $0.contains("Kiro") }, "Gemini CLI and Kiro CLI have no minimum")
    }

    @Test(arguments: [
        (ClientCompatibility.Feature.accountReader, ClientKind.codex, "codex-cli 0.158.0", true),
        (.accountReader, .codex, "codex-cli 0.164.0", false),
        (.accountReader, .codex, "codex-cli 0.162.1", false),
        (.accountReader, .claude, "2.1.304 (Claude Code)", false),
        (.accountReader, .claude, "2.1.299 (Claude Code)", true),
        (.accountSync, .claude, "2.1.272 (Claude Code)", true),
        (.accountSync, .claude, "2.1.273 (Claude Code)", false),
        (.releaseGate, .claude, "2.1.206 (Claude Code)", true),
        (.releaseGate, .codex, "codex-cli 0.143.9", true),
        (.releaseGate, .codex, "codex-cli 0.144.0-alpha.3", false),
        (.releaseGate, .codex, "codex-cli 0.144.0", false),
        (.accountSync, .codex, "codex-cli 0.0.1", false),
        (.accountReader, .gemini, "0.0.1", false),
        (.releaseGate, .kiro, "kiro-cli 0.0.1", false),
    ])
    func belowIsAComparedFinding(feature: ClientCompatibility.Feature, client: ClientKind, line: String, below: Bool) {
        #expect(ClientCompatibility.isBelow(feature, client: client, versionLine: line) == below)
    }

    @Test func anUnknownVersionIsNeverTooOld() {
        for feature in ClientCompatibility.Feature.allCases {
            for client in ClientKind.allCases {
                #expect(!ClientCompatibility.isBelow(feature, client: client, versionLine: nil))
                #expect(!ClientCompatibility.isBelow(feature, client: client, versionLine: "nightly"))
                #expect(!ClientCompatibility.isBelow(feature, client: client, versionLine: ""))
            }
        }
    }
}
