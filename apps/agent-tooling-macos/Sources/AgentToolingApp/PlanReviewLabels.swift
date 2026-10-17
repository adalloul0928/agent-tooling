/// The wording for a deployment plan wherever it is named: the review sheet's
/// title and button, and the cards and lines on Home and Apps that count what
/// a plan is holding. Kept apart from the views so every case can be pinned in
/// a test.
///
/// A plan can install, update, remove, or any mix. Calling a plan that only
/// removes "Install 1 change" misreads what the button does, so the verb is
/// "Apply" whenever the plan removes anything and "Install" otherwise, and the
/// same verb names the plan everywhere it is counted. The two empty-plan titles
/// are unchanged: a plan with nothing to run says so rather than counting zero
/// changes.
enum PlanReviewLabels {
    /// "Install" while every step puts something in place; "Apply" once any
    /// step takes something out.
    static func verb(hasRemoval: Bool) -> String {
        hasRemoval ? "Apply" : "Install"
    }

    /// The primary button's label.
    ///
    /// - Parameters:
    ///   - listedCount: Every step the plan lists.
    ///   - runnableCount: The listed steps that will run when the button is
    ///     pressed (the rest are waiting on something a person must do).
    ///   - hasRemoval: True when a step that will run removes content.
    static func actionLabel(listedCount: Int, runnableCount: Int, hasRemoval: Bool) -> String {
        if listedCount == 0 {
            // Nothing to run and nothing listed: the button says so rather than
            // "Install 0 changes", which reads as an action that does something.
            return "Nothing to install"
        }
        if runnableCount == 0 { return "Nothing can run yet" }
        return "\(verb(hasRemoval: hasRemoval)) \(CountNoun.change.phrase(runnableCount))"
    }

    /// The sheet's title, which matches the button once there is something to
    /// run and otherwise explains why there is not.
    static func title(listedCount: Int, runnableCount: Int, hasRemoval: Bool, hasExclusions: Bool) -> String {
        if listedCount == 0 {
            return hasExclusions ? "Nothing can be installed right now" : "Nothing to install"
        }
        return actionLabel(listedCount: listedCount, runnableCount: runnableCount, hasRemoval: hasRemoval)
    }

    /// The banner over a plan that stopped before it wrote anything.
    static func nothingDoneTitle(hasRemoval: Bool) -> String {
        hasRemoval ? "Nothing was changed" : "Nothing was installed"
    }

    /// What VoiceOver hears from the button while the plan runs.
    static func runningLabel(hasRemoval: Bool) -> String {
        hasRemoval ? "Applying changes" : "Installing"
    }

    /// The heading over the steps a prepared plan is holding: "Ready to
    /// install", or "Ready to apply" once one of them removes something.
    static func readyTitle(hasRemoval: Bool) -> String {
        "Ready to \(verb(hasRemoval: hasRemoval).lowercased())"
    }

    /// The same, counted, for a line under a title: "3 changes ready to
    /// install".
    static func readyLine(count: Int, hasRemoval: Bool) -> String {
        "\(CountNoun.change.phrase(count)) \(readyTitle(hasRemoval: hasRemoval).lowercased())"
    }

    /// The count on a tile with room for a few words only: "3 to install".
    static func waitingCount(_ count: Int, hasRemoval: Bool) -> String {
        "\(count) to \(verb(hasRemoval: hasRemoval).lowercased())"
    }
}
