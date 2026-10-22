import AgentToolingCore
import Foundation
import Observation

/// Previews placements against the actual planner. Includes owned top-level items
/// and checked managed clients; excludes tracked-only items and plugin children.
/// Unowned or modified copies are held back. Shared skill folders follow their
/// owning client's column instead of producing duplicate writes.
/// Continue saves assignment intent in one revision without installing. Later
/// edits withdraw only this setup's contributions. Resumed flows restore saved
/// rows, scope, and explicitly omitted cells.
@MainActor @Observable
final class LaunchpadPlacement {
    /// One row: an item the grid can place.
    struct Item: Identifiable, Equatable, Sendable {
        let artifactID: ArtifactID
        let name: String
        let kind: ArtifactKind
        /// "Skill · Personal library", "Plugin · Claude Code’s catalog".
        let subtitle: String
        /// The catalog identity the row's artwork is drawn from, when the
        /// bundled artwork has it.
        let artworkID: String?

        var id: ArtifactID { artifactID }
    }

    /// One cell: an item in an app.
    struct Key: Hashable, Sendable {
        let item: ArtifactID
        let app: ClientKind
    }

    /// What a cell says, and whether Continue records it.
    enum Cell: Equatable, Sendable {
        /// The review installs it. Space leaves it out.
        case willInstall
        /// It could install and is left out. Space puts it back.
        case add
        /// The app already holds the library's copy.
        case hasIt
        /// The app holds a copy Agent Tooling will not replace, for `reason`.
        case leftAlone(reason: String)
        /// The app reads `app`'s skill folder, which gets the library's copy.
        case through(ClientKind)
        /// The app reads `app`'s skill folder, where `app`'s own copy stays.
        case readsCopy(of: ClientKind)
        /// The app reads `app`'s skill folder, where nothing is going.
        case readsFolder(of: ClientKind)
        /// Nothing can go here, for `reason`.
        case unavailable(String)

        /// Whether Continue records it as intent: a change, or a copy already
        /// there or left alone, so a Mac that joins later gets it too.
        var isRecorded: Bool {
            switch self {
            case .willInstall, .hasIt, .leftAlone: true
            case .add, .through, .readsCopy, .readsFolder, .unavailable: false
            }
        }
    }

    /// The Where control's choices.
    enum Scope: Hashable, Sendable {
        case everyMac
        case thisMacOnly
        case oneProject
    }

    /// A project this Mac tracks, with a folder here.
    struct Project: Identifiable, Hashable, Sendable {
        let id: ArtifactID
        let name: String
    }

    /// A move of the cursor, one cell at a time.
    enum Move: Sendable {
        case up
        case down
        case left
        case right
    }

    enum Phase: Equatable, Sendable {
        case loading
        case ready
        case saving
        /// The grid could not be worked out; the sentence says so.
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [Item] = []
    /// The columns, in the app order.
    private(set) var apps: [ClientKind] = []
    private(set) var cells: [Key: Cell] = [:]
    /// Where the keyboard is in the grid.
    private(set) var cursor: Key?
    private(set) var scope: Scope = .everyMac
    /// The project One project places into.
    private(set) var projectID: ArtifactID?
    /// The projects this Mac tracks. With none, One project cannot be chosen.
    private(set) var projects: [Project] = []
    /// Whether another Mac shares the library.
    private(set) var hasOtherMacs = false
    /// Whether this Mac is set to take only what names it, so what goes to
    /// every Mac leaves it out. The grid opens on This Mac only there.
    private(set) var takesOnlyWhatNamesIt = false
    /// What the library holds that is not a row, and why: what stays with
    /// its apps and what is not yours yet.
    private(set) var libraryCaption: String?
    /// Why each app with no column has none.
    private(set) var appCaptions: [String] = []
    /// What the card says when there is no row to place.
    private(set) var emptyText = ""
    /// Why the last save failed, until the next one.
    private(set) var saveError: String?
    /// How many reads and re-plans are under way over the grid on screen.
    private var refreshes = 0

    /// True while the grid is read again, or worked out again for another
    /// Where choice, over the one on screen: nothing is saved or re-planned
    /// until the new one is in.
    var isRefreshing: Bool { refreshes > 0 }

    /// How many times the grid has been read for the screen. Put in apps
    /// reads it each time it appears, so a save asked for on one appearance
    /// can tell whether the walk left the step and came back while it saved.
    @ObservationIgnored private(set) var visit = 0

    @ObservationIgnored private let workspace: WorkspaceLaunch.Workspace
    /// Cells the person turned off, kept across a reload, so going back to
    /// the grid finds it as it was left.
    @ObservationIgnored private var leftOut: Set<Key> = []
    /// Cells something else already asks for: drawn, never toggled.
    @ObservationIgnored private var locked: Set<Key> = []
    /// The apps whose own catalog each row comes from: a plugin's routes.
    @ObservationIgnored private var catalogs: [ArtifactID: Set<ClientKind>] = [:]
    /// The load under way, which a second caller waits for.
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Whether a read has landed. The first opens the grid on what this
    /// setup saved before, when it saved anything.
    @ObservationIgnored private var hasRead = false

    init(workspace: WorkspaceLaunch.Workspace) {
        self.workspace = workspace
    }

    // MARK: Reading the grid

    /// What the next step's review installs from here: Will install cells
    /// only. Has it never counts, and neither does a cell another app's
    /// folder serves.
    var changeCount: Int {
        cells.values.filter { $0 == .willInstall }.count
    }

    /// Whether Continue can save now.
    var canContinue: Bool {
        phase == .ready && !isRefreshing && !(scope == .oneProject && projectID == nil)
    }

    /// Whether Space turns this cell on or off. Every other cell is read and
    /// passed over.
    func isToggleable(_ key: Key) -> Bool {
        guard !locked.contains(key) else { return false }
        return cells[key] == .willInstall || cells[key] == .add
    }

    /// The project One project places into, by name.
    var projectName: String? {
        projects.first { $0.id == projectID }?.name
    }

    /// Reads the library and this Mac's apps, then works the cells out. The
    /// grid keeps what the person turned off and where the cursor was. A
    /// load asked for while one is under way waits for that one; while the
    /// grid is being saved it is left as it is. `decisions.contributionIDs`
    /// are this setup's own placements, which the grid may change.
    func load(decisions: LaunchpadLibraryDecisions) async {
        visit += 1
        if let loading {
            await loading.value
            return
        }
        guard phase != .saving else { return }
        let loading = Task { await self.read(decisions: decisions) }
        self.loading = loading
        await loading.value
        self.loading = nil
    }

    private func read(decisions: LaunchpadLibraryDecisions) async {
        refreshes += 1
        defer { refreshes -= 1 }
        await workspace.library.refresh()
        guard phase != .saving else { return }
        guard let state = workspace.library.state else {
            phase = .failed(LaunchpadCopy.Place.Failures.notChecked)
            return
        }
        let snapshot = state.snapshot
        let document = snapshot.document
        let thisMac = workspace.library.deviceID
        hasOtherMacs = document.deviceRegistry.contains { $0.id != thisMac && !$0.isRetired }
        takesOnlyWhatNamesIt = document.deviceRegistry.first { $0.id == thisMac }.map { !$0.receivesSharedAssignments } ?? false
        let names = Dictionary(document.logicalProjects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        projects = (snapshot.device.projectRoots ?? [])
            .compactMap { root in names[root.projectID].map { Project(id: root.projectID, name: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let projectID, !projects.contains(where: { $0.id == projectID }) { self.projectID = nil }
        if scope == .oneProject, projects.isEmpty { scope = .everyMac }
        let own = Set(decisions.contributionIDs)
        let saved = document.assignments.filter { own.contains($0.id) }
        let opensOnSaved = !hasRead
        hasRead = true
        if opensOnSaved { openScope(on: saved) }
        readColumns()
        readRows(state, decisions: decisions)
        if opensOnSaved { openLeftOut(on: saved) }
        await plan(own: own)
    }

    private func readColumns() {
        let managed = workspace.device.managedClients
        let observations = workspace.device.observations
        func observation(_ app: ClientKind) -> TargetObservation? {
            observations.first { $0.surface == app.defaultSurface }
        }
        apps = managed.filter { observation($0)?.installed == true }
        let copy = LaunchpadCopy.Place.self
        var captions: [String] = []
        let off = ClientKind.allCases.filter { !managed.contains($0) }
        if !off.isEmpty { captions.append(copy.off(LaunchpadCopy.list(off.map(\.rawValue)), count: off.count)) }
        let unchecked = managed.filter { observation($0) == nil }
        if !unchecked.isEmpty {
            captions.append(copy.notChecked(LaunchpadCopy.list(unchecked.map(\.rawValue)), count: unchecked.count))
        }
        let missing = managed.filter { observation($0).map { !$0.installed } ?? false }
        if !missing.isEmpty { captions.append(copy.notFound(LaunchpadCopy.list(missing.map(\.rawValue)), count: missing.count)) }
        appCaptions = captions
    }

    private func readRows(_ state: WorkspaceLibraryState, decisions: LaunchpadLibraryDecisions) {
        let document = state.snapshot.document
        let thisMac = workspace.library.deviceID
        let managed = Set(workspace.device.managedClients)
        let artifacts = Dictionary(document.artifacts.map { ($0.identity.id, $0) }, uniquingKeysWith: { first, _ in first })
        let definitions = document.mcpDefinitions ?? []
        // The packages this Mac's apps report having: an app installed them
        // and keeps them, so they stay as their apps manage them.
        let reported = Set(
            workspace.device.observations.flatMap { Array($0.pluginMetadata.keys) + $0.discoveredPlugins })
        func isOwnConnection(_ id: ArtifactID) -> Bool {
            id == decisions.helperArtifactID
                || artifacts[id].map { AgentToolingConnection.isOwnConnection($0, definitions: definitions) } == true
        }
        func isPlaceable(_ row: WorkspaceLibraryReadModelRow) -> Bool {
            row.isAssignable && [.skill, .package, .mcpServer, .nativePlugin].contains(row.kind)
                && !isOwnConnection(row.artifactID)
        }
        func isAppManaged(_ row: WorkspaceLibraryReadModelRow) -> Bool {
            guard row.ownership == .nativeOwned, let artifact = artifacts[row.artifactID] else { return false }
            return artifact.nativeRoutes.contains { reported.contains($0.externalPluginID) }
                || artifact.declaredName.map(reported.contains) == true
        }
        func isPlacedHere(_ row: WorkspaceLibraryReadModelRow) -> Bool {
            document.assignments.contains { assignment in
                assignment.artifactID == row.artifactID
                    && assignment.destination.applies(to: thisMac, registry: document.deviceRegistry)
                    && assignment.destination.surface.client.map(managed.contains) == true
            }
        }

        let rows = state.library.rows
        let byID = Dictionary(rows.map { ($0.artifactID, $0) }, uniquingKeysWith: { first, _ in first })
        // What this setup placed before, in the order it saved them: a walk
        // relaunched or resumed past this step no longer has the decisions
        // that made them rows, so its placements bring the rows back.
        let assignments = Dictionary(document.assignments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placedBefore = decisions.contributionIDs.compactMap { assignments[$0]?.artifactID }
        var seen = Set<ArtifactID>()
        let fromThisRun = (decisions.adopted.map(\.artifactID) + decisions.added.map(\.artifactID) + placedBefore)
            .filter { seen.insert($0).inserted }
            .compactMap { byID[$0] }
            .filter(isPlaceable)
        let unplaced = rows.filter {
            !seen.contains($0.artifactID) && isPlaceable($0) && !isAppManaged($0) && !isPlacedHere($0)
        }
        let placeable = fromThisRun + unplaced
        catalogs = Dictionary(
            placeable.map { row in (row.artifactID, Set(artifacts[row.artifactID]?.nativeRoutes.map(\.client) ?? [])) },
            uniquingKeysWith: { first, _ in first })
        items = placeable.map { item(for: $0, decisions: decisions) }

        let copy = LaunchpadCopy.Place.self
        let appManaged = rows.filter { !seen.contains($0.artifactID) && isAppManaged($0) && !isPlacedHere($0) }
            .map(\.displayName)
        let notYours = rows.filter { $0.ownership == .trackedOnly && $0.kind == .skill }.map(\.displayName)
        var sentences: [String] = []
        if !appManaged.isEmpty {
            sentences.append(copy.stayWithTheirApps(LaunchpadCopy.list(appManaged), count: appManaged.count))
        }
        if !notYours.isEmpty { sentences.append(copy.placedOnceYours(LaunchpadCopy.list(notYours), count: notYours.count)) }
        libraryCaption = sentences.isEmpty ? nil : sentences.joined(separator: " ")
        emptyText =
            apps.isEmpty && !items.isEmpty
            ? appCaptions.joined(separator: " ")
            : copy.nothingToPlace(
                appManaged: appManaged.isEmpty ? nil : LaunchpadCopy.list(appManaged), count: appManaged.count)
    }

    private func item(for row: WorkspaceLibraryReadModelRow, decisions: LaunchpadLibraryDecisions) -> Item {
        let copy = LaunchpadCopy.Place.self
        let kind =
            switch row.kind {
            case .skill: copy.skill
            case .mcpServer: copy.connection
            case .nativePlugin, .package, .preset, .logicalProject: copy.plugin
            }
        // A plugin this walk did not add (one a relaunched walk placed
        // before, or one already in the library) is named for the one app
        // whose catalog it comes from, as it was when it was added.
        let catalog = row.kind == .nativePlugin ? catalogs[row.artifactID].flatMap { $0.count == 1 ? $0.first : nil } : nil
        let source: String =
            switch decisions.added.first(where: { $0.artifactID == row.artifactID })?.source {
            case .catalog(let app): copy.catalog(of: app.rawValue)
            case .skillsSh: copy.skillsSh
            case .written, .pasted: row.ownershipLabel
            case nil: catalog.map { copy.catalog(of: $0.rawValue) } ?? row.ownershipLabel
            }
        let artwork = row.kind == .nativePlugin ? row.declaredName : nil
        return Item(
            artifactID: row.artifactID, name: row.displayName, kind: row.kind,
            subtitle: copy.rowSubtitle(kind: kind, source: source), artworkID: artwork)
    }

    // MARK: Opening on what was saved

    /// The Where choice the grid opens on: the one this setup's saved
    /// placements were made for, or This Mac only on a Mac set to take only
    /// what names it, where Every Mac would put nothing in its apps.
    private func openScope(on saved: [AssignmentContribution]) {
        let thisMac = workspace.library.deviceID
        let project = saved.lazy.compactMap { $0.destination.scope == .project ? $0.destination.logicalProjectID : nil }.first
        if let project, projects.contains(where: { $0.id == project }) {
            scope = .oneProject
            projectID = project
        } else if saved.isEmpty {
            if takesOnlyWhatNamesIt { scope = .thisMacOnly }
        } else if saved.allSatisfy({ $0.destination.scope == .user && $0.destination.deviceIDs == [thisMac] }) {
            scope = .thisMacOnly
        }
    }

    /// Every cell of a row this setup saved that it did not save then: it
    /// was left out, so it opens left out.
    private func openLeftOut(on saved: [AssignmentContribution]) {
        let rows = Set(saved.map(\.artifactID))
        for item in items where rows.contains(item.artifactID) {
            for app in apps where Self.takes(app, item.kind) && leader(of: app, for: item.kind) == nil {
                let selector = ResolvedAssignmentSelector(destination: destination(for: app))
                let isSaved = saved.contains {
                    $0.artifactID == item.artifactID && ResolvedAssignmentSelector(destination: $0.destination) == selector
                }
                if !isSaved { leftOut.insert(Key(item: item.artifactID, app: app)) }
            }
        }
    }

    // MARK: The what-if plan

    /// Works every cell out from one what-if plan: a placement for each row
    /// in each app that takes its kind, except where something already asks
    /// for it, whose cell the plan already holds. A placement asked for
    /// already is never asked for again, so the plan is never refused for
    /// asking twice: `own` are this setup's, which the cell can change.
    private func plan(own: Set<WorkspaceObjectID>) async {
        locked = []
        guard !items.isEmpty, !apps.isEmpty else {
            cells = [:]
            cursor = nil
            phase = .ready
            return
        }
        guard let document = workspace.library.state?.snapshot.document else {
            phase = .failed(LaunchpadCopy.Place.Failures.notChecked)
            return
        }
        let thisMac = workspace.library.deviceID
        var additions: [AssignmentContribution] = []
        for item in items {
            let contributions = document.assignments.filter { $0.artifactID == item.artifactID }
            for app in apps where Self.takes(app, item.kind) && leader(of: app, for: item.kind) == nil {
                let destination = destination(for: app)
                let placement = WorkspacePlacement(artifactID: item.artifactID, destination: destination)
                let selector = ResolvedAssignmentSelector(destination: destination)
                // What asks for this cell already: the same request, which
                // saving passes over (or keeps, when it is this setup's), or
                // anything that puts the item in this folder on this Mac.
                let asking = contributions.filter { contribution in
                    placement.isAsked(by: contribution)
                        || (ResolvedAssignmentSelector(destination: contribution.destination) == selector
                            && contribution.destination.applies(to: thisMac, registry: document.deviceRegistry))
                }
                if asking.isEmpty {
                    additions.append(.init(artifactID: item.artifactID, destination: destination, reason: .manual))
                } else if asking.contains(where: { !own.contains($0.id) }) {
                    // Something else asks for it: turning the cell off would
                    // not stop it.
                    locked.insert(Key(item: item.artifactID, app: app))
                }
            }
        }
        let preview = await workspace.deployment.previewPlan(assuming: additions)
        // A save that began while the plan was worked out keeps the grid it
        // is saving.
        guard phase != .saving else { return }
        guard let preview else {
            phase = .failed(LaunchpadCopy.Place.Failures.notChecked)
            return
        }
        var next: [Key: Cell] = [:]
        for item in items {
            for app in apps where leader(of: app, for: item.kind) == nil {
                let key = Key(item: item.artifactID, app: app)
                next[key] = cell(for: key, kind: item.kind, in: preview)
            }
            for app in apps {
                guard let leader = leader(of: app, for: item.kind) else { continue }
                next[Key(item: item.artifactID, app: app)] = Self.follower(of: next[Key(item: item.artifactID, app: leader)], leader)
            }
        }
        cells = next
        if cursor.map({ next[$0] == nil }) ?? true {
            cursor = keys.first(where: isToggleable) ?? keys.first
        }
        phase = .ready
    }

    /// One cell, from the plan's step or exclusion at its destination.
    private func cell(for key: Key, kind: ArtifactKind, in preview: PlacementPreview) -> Cell {
        let copy = LaunchpadCopy.Place.self
        let app = key.app.rawValue
        guard Self.takes(key.app, kind) else {
            return .unavailable(kind == .nativePlugin ? copy.takesNoPlugins(app) : copy.cannotTakeIt)
        }
        let selector = ResolvedAssignmentSelector(destination: destination(for: key.app))
        guard let target = preview.plan.resolvedTargets.first(where: { $0.selector == selector }) else {
            return .unavailable(copy.notOnThisMac)
        }
        let installKey = WorkspaceDeploymentInstallKey(artifactID: key.item, physicalDestinationID: target.physicalDestinationID)
        let step = preview.plan.items.first { step in
            !step.isRemoval && WorkspaceDeploymentSession.installKey(step) == installKey
        }
        if step != nil {
            if preview.edited.contains(installKey) { return .leftAlone(reason: copy.editedCopy(in: app)) }
            if preview.unproven.contains(installKey) { return .leftAlone(reason: copy.differentCopy(in: app)) }
            return leftOut.contains(key) && !locked.contains(key) ? .add : .willInstall
        }
        guard
            let exclusion = preview.plan.exclusions.first(where: {
                $0.artifactID == key.item && $0.physicalDestinationID == target.physicalDestinationID
            })
        else { return .unavailable(copy.notOnThisMac) }
        guard exclusion.reason != .alreadyPresent else { return .hasIt }
        return .unavailable(
            Self.reason(for: exclusion.reason, kind: kind, in: key.app, catalogs: catalogs[key.item] ?? [], scope: scope))
    }

    /// Why nothing can go in `app`, in a person's words, from the planner's
    /// exclusion there. A plugin from another app's catalog, or one asked for
    /// in one project, can never go there, whatever else the planner stopped
    /// at first, so that is the reason given: Agent Tooling installs plugins
    /// for every project only (`WorkspaceNativePluginCommandPlanning` builds
    /// only the user-scoped command). `catalogs` are the apps whose own
    /// catalog the item comes from.
    nonisolated static func reason(
        for exclusion: WorkspaceDeploymentExclusionReason, kind: ArtifactKind, in app: ClientKind,
        catalogs: Set<ClientKind>, scope: Scope
    ) -> String {
        let copy = LaunchpadCopy.Place.self
        if kind == .nativePlugin, exclusion != .alreadyPresent {
            if !catalogs.contains(app) { return copy.ownCatalog(app.rawValue) }
            if scope == .oneProject { return copy.pluginsForEveryProject }
        }
        switch exclusion {
        case .alreadyPresent: return copy.hasIt
        case .unknownClientVersion: return copy.waitsForVersion
        case .missingNativeRoute:
            // From this app's own catalog, with no install command here; from
            // another app's, it is that app's to install.
            return catalogs.isEmpty || catalogs.contains(app) ? copy.cannotTakeIt : copy.ownCatalog(app.rawValue)
        case .missingContent: return copy.noVerifiedCopy
        case .noDestination: return copy.notOnThisMac
        case .needsAssignmentReview:
            // A connection bound to each Mac has no setup on this one yet;
            // anything else the planner will not take as asked.
            return kind == .mcpServer ? copy.notSetUpHere : copy.cannotTakeIt
        case .unsupportedByAdapter, .trackedOwnership, .packageMember: return copy.cannotTakeIt
        }
    }

    /// A cell an app gets through another app's skill folder: the library's
    /// copy where that app has it or gets it, that app's own copy where it is
    /// left alone, and nothing otherwise.
    private static func follower(of leader: Cell?, _ app: ClientKind) -> Cell {
        switch leader {
        case .willInstall, .hasIt: .through(app)
        case .leftAlone: .readsCopy(of: app)
        default: .readsFolder(of: app)
        }
    }

    /// The app whose skill folder `app` also reads and that has a column, for
    /// a kind that is a folder copy: its cells follow that app's. Only in the
    /// home folder, as `NativeSkillDestination.alsoReads` states it: in a
    /// project, each app gets its own placement.
    private func leader(of app: ClientKind, for kind: ArtifactKind) -> ClientKind? {
        guard kind == .skill || kind == .package, scope != .oneProject else { return nil }
        return NativeSkillDestination.alsoReads(app).first(where: apps.contains)
    }

    /// Whether `app` can hold an item of `kind` at all.
    static func takes(_ app: ClientKind, _ kind: ArtifactKind) -> Bool {
        let surface = app.defaultSurface
        switch kind {
        case .skill, .package: return TargetSurfaceCapability.skillClient(for: surface) != nil
        case .mcpServer: return TargetSurfaceCapability.managedMCPClient(for: surface) != nil
        case .nativePlugin: return TargetSurfaceCapability.nativePluginClient(for: surface) != nil
        case .preset, .logicalProject: return false
        }
    }

    /// Where a placement in `app` goes for the Where control's choice.
    private func destination(for app: ClientKind) -> PortableDestination {
        let thisMac = workspace.library.deviceID
        switch scope {
        case .everyMac:
            return PortableDestination(surface: app.defaultSurface, scope: .user)
        case .thisMacOnly:
            return PortableDestination(surface: app.defaultSurface, scope: .user, deviceIDs: [thisMac])
        case .oneProject:
            // A project's folder is this Mac's, so a project placement stays
            // on this Mac.
            return PortableDestination(
                surface: app.defaultSurface, scope: .project, logicalProjectID: projectID, deviceIDs: [thisMac])
        }
    }

    // MARK: Changing the grid

    /// Space, or a click: Will install becomes Add and Add becomes Will
    /// install. Any other cell is read and left as it is.
    func toggle(_ key: Key) {
        guard phase == .ready else { return }
        cursor = key
        guard isToggleable(key) else { return }
        if cells[key] == .willInstall {
            cells[key] = .add
            leftOut.insert(key)
        } else {
            cells[key] = .willInstall
            leftOut.remove(key)
        }
        for app in apps where leader(of: app, for: itemKind(key.item)) == key.app {
            cells[Key(item: key.item, app: app)] = Self.follower(of: cells[key], key.app)
        }
    }

    /// Moves the cursor one cell, stopping at the grid's edges.
    func moveCursor(_ move: Move) {
        guard let cursor, let row = items.firstIndex(where: { $0.artifactID == cursor.item }),
            let column = apps.firstIndex(of: cursor.app)
        else {
            self.cursor = keys.first
            return
        }
        var nextRow = row
        var nextColumn = column
        switch move {
        case .up: nextRow = max(row - 1, 0)
        case .down: nextRow = min(row + 1, items.count - 1)
        case .left: nextColumn = max(column - 1, 0)
        case .right: nextColumn = min(column + 1, apps.count - 1)
        }
        self.cursor = Key(item: items[nextRow].artifactID, app: apps[nextColumn])
    }

    /// The Where control: which Macs, or which project, a placement is for.
    /// One project places into the first project this Mac tracks until
    /// another is chosen; with none tracked it cannot be chosen. Continue
    /// waits for the cells of the new choice.
    func choose(_ next: Scope, decisions: LaunchpadLibraryDecisions) async {
        guard next != scope, phase == .ready, !isRefreshing else { return }
        if next == .oneProject {
            guard let first = projects.first else { return }
            if projectID == nil { projectID = first.id }
        }
        // Every Mac and This Mac only place into the same folders, so their
        // cells are the same, except on a Mac set to take only what names
        // it, where Every Mac puts nothing; a project's folder is another
        // place.
        let replans = next == .oneProject || scope == .oneProject || takesOnlyWhatNamesIt
        scope = next
        guard replans else { return }
        refreshes += 1
        defer { refreshes -= 1 }
        await plan(own: Set(decisions.contributionIDs))
    }

    /// The project One project places into. Continue waits for its cells.
    func choose(project: ArtifactID, decisions: LaunchpadLibraryDecisions) async {
        guard project != projectID, projects.contains(where: { $0.id == project }), phase == .ready, !isRefreshing else {
            return
        }
        projectID = project
        guard scope == .oneProject else { return }
        refreshes += 1
        defer { refreshes -= 1 }
        await plan(own: Set(decisions.contributionIDs))
    }

    // MARK: Saving

    /// Records every Will install, Has it and Left alone cell as intent for
    /// the Where control's choice, in one revision, withdrawing what this
    /// setup recorded before wherever no cell asks for it now. Nothing is
    /// installed and no app is touched. Returns the decisions with the
    /// placements and this setup's own contributions as they now stand, or
    /// nil when nothing could be saved, with `saveError` saying so.
    func commit(decisions: LaunchpadLibraryDecisions) async -> LaunchpadLibraryDecisions? {
        guard canContinue else { return nil }
        phase = .saving
        saveError = nil
        defer { if phase == .saving { phase = .ready } }
        let library = workspace.library
        let placements = recordedPlacements
        // A save that finds the library moved since its review (another
        // writer committed in between) drops the review; one more try is
        // reviewed against the new head.
        for _ in 0..<2 {
            await library.reviewPlacements(placements, withdrawing: decisions.contributionIDs)
            let reviewedOn = Set(library.state?.snapshot.document.assignments.map(\.id) ?? [])
            guard let review = library.review else {
                guard library.errorMessage == nil else { break }
                // Everything is already asked for as it stands: nothing to save.
                return recorded(decisions, own: decisions.contributionIDs.filter(reviewedOn.contains))
            }
            await library.applyReviewedAssignments()
            if library.lastReceipt != nil {
                let kept = decisions.contributionIDs.filter {
                    reviewedOn.contains($0) && !review.command.removalIDs.contains($0)
                }
                return recorded(decisions, own: kept + review.command.additions.map(\.id))
            }
            guard library.review == nil else { break }
        }
        saveError = LaunchpadCopy.Place.Failures.notSaved
        return nil
    }

    /// Each recorded cell as a placement, row by row in the app order.
    private var recordedPlacements: [WorkspacePlacement] {
        items.flatMap { item in
            apps.compactMap { app -> WorkspacePlacement? in
                guard cells[Key(item: item.artifactID, app: app)]?.isRecorded == true else { return nil }
                return WorkspacePlacement(artifactID: item.artifactID, destination: destination(for: app))
            }
        }
    }

    private func recorded(_ decisions: LaunchpadLibraryDecisions, own: [WorkspaceObjectID]) -> LaunchpadLibraryDecisions {
        let scope: LaunchpadLibraryDecisions.Scope =
            switch self.scope {
            case .everyMac: .everyMac
            case .thisMacOnly: .thisMacOnly
            case .oneProject: .project(projectName ?? "")
            }
        var next = decisions
        next.placed = items.compactMap { item in
            let placed = apps.filter { cells[Key(item: item.artifactID, app: $0)]?.isRecorded == true }
            return placed.isEmpty ? nil : .init(artifactID: item.artifactID, name: item.name, apps: placed, scope: scope)
        }
        next.contributionIDs = own
        return next
    }

    // MARK: What VoiceOver reads

    /// One cell as VoiceOver reads it: the item, the app, what happens there
    /// and why.
    func accessibilityLabel(for key: Key) -> String {
        let copy = LaunchpadCopy.Place.self
        let name = items.first { $0.artifactID == key.item }?.name ?? ""
        let state: String =
            switch cells[key] {
            case .willInstall: copy.spokenWillInstall
            case .add: copy.spokenAdd
            case .hasIt: copy.spokenHasIt
            case .leftAlone(let reason): copy.spokenLeftAlone(because: reason)
            case .through(let app): copy.spokenThrough(app.rawValue)
            case .readsCopy(let app): copy.spokenReadsCopy(of: app.rawValue, in: skillFolder(of: app))
            case .readsFolder(let app): copy.spokenReadsFolder(of: app.rawValue, in: skillFolder(of: app))
            case .unavailable(let reason): reason
            case nil: ""
            }
        return copy.cell(name, in: key.app.rawValue, state)
    }

    /// What Space does to a cell, when it does anything.
    func accessibilityHint(for key: Key) -> String? {
        guard isToggleable(key) else { return nil }
        return cells[key] == .willInstall ? LaunchpadCopy.Place.spokenTurnOff : LaunchpadCopy.Place.spokenTurnOn
    }

    // MARK: Helpers

    /// Every cell, row by row in the app order.
    private var keys: [Key] {
        items.flatMap { item in apps.map { Key(item: item.artifactID, app: $0) } }
    }

    private func itemKind(_ id: ArtifactID) -> ArtifactKind {
        items.first { $0.artifactID == id }?.kind ?? .skill
    }

    /// `app`'s own skill folder, as a person reads it: "~/.agents/skills".
    private func skillFolder(of app: ClientKind) -> String {
        let home = workspace.deployment.homeRoot
        guard let folder = try? NativeSkillDestination.directory(client: app, homeURL: home, scope: .user, projectRoot: nil) else {
            return ""
        }
        var path = folder.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        return PathDisplay.abbreviatingHome(path, home: home)
    }
}
