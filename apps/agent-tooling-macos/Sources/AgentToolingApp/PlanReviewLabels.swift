/// The button and title wording for a deployment plan, kept apart from the
/// view so every case can be pinned in a test.
///
/// A plan can install, update, remove, or any mix. Calling a plan that only
/// removes "Install 1 change" misreads what the button does, so the verb is
/// "Apply" whenever the plan removes anything and "Install" otherwise. The two
/// empty-plan titles are unchanged: a plan with nothing to run says so rather
/// than counting zero changes.
enum PlanReviewLabels {
    /// The primary button's label.
    ///
    /// - Parameters:
    ///   - listedCount: Every step the plan lists.
    ///   - runnableCount: The listed steps that will run when the button is
    ///     pressed (the rest are waiting on something a person must do).
    ///   - hasRemoval: True when any listed step removes content.
    static func actionLabel(listedCount: Int, runnableCount: Int, hasRemoval: Bool) -> String {
        if listedCount == 0 {
            // Nothing to run and nothing listed: the button says so rather than
            // "Install 0 changes", which reads as an action that does something.
            return "Nothing to install"
        }
        if runnableCount == 0 { return "Nothing can run yet" }
        let verb = hasRemoval ? "Apply" : "Install"
        return "\(verb) \(runnableCount) change\(runnableCount == 1 ? "" : "s")"
    }

    /// The sheet's title, which matches the button once there is something to
    /// run and otherwise explains why there is not.
    static func title(listedCount: Int, runnableCount: Int, hasRemoval: Bool, hasExclusions: Bool) -> String {
        if listedCount == 0 {
            return hasExclusions ? "Nothing can be installed right now" : "Nothing to install"
        }
        return actionLabel(listedCount: listedCount, runnableCount: runnableCount, hasRemoval: hasRemoval)
    }
}
