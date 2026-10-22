import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import SwiftUI

@testable import AgentToolingApp

/// Synthetic progress and service responses for Home's setup card and Done.
/// No service reads the Mac running the test. These hand-built facts also
/// cover states absent from the executable Launchpad sample workflow.
@MainActor
enum FinishSetupFixture {
    /// When Done is on screen and Home first opens: 9:54.
    static let doneAt = ClientHomeFixture.now.addingTimeInterval(13 * 60)
    /// When the review's install finished: 9:52.
    static let installedAt = ClientHomeFixture.now.addingTimeInterval(11 * 60)
    /// When Other Macs published: half a minute before Done.
    static let syncedAt = doneAt.addingTimeInterval(-30)
    /// "9:52 AM", as this Mac writes a time: the receipt's own format, with
    /// whatever space the locale puts before the period.
    static var installedTime: String { installedAt.formatted(date: .omitted, time: .shortened) }
    static let remote = "https://github.com/you/agent-tooling-workspace.git"

    static let releaseNotes = FinishSetupFacts.Skill(id: ArtifactID(), name: "Release Notes", declaredName: "release-notes")
    static let frontendDesign = FinishSetupFacts.Skill(
        id: ArtifactID(), name: "Frontend Design", declaredName: "frontend-design")
    static let sentry = FinishSetupFacts.Connection(name: "Sentry", serverID: "plugin:sentry:sentry", client: .claude)

    /// Juniper's Checkup after the run: Webapp Testing in two apps, Context7
    /// and Playwright each set up by hand in two.
    static let juniperFindings: [FinishSetupFacts.Finding] = [
        .init(
            id: "webapp-codex", kind: .unmanagedSkill, name: "Webapp Testing", apps: [.codex],
            title: "webapp-testing is not managed by this app"),
        .init(
            id: "webapp-claude", kind: .unmanagedSkill, name: "Webapp Testing", apps: [.claude],
            title: "webapp-testing is not managed by this app"),
        .init(
            id: "context7", kind: .mcpServerRepeatedAcrossClients, name: "Context7", apps: [.claude, .gemini],
            title: "context7 is configured separately in 2 apps"),
        .init(
            id: "playwright", kind: .mcpServerRepeatedAcrossClients, name: "Playwright", apps: [.codex, .claude],
            title: "playwright is configured separately in 2 apps"),
    ]

    /// The skill Home offers to try on Juniper.
    static let releaseNotesInCodex = SetupProgressRecord.Trial(skillName: "Release Notes", skillID: "release-notes", client: .codex)

    /// Juniper as Done finds it: three apps read, two skills made yours,
    /// the helper in Codex and Claude Code, shared with the repository, and
    /// Checkup's four findings.
    static func juniperFacts(record: SetupProgressRecord? = startedRecord()) -> FinishSetupFacts {
        var facts = FinishSetupFacts(record: record)
        facts.personalSkills = [releaseNotes, frontendDesign]
        facts.managedClients = [.codex, .claude, .gemini]
        facts.observedSkills = [
            .codex: ["frontend-design", "webapp-testing", "release-notes"],
            .claude: ["frontend-design", "webapp-testing", "release-notes"], .gemini: ["frontend-design"],
        ]
        facts.names = ["release-notes": "Release Notes", "frontend-design": "Frontend Design", "webapp-testing": "Webapp Testing"]
        facts.helperConnectedApps = [.codex, .claude]
        facts.signInCandidates = [sentry]
        facts.pendingChanges = 0
        facts.openFindings = juniperFindings
        facts.sync = .init(remote: remote, lastSynced: syncedAt)
        return facts
    }

    /// The first run's record as Done finds it: in progress at Done, with
    /// the folders Claude Code's history named.
    static func startedRecord(path: LaunchpadPath = .startHere, cursor: LaunchpadStep = .done) -> SetupProgressRecord {
        var record = SetupProgressRecord.started(path: path, cursor: cursor, now: ClientHomeFixture.now)
        record.evidence.projectFolderCount = 4
        return record
    }

    /// What Juniper's walk decided and did, as Done reads it.
    static func juniperInputs() -> LaunchpadDoneSummary.Inputs {
        var inputs = LaunchpadDoneSummary.Inputs(path: .startHere)
        inputs.decisions.adopted = [
            .init(artifactID: releaseNotes.id, name: "Release Notes", copyFrom: nil),
            .init(artifactID: frontendDesign.id, name: "Frontend Design", copyFrom: .claude),
        ]
        inputs.decisions.placed = [
            .init(artifactID: releaseNotes.id, name: "Release Notes", apps: [.codex, .claude], scope: .everyMac),
            .init(artifactID: frontendDesign.id, name: "Frontend Design", apps: [.codex, .claude], scope: .everyMac),
        ]
        inputs.decisions.helperApps = [.codex, .claude]
        inputs.outcomes.read = .init(
            looked: [
                .init(client: .codex, version: "0.164.0"), .init(client: .claude, version: "2.1.304"),
                .init(client: .gemini, version: "0.38.2"),
            ],
            notFound: [.kiro], places: 14, commands: 9)
        inputs.outcomes.addedPluginsAwaitingCheck = ["Supabase"]
        inputs.outcomes.install = DeploymentOutcome(
            installed: [.codex, .claude],
            leftAlone: [.init(artifactID: frontendDesign.id, physicalDestinationID: WorkspaceObjectID())], succeededSteps: 4,
            finishedAt: installedAt)
        inputs.outcomes.helperApps = [.codex, .claude]
        inputs.outcomes.sync = .init(address: remote, publishedAt: syncedAt, upToDate: true)
        inputs.facts = juniperFacts()
        inputs.tools = 13
        inputs.entries = 9
        inputs.leftAlone = ["Frontend Design in Codex"]
        inputs.alsoReads = [.init(app: .gemini, skill: "Release Notes", folder: "~/.agents/skills")]
        inputs.consent = AssistantRunConsent(weeklyReview: true, dailyDeepDive: false, localInsights: false)
        inputs.assistant = .claude
        inputs.deviceName = "Juniper"
        inputs.now = doneAt
        return inputs
    }

    /// The ↩-through walk on Juniper: nothing made yours, Agent Tooling's own
    /// connection installed in all three apps, Other Macs skipped, and
    /// Checkup's first-run eight left.
    static func returnThroughInputs() -> LaunchpadDoneSummary.Inputs {
        var inputs = juniperInputs()
        inputs.decisions = LaunchpadLibraryDecisions()
        inputs.decisions.helperApps = [.codex, .claude, .gemini]
        inputs.outcomes.addedPluginsAwaitingCheck = []
        inputs.outcomes.install = DeploymentOutcome(
            installed: [.codex, .claude, .gemini], succeededSteps: 3, finishedAt: installedAt)
        inputs.outcomes.helperApps = [.codex, .claude, .gemini]
        inputs.outcomes.sync = nil
        inputs.facts.personalSkills = []
        inputs.facts.helperConnectedApps = [.codex, .claude, .gemini]
        inputs.facts.sync = nil
        inputs.facts.openFindings = (0..<8).map { index in
            .init(
                id: "finding-\(index)", kind: .unmanagedSkill, name: ["Frontend Design", "Webapp Testing", "Release Notes"][index % 3],
                apps: [ClientKind.allCases[index % 3]], title: "")
        }
        inputs.tools = 12
        inputs.entries = 8
        inputs.leftAlone = []
        inputs.alsoReads = []
        return inputs
    }

    /// Cedar's join: Codex and Claude Code read, Juniper's five installs,
    /// joined over the repository, Db Migrations found here and left on
    /// Checkup, and Agent Tooling's own connection on Juniper only.
    static func cedarInputs() -> LaunchpadDoneSummary.Inputs {
        var inputs = LaunchpadDoneSummary.Inputs(path: .join)
        var record = startedRecord(path: .join, cursor: .done)
        record.evidence.personalSkillsBefore = [releaseNotes.id, frontendDesign.id]
        record.evidence.projectFolderCount = nil
        var facts = FinishSetupFacts(record: record)
        facts.personalSkills = [releaseNotes, frontendDesign]
        facts.managedClients = [.codex, .claude]
        facts.observedSkills = [
            .codex: ["release-notes", "frontend-design"], .claude: ["release-notes", "frontend-design", "db-migrations"],
        ]
        facts.names = ["db-migrations": "Db Migrations", "release-notes": "Release Notes", "frontend-design": "Frontend Design"]
        facts.openFindings = [.init(id: "db", kind: .unmanagedSkill, name: "Db Migrations", apps: [.claude], title: "")]
        facts.sync = .init(remote: remote, lastSynced: doneAt)
        facts.pendingChanges = 0
        inputs.facts = facts
        inputs.looked = [.init(client: .codex, version: "0.164.0"), .init(client: .claude, version: "2.1.304")]
        inputs.outcomes.install = DeploymentOutcome(installed: [.codex, .claude], succeededSteps: 5, finishedAt: installedAt)
        inputs.tools = 14
        inputs.entries = 10
        inputs.foundHere = ["Db Migrations"]
        inputs.consent = AssistantRunConsent(weeklyReview: true, dailyDeepDive: false, localInsights: false)
        inputs.assistant = .claude
        inputs.deviceName = "Cedar"
        inputs.now = doneAt
        return inputs
    }

    /// An empty Mac (V01): no app found, an empty library, nothing to read,
    /// place, connect or review.
    static func emptyMacInputs() -> LaunchpadDoneSummary.Inputs {
        var inputs = LaunchpadDoneSummary.Inputs(path: .startHere)
        var record = startedRecord()
        record.evidence.projectFolderCount = nil
        var facts = FinishSetupFacts(record: record)
        facts.openFindings = []
        facts.pendingChanges = 0
        inputs.facts = facts
        inputs.outcomes.read = .init(looked: [], notFound: ClientKind.allCases, places: 0, commands: 0)
        inputs.outcomes.skipped = [
            .place: "Nothing is put in apps: this Mac manages none yet.",
            .ask: "Agent Tooling is not connected: this Mac manages no app yet.",
        ]
        inputs.deviceName = "Juniper"
        inputs.now = doneAt
        return inputs
    }

    // MARK: Records

    /// The shapes of record Home's card is drawn from.
    enum Shape {
        /// Juniper after Go to Home: 7 rows, 3 done in setup.
        case juniper
        /// Left for later at `cursor`, with no rows of its own yet.
        case deferred(LaunchpadStep)
        /// Every row done.
        case allDone
        /// Juniper's card, hidden.
        case hidden
        /// The ↩-through walk's: 6 rows, 1 done in setup.
        case returnThrough
    }

    /// The finished record Done writes for Juniper, from the same summary
    /// Done draws, so the card and Done can never disagree.
    static func record(_ shape: Shape) -> SetupProgressRecord {
        switch shape {
        case .juniper, .hidden, .allDone:
            let summary = LaunchpadDoneSummary(juniperInputs())
            var record = startedRecord()
            record.state = .finished
            record.items = summary.items
            record.ticks = summary.ticks
            record.evidence = summary.evidence
            record.finishedAt = doneAt
            if case .hidden = shape { record.hiddenAt = doneAt }
            if case .allDone = shape {
                let done = Set(record.ticks.map(\.item))
                record.ticks += record.items.filter { !done.contains($0) }.map {
                    .init(item: $0, place: $0.canonicalPlace, at: doneAt, summary: nil)
                }
            }
            return record
        case .deferred(let cursor):
            var record = startedRecord(cursor: cursor)
            record.state = .deferred
            return record
        case .returnThrough:
            let summary = LaunchpadDoneSummary(returnThroughInputs())
            var record = startedRecord()
            record.state = .finished
            record.items = summary.items
            record.ticks = summary.ticks
            record.evidence = summary.evidence
            return record
        }
    }

    /// `facts` as Home shows them once the tracker has had its first look:
    /// each row the facts make true ticked where the tracker would name.
    static func afterFirstLook(_ facts: FinishSetupFacts) -> FinishSetupFacts {
        let session = WorkspaceSetupProgressSession(store: StubSetupProgressStore(facts.record))
        for (item, place) in FinishSetupTracker.ticks(
            FinishSetupChecklist.satisfied(facts), facts: facts, section: .overview, stagePresented: false, settled: false)
        {
            session.tick(item, place: place, summary: FinishSetupChecklist.summary(for: item, facts: facts, now: doneAt), now: doneAt)
        }
        var looked = facts
        looked.record = session.record
        return looked
    }

    /// Services that read nothing: a development build, and Raycast with no
    /// Agent Tooling extension.
    static let services = FinishSetupServices(
        installation: { home in
            AgentToolingInstallation(
                bundleURL: home.appending(path: "Agent Tooling.app"), location: .developmentBuild, mcpHelperURL: nil,
                cliHelperURL: nil, isAdHocSigned: true)
        },
        raycast: { _ in .appOnly })
}

extension View {
    /// What Home's card needs around it in a test: the navigation, a clock
    /// at Done's minute, no motion, so a capture is the card's final frame,
    /// and services that read nothing.
    @MainActor
    func finishSetupEnvironment(now: Date = FinishSetupFixture.doneAt) -> some View {
        environment(AppNavigationState())
            .environment(\.snapshotNow, now)
            .environment(\.stageMotion, .still)
            .environment(\.finishSetupServices, FinishSetupFixture.services)
            .environment(\.skillTrialOpening) { _ in RecordingSkillTrialOpening(available: []) }
    }
}

/// A health session over a scripted runner and locator, checked once: the
/// shape of `WorkspaceHealthSessionTests`, so no real app is ever run.
@MainActor
enum FinishSetupHealthCheck {
    final class Runner: CommandRunning, @unchecked Sendable {
        let answers: [String: String]

        init(answers: [String: String]) { self.answers = answers }

        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            let key = ([URL(filePath: executable).lastPathComponent] + arguments).joined(separator: " ")
            return CommandOutput(status: 0, standardOutput: answers[key] ?? "", standardError: "")
        }
    }

    static func checked(
        fixture: ShellRenderFixture, managing: Set<ClientKind>, answers: [String: String]
    ) async throws -> WorkspaceHealthSession {
        for client in ClientKind.allCases {
            await fixture.workspace.device.setEnabled(client, managing.contains(client))
        }
        let health = WorkspaceHealthSession(
            device: fixture.workspace.device, homeRoot: fixture.home, runner: Runner(answers: answers),
            locate: { client, _ in URL(filePath: "/opt/homebrew/bin/\(ClientExecutableLocator.executableName(for: client))") },
            loginRun: { _, _, _ in .completed(transcript: "Signed in.") }, openURL: { _ in })
        await health.check()
        return health
    }
}
