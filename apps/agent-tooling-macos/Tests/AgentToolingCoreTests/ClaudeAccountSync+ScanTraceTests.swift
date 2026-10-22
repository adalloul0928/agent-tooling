import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Every app's scan checks each skill it finds against the folder Claude
/// Code keeps its account's skills in. That check looks at `~/.claude` only
/// for a path that could be inside it, and a trace hears of the look, so a
/// first read of another app touches nothing of Claude Code's unseen.
@Suite("Accounts · the synced-skills check and the scan trace")
struct ClaudeAccountSyncScanTraceTests {
    /// A path with no `synced` component is answered without a look at
    /// `~/.claude`.
    @Test func aPathElsewhereIsAnsweredWithoutALookAtClaudeCodesFolder() throws {
        let home = try FixtureHome("synced-check-elsewhere")
        defer { home.remove() }
        let trace = FirstReadPlaceLog()

        let inside = ScanTrace.$current.withValue(trace) {
            ClaudeAccountSync.isInsideSyncedSkills(home.appending(".agents/skills/pdf"), homeURL: home.url)
        }

        #expect(!inside)
        #expect(trace.places.isEmpty, "\(trace.places.map(\.path))")
    }

    /// A path that could be inside is checked against `~/.claude/skills`
    /// with links followed, and the trace hears of that look: for the
    /// account's own folder, and for a skill in another app's folder that a
    /// link leads into it.
    @Test func aPathThatCouldBeInsideIsCheckedAndTheLookIsTraced() throws {
        let home = try FixtureHome("synced-check-inside")
        defer { home.remove() }
        try home.plantSkill(".claude/skills/synced/pdf", name: "pdf", description: "The account's.")
        try FileManager.default.createDirectory(
            at: home.appending(".codex/skills", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appending(".codex/skills/pdf"), withDestinationURL: home.appending(".claude/skills/synced/pdf"))
        let skills = home.appending(".claude/skills", directoryHint: .isDirectory)

        for path in [".claude/skills/synced/pdf", ".codex/skills/pdf"] {
            let trace = FirstReadPlaceLog()
            let inside = ScanTrace.$current.withValue(trace) {
                ClaudeAccountSync.isInsideSyncedSkills(home.appending(path), homeURL: home.url)
            }
            #expect(inside, "\(path)")
            #expect(trace.places == [skills], "\(path): \(trace.places.map(\.path))")
        }
    }

    /// The component is found as the containment check finds it, at every
    /// separator scalar, so a name after the folder that begins with a
    /// combining mark still leaves `synced` a component of its own.
    @Test func aNameThatBeginsWithACombiningMarkStillLeavesTheFolderItsOwnComponent() {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        #expect(ClaudeAccountSync.isInsideSyncedSkills(URL(filePath: "/Users/example/.claude/skills/synced/\u{301}pdf"), homeURL: home))
        #expect(ClaudeAccountSync.isInsideSyncedSkills(URL(filePath: "/Users/example/.claude/skills/Synced"), homeURL: home))
        #expect(!ClaudeAccountSync.isInsideSyncedSkills(URL(filePath: "/Users/example/.claude/skills/synced\u{301}/pdf"), homeURL: home))
    }
}
