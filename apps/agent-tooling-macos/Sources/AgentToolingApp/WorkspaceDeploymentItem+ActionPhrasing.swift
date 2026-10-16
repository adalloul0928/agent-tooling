import AgentToolingCore

/// One wording for each deployment action, shared by the two sheets that show a
/// plan. The install sheet names the app inside the phrase ("Install in Claude
/// Code"); the plan sheet already prints the app after a separator, so it uses
/// the same verb with the place instead ("Install on this Mac"). Keeping
/// both renderings here stops the two sheets describing the same action in two
/// different ways.
///
/// The place always follows the phrase directly, with no comma, so no action
/// reads as an afterthought beside another. A removal is "the copy Agent
/// Tooling installed" in both sheets: the planner only ever offers to remove a
/// copy it can prove it put there.
extension WorkspaceDeploymentItem {
    /// Whether this step takes something out rather than putting something in.
    /// A plan holding one is not an install, so everything that names the plan
    /// says apply (`PlanReviewLabels`).
    var isRemoval: Bool {
        if case .removeContent = action { true } else { false }
    }

    /// The phrase for the assignment (install) sheet, where `app` is the
    /// destination app's display name.
    func installActionText(app: String) -> String {
        switch action {
        case .installContent: "Install in \(app)"
        case .updateContent(let from, _):
            from == nil
                ? "Replace what is there now in \(app)"
                : "Update to your approved version in \(app)"
        case .installNativePackage: "Ask \(app) to install it"
        case .configureManagedConnection: "Add the connection to \(app)"
        case .removeContent: "Remove the copy Agent Tooling installed in \(app)"
        }
    }

    /// The phrase for the plan review sheet, where `place` is where the write
    /// lands ("in this project" / "on this Mac"). The app itself is shown
    /// separately by that sheet, so it is not repeated here.
    func planActionClause(place: String) -> String {
        switch action {
        case .installContent: "Install \(place)"
        case .updateContent(let from, _):
            from == nil
                ? "Replace what is there now \(place)"
                : "Update to your approved version \(place)"
        case .installNativePackage: "Ask its app to install it \(place)"
        case .configureManagedConnection: "Add the connection \(place)"
        case .removeContent: "Remove the copy Agent Tooling installed \(place)"
        }
    }

    /// The sentence the plan review sheet sets on its own line under a step,
    /// when the step needs one. A removal keeps the reassurance that a copy
    /// someone edited is left untouched. It used to end the clause, so that
    /// one step read as two sentences before the app's name; on its own line
    /// the clause stays one clause, like every other step's. The install sheet
    /// has no room for it.
    var planActionNote: String? {
        isRemoval ? "Anything you changed is left alone." : nil
    }
}
