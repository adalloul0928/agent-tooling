import AgentToolingCore
import Foundation

/// Saves assignments, plans deployment, classifies risk, and applies or requests
/// review through the existing Apps pipeline. Undo withdraws only assignments
/// and installations added by this operation; prior installs remain intact.
@MainActor @Observable
final class WorkspaceInstallSession {
    enum Phase: Equatable {
        /// Choosing apps.
        case choosing
        /// Saving the assignments and planning.
        case preparing
        /// The plan needs eyes before it runs; the picker shows it in place.
        case reviewing([OperationPlanRiskClassifier.Reason])
        /// Writing to the apps.
        case installing
        /// Done, with what happened to each app.
        case finished(InstallOutcome)
        /// Putting things back.
        case undoing
    }

    struct InstallOutcome: Equatable {
        var installed: [ClientKind]
        var failed: [ClientKind: String]
        /// What the planner left out, by sentence, so "installed to 2 of 3"
        /// says which one and why.
        var skipped: [String]
        var canUndo: Bool
        /// Nothing to write: every app asked for already had it.
        var alreadyPresent = false

        var summary: String {
            let names = installed.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)
            if alreadyPresent { return "Every app asked for already has it. Nothing was written." }
            switch (installed.count, failed.count + skipped.count) {
            case (0, 0): return "Nothing was installed."
            case (0, let rest): return rest == 1 ? "One step was left alone." : "\(rest) steps were left alone."
            case (_, 0): return "Installed to \(names.formatted(.list(type: .and)))."
            default: return "Installed to \(installed.count) of \(installed.count + failed.count + skipped.count) apps."
            }
        }
    }

    private(set) var phase: Phase = .choosing
    private(set) var errorMessage: String?
    /// The plan the review shows, when there is one to show.
    private(set) var reviewPlan: WorkspaceDeploymentPlan?
    /// Steps that will not run whatever anyone presses: they would replace
    /// files Agent Tooling did not put there, or a copy of its own that was
    /// edited since. The review lists them apart, and Install leaves them
    /// out. Adopting or removing the copy (Checkup) is the way through.
    private(set) var heldBack: [WorkspaceDeploymentItem] = []

    /// The review's steps that will run when approved.
    var runnableReviewItems: [WorkspaceDeploymentItem] {
        let held = Set(heldBack.map(WorkspaceDeploymentSession.installKey))
        return reviewPlan?.items.filter { !held.contains(WorkspaceDeploymentSession.installKey($0)) } ?? []
    }

    private let library: WorkspaceLibrarySession
    private let deployment: WorkspaceDeploymentSession
    private let device: WorkspaceDeviceSession
    private let service: WorkspaceApplicationService
    /// The contributions this install added, for Undo. Empty until saved.
    private var addedContributionIDs: [WorkspaceObjectID] = []
    /// The exact place-and-thing this install actually wrote, for Undo. Only a
    /// removal whose key is in here is applied when undoing, so a removal
    /// pending at another destination of the same artifact — left over from an
    /// unrelated withdrawal — is not swept up by scoping removals by artifact.
    private var installedKeys: Set<WorkspaceDeploymentInstallKey> = []
    private var targetArtifactIDs: Set<ArtifactID> = []
    /// The library revision the plan was read at: it installs only while the
    /// library is still there, so an approval given after another write is
    /// refused rather than run against a library the plan was not read from.
    private var planRevision: WorkspaceObjectID?

    init(
        library: WorkspaceLibrarySession, deployment: WorkspaceDeploymentSession,
        device: WorkspaceDeviceSession, service: WorkspaceApplicationService
    ) {
        self.library = library
        self.deployment = deployment
        self.device = device
        self.service = service
    }

    var isBusy: Bool {
        switch phase {
        case .preparing, .installing, .undoing: true
        case .choosing, .reviewing, .finished: false
        }
    }

    /// Saves the assignments and installs, or stops to show the plan.
    ///
    /// `requestedByAgent` marks a plan that came from the request queue rather
    /// than a click; those are always shown.
    func install(
        artifactIDs: [ArtifactID], presetID: ArtifactID? = nil,
        destinations: [PortableDestination], requestedByAgent: Bool = false
    ) async {
        guard !isBusy else { return }
        phase = .preparing
        errorMessage = nil
        targetArtifactIDs = Set(artifactIDs)

        // 0. The plan needs to have seen each chosen app. The launch scan
        //    usually has; when it has not (automatic checks off, a fresh
        //    workspace), look now rather than planning over nothing.
        let unseen = destinations.contains { destination in
            !device.observations.contains { $0.surface == destination.surface }
        }
        if unseen { await device.refresh() }

        // 1. Assign. The review step the library session insists on is run
        //    and applied here in one motion; the preview it produces is what
        //    tells Undo which contributions were new.
        if let presetID {
            await library.reviewPreset(presetID: presetID, destinations: destinations)
        } else {
            await library.reviewAssignments(artifactIDs: artifactIDs, destinations: destinations)
        }
        guard let review = library.review else {
            fail(library.errorMessage ?? "The assignments could not be prepared.")
            return
        }
        if presetID != nil {
            targetArtifactIDs.formUnion(review.command.additions.map(\.artifactID))
        }
        addedContributionIDs = review.command.additions.map(\.id)
        await library.applyReviewedAssignments()
        guard let receipt = library.lastReceipt else {
            fail(library.errorMessage ?? "The assignments could not be saved.")
            return
        }
        // A read that was already in flight when the save landed is a read of
        // the library before it; planning over that would find nothing to
        // install. Read again until the state carries the commit.
        if library.state?.snapshot.document.revision.id != receipt.committedRevisionID {
            await library.refresh()
        }

        // 2. Plan over this Mac, then look only at what was just asked for.
        await deployment.prepare()
        if let message = deployment.errorMessage, deployment.plan == nil {
            fail(message)
            return
        }
        guard let scoped = deployment.plan(for: targetArtifactIDs) else {
            fail("This Mac's apps could not be checked. The assignments are saved; install from the Apps screen.")
            return
        }
        planRevision = deployment.planRevision
        if scoped.items.isEmpty, scoped.exclusions.allSatisfy({ $0.reason == .alreadyPresent }) {
            // Already there everywhere it was asked for (Has it is not a
            // step). The assignment is saved, which is all there was to do;
            // nothing was written.
            phase = .finished(.init(installed: [], failed: [:], skipped: [], canUndo: false, alreadyPresent: true))
            return
        }

        // 3. Decide.
        heldBack = deployment.heldBack(in: scoped)
        switch deployment.risk(for: targetArtifactIDs, requestedByAgent: requestedByAgent) ?? .direct {
        case .direct:
            await apply(scoped)
        case .needsReview(let reasons):
            reviewPlan = scoped
            phase = .reviewing(reasons)
        }
    }

    /// The person has read the plan; run it.
    func approveReview() async {
        guard case .reviewing = phase, let reviewPlan else { return }
        await apply(reviewPlan)
    }

    /// Runs exactly the steps of `plan` that may run, and reads the outcome
    /// from each step: an app counts as installed only when every one of its
    /// steps ran and succeeded, so a step with no command to run it never
    /// makes its app read as installed.
    private func apply(_ plan: WorkspaceDeploymentPlan) async {
        phase = .installing
        let held = Set(heldBack.map(WorkspaceDeploymentSession.installKey))
        let running = plan.items.filter { !held.contains(WorkspaceDeploymentSession.installKey($0)) }
        let ends = StepEnds()
        if !running.isEmpty {
            guard let revision = planRevision else {
                fail(deployment.errorMessage ?? "This Mac's apps could not be checked. Nothing was changed.")
                return
            }
            let reviewed = WorkspaceDeploymentPlan(
                items: running, exclusions: [], requirements: plan.requirements, resolvedTargets: plan.resolvedTargets)
            switch await deployment.applyReviewed(reviewed, basedOn: revision, onStep: { ends.take($1, for: $0) }) {
            case .applied:
                break
            case .stale:
                fail(LaunchpadCopy.Review.changedWhileOpen)
                return
            case .notRun(let message):
                fail(message)
                return
            }
            // The apps whose own tool ran are checked again first, so the plan
            // read next sees what the install left there (D29). A copy needs
            // no check: the plan measures the folder itself.
            let asked = running.filter { item in
                switch item.action {
                case .installNativePackage, .configureManagedConnection, .removeManagedConnection:
                    ends.ran(WorkspaceDeploymentSession.installKey(item))
                case .installContent, .updateContent, .removeContent: false
                }
            }
            await device.refresh(only: Set(asked.compactMap(\.surface.client)))
            // Re-read, so what is shown next reflects what actually happened.
            await deployment.prepare()
        }
        var installed = Set<ClientKind>()
        var failed: [ClientKind: String] = [:]
        var notRun: [WorkspaceDeploymentItem] = []
        for item in running {
            guard let client = item.surface.client else { continue }
            switch ends.end(of: WorkspaceDeploymentSession.installKey(item)) {
            case .succeeded:
                installed.insert(client)
            case .failed(let output):
                if failed[client] == nil { failed[client] = output.isEmpty ? "Failed." : output }
            case .started, .notRun, nil:
                notRun.append(item)
            }
        }
        // An app with any step that did not succeed is not installed.
        installed.subtract(failed.keys)
        installed.subtract(notRun.compactMap(\.surface.client))
        // Remember the exact place-and-thing that actually landed, so Undo
        // removes only those: a step that failed or never ran did not write.
        installedKeys = Set(
            running.map(WorkspaceDeploymentSession.installKey).filter { ends.end(of: $0) == .succeeded })
        let skipped =
            plan.exclusions.filter { $0.reason != .alreadyPresent }.map(\.detail)
            + heldBack.map { "\($0.appName) already has \($0.displayName) from somewhere else; it was left alone." }
            + notRun.map { "\($0.appName) could not be asked to install \($0.displayName) on this Mac." }
        phase = .finished(
            .init(
                installed: Array(installed), failed: failed, skipped: skipped,
                canUndo: !installed.isEmpty && !addedContributionIDs.isEmpty))
    }

    /// Withdraws what this install added and removes the copies it placed.
    func undo() async {
        guard case .finished(let outcome) = phase, outcome.canUndo else { return }
        phase = .undoing
        errorMessage = nil
        await library.reviewRemoval(contributionIDs: addedContributionIDs)
        guard library.review != nil else {
            fail(library.errorMessage ?? "The install could not be undone.")
            return
        }
        await library.applyReviewedAssignments()
        guard library.lastReceipt != nil else {
            fail(library.errorMessage ?? "The install could not be undone.")
            return
        }
        // With the assignments gone, the planner offers the copies it proved
        // this app placed for removal; applying that is the undo. Only the keys
        // this install actually wrote are removed, so a removal pending at
        // another destination of the same artifact is left where it is.
        await deployment.prepare()
        await deployment.apply(only: targetArtifactIDs, includingRemovals: true, onlyRemovalKeys: installedKeys)
        if let message = deployment.errorMessage {
            fail(message)
            return
        }
        addedContributionIDs = []
        installedKeys = []
        phase = .finished(.init(installed: [], failed: [:], skipped: [], canUndo: false))
    }

    func reset() {
        phase = .choosing
        errorMessage = nil
        reviewPlan = nil
        heldBack = []
        addedContributionIDs = []
        installedKeys = []
        targetArtifactIDs = []
        planRevision = nil
        if library.review != nil, !library.isBusy { library.discardReview() }
    }

    private func fail(_ message: String) {
        errorMessage = message
        phase = .choosing
    }
}

/// How each step of an install ended, as the deployment session reports it.
@MainActor
private final class StepEnds {
    private var ends: [WorkspaceDeploymentInstallKey: ReviewedStepProgress] = [:]

    func take(_ progress: ReviewedStepProgress, for key: WorkspaceDeploymentInstallKey) {
        ends[key] = progress
    }

    func end(of key: WorkspaceDeploymentInstallKey) -> ReviewedStepProgress? {
        ends[key]
    }

    /// Whether the step ran, whatever came of it.
    func ran(_ key: WorkspaceDeploymentInstallKey) -> Bool {
        switch ends[key] {
        case .succeeded, .failed: true
        case .started, .notRun, nil: false
        }
    }
}
