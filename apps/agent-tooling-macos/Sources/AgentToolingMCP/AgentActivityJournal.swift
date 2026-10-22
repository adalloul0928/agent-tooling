import AgentToolingCore
import Foundation

/// `AgentActivityJournal`'s model lives in `AgentToolingCore` now, shared with
/// the app's Activity screen; this file keeps the MCP server's own reading and
/// writing of it, and the service that records a call into it.
extension WorkspaceRevisionStore {
    func loadAgentActivityJournal() throws -> AgentActivityJournal {
        try activityJournal(as: AgentActivityJournal.self, default: AgentActivityJournal())
    }

    func saveAgentActivityJournal(_ journal: AgentActivityJournal) throws {
        try saveActivityJournal(journal)
    }
}

enum AgentActivityJournalService {
    static func record(
        tool: String,
        tier: ToolTier,
        outcome: HealthState,
        detail: String,
        client: UntrustedClientIdentity,
        store: WorkspaceRevisionStore,
        now: Date = .now
    ) {
        // A failure to journal must never fail the tool call it is describing,
        // and must never be reported to the caller: a caller that can tell
        // whether it was logged can probe for the condition where it is not.
        do {
            var journal = try store.loadAgentActivityJournal()
            let receipt = ActivityReceipt(
                kind: .configuration,
                title: "\(client.displayLabel) called \(tool)",
                detail: ResponseRedaction.redactedText(String(detail.prefix(400))),
                date: now,
                state: outcome,
                command: "mcp:\(tier.rawValue):\(tool)"
            )
            journal.entries.append(receipt)
            if journal.entries.count > AgentActivityJournal.maximumEntries {
                journal.entries.removeFirst(journal.entries.count - AgentActivityJournal.maximumEntries)
            }
            let day = dayKey(for: now)
            journal.dailyToolCallCounts[day, default: [:]][tool, default: 0] += 1
            if journal.dailyToolCallCounts.count > AgentActivityJournal.maximumRetainedDays {
                let retained = journal.dailyToolCallCounts.keys.sorted().suffix(AgentActivityJournal.maximumRetainedDays)
                journal.dailyToolCallCounts = journal.dailyToolCallCounts.filter { retained.contains($0.key) }
            }
            try store.saveAgentActivityJournal(journal)
        } catch {
            return
        }
    }

    static func dayKey(for date: Date) -> String {
        var formatter = Date.ISO8601FormatStyle(timeZone: .current)
        formatter = formatter.year().month().day().dateSeparator(.dash)
        return date.formatted(formatter)
    }
}
