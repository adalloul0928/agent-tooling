import Foundation

/// Decides whether a plan can run from the button that made it, or has to be
/// shown first.
///
/// Every plan still travels the same path — plan, safety review, approval
/// digest, staged execution, receipt. What this decides is only whether a
/// person has to look at the plan before it runs. A plan is shown when it
/// would do something they could not have guessed from the button they
/// pressed: touch files this app did not put there, remove anything, rewrite
/// a connection an app already has, do a lot at once, or carry content a scan
/// flagged. Everything else — putting a tool where nothing is, replacing a
/// copy this app installed and still holds the previous bytes of, adding a
/// connection an app does not have yet, or handing a package to the app's own
/// installer — is what the button said it would do, and runs.
///
/// The classifier is pure and reads only the plan plus facts the planner was
/// already given. It never looks at the disk; the executor's own checks remain
/// the last word on every write.
public enum OperationPlanRiskClassifier {
    /// How many items a plan may carry and still be "what the button said".
    /// Past this a person wants the summary even when every item is safe.
    public static let directItemLimit = 5

    public enum Verdict: Hashable, Sendable {
        /// Run it. The plan does only what was asked, where nothing is at risk.
        case direct
        /// Show it. Each reason is one sentence a person needs to read first.
        case needsReview([Reason])

        public var requiresReview: Bool {
            if case .needsReview = self { return true }
            return false
        }

        public var reasons: [Reason] {
            if case .needsReview(let reasons) = self { return reasons }
            return []
        }
    }

    /// Why a plan needs eyes. Ordered by how much a person would want to know
    /// first, so the review headline can lead with the most serious.
    public enum Reason: Hashable, Sendable, Comparable {
        /// A step would replace files this app cannot prove it installed.
        case replacesUnprovenContent(count: Int)
        /// A step would replace a copy this app installed that somebody has
        /// edited since. Theirs now, in the way that matters: overwriting it
        /// loses work.
        case replacesEditedCopies(count: Int)
        /// A step removes an install.
        case removesContent(count: Int)
        /// A step rewrites a connection the app already has configured. Adding
        /// one it does not have is an add like any other; changing one it has
        /// may change what the app is talking to.
        case reconfiguresConnection(count: Int)
        /// A content scan found something, or could not finish.
        case contentFlagged(count: Int)
        /// More items than fit under one button.
        case bulk(count: Int)
        /// Assignments the plan cannot carry out; the person should know what
        /// will not happen before deciding whether the rest should.
        case exclusions(count: Int)
        /// The plan was asked for by an agent, not a click.
        case requestedByAgent

        private var rank: Int {
            switch self {
            case .contentFlagged: 0
            case .replacesUnprovenContent: 1
            case .replacesEditedCopies: 2
            case .removesContent: 3
            case .reconfiguresConnection: 4
            case .requestedByAgent: 5
            case .exclusions: 6
            case .bulk: 7
            }
        }

        public static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rank < rhs.rank }

        /// One sentence, stated as a fact about the plan.
        public var summary: String {
            switch self {
            case .replacesUnprovenContent(let count):
                plural(count, "step", "replaces", "replace") + " files Agent Tooling did not put there."
            case .replacesEditedCopies(let count):
                plural(count, "step", "replaces", "replace") + " a copy that was edited after Agent Tooling installed it."
            case .removesContent(let count):
                plural(count, "step", "removes", "remove") + " an installed tool."
            case .reconfiguresConnection(let count):
                plural(count, "step", "changes", "change") + " a connection an app already has."
            case .contentFlagged(let count):
                "\(count) package\(count == 1 ? "" : "s") " + (count == 1 ? "has" : "have") + " a content finding to read first."
            case .bulk(let count):
                "\(count) changes at once."
            case .exclusions(let count):
                "\(count) assignment\(count == 1 ? "" : "s") cannot be carried out on this Mac."
            case .requestedByAgent:
                "An agent asked for this; nothing it asks for runs unseen."
            }
        }

        private func plural(_ count: Int, _ noun: String, _ singular: String, _ pluralVerb: String) -> String {
            count == 1 ? "1 \(noun) \(singular)" : "\(count) \(noun)s \(pluralVerb)"
        }
    }

    /// Facts about the plan the planner did not need but the decision does.
    public struct Context: Sendable {
        /// Destinations proven to hold an install this app made. A replacement
        /// at one of these is an update of our own copy; anywhere else it is
        /// somebody else's files.
        public var provenInstalls: Set<WorkspaceDeploymentInstallKey>
        /// Proven installs whose files no longer match what was installed:
        /// somebody edited them. Replacing one is a loss, not an update.
        public var editedInstalls: Set<WorkspaceDeploymentInstallKey>
        /// Steps the review found content findings for, or could not scan.
        public var flaggedContent: Set<WorkspaceDeploymentInstallKey>
        /// Connections the destination app already has configured under the
        /// same name. The planner cannot see inside an app's connection file,
        /// so the caller that can says so here; a step for one of these is a
        /// change, not an add.
        public var configuredConnections: Set<WorkspaceDeploymentInstallKey>
        /// Whether the plan originates from an agent's request rather than a
        /// person's click.
        public var requestedByAgent: Bool

        public init(
            provenInstalls: Set<WorkspaceDeploymentInstallKey> = [],
            editedInstalls: Set<WorkspaceDeploymentInstallKey> = [],
            flaggedContent: Set<WorkspaceDeploymentInstallKey> = [],
            configuredConnections: Set<WorkspaceDeploymentInstallKey> = [],
            requestedByAgent: Bool = false
        ) {
            self.provenInstalls = provenInstalls
            self.editedInstalls = editedInstalls
            self.flaggedContent = flaggedContent
            self.configuredConnections = configuredConnections
            self.requestedByAgent = requestedByAgent
        }
    }

    public static func classify(_ plan: WorkspaceDeploymentPlan, context: Context = .init()) -> Verdict {
        var reasons: [Reason] = []
        var unproven = 0
        var edited = 0
        var removals = 0
        var reconfigured = 0
        var flagged = 0

        for item in plan.items {
            let key = WorkspaceDeploymentInstallKey(
                artifactID: item.artifactID, physicalDestinationID: item.physicalDestinationID)
            if context.flaggedContent.contains(key) { flagged += 1 }
            switch item.action {
            case .installContent:
                // Nothing is there, by the planner's own observation. Adding
                // is what the button said.
                break
            case .updateContent:
                // Replacing is an update when it is our copy, and somebody
                // else's files when it is not.
                if !context.provenInstalls.contains(key) {
                    unproven += 1
                } else if context.editedInstalls.contains(key) {
                    edited += 1
                }
            case .removeContent:
                removals += 1
            case .installNativePackage:
                // The app's own installer does the work, with the app's own
                // rules. The person chose that app; this is the install they
                // asked for.
                break
            case .configureManagedConnection:
                if context.configuredConnections.contains(key) { reconfigured += 1 }
            }
        }

        if flagged > 0 { reasons.append(.contentFlagged(count: flagged)) }
        if unproven > 0 { reasons.append(.replacesUnprovenContent(count: unproven)) }
        if edited > 0 { reasons.append(.replacesEditedCopies(count: edited)) }
        if removals > 0 { reasons.append(.removesContent(count: removals)) }
        if reconfigured > 0 { reasons.append(.reconfiguresConnection(count: reconfigured)) }
        if context.requestedByAgent { reasons.append(.requestedByAgent) }
        if !plan.exclusions.isEmpty { reasons.append(.exclusions(count: plan.exclusions.count)) }
        if plan.items.count > directItemLimit { reasons.append(.bulk(count: plan.items.count)) }

        return reasons.isEmpty ? .direct : .needsReview(reasons.sorted())
    }
}
