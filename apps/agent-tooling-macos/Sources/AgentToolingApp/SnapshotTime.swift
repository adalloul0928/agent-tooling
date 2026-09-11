import Foundation

/// A moment, said once, the way a person would say it: "just now", "25m ago",
/// "yesterday", "Sep 8". It is a snapshot of when something happened, not a
/// clock running against it, so nothing on screen ticks.
enum SnapshotTime {
    /// Lower-case, for the middle of a sentence: "checked 25m ago".
    static func compact(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        // Measured against the `now` given, never the wall clock: a snapshot of
        // one moment must say the same thing wherever and whenever it is asked.
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: dayBefore)
        {
            return "yesterday"
        }
        if seconds < 7 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// Capitalised, for standing on its own: "Yesterday".
    static func standalone(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let text = compact(date, now: now, calendar: calendar)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
