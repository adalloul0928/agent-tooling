import AgentToolingCore
import Foundation

/// Shared result wording for reviewed installs. Only successful executable steps
/// count as installed; failed, held-back, and cancelled steps remain distinct.
/// App summaries distinguish complete success from partial completion.
struct DeploymentOutcome: Equatable, Sendable {
    /// The apps every step of which succeeded, in the app order.
    var installed: [ClientKind]
    /// The apps a step failed in, with the first failure's words.
    var failed: [ClientKind: String]
    /// The apps with a step the install never ran and none that failed: it
    /// was stopped before them.
    var unfinished: [ClientKind]
    /// The steps that were drawn but not run, because they would replace a
    /// copy, or a registration, Agent Tooling cannot prove it put there.
    var leftAlone: [WorkspaceDeploymentInstallKey]
    var succeededSteps: Int
    var failedSteps: Int
    /// The steps the install never ran.
    var stoppedSteps: Int
    var finishedAt: Date
    /// Whether a step took something out of an app, so what the install did
    /// is said as applied rather than installed, as its title said Apply.
    var hasRemoval = false

    init(
        installed: [ClientKind], failed: [ClientKind: String] = [:], unfinished: [ClientKind] = [],
        leftAlone: [WorkspaceDeploymentInstallKey] = [], succeededSteps: Int, failedSteps: Int = 0, stoppedSteps: Int = 0,
        finishedAt: Date
    ) {
        self.installed = ClientKind.allCases.filter(installed.contains)
        self.failed = failed
        self.unfinished = ClientKind.allCases.filter { unfinished.contains($0) && failed[$0] == nil }
        self.leftAlone = leftAlone
        self.succeededSteps = succeededSteps
        self.failedSteps = failedSteps
        self.stoppedSteps = stoppedSteps
        self.finishedAt = finishedAt
    }

    /// Whether every step ran and succeeded.
    var isComplete: Bool { failed.isEmpty && unfinished.isEmpty }

    /// One sentence for the result: "Installed to Claude Code and Codex.", or
    /// "Installed to 1 of 2 apps." when an app failed. A stopped install says
    /// it stopped, and how far it got; with no app installed throughout, the
    /// changes are counted, so the sentence never contradicts the receipt.
    var summary: String {
        let copy = LaunchpadCopy.Review.self
        let total = succeededSteps + failedSteps + stoppedSteps
        if succeededSteps == 0 {
            if !failed.isEmpty { return copy.nothingInstalled(appsRefusing: failed.count, hasRemoval: hasRemoval) }
            return stoppedSteps > 0 ? copy.stoppedBeforeAnything(hasRemoval: hasRemoval) : copy.nothingInstalled(hasRemoval: hasRemoval)
        }
        if isComplete {
            return copy.installed(to: LaunchpadCopy.list(installed.map(\.rawValue).sorted()), hasRemoval: hasRemoval)
        }
        if failed.isEmpty { return copy.stopped(after: succeededSteps, of: total) }
        if installed.isEmpty { return copy.installedChanges(succeededSteps, of: total, hasRemoval: hasRemoval) }
        return copy.installed(installed.count, of: installed.count + failed.count + unfinished.count, hasRemoval: hasRemoval)
    }

    /// The receipt's line: "Installed 4 changes · 9:52 AM".
    var receiptLine: String {
        LaunchpadCopy.Review.receipt(
            changes: succeededSteps, at: finishedAt.formatted(date: .omitted, time: .shortened), hasRemoval: hasRemoval)
    }

    /// The outcome of a reviewed install from how each of its steps ended, in
    /// the app each ran in. An app counts as installed only when every one of
    /// its steps succeeded; one failed step charges the app with that step's
    /// words, and a step the install stopped before (or could not run) keeps
    /// its app from counting as installed without counting as a failure.
    static func from(
        steps: [(client: ClientKind, end: ReviewedStepProgress)], leftAlone: [WorkspaceDeploymentInstallKey] = [],
        finishedAt: Date
    ) -> DeploymentOutcome {
        var failed: [ClientKind: String] = [:]
        var unfinished: Set<ClientKind> = []
        var succeeded = 0
        var failures = 0
        var stopped = 0
        for step in steps {
            switch step.end {
            case .succeeded:
                succeeded += 1
            case .failed(let words):
                failures += 1
                if failed[step.client] == nil {
                    failed[step.client] = words.isEmpty ? LaunchpadCopy.Review.stepDidNotFinish(in: step.client.rawValue) : words
                }
            case .started, .notRun:
                stopped += 1
                unfinished.insert(step.client)
            }
        }
        let apps = Set(steps.map(\.client))
        return DeploymentOutcome(
            installed: Array(apps.subtracting(failed.keys).subtracting(unfinished)), failed: failed,
            unfinished: Array(unfinished), leftAlone: leftAlone, succeededSteps: succeeded, failedSteps: failures,
            stoppedSteps: stopped, finishedAt: finishedAt)
    }

    /// The outcome of a run of the deployment session's operations: each
    /// result names the apps its operation wrote to, so a failure is charged
    /// to the app it happened in and an app with no failure counts as
    /// installed.
    static func from(
        results: [WorkspaceDeploymentSession.Result], leftAlone: [WorkspaceDeploymentInstallKey], finishedAt: Date
    ) -> DeploymentOutcome {
        var touched: Set<ClientKind> = []
        var failed: [ClientKind: String] = [:]
        for result in results {
            let clients = result.surfaces.compactMap(\.client)
            touched.formUnion(clients)
            guard result.failed > 0 else { continue }
            for client in clients where failed[client] == nil {
                failed[client] = result.outputs.first ?? LaunchpadCopy.Review.stepDidNotFinish(in: client.rawValue)
            }
        }
        return DeploymentOutcome(
            installed: Array(touched.subtracting(failed.keys)), failed: failed, leftAlone: leftAlone,
            succeededSteps: results.reduce(0) { $0 + $1.succeeded }, failedSteps: results.reduce(0) { $0 + $1.failed },
            finishedAt: finishedAt)
    }
}
