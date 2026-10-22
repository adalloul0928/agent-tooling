import AgentToolingCore
import Foundation

/// A read-only snapshot for the setup checklist, tracker, and Done. Missing
/// observations mean unknown, never success or failure. Building these facts
/// starts no client checks, account probes, project discovery, or audits.
struct FinishSetupFacts: Equatable, Sendable {
    /// A skill that is yours in the library, on its own (not inside a
    /// plugin).
    struct Skill: Equatable, Sendable {
        let id: ArtifactID
        let name: String
        let declaredName: String?
    }

    /// A connection in one app, by the name a person reads and the name the
    /// app knows it by ("Sentry", "plugin:sentry:sentry").
    struct Connection: Equatable, Sendable {
        let name: String
        let serverID: String
        let client: ClientKind
    }

    /// What the last connection check found.
    struct ConnectionCheck: Equatable, Sendable {
        var checkedAt: Date
        /// The connections a sign-in this app can run would fix.
        var signInOffers: [Connection]
        /// Every connection that reads "Needs authentication", whether or not
        /// a sign-in this app can run would fix it.
        var needsAuthentication: [Connection]
        /// Remote connections the check found connected.
        var connected: [Connection]

        /// The connections that need a sign-in only their own app can run: a
        /// local server, a claude.ai connector, an app with no login.
        var signInElsewhere: [Connection] {
            needsAuthentication.filter { needing in
                !signInOffers.contains { $0.client == needing.client && $0.serverID == needing.serverID }
            }
        }
    }

    /// One finding Checkup still shows, named as a person reads it.
    struct Finding: Equatable, Sendable {
        let id: String
        let kind: SetupFinding.Kind
        /// What it is about, as the library names it: "Webapp Testing".
        let name: String
        /// The apps it is about, in the app order.
        let apps: [ClientKind]
        /// The audit's own sentence, for a kind with no shorter form.
        let title: String

        /// `findings` in the order sentences about them name them: by kind,
        /// in the order the audit looks for each (a skill this library does
        /// not hold before a connection set up by hand in several apps), and
        /// within a kind in Checkup's own order. Checkup's report sorts its
        /// kinds by name, which would put the connections first.
        static func inWordingOrder(_ findings: [Finding]) -> [Finding] {
            let rank = Dictionary(uniqueKeysWithValues: SetupFinding.Kind.allCases.enumerated().map { ($1, $0) })
            return findings.enumerated()
                .sorted { lhs, rhs in
                    let left = rank[lhs.element.kind] ?? 0
                    let right = rank[rhs.element.kind] ?? 0
                    return left == right ? lhs.offset < rhs.offset : left < right
                }
                .map(\.element)
        }
    }

    /// This Mac's connection to the repository its other Macs share.
    struct Sync: Equatable, Sendable {
        var remote: String
        /// When the last pass finished; nil until one has, this launch.
        var lastSynced: Date?
    }

    /// The installs this launch ran, added up.
    struct Install: Equatable, Sendable {
        var changes: Int
        var failures: Int
    }

    var record: SetupProgressRecord?
    /// Whether this Mac may change the library: the card shows only then.
    var isWritable = true
    /// The name this Mac is registered under in the library, once it has one.
    var deviceName: String?
    var personalSkills: [Skill] = []
    var managedClients: [ClientKind] = []
    /// The skills each app's last check found on their own, by the name each
    /// declares.
    var observedSkills: [ClientKind: Set<String>] = [:]
    /// The different copies of each of those skills the managed apps hold,
    /// as their definition digests (D37), by the name it declares. Absent or
    /// one digest: every app that has it has the same copy.
    var skillCopies: [String: Set<String>] = [:]
    /// What the library calls a skill or a connection, by the name it
    /// declares: how a finding's subject and an observed skill are named.
    var names: [String: String] = [:]
    /// The managed apps that hold Agent Tooling's own connection for the
    /// person: their own configuration registers it for the whole account
    /// and their last check found it outside a plugin, as the planner and
    /// Let your apps ask count it. A plugin's server or one project's of the
    /// same name is not it.
    var helperConnectedApps: [ClientKind] = []
    /// Connections that may need a sign-in before any check has said so:
    /// remote connections a plugin brought into an app whose sign-in Agent
    /// Tooling can run, and the ones an app itself reports signed out.
    var signInCandidates: [Connection] = []
    /// Steps the prepared plan would run; nil before a plan is prepared.
    var pendingChanges: Int?
    /// The installs this launch ran; nil before any.
    var lastInstall: Install?
    var connectionCheck: ConnectionCheck?
    /// The findings Checkup shows; nil before any audit. A finding that this
    /// Mac and another are signed in to different accounts is left out: it
    /// is never one of setup's counts (D34).
    var openFindings: [Finding]?
    /// Project folders this Mac tracks.
    var trackedProjects = 0
    /// Nil while this Mac shares with no repository.
    var sync: Sync?
    /// Whether this copy runs from outside Applications and should move.
    var offersMove = false
}

extension FinishSetupFacts {
    /// The facts as they stand in `workspace` now. `installation` says where
    /// this copy runs from, when the caller knows; reading it can be slow, so
    /// it is never read here.
    @MainActor
    static func live(workspace: WorkspaceLaunch.Workspace, installation: AgentToolingInstallation? = nil) -> FinishSetupFacts {
        let snapshot = workspace.library.state?.snapshot
        let document = snapshot?.document
        let managed = workspace.device.managedClients
        let observations = workspace.device.observations.filter { $0.surface.client.map(managed.contains) ?? false }

        var facts = FinishSetupFacts(record: workspace.setupProgress.record)
        facts.isWritable = workspace.library.access == .writable
        facts.deviceName = document?.deviceRegistry.first { $0.id == workspace.store.deviceID }?.name
        facts.managedClients = managed
        facts.offersMove = installation?.offersMove ?? false

        let standalone = (document?.artifacts ?? []).filter { $0.identity.parentPackageID == nil }
        facts.personalSkills = standalone.filter { $0.identity.kind == .skill && $0.authority == .centralPersonal }
            .map { Skill(id: $0.identity.id, name: $0.identity.displayName, declaredName: $0.declaredName) }
        for artifact in standalone where [.skill, .mcpServer].contains(artifact.identity.kind) {
            guard let declared = artifact.declaredName, facts.names[declared] == nil else { continue }
            facts.names[declared] = artifact.identity.displayName
        }

        let signIns = ConnectionHealthLoginRunner(homeURL: workspace.homeRoot)
        for observation in observations {
            guard let client = observation.surface.client else { continue }
            let own = observation.skillMetadata.filter { $0.value.providerPluginID == nil }
            facts.observedSkills[client, default: []].formUnion(own.keys)
            for (name, metadata) in own {
                guard let digest = metadata.definitionDigest else { continue }
                facts.skillCopies[name, default: []].insert(digest)
            }
            if signIns.canLogIn(client: client) {
                facts.signInCandidates += signInCandidates(in: observation, client: client)
            }
        }
        facts.helperConnectedApps = FinishSetupHelperPresence.apps(in: observations)

        if workspace.deployment.plan != nil { facts.pendingChanges = workspace.deployment.pendingCount }
        let results = workspace.deployment.results
        if !results.isEmpty {
            facts.lastInstall = Install(
                changes: results.reduce(0) { $0 + $1.succeeded }, failures: results.reduce(0) { $0 + $1.failed })
        }

        facts.connectionCheck = connectionCheck(workspace.health, naming: facts)

        if let checkup = workspace.setup.checkup {
            facts.openFindings = checkup.openFindings.filter { $0.kind != .accountDiffersFromOtherMacs }.map { finding in
                Finding(
                    id: finding.id, kind: finding.kind, name: facts.names[finding.subject] ?? readableName(finding.subject),
                    apps: apps(of: finding), title: finding.title)
            }
        }

        facts.trackedProjects = snapshot?.device.projectRoots?.count ?? 0
        if let sync = workspace.sync, let enrollment = sync.enrollment {
            facts.sync = Sync(remote: enrollment.remote, lastSynced: sync.lastSynced)
        }
        return facts
    }

    /// What the last connection check found, or nil when none ran. A
    /// connection is named as setup already named it, else as the library
    /// does, else by its own name.
    @MainActor
    static func connectionCheck(_ health: WorkspaceHealthSession, naming facts: FinishSetupFacts) -> ConnectionCheck? {
        guard let checkedAt = health.lastCheckedAt else { return nil }
        let name = facts.connectionName
        return ConnectionCheck(
            checkedAt: checkedAt, signInOffers: health.reauthenticatableEntries.map(name),
            needsAuthentication: health.entries.filter { $0.status == .needsAuthentication }.map(name),
            connected: health.entries.filter { $0.status == .connected && $0.isRemoteEndpoint }.map(name))
    }

    /// The connections in one app's last check that may need a sign-in, for
    /// an app whose sign-in Agent Tooling can run: a remote connection a
    /// plugin brought, which signs in with an account, and any connection
    /// the app itself reports signed out. A connection set up by hand is
    /// left to the person who set it up; a local command signs in, if at
    /// all, through the app's own session.
    static func signInCandidates(in observation: TargetObservation, client: ClientKind) -> [Connection] {
        var found: [Connection] = []
        for (pluginID, plugin) in observation.pluginMetadata.sorted(by: { $0.key < $1.key }) where plugin.enabled {
            for server in plugin.mcpServerIDs {
                guard let metadata = observation.mcpMetadata[server], isRemote(metadata.transport) else { continue }
                let namespace = pluginID.split(separator: "@").first.map(String.init) ?? pluginID
                // Claude Code lists a plugin's connection as
                // plugin:<plugin>:<server>, and signs in to it by that name.
                let serverID = client == .claude ? "plugin:\(namespace):\(server)" : server
                found.append(Connection(name: plugin.name, serverID: serverID, client: client))
            }
        }
        for (server, metadata) in observation.mcpMetadata.sorted(by: { $0.key < $1.key })
        where metadata.authentication.lowercased() == "not logged in"
            && !found.contains(where: { $0.serverID == server })
        {
            found.append(Connection(name: server, serverID: server, client: client))
        }
        return found
    }

    /// Whether every managed app that has the skill declaring `declared`
    /// has the same copy of it, so any of them holds the library's.
    func holdsOneCopy(of declared: String) -> Bool {
        (skillCopies[declared]?.count ?? 0) <= 1
    }

    /// What a declared name reads as when the library holds nothing by it,
    /// the way a check names what it finds: "db-migrations" is "Db
    /// Migrations".
    static func readableName(_ declared: String) -> String {
        declared.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func isRemote(_ transport: String) -> Bool {
        let lowered = transport.lowercased()
        return lowered.contains("http") || lowered.contains("sse")
    }

    /// A connection a check listed, under the name setup already used for
    /// it, else the library's name for it, else its own.
    private func connectionName(_ entry: ConnectionHealthEntry) -> Connection {
        let known = signInCandidates.first { $0.client == entry.client && $0.serverID == entry.name }?.name
        return Connection(
            name: known ?? names[entry.displayName] ?? entry.displayName, serverID: entry.name, client: entry.client)
    }

    /// The apps a finding is about: its own, or for a server set up in
    /// several apps by hand, each of them.
    private static func apps(of finding: SetupFinding) -> [ClientKind] {
        if let client = finding.client { return [client] }
        let named = Set(finding.evidence.compactMap(ClientKind.init(rawValue:)))
        return ClientKind.allCases.filter(named.contains)
    }
}

/// Which apps hold Agent Tooling's own connection for the person, read from
/// their configuration files once per check rather than once per redraw: the
/// card, the tracker and Done read the facts on every look.
@MainActor
enum FinishSetupHelperPresence {
    private static var memo: (observations: [TargetObservation], apps: [ClientKind])?

    /// The apps among `observations` whose own configuration registers
    /// `agent-tooling` for the whole account and whose last check found it
    /// outside a plugin (`TargetObservation.userScopeMCPRegistrations()`), in
    /// the app order.
    static func apps(in observations: [TargetObservation]) -> [ClientKind] {
        if let memo, memo.observations == observations { return memo.apps }
        let holding = Set(
            observations.filter { $0.userScopeMCPRegistrations()[AgentToolingConnection.declaredName] != nil }
                .compactMap(\.surface.client))
        let apps = ClientKind.allCases.filter(holding.contains)
        memo = (observations, apps)
        return apps
    }
}
