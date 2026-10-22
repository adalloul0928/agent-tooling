import AgentToolingCore

/// Shared deployment verbs for install and review sheets, with either the
/// client name or destination appended. Removal labels identify only copies
/// whose installation ownership the planner has verified.
extension WorkspaceDeploymentItem {
    /// Whether this step takes something out rather than putting something in.
    /// A plan holding one is not an install, so everything that names the plan
    /// says apply (`PlanReviewLabels`).
    var isRemoval: Bool { action.isRemoval }

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
        case .removeManagedConnection: "Remove the connection Agent Tooling added to \(app)"
        }
    }

    /// The step as a review lists it, the item and its app in one phrase, the
    /// app named as a person knows it (`ClientKind.rawValue`, "Codex", never
    /// "Codex CLI"): "Copy Release Notes into Codex", "Ask Claude Code to
    /// install Supabase", "Add Agent Tooling to Codex", "Remove Agent Tooling
    /// from Claude Code".
    func reviewTitle(app: String) -> String {
        switch action {
        case .installContent: "Copy \(displayName) into \(app)"
        case .updateContent(let from, _):
            from == nil ? "Replace \(displayName) in \(app)" : "Update \(displayName) in \(app)"
        case .installNativePackage: "Ask \(app) to install \(displayName)"
        case .configureManagedConnection: "Add \(displayName) to \(app)"
        case .removeContent, .removeManagedConnection: "Remove \(displayName) from \(app)"
        }
    }

    /// A step a review draws where it would have gone and does not run: the
    /// item and its app only, "Frontend Design in Codex".
    func leftAloneTitle(app: String) -> String {
        "\(displayName) in \(app)"
    }

    /// The app this step lands in, as a person knows it.
    var appName: String {
        surface.client?.rawValue ?? surface.displayName
    }

    /// The sentence a review sets on its own line under a step, when the step
    /// needs one. A copy's removal keeps the reassurance that a copy someone
    /// edited is left untouched. The install sheet has no room for it.
    var planActionNote: String? {
        if case .removeContent = action { "Anything you changed is left alone." } else { nil }
    }
}
