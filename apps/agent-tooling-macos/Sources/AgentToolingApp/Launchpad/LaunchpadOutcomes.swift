import AgentToolingCore
import Foundation

/// What Your apps and What Agent Tooling reads decided before anything is
/// written: the apps chosen, any tool folders the login shell found, and
/// whether Claude Code's history is read for projects. The commit records it
/// in revision 1.
struct LaunchpadSeed: Equatable, Sendable {
    var chosen: Set<ClientKind>
    /// Folders the login shell found tools in that the locator does not check
    /// on its own. Held in memory until the commit records them.
    var toolDirectories: [String] = []
    var findsProjectsFromClaudeHistory = true

    /// The device preferences revision 1 records for this seed: the chosen
    /// apps, the tool folders, the projects choice, and every assistant run
    /// off until Let your assistant help turns one on.
    var preferences: DeviceWorkspacePreferences {
        let clients = ClientKind.allCases.filter(chosen.contains)
        return DeviceWorkspacePreferences(
            enabledClients: clients, chosenClients: clients,
            customToolDirectories: toolDirectories.isEmpty ? nil : toolDirectories.sorted(),
            assistantRuns: .off, findsProjectsFromClaudeHistory: findsProjectsFromClaudeHistory)
    }
}

/// What a setup did in the library, kept by the stage because the library
/// alone cannot say it: which skills were made yours and from which copy,
/// what was added and from where, where things were put, and Agent Tooling's
/// own connection. The review panel's first row, Done's lines and Back's
/// withdrawal of this run's own placements read it.
struct LaunchpadLibraryDecisions: Equatable, Sendable {
    /// A skill made yours.
    struct Adopted: Equatable, Sendable {
        let artifactID: ArtifactID
        let name: String
        /// The app whose copy was brought in, when the apps had different
        /// copies and one was chosen; nil when there was only one.
        let copyFrom: ClientKind?
    }

    /// Something added to the library.
    struct Added: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// From an app's own catalog.
            case catalog(ClientKind)
            /// A skill from skills.sh.
            case skillsSh
            /// Written here, in the skill editor.
            case written
            /// From a pasted command or URL.
            case pasted
        }

        let artifactID: ArtifactID
        let name: String
        let source: Source
    }

    /// Where a placement applies.
    enum Scope: Equatable, Sendable {
        case everyMac
        case thisMacOnly
        case project(String)
    }

    /// One item put in apps.
    struct Placed: Equatable, Sendable {
        let artifactID: ArtifactID
        let name: String
        /// In the app order.
        let apps: [ClientKind]
        let scope: Scope
    }

    var adopted: [Adopted] = []
    var added: [Added] = []
    var placed: [Placed] = []
    /// The contributions this run recorded, so going Back and changing a
    /// cell withdraws exactly these.
    var contributionIDs: [WorkspaceObjectID] = []
    var helperArtifactID: ArtifactID?
    /// The apps Agent Tooling's own connection was set up for, on this Mac.
    var helperApps: [ClientKind] = []

    /// How many decisions there are: each skill made yours, each thing added,
    /// each item placed, and the connection.
    var count: Int { adopted.count + added.count + placed.count + (helperApps.isEmpty ? 0 : 1) }

    /// One line per decision, in the order they were made, as the review's
    /// library row and Done say them.
    var lines: [String] {
        let copy = LaunchpadCopy.Review.self
        var lines: [String] = []
        for skill in adopted {
            lines.append(skill.copyFrom.map { copy.madeYours(skill.name, fromCopyIn: $0.rawValue) } ?? copy.madeYours(skill.name))
        }
        for item in added {
            switch item.source {
            case .catalog(let client): lines.append(copy.added(item.name, fromCatalogOf: client.rawValue))
            case .skillsSh: lines.append(copy.addedFromSkillsSh(item.name))
            case .written: lines.append(copy.addedWrittenHere(item.name))
            case .pasted: lines.append(copy.addedFromPastedCommand(item.name))
            }
        }
        for item in placed {
            let apps = LaunchpadCopy.list(ClientKind.allCases.filter(item.apps.contains).map(\.rawValue))
            switch item.scope {
            case .everyMac: lines.append(copy.goesToEveryMac(item.name, apps: apps))
            case .thisMacOnly: lines.append(copy.goesToThisMacOnly(item.name, apps: apps))
            case .project(let project): lines.append(copy.goes(item.name, to: apps, inProject: project))
            }
        }
        if !helperApps.isEmpty {
            lines.append(copy.ownConnection(for: LaunchpadCopy.list(ClientKind.allCases.filter(helperApps.contains).map(\.rawValue))))
        }
        return lines
    }
}

/// What the setup's steps did, for Done: what was read, what was installed,
/// what was set up and synced, and each step passed over with its reason.
struct LaunchpadOutcomes: Equatable, Sendable {
    /// One app the read looked at.
    struct AppLine: Equatable, Sendable {
        let client: ClientKind
        /// As the app reported it, normalized for display.
        let version: String?
    }

    /// The first read, as it finished.
    struct ReadSummary: Equatable, Sendable {
        var looked: [AppLine] = []
        var notFound: [ClientKind] = []
        /// Chosen, but skipped before its read finished.
        var skipped: [ClientKind] = []
        var places = 0
        var commands = 0
    }

    /// Your other Macs, as it ended.
    struct SyncSummary: Equatable, Sendable {
        var address: String
        var publishedAt: Date?
        var upToDate: Bool
    }

    var read: ReadSummary?
    /// Plugins added from a catalog whose contents appear only after the next
    /// check.
    var addedPluginsAwaitingCheck: [String] = []
    var install: DeploymentOutcome?
    var helperApps: [ClientKind] = []
    /// Why Agent Tooling's own connection could not be set up here.
    var helperUnavailable: String?
    var sync: SyncSummary?
    /// Each step the walk passed over, with the sentence its screen gives.
    var skipped: [LaunchpadStep: String] = [:]
}
