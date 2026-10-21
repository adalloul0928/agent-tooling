import AgentToolingCore
import Foundation
import Observation

/// Publishes this Mac's status and fetches shared files once, then prepares an
/// incoming review. Nothing installs automatically. Library or observation changes
/// refresh the plan without repeating the initial sync pass.
@MainActor @Observable
final class LaunchpadArrivals {
    enum Phase: Equatable {
        /// The first pass, or a look at what arrived, is running.
        case checking
        case ready
    }

    /// One item another Mac shares that this Mac does not have yet.
    struct Row: Identifiable, Equatable {
        let artifactID: ArtifactID
        let name: String
        let kind: ToolingItemKind
        /// The apps on this Mac it goes into, in the app order.
        let apps: [ClientKind]
        /// The catalog's own identity, for its artwork, when it has one.
        let packageID: String?
        var id: ArtifactID { artifactID }
    }

    /// An item another Mac shares that cannot come in yet: its files are not
    /// in the library.
    struct LeftOut: Identifiable, Equatable {
        let artifactID: ArtifactID
        let name: String
        let kind: ToolingItemKind
        var id: ArtifactID { artifactID }
    }

    /// Another Mac using the library, with what it last published.
    struct OtherMac: Identifiable, Equatable {
        let id: WorkspaceObjectID
        let name: String
        let status: PublishedDeviceStatus?
    }

    /// Agent Tooling's own connection, which is bound to each Mac: where it is
    /// set up, and whether it is set up here.
    struct Helper: Equatable {
        let macs: [String]
        let isSetUpHere: Bool

        /// Where it is set up, as its row says it: on the other Macs only, on
        /// this one too, or on this one alone.
        var line: String {
            let copy = LaunchpadCopy.Join.self
            if macs.isEmpty { return copy.setUpHere }
            return isSetUpHere ? copy.setUpHereToo : copy.setUpOn(macs)
        }
    }

    private(set) var phase = Phase.checking
    private(set) var rows: [Row] = []
    private(set) var leftOut: [LeftOut] = []
    /// Why the first pass did not run, when it failed; the arrivals are then
    /// worked out from what the join brought.
    private(set) var passProblem: String?
    /// Why what arrived could not be worked out, when the plan could not be
    /// made: nothing is listed then, and nothing is said to be zero.
    private(set) var reviewProblem: String?
    private(set) var renameProblem: String?

    /// What the other Macs had published as the join read it, until the first
    /// pass here reads again.
    let joinStatuses: [PublishedDeviceStatus]

    @ObservationIgnored private let workspace: WorkspaceLaunch.Workspace
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// What the rows were worked out from, once they were.
    @ObservationIgnored private var settledMark: Mark?

    init(workspace: WorkspaceLaunch.Workspace, joinStatuses: [PublishedDeviceStatus] = []) {
        self.workspace = workspace
        self.joinStatuses = joinStatuses
    }

    // MARK: What the screen reads

    /// The name this Mac is registered under, read from the registry.
    var thisMacName: String {
        let registry = workspace.library.state?.snapshot.document.deviceRegistry ?? []
        return registry.first { $0.id == workspace.store.deviceID }?.name ?? ""
    }

    /// The other living Macs, in the order they joined, each with what it
    /// last published: as of the first pass, or as the join read it.
    var otherMacs: [OtherMac] {
        let registry = workspace.library.state?.snapshot.document.deviceRegistry ?? []
        let statuses = (workspace.sync?.otherDeviceStatuses ?? []) + joinStatuses
        return registry.filter { $0.id != workspace.store.deviceID && !$0.isRetired }
            .sorted { ($0.registeredAt, $0.name) < ($1.registeredAt, $1.name) }
            .map { device in OtherMac(id: device.id, name: device.name, status: statuses.first { $0.deviceID == device.id }) }
    }

    /// The other Mac the screen names: the first that joined.
    var otherMacName: String { otherMacs.first?.name ?? LaunchpadCopy.Join.otherMac }

    /// How many tools the library holds, as Library counts them, without
    /// Agent Tooling's own connection.
    var toolCount: Int {
        guard let state = workspace.library.state else { return 0 }
        let document = state.snapshot.document
        let definitions = document.mcpDefinitions ?? []
        let own = Set(
            document.artifacts.filter { AgentToolingConnection.isOwnConnection($0, definitions: definitions) }.map(\.identity.id))
        return state.library.rows.filter { !own.contains($0.artifactID) }.count + state.library.nestedToolCount
    }

    /// The library's own skills that came across.
    var personalSkillCount: Int {
        workspace.library.state.map { LaunchpadJoin.personalSkills(in: $0.snapshot.document).count } ?? 0
    }

    /// Every install the review would run: each arrival in each of its apps.
    var installCount: Int { rows.reduce(0) { $0 + $1.apps.count } }

    /// Agent Tooling's own connection, as the library has it now: Connect it
    /// here too records it for this Mac, so the row follows the library
    /// rather than the first look.
    var helper: Helper? {
        guard let document = workspace.library.state?.snapshot.document else { return nil }
        return Self.helper(in: document, thisDevice: workspace.store.deviceID)
    }

    /// Rename… can open: the first look has ended, and nothing is sharing.
    var canRename: Bool { phase == .ready && workspace.sync.map { !$0.isBusy } == true }

    /// The line under the greeting for `mac`: "Juniper · published 6 min ago
    /// · Codex 0.164.0 · Claude Code 2.1.304". The versions are the other
    /// Mac's, for the apps this Mac manages, in the app order: what the
    /// arrivals are about to be installed into here.
    func line(for mac: OtherMac, now: Date) -> String {
        let copy = LaunchpadCopy.Join.self
        guard let status = mac.status else { return copy.otherMacLine(name: mac.name, published: nil, apps: []) }
        let apps = workspace.device.managedClients.compactMap { client -> (name: String, version: String)? in
            guard let app = status.apps.first(where: { $0.surface.client == client && $0.installed }),
                let version = ClientVersionText.number(in: app.version)
            else { return nil }
            return (client.rawValue, version)
        }
        return copy.otherMacLine(name: mac.name, published: copy.ago(status.publishedAt, now: now), apps: apps)
    }

    // MARK: Loading

    /// The first pass, then what arrived. Called each time You joined
    /// appears: the pass runs once, and what arrived is worked out again when
    /// something it depends on moved since: the library, this Mac's check, or
    /// the plan, which a look that could not make one waits for. A call while
    /// one runs waits for it.
    func load() async {
        if let loading {
            await loading.value
            return
        }
        guard settledMark == nil || settledMark != mark else { return }
        let first = settledMark == nil
        phase = .checking
        let task = Task { await self.look(passingFirst: first) }
        loading = task
        await task.value
        loading = nil
    }

    private func look(passingFirst: Bool) async {
        if passingFirst {
            if workspace.setupProgress.record?.cursor == .join {
                // A launch that found the record still at Join opens here:
                // the app ended between the library record and the join's
                // own record of it, so what the join keeps is kept now.
                LaunchpadJoin.recordSkillsAlreadyYours(in: workspace)
            }
            workspace.installSyncStatusProvider()
            if let sync = workspace.sync {
                sync.load()
                if sync.isConnected {
                    await sync.sync()
                    passProblem = sync.errorMessage
                }
            }
        }
        await workspace.incoming.review(installingAutomatically: false)
        await workspace.library.refresh()
        settle()
        phase = .ready
    }

    /// What the rows are worked out from: the library, this Mac's check, and
    /// the plan, which an install changes without a new revision.
    private struct Mark: Equatable {
        let head: WorkspaceObjectID?
        let checkedAt: Date?
        let items: [WorkspaceDeploymentItem]?
        let exclusions: [WorkspaceDeploymentExclusion]?
    }

    private var mark: Mark {
        Mark(
            head: workspace.library.state?.snapshot.document.revision.id, checkedAt: workspace.device.lastCheckedAt,
            items: workspace.deployment.plan?.items, exclusions: workspace.deployment.plan?.exclusions)
    }

    private func settle() {
        settledMark = mark
        let deployment = workspace.deployment
        guard let state = workspace.library.state, deployment.plan != nil else {
            // No plan: what arrived is unknown, which is never zero.
            rows = []
            leftOut = []
            reviewProblem = LaunchpadCopy.Join.Failures.notWorkedOut(
                otherMacName, reason: workspace.incoming.errorMessage ?? deployment.errorMessage)
            return
        }
        reviewProblem = nil
        let rowsByID = Dictionary(state.library.rows.map { ($0.artifactID, $0) }, uniquingKeysWith: { first, _ in first })
        // In the order the review installs them: what is copied in, then what
        // an app installs itself, then connections; by name within each.
        func order(_ kind: ToolingItemKind) -> Int { Self.installOrder.firstIndex(of: kind) ?? Self.installOrder.count }
        rows = workspace.incoming.waiting
            .map { arrival in
                Row(
                    artifactID: arrival.artifactID, name: arrival.displayName, kind: arrival.kind, apps: arrival.clients,
                    packageID: rowsByID[arrival.artifactID]?.nativeRoutes.first?.externalPluginID)
            }
            .sorted { (order($0.kind), $0.name.lowercased()) < (order($1.kind), $1.name.lowercased()) }
        let arriving = Set(rows.map(\.artifactID))
        let missing = (workspace.deployment.plan?.exclusions ?? [])
            .filter { $0.reason == .missingContent }
            .compactMap(\.artifactID)
        leftOut = Array(Set(missing).subtracting(arriving))
            .compactMap { id -> LeftOut? in
                guard let row = rowsByID[id], Self.isFromAnotherMac(row, thisDevice: workspace.store.deviceID) else {
                    return nil
                }
                return LeftOut(artifactID: id, name: row.displayName, kind: Self.kind(of: row.kind))
            }
            .sorted { (order($0.kind), $0.name.lowercased()) < (order($1.kind), $1.name.lowercased()) }
    }

    /// The kinds in the order an install runs them.
    private static let installOrder: [ToolingItemKind] = [.skill, .plugin, .mcpServer]

    /// Whether another Mac asked for `row` here: a placement on every Mac, or
    /// one naming this Mac among others.
    private static func isFromAnotherMac(_ row: WorkspaceLibraryReadModelRow, thisDevice: WorkspaceObjectID) -> Bool {
        row.requestedAssignments.contains { WorkspaceIncomingSession.isShared($0.destination.deviceIDs, with: thisDevice) }
    }

    private static func kind(of kind: ArtifactKind) -> ToolingItemKind {
        switch kind {
        case .mcpServer: .mcpServer
        case .skill: .skill
        case .nativePlugin, .package, .preset, .logicalProject: .plugin
        }
    }

    /// Where Agent Tooling's own connection is set up, from the Macs its
    /// this-Mac-only placements name; nil when no Mac has it.
    static func helper(in document: PortableWorkspaceDocument, thisDevice: WorkspaceObjectID) -> Helper? {
        let definitions = document.mcpDefinitions ?? []
        guard let own = document.artifacts.first(where: { AgentToolingConnection.isOwnConnection($0, definitions: definitions) })
        else { return nil }
        let devices = Set(
            document.assignments.filter { $0.artifactID == own.identity.id && $0.desiredPresence }
                .flatMap { $0.destination.deviceIDs ?? [] })
        guard !devices.isEmpty else { return nil }
        let names = document.deviceRegistry
            .filter { devices.contains($0.id) && $0.id != thisDevice && !$0.isRetired }
            .sorted { ($0.registeredAt, $0.name) < ($1.registeredAt, $1.name) }
            .map(\.name)
        let isSetUpHere = devices.contains(thisDevice)
        guard !names.isEmpty || isSetUpHere else { return nil }
        return Helper(macs: names, isSetUpHere: isSetUpHere)
    }

    // MARK: Acting

    /// The review of every arrival, in the stage's own panel: the library
    /// decisions row is left out, as nothing was decided in the library here.
    func review() -> ScopedPlanReview {
        ScopedPlanReview(
            workspace: workspace, scope: .artifacts(Set(rows.map(\.artifactID))), includingRemovals: false,
            deviceName: thisMacName, libraryDecisions: nil)
    }

    /// Whether Rename ↩ takes `draft`: a name, and not the one this Mac has.
    func canRename(to draft: String) -> Bool {
        let wanted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return canRename && !wanted.isEmpty && wanted != thisMacName
    }

    /// Renames this Mac in the registry, then shares the new name. Returns
    /// whether it was renamed.
    @discardableResult
    func rename(to name: String) async -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sync = workspace.sync, !wanted.isEmpty, wanted != thisMacName else { return wanted == thisMacName }
        guard !sync.isBusy else {
            // The registry takes no change while a pass runs.
            renameProblem = LaunchpadCopy.Join.Failures.renameWhileSharing
            return false
        }
        renameProblem = nil
        await sync.renameDevice(workspace.store.deviceID, to: wanted)
        await workspace.library.refresh()
        if let message = sync.errorMessage, thisMacName != wanted {
            renameProblem = LaunchpadCopy.Join.Failures.notRenamed(message)
            return false
        }
        return thisMacName == wanted
    }

    /// Clears what a rename said, when its popover closes.
    func dismissRenameProblem() {
        renameProblem = nil
    }
}
