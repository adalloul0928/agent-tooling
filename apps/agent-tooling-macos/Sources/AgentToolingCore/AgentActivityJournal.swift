import Foundation

/// Every tool call an MCP client made, including the read-only ones.
///
/// Reads are recorded because reads are how reconnaissance looks. A person who
/// finds two queued requests should also be able to see that the same client
/// searched the inventory forty times first — that pattern is the signal, and
/// it is invisible if only writes are logged.
///
/// Entries are `ActivityReceipt` values, the same type the app's Activity
/// screen already uses, so that screen can render them without a second
/// vocabulary. The journal lives under its own key rather than inside the
/// workspace snapshot: the snapshot is rewritten wholesale by the app, and a
/// separate process appending to it would race the app's own writes.
///
/// The model lives in the core target so both the MCP server, which appends to
/// it (`AgentActivityJournalService`, kept beside the MCP server's own reading
/// and writing extension), and the app, which reads it for Activity, share one
/// on-disk shape instead of each keeping a private copy of it.
public struct AgentActivityJournal: Codable, Sendable {
    /// Detail rows are bounded so an agent in a loop cannot grow the workspace
    /// database without limit. Oldest rows roll off first.
    public static let maximumEntries = 200
    /// Daily totals outlive the detail rows, so "searched 40 times today"
    /// survives even after the individual rows have rolled off.
    public static let maximumRetainedDays = 30

    public var entries: [ActivityReceipt]
    /// Day (`yyyy-MM-dd`) to tool name to call count.
    public var dailyToolCallCounts: [String: [String: Int]]

    public init(entries: [ActivityReceipt] = [], dailyToolCallCounts: [String: [String: Int]] = [:]) {
        self.entries = entries
        self.dailyToolCallCounts = dailyToolCallCounts
    }
}
