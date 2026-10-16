import Foundation

/// One source for the button and accessibility strings that would otherwise
/// drift apart across screens. Keeping them here means Home, Apps and Accounts
/// all name the same action the same way.
enum ActionTitles {
    /// The label for a button that opens the review sheet. The trailing
    /// ellipsis marks it as opening a sheet rather than acting at once, the
    /// convention this app already follows for "Set up…" and "Add connection…".
    ///
    /// Pass the plan's change count when there is a plan so the button can say
    /// how much is waiting; pass `nil` when none has been prepared yet.
    static func reviewChanges(count: Int?) -> String {
        guard let count else { return "Review changes…" }
        return "Review \(count) change\(count == 1 ? "" : "s")…"
    }
}
