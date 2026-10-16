import AgentToolingCore

/// One wording for each deployment action, shared by the two sheets that show a
/// plan. The install sheet names the app inside the phrase ("Install in Claude
/// Code"); the plan sheet already prints the app after a separator, so it uses
/// the same verb with the place instead ("Install for your account"). Keeping
/// both renderings here stops the two sheets describing the same action in two
/// different ways.
extension WorkspaceDeploymentItem {
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
        case .removeContent: "Remove from \(app)"
        }
    }

    /// The phrase for the plan review sheet, where `place` is where the write
    /// lands ("in this project" / "for your account"). The app itself is shown
    /// separately by that sheet, so it is not repeated here.
    func planActionClause(place: String) -> String {
        switch action {
        case .installContent: "Install \(place)"
        case .updateContent(let from, _):
            from == nil
                ? "Replace what is there now, \(place)"
                : "Update to your approved version, \(place)"
        case .installNativePackage: "Ask its app to install it, \(place)"
        case .configureManagedConnection: "Add the connection \(place)"
        case .removeContent:
            // The plan sheet keeps the reassurance that a hand-edited copy is
            // left untouched; the install sheet has no room for it.
            "Remove the copy this app installed, \(place). Anything you changed is left alone."
        }
    }
}
