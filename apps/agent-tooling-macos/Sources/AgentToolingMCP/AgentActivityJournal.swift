import AgentToolingCore
import Foundation

/// Every tool call, including the read-only ones, lands here.
///
/// Reads are recorded because reads are how reconnaissance looks. A person who
/// finds two queued requests should also be able to see that the same client
/// searched the inventory forty times first — that pattern is the signal, and
/// it is invisible if only writes are logged.
///
/// Entries are `ActivityReceipt` values, the same type the app's activity trail
/// already uses, so Insights can render them without a second vocabulary. The
/// journal lives under its own key rather than inside the workspace snapshot:
/// the snapshot is rewritten wholesale by the app, and a separate process
/// appending to it would race the app's own writes.
struct AgentActivityJournal: Codable, Sendable {
    /// Detail rows are bounded so an agent in a loop cannot grow the workspace
    /// database without limit. Oldest rows roll off first.
    static let maximumEntries = 200
    /// Daily totals outlive the detail rows, so "searched 40 times today"
    /// survives even after the individual rows have rolled off.
    static let maximumRetainedDays = 30

    var entries: [ActivityReceipt] = []
    /// Day (`yyyy-MM-dd`) to tool name to call count.
    var dailyToolCallCounts: [String: [String: Int]] = [:]
}

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
