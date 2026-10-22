import Foundation

@testable import AgentToolingApp
@testable import AgentToolingCore

/// A drift reader that always answers with what it was configured to, so a
/// test exercising drift never hashes a real path on disk.
struct StubInstallDriftReader: InstallDriftReading {
    var reports: [InstalledPackageDrift] = []
    func drift(in store: WorkspaceRevisionStore) async -> [InstalledPackageDrift] { reports }
}

extension ShellRenderFixture {
    /// One operation receipt and the journal entry that links back to it: the
    /// shapes `ActivitySection` and the command palette's receipts both reach
    /// for. Recorded straight onto the fixture's own store, the same way the
    /// app itself would have written them.
    @discardableResult
    func seedActivity(now: Date = .now) throws -> OperationReceipt {
        let receipt = OperationReceipt(
            planID: UUID(),
            kind: .installSkill,
            title: "Install Example Skill",
            state: .healthy,
            targetSurfaces: [.claudeCode],
            results: [],
            createdAt: now,
            verificationSummary: "Installed for Claude Code.",
            itemOutcomes: [
                OperationItemOutcome(id: UUID(), title: "Example Skill", status: .succeeded, reason: "Copied into place."),
                OperationItemOutcome(id: UUID(), title: "Optional Extra", status: .skipped, reason: "Already up to date."),
            ])
        try store.recordOperationReceipt(receipt)
        let journal = AgentActivityJournal(entries: [
            ActivityReceipt(
                kind: .configuration,
                title: "Installed Example Skill",
                detail: "Copied into ~/.claude/skills.",
                date: now,
                state: .healthy,
                command: "cp -R example ~/.claude/skills/example",
                affectedPaths: ["~/.claude/skills/example"],
                operationReceiptID: receipt.id)
        ])
        try store.saveActivityJournal(journal)
        return receipt
    }
}
