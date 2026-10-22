import AgentToolingCore
import Foundation

/// The plan-time answer to "what would this actually put on my Mac?".
///
/// Two things a person cannot see from a list of names: what is inside the
/// folders that would be copied, and what command an app would be asked to run.
/// Both are worked out here, from the exact plan the Install button applies, so
/// the decision is made with the evidence in front of it.
struct DeploymentPlanReview: Sendable {
    private let contentRisks: [WorkspaceDeploymentInstallKey: ContentRiskReport]
    private let commands: [WorkspaceDeploymentInstallKey: String]
    /// The commands that run before a step's own, in order: the removal of
    /// the registration a connection replaces (D30).
    private let commandsFirst: [WorkspaceDeploymentInstallKey: [String]]
    /// What each replaced registration started, when it could be read.
    private let replaced: [WorkspaceDeploymentInstallKey: String]
    /// Steps that would ask an app to run a command, for which no command
    /// could be built, and why. They are still listed, marked as not running,
    /// so the count on the Install button is the count of things that happen.
    private let withoutCommand: [WorkspaceDeploymentInstallKey: String]

    init(
        contentRisks: [WorkspaceDeploymentInstallKey: ContentRiskReport] = [:],
        commands: [WorkspaceDeploymentInstallKey: String] = [:],
        commandsFirst: [WorkspaceDeploymentInstallKey: [String]] = [:],
        replaced: [WorkspaceDeploymentInstallKey: String] = [:],
        withoutCommand: [WorkspaceDeploymentInstallKey: String] = [:]
    ) {
        self.contentRisks = contentRisks
        self.commands = commands
        self.commandsFirst = commandsFirst
        self.replaced = replaced
        self.withoutCommand = withoutCommand
    }

    func contentRisk(for item: WorkspaceDeploymentItem) -> ContentRiskReport? {
        contentRisks[key(item)]
    }

    func command(for item: WorkspaceDeploymentItem) -> String? {
        commands[key(item)]
    }

    /// Every command the step runs, in the order it runs them: a replacement's
    /// removal, then its add. Empty for a step that runs none.
    func commandLines(for item: WorkspaceDeploymentItem) -> [String] {
        guard let command = commands[key(item)] else { return [] }
        return (commandsFirst[key(item)] ?? []) + [command]
    }

    /// What the registration this step replaces started, when the step
    /// replaces one and its app's configuration says.
    func replacedCommand(for item: WorkspaceDeploymentItem) -> String? {
        replaced[key(item)]
    }

    /// Whether this step replaces a registration its app already holds.
    func replacesRegistration(_ item: WorkspaceDeploymentItem) -> Bool {
        commandsFirst[key(item)] != nil
    }

    /// Why this step will do nothing when Install is pressed, if it will not.
    func reasonNothingRuns(for item: WorkspaceDeploymentItem) -> String? {
        withoutCommand[key(item)]
    }

    var stepsWithoutCommand: Int { withoutCommand.count }

    /// The listed steps that will do something when the plan is approved:
    /// every one but those no command could be built for. What the button
    /// counts and the verb it uses both come from this one list.
    func runnableSteps(of items: [WorkspaceDeploymentItem]) -> [WorkspaceDeploymentItem] {
        items.filter { reasonNothingRuns(for: $0) == nil }
    }

    /// Content that could not be read completely blocks its step.
    ///
    /// A partial scan must never borrow the reassuring semantics of a clean
    /// one: files nobody could inspect are exactly the files worth refusing to
    /// copy on somebody's behalf.
    var hasBlockedItems: Bool { contentRisks.values.contains { !$0.isComplete } }

    /// A single honest line for the top of the sheet. It states facts and never
    /// tells the operator what to decide.
    var headline: String? {
        var parts: [String] = []
        let incomplete = contentRisks.values.count { !$0.isComplete }
        if incomplete > 0 {
            parts.append("\(CountNoun("package scan").phrase(incomplete)) incomplete")
        }
        let findings = contentRisks.values.flatMap(\.findings)
        let malicious = findings.count { $0.severity == .malicious }
        let risky = findings.count { $0.severity == .risky }
        if malicious > 0 {
            parts.append(CountNoun("malicious content finding").phrase(malicious))
        }
        if risky > 0 { parts.append(CountNoun("risky content finding").phrase(risky)) }
        let step = CountNoun("step")
        if !commands.isEmpty {
            // The verb agrees with the count: "1 step runs", "2 steps run".
            parts.append("\(step.phrase(commands.count)) \(commands.count == 1 ? "runs" : "run") a command")
        }
        if !withoutCommand.isEmpty {
            parts.append("\(step.phrase(withoutCommand.count)) cannot run yet")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func key(_ item: WorkspaceDeploymentItem) -> WorkspaceDeploymentInstallKey {
        .init(artifactID: item.artifactID, physicalDestinationID: item.physicalDestinationID)
    }
}

/// Builds the review. Reading is all it does: nothing here writes, stages,
/// moves or deletes anything, and no command is run to find out what a command
/// would be.
enum DeploymentPlanReviewer {
    /// `locate` finds each app's tool, as the install that follows finds it,
    /// and `provenConnections` are the connections a receipt shows Agent
    /// Tooling set up, which decide whether a registration is replaced (D30).
    static func review(
        plan: WorkspaceDeploymentPlan,
        snapshot: WorkspaceApplicationSnapshot,
        contentStore: CentralPackageContentStore,
        homeRoot: URL,
        locate: (ClientKind, URL) -> URL? = { ClientExecutableLocator.locate($0, homeURL: $1) },
        provenConnections: [TargetSurface: Set<String>] = [:]
    ) async -> DeploymentPlanReview {
        var scanned: [ContentDigest: ContentRiskReport] = [:]
        var contentRisks: [WorkspaceDeploymentInstallKey: ContentRiskReport] = [:]
        for item in plan.items {
            let digest: ContentDigest
            switch item.action {
            case .installContent(let value): digest = value
            case .updateContent(_, let value): digest = value
            // Removing takes away the copy this app installed; there is no
            // incoming content to read.
            case .removeContent, .installNativePackage, .configureManagedConnection, .removeManagedConnection: continue
            }
            let key = WorkspaceDeploymentInstallKey(
                artifactID: item.artifactID, physicalDestinationID: item.physicalDestinationID)
            if let already = scanned[digest] {
                contentRisks[key] = already
                continue
            }
            let report: ContentRiskReport
            if let tree = try? await contentStore.read(digest) {
                report = scan(tree)
            } else {
                // Content the review could not open is content nobody has read.
                report = ContentRiskReport(
                    findings: [],
                    filesScanned: 0,
                    coverageNotes: [
                        "The approved copy of \(item.displayName) could not be read from your library, so nothing in it has been reviewed."
                    ],
                    reachedScanLimit: true)
            }
            scanned[digest] = report
            contentRisks[key] = report
        }

        // The same command builder the install itself uses, called with the
        // same plan and snapshot, so what is shown is what would run.
        let planned = WorkspaceDeploymentSession.commandPlans(
            plan: plan, snapshot: snapshot, homeRoot: homeRoot, locate: locate, provenConnections: provenConnections)
        var commands: [WorkspaceDeploymentInstallKey: String] = [:]
        var commandsFirst: [WorkspaceDeploymentInstallKey: [String]] = [:]
        var replaced: [WorkspaceDeploymentInstallKey: String] = [:]
        for step in planned.plugins {
            commands[
                .init(artifactID: step.artifactID, physicalDestinationID: step.physicalDestinationID)
            ] = rendered(step.executableURL, step.arguments)
        }
        for step in planned.connections {
            let key = WorkspaceDeploymentInstallKey(artifactID: step.artifactID, physicalDestinationID: step.physicalDestinationID)
            commands[key] = rendered(step.executableURL, step.arguments)
            if let first = step.preArguments { commandsFirst[key] = [rendered(step.executableURL, first)] }
            if let old = step.replacedCommand { replaced[key] = old }
        }
        return DeploymentPlanReview(
            contentRisks: contentRisks, commands: commands, commandsFirst: commandsFirst, replaced: replaced,
            withoutCommand: planned.withoutCommand)
    }

    /// One command, in the words a shell would read, for looking at only.
    private static func rendered(_ executable: URL, _ arguments: [String]) -> String {
        CommandLineDisplay.rendered(executable: executable, arguments: arguments)
    }

    /// Scans the exact bytes the library holds, without writing them anywhere
    /// first.
    ///
    /// The core scanner walks a directory, which would mean staging untrusted
    /// content on disk in order to decide whether to put it on disk. The rules
    /// are the scanner's own: its text taxonomy, its limits, and its refusal to
    /// call a partial answer a clean one.
    static func scan(
        _ tree: CapturedPackageTree,
        limits: ContentRiskScanner.Limits = ContentRiskScanner.Limits()
    ) -> ContentRiskReport {
        var findings: [ContentRiskFinding] = []
        var coverageNotes: [String] = []
        var filesScanned = 0
        var bytesScanned = 0
        var reachedLimit = false

        for entry in tree.entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard filesScanned < limits.maximumFiles, findings.count < limits.maximumFindings else {
                reachedLimit = true
                note(
                    findings.count >= limits.maximumFindings
                        ? "The finding limit was reached; remaining package entries were not inspected."
                        : "The file limit was reached before \(entry.relativePath).",
                    into: &coverageNotes)
                break
            }
            switch entry.kind {
            case .directory:
                continue
            case .symbolicLink:
                // A link points outside whatever the reviewer just read.
                findings.append(
                    ContentRiskFinding(
                        category: .remoteDependency,
                        severity: .risky,
                        relativePath: entry.relativePath,
                        headline: "Symbolic link leaves the reviewed package",
                        evidence: entry.relativePath,
                        guidance: "What this resolves to is not part of the content you reviewed."))
            case .file(let bytes, let executable):
                filesScanned += 1
                if executable {
                    findings.append(
                        ContentRiskFinding(
                            category: .executableContent,
                            severity: .risky,
                            relativePath: entry.relativePath,
                            headline: "Marked executable",
                            evidence: entry.relativePath,
                            guidance: "This file can be run directly. Read it as code, not as documentation."
                        ))
                }
                guard bytes.count <= limits.maximumFileBytes else {
                    reachedLimit = true
                    note("\(entry.relativePath) exceeded the per-file review limit.", into: &coverageNotes)
                    continue
                }
                guard bytes.count <= limits.maximumTotalBytes - min(bytesScanned, limits.maximumTotalBytes)
                else {
                    reachedLimit = true
                    note(
                        "The package exceeded the total content review limit before \(entry.relativePath).",
                        into: &coverageNotes)
                    break
                }
                bytesScanned += bytes.count
                // A file the scanner cannot decode has not been checked.
                guard let text = String(data: bytes, encoding: .utf8) else {
                    reachedLimit = true
                    note(
                        "\(entry.relativePath) was unreadable or was not valid UTF-8 text.",
                        into: &coverageNotes)
                    continue
                }
                // One call answers both halves: what the scanner found, and
                // whether a bound stopped it short of the whole text.
                let inspected = ContentRiskScanner.inspect(
                    text: text, relativePath: entry.relativePath, limits: limits)
                findings.append(contentsOf: inspected.findings)
                if inspected.wasTruncated {
                    reachedLimit = true
                    note(
                        "\(entry.relativePath) exceeded a line or line-length review limit.",
                        into: &coverageNotes)
                }
            }
        }

        let bounded = Array(findings.prefix(limits.maximumFindings))
        return ContentRiskReport(
            findings: bounded,
            filesScanned: filesScanned,
            coverageNotes: coverageNotes,
            reachedScanLimit: reachedLimit || bounded.count < findings.count)
    }

    private static func note(_ value: String, into notes: inout [String]) {
        guard notes.count < 32, !notes.contains(value) else { return }
        notes.append(value)
    }
}
