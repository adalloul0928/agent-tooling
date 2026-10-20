import Foundation

/// Records all MCP tool calls, including reads, to expose reconnaissance as
/// well as queued changes. App and server share ActivityReceipt entries.
/// Stored separately from workspace snapshots to avoid cross-process races
/// when the app replaces a snapshot.
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
