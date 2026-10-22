extension LaunchpadCopy.Unreadable {
    // The screen the stage shows in Welcome's place when this Mac's library
    // record, workspace.json, cannot be read (plan §6).

    /// A newer Agent Tooling wrote the record.
    static let newerTitle = "This library was made by a newer Agent Tooling"
    /// The record is damaged, or could not be read from disk.
    static let unreadableTitle = "Agent Tooling could not read this Mac’s library"

    /// The menu-bar item's Quit, word for word.
    static let quit = ActionTitles.quitAgentTooling
    /// Shows the support folder in Finder, with the record selected.
    static let showInFinder = "Show in Finder"
    static let tryAgain = "Try again"

    enum Failures {
        static let newerFormat = "Update Agent Tooling on this Mac, then open it again. Nothing was changed."
        static let damaged = "Its record, workspace.json, is damaged, so it was left as it is. Nothing was changed."

        /// The reason the record could not be read, then that nothing was
        /// changed. A reason that already says so is not made to say it twice,
        /// and its apostrophes are set curly, as the stage's own are.
        static func unreadable(_ reason: String) -> String {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let said = trimmed.hasSuffix(nothingWasChanged) ? String(trimmed.dropLast(nothingWasChanged.count)) : trimmed
            let lead = said.trimmingCharacters(in: .whitespacesAndNewlines).withCurlyApostrophes
            return lead.isEmpty ? nothingWasChanged : "\(lead) Nothing was changed."
        }

        private static let nothingWasChanged = "Nothing was changed."
    }
}

extension String {
    /// The text with each straight apostrophe set curly.
    fileprivate var withCurlyApostrophes: String {
        replacingOccurrences(of: "\u{27}", with: "\u{2019}")
    }
}
