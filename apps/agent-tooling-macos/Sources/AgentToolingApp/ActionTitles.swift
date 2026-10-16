import Foundation

/// One source for the button and accessibility strings that would otherwise
/// drift apart across screens. Keeping them here means Home, Apps and Accounts
/// all name the same action the same way.
enum ActionTitles {
    /// Where a command's title is shown. A menu title-cases its items, the way
    /// the system's own do ("Quit Agent Tooling", "Show Sidebar"): the main
    /// menu and the menu-bar item. The command palette is part of the window
    /// and uses the window's sentence case.
    enum CommandPlacement {
        case menu
        case palette
    }

    /// The label for a button that opens the review sheet. The trailing
    /// ellipsis marks it as opening a sheet rather than acting at once, the
    /// convention this app already follows for "Set up…" and "Add connection…".
    ///
    /// Pass the plan's change count when there is a plan so the button can say
    /// how much is waiting; pass `nil` when none has been prepared yet. A plan
    /// with nothing in it reads the same as no plan, never "Review 0 changes…".
    static func reviewChanges(count: Int?) -> String {
        guard let count, count > 0 else { return "Review changes…" }
        return "Review \(CountNoun.change.phrase(count))…"
    }

    /// The command that opens the same review from the main menu, the menu-bar
    /// item, or the command palette. It names no count: a command is there
    /// before any plan is.
    static func reviewChangesCommand(_ placement: CommandPlacement) -> String {
        switch placement {
        case .menu: "Review Changes…"
        case .palette: reviewChanges(count: nil)
        }
    }
}
