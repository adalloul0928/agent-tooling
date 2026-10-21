import AgentToolingCore
import Foundation
import Observation

/// Records per-app intent for Agent Tooling's MCP connection. Observed compatible
/// clients start selected; existing choices take precedence. Manual registrations
/// remain untouched. Replacement or removal requires a receipt proving ownership.
/// Recording saves the connection, local helper binding, and target apps in one
/// revision. Client configuration changes only through the subsequent review.
@MainActor @Observable
final class AgentToolingHookUp {
    /// Why the connection cannot be set up from this copy.
    enum Unavailable: Equatable, Sendable {
        /// This copy runs outside Applications; the move is offered first
        /// when `offersMove`.
        case outsideApplications(offersMove: Bool)
        /// A build with no helper in it.
        case developmentBuild

        /// What Let your apps ask says, and what Done keeps.
        var sentence: String {
            switch self {
            case .outsideApplications: LaunchpadCopy.Helper.moveFirst
            case .developmentBuild: LaunchpadCopy.Helper.noHelper
            }
        }
    }

    /// Where one app stands, as its row shows it.
    enum Status: Equatable, Sendable {
        /// It answered with a version and has no registration: a checkbox and
        /// the command it would run.
        case ready
        /// It already runs this copy's helper; `provenOurs` when a receipt
        /// shows Agent Tooling set it up there, so it may be taken out again.
        case alreadyConnected(provenOurs: Bool)
        /// It runs a helper at `path`; `provenOurs` when a receipt shows Agent
        /// Tooling set that one up.
        case connectedElsewhere(path: String, provenOurs: Bool)
        case waitsForVersion
        /// Chosen, but not read on this Mac yet.
        case notChecked
        /// Found here, but this Mac does not manage it.
        case notManaged
        case notFound

        /// Whether ticking the row adds a step: an app ready for the
        /// command, or one whose registration elsewhere is proven Agent
        /// Tooling's, which the review replaces.
        var addsWhenTicked: Bool {
            switch self {
            case .ready, .connectedElsewhere(_, provenOurs: true): true
            default: false
            }
        }

        /// Whether unticking the row takes the connection out of the app: it
        /// runs this copy's helper, and a receipt shows Agent Tooling set it
        /// up there (D10).
        var removesWhenUnticked: Bool { self == .alreadyConnected(provenOurs: true) }

        /// Whether a person can tick the row: one whose tick adds a step, or
        /// one whose untick takes the connection out.
        var isTickable: Bool { addsWhenTicked || removesWhenUnticked }

        /// Whether the app's row is the short one, with nothing to run.
        var isQuiet: Bool {
            switch self {
            case .notChecked, .notManaged, .notFound: true
            default: false
            }
        }

        /// The row's line in words, beside or under the name, when it has
        /// one.
        var words: String? {
            let copy = LaunchpadCopy.Helper.self
            switch self {
            case .ready: return nil
            case .alreadyConnected: return copy.alreadyConnected
            case .connectedElsewhere(let path, _): return copy.connectedToAnotherCopy(at: path)
            case .waitsForVersion: return copy.waitsForVersion
            case .notChecked: return copy.notChecked
            case .notManaged: return copy.notManaged
            case .notFound: return copy.notFound
            }
        }
    }

    /// One app's row.
    struct Row: Identifiable, Equatable, Sendable {
        let client: ClientKind
        let status: Status
        /// The connection is recorded for this app. An app somebody connected
        /// by hand counts as ticked, though it has no checkbox.
        let isTicked: Bool
        /// Whether a tick can change.
        let canTick: Bool
        /// The command this app would run to add the helper, as a person reads
        /// it, then shorter forms that elide the middle of the helper's path,
        /// for the row to take the longest that fits; for a connected app
        /// unticked, the one that takes it out. Empty when nothing would run.
        let commandLines: [String]
        /// Whether the plan would run this app's step once it is ticked: false
        /// when the planner would leave it out (an app that cannot take the
        /// command). True until the plan has been read.
        let planRunsStep: Bool
        /// Whether the plan would take the connection out of this app once it
        /// is unticked: false when the planner would leave the registration
        /// where it is. True until the plan has been read.
        let planRemovesStep: Bool

        var id: ClientKind { client }

        /// The whole command, for the row's tooltip and VoiceOver.
        var command: String? { commandLines.first }

        /// Whether the review gets a step adding the connection for this row:
        /// ticked, not connected here yet, and a step the plan would run
        /// rather than leave out.
        var addsStep: Bool { isTicked && status.addsWhenTicked && planRunsStep }

        /// Whether the review gets a step taking the connection out of this
        /// row's app: unticked, connected by Agent Tooling, and a step the
        /// plan would run.
        var removesStep: Bool { canTick && !isTicked && status.removesWhenUnticked && planRemovesStep }

        /// Whether the row shows the ok glyph in its checkbox's place: the
        /// app is connected, and nothing here can change that.
        var showsConnectedGlyph: Bool {
            guard !canTick, case .alreadyConnected = status else { return false }
            return true
        }

        /// Whether the row is the short one: an app not found, not checked or
        /// not managed here, or one with no command to show, as in a build with
        /// no helper.
        var isQuiet: Bool { status.isQuiet || (status == .ready && commandLines.isEmpty) }
    }

    let installation: AgentToolingInstallation
    @ObservationIgnored private let workspace: WorkspaceLaunch.Workspace?
    @ObservationIgnored private let locate: (ClientKind) -> Bool
    @ObservationIgnored private let deviceName: @Sendable () async -> String
    /// The person's own ticks, over the starting ones.
    private var choices: [ClientKind: Bool] = [:]
    private(set) var provenSurfaces: Set<TargetSurface> = []
    /// What else the review runs: the setup's other changes in its scope,
    /// once the plan has been read.
    private(set) var otherChanges: Int?
    /// The apps whose step the plan would run, were every app that can be
    /// ticked ticked: what the count takes each row's step from. Nil until the
    /// plan has been read, or when it could not be.
    private(set) var appsThePlanRuns: Set<ClientKind>?
    /// The apps the plan would take the connection out of, were every app
    /// Agent Tooling connected unticked. Nil until the plan has been read.
    private(set) var appsThePlanRemovesFrom: Set<ClientKind>?
    private(set) var reviewDeviceName: String?
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    /// The row the keyboard is on, once ↑ or ↓ or a click put it somewhere.
    var focused: ClientKind?
    /// Each app's status for the inputs it was last worked out from: reading
    /// a registration reads the app's own files, so it is done once per
    /// change rather than once per redraw or keystroke.
    @ObservationIgnored private var statusMemo: (key: StatusInputs, statuses: [ClientKind: Status])?

    init(
        installation: AgentToolingInstallation, workspace: WorkspaceLaunch.Workspace?,
        locate: @escaping (ClientKind) -> Bool, deviceName: @escaping @Sendable () async -> String
    ) {
        self.installation = installation
        self.workspace = workspace
        self.locate = locate
        self.deviceName = deviceName
    }

    /// The flow's one model for the step, made the first time it is asked
    /// for.
    static func of(_ flow: LaunchpadFlow) -> AgentToolingHookUp {
        flow.model(for: .ask) {
            let environment = flow.environment
            return AgentToolingHookUp(
                installation: environment.installation(), workspace: flow.workspace,
                locate: { environment.locate($0, environment.homeURL) != nil }, deviceName: environment.deviceName)
        }
    }

    // MARK: What the screen shows

    /// The helper path apps are given, from this copy in Applications.
    var helperPath: String? { installation.registrableHelperPath }

    /// Why nothing can be connected from this copy, or nil. A copy with its
    /// helper that still cannot hand it out is outside Applications, or in
    /// an Applications folder an app may not keep a path into (on a mounted
    /// volume); one with no helper is a development build.
    var unavailable: Unavailable? {
        guard helperPath == nil else { return nil }
        switch installation.location {
        case .diskImage, .translocated, .elsewhere, .applications:
            return installation.mcpHelperURL == nil ? .developmentBuild : .outsideApplications(offersMove: installation.offersMove)
        case .developmentBuild:
            return .developmentBuild
        }
    }

    /// One row per app, in the app order.
    ///
    /// An app somebody connected to this copy by hand counts as ticked. One
    /// Agent Tooling connected is ticked while this Mac asks for it there.
    /// One this Mac chose before that has not answered since (no version, or
    /// not checked yet) keeps that choice without a checkbox, so a check that
    /// failed once does not undo it.
    var rows: [Row] {
        let statuses = self.statuses
        let starting = startingTicks(statuses)
        let recorded = boundPath == nil ? [] : recordedApps
        let available = unavailable == nil
        return ClientKind.allCases.map { client in
            let status = statuses[client] ?? .notFound
            let canTick = available && status.isTickable
            let ticked: Bool
            switch status {
            case .alreadyConnected(provenOurs: false): ticked = available
            case .waitsForVersion, .notChecked: ticked = available && recorded.contains(client)
            default: ticked = canTick && (choices[client] ?? starting.contains(client))
            }
            return Row(
                client: client, status: status, isTicked: ticked, canTick: canTick,
                commandLines: commandLines(for: client, status: status, removes: canTick && !ticked),
                planRunsStep: appsThePlanRuns.map { $0.contains(client) } ?? true,
                planRemovesStep: appsThePlanRemovesFrom.map { $0.contains(client) } ?? true)
        }
    }

    /// The apps the connection is recorded for once the primary is pressed,
    /// in the app order.
    var appsToRecord: [ClientKind] { rows.filter(\.isTicked).map(\.client) }

    /// How many changes the review will list: the setup's other changes, a
    /// step for each row that adds one, and one for each row whose app the
    /// connection is taken out of. Nil until the plan has been read.
    var changeCount: Int? {
        otherChanges.map { other in other + rows.count { $0.addsStep || $0.removesStep } }
    }

    /// "Review 4 changes…".
    var primaryTitle: String { LaunchpadCopy.Helper.review(changes: changeCount) }

    /// The apps that answered with a version, for the caption, in the app
    /// order.
    var answeredApps: [ClientKind] { rows.filter { $0.status == .ready }.map(\.client) }

    /// The caption's first sentence, why the rows start as they do: "All
    /// three answered with a version, so all three start ticked." Nil once
    /// this Mac has recorded a choice, which the rows start from instead, and
    /// when no app answered.
    var startingTicksSentence: String? {
        guard boundPath == nil else { return nil }
        return LaunchpadCopy.Helper.answeredWithAVersion(answeredApps.map(\.rawValue))
    }

    /// The copy apps find, as the caption names it: "/Applications/Agent
    /// Tooling.app".
    var bundlePath: String {
        PathDisplay.abbreviatingHome(LaunchpadMoveModel.path(of: installation.bundleURL), home: homeURL)
    }

    // MARK: Changing it

    func toggle(_ client: ClientKind) {
        guard let row = rows.first(where: { $0.client == client }), row.canTick, !isRecording else { return }
        choices[client] = !row.isTicked
        focused = client
    }

    /// ↑ or ↓: the keyboard moves to the next row that can be ticked.
    func moveFocus(by step: Int) {
        let tickable = rows.filter(\.canTick).map(\.client)
        guard !tickable.isEmpty else { return }
        guard let current = focused, let index = tickable.firstIndex(of: current) else {
            focused = step < 0 ? tickable.last : tickable.first
            return
        }
        focused = tickable[min(max(index + step, 0), tickable.count - 1)]
    }

    /// Reads what the screen needs that is not on hand: the receipts that
    /// prove an earlier registration was Agent Tooling's, this Mac's name for
    /// the review's chip, how many other changes the review will list for
    /// what the setup decided, and which apps' steps the plan would run once
    /// the connection is recorded for them, or taken out of them. Reads only.
    func load(decisions: LaunchpadLibraryDecisions) async {
        guard let workspace else { return }
        // The same receipts, read the same way, as the plan the review reads,
        // so a row cannot say Agent Tooling did not add a registration the
        // review then replaces or takes out.
        let proven = await WorkspaceDeploymentSession.provenConnections(in: workspace.store)
        provenSurfaces = Set(proven.filter { $0.value.contains(AgentToolingConnection.declaredName) }.keys)
        reviewDeviceName = await deviceName()
        await workspace.library.refresh()
        await workspace.deployment.prepare()
        var scope = reviewScope(for: decisions)
        if let own = ownConnection?.identity.id { scope.remove(own) }
        if let plan = workspace.deployment.plan(for: scope) {
            otherChanges = plan.items.count - workspace.deployment.heldBack(in: plan).count
        }
        // Each app's step stands or falls on its own, so one plan, with every
        // app the connection can be added to ticked and every app it can be
        // taken out of unticked, says which of them would run.
        let assumed = Set(
            rows.filter { row in
                if row.status.addsWhenTicked { return row.canTick }
                if row.status.removesWhenUnticked { return false }
                return row.isTicked
            }
            .map(\.client))
        if let helperPath, let head = document?.revision.id,
            let everyApp = try? ConnectAgentToolingCommand(expectedRevisionID: head, helperPath: helperPath, apps: assumed),
            let steps = await workspace.deployment.helperSteps(assuming: everyApp)
        {
            appsThePlanRuns = Set(steps.adds.compactMap(\.client))
            appsThePlanRemovesFrom = Set(steps.removals.compactMap(\.client))
        }
    }

    /// The primary: records the choice when it changed, then opens the review
    /// of what the setup has decided. On Join's detour the review returns to
    /// You joined.
    func review(in flow: LaunchpadFlow) {
        guard !isRecording else { return }
        guard let workspace = flow.workspace else {
            flow.advance()
            return
        }
        flow.outcomes.helperUnavailable = unavailable?.sentence
        let command: ConnectAgentToolingCommand?
        do {
            command = try pendingCommand()
        } catch {
            // A path the command refuses records nothing; the person is told
            // rather than taken on to a review without the steps counted here.
            errorMessage = error.localizedDescription
            return
        }
        guard let command else {
            recordDecisions(in: flow)
            present(in: flow, workspace: workspace)
            return
        }
        isRecording = true
        errorMessage = nil
        Task {
            defer { isRecording = false }
            do {
                _ = try await workspace.service.connectAgentTooling(command)
                await workspace.library.refresh()
                choices = [:]
                recordDecisions(in: flow)
                guard flow.step == .ask, flow.presentedReview == nil else { return }
                present(in: flow, workspace: workspace)
            } catch {
                errorMessage = LaunchpadCopy.Footer.Failures.notRecorded
            }
        }
    }

    /// What the review covers: everything the setup decided in the library,
    /// and this connection.
    func reviewScope(for decisions: LaunchpadLibraryDecisions) -> Set<ArtifactID> {
        var scope = Set(decisions.adopted.map(\.artifactID) + decisions.added.map(\.artifactID) + decisions.placed.map(\.artifactID))
        if let own = ownConnection?.identity.id ?? decisions.helperArtifactID { scope.insert(own) }
        return scope
    }

    // MARK: Reading the library

    private var homeURL: URL { workspace?.homeRoot ?? FileManager.default.homeDirectoryForCurrentUser }

    private var document: PortableWorkspaceDocument? { workspace?.library.state?.snapshot.document }

    /// The library's own connection, when it holds one.
    private var ownConnection: ArtifactRecord? { document.flatMap(AgentToolingConnection.ownConnection(in:)) }

    /// The helper path this Mac's binding of the connection holds: whether
    /// this Mac has chosen before.
    private var boundPath: String? {
        guard let own = ownConnection,
            let binding = workspace?.library.state?.snapshot.device.mcpBindings?.first(where: { $0.artifactID == own.identity.id }),
            case .stdio(let executable, _) = binding.destination
        else { return nil }
        return executable
    }

    /// The apps this Mac's contributions name.
    private var recordedApps: Set<ClientKind> {
        guard let document, let workspace else { return [] }
        return AgentToolingConnection.apps(on: workspace.store.deviceID, in: document)
    }

    /// The path the rows' commands name: this copy's helper, or, for a copy
    /// still outside Applications, the one it will have there.
    private var shownHelperPath: String? {
        if let helperPath { return helperPath }
        guard case .outsideApplications = unavailable else { return nil }
        return URL(filePath: "/Applications", directoryHint: .isDirectory)
            .appending(path: installation.bundleURL.lastPathComponent, directoryHint: .isDirectory)
            .appending(path: "Contents/Helpers/agent-tooling-mcp").path(percentEncoded: false)
    }

    /// What each app's status is worked out from.
    private struct StatusInputs: Equatable {
        let observations: [TargetObservation]
        let managed: Set<ClientKind>
        let helperPath: String
        let provenSurfaces: Set<TargetSurface>
    }

    /// Each app's status, from this Mac's observations and what it manages,
    /// worked out again only when one of them changed.
    private var statuses: [ClientKind: Status] {
        let inputs = StatusInputs(
            observations: workspace?.device.observations ?? [], managed: Set(workspace?.device.managedClients ?? []),
            helperPath: shownHelperPath ?? "", provenSurfaces: provenSurfaces)
        if let statusMemo, statusMemo.key == inputs { return statusMemo.statuses }
        let states = AgentToolingConnection.states(
            observations: inputs.observations, helperPath: inputs.helperPath, provenSurfaces: inputs.provenSurfaces)
        let statuses = Dictionary(
            uniqueKeysWithValues: ClientKind.allCases.map { client in
                (
                    client,
                    Self.status(states[client] ?? .notChecked, isManaged: inputs.managed.contains(client), isLocated: locate(client))
                )
            })
        statusMemo = (inputs, statuses)
        return statuses
    }

    private static func status(_ state: AgentToolingConnection.AppState, isManaged: Bool, isLocated: Bool) -> Status {
        switch state {
        case .notFound: return .notFound
        case .notChecked:
            if isManaged { return .notChecked }
            return isLocated ? .notManaged : .notFound
        case _ where !isManaged: return .notManaged
        case .waitsForVersion: return .waitsForVersion
        case .notConnected: return .ready
        case .alreadyConnected(let proven): return .alreadyConnected(provenOurs: proven)
        case .connectedToAnotherCopy(let path, let proven): return .connectedElsewhere(path: path, provenOurs: proven)
        }
    }

    /// The ticks the rows start from: this Mac's recorded choice once it has
    /// made one, otherwise every app that answered with a version, and every
    /// app Agent Tooling already connected.
    private func startingTicks(_ statuses: [ClientKind: Status]) -> Set<ClientKind> {
        if boundPath != nil { return recordedApps }
        return Set(statuses.filter { $0.value == .ready || $0.value.removesWhenUnticked }.map(\.key))
    }

    /// The command a row shows: the add, or, for an app Agent Tooling
    /// connected that is now unticked (`removes`), the removal the review
    /// would run.
    private func commandLines(for client: ClientKind, status: Status, removes: Bool) -> [String] {
        guard let path = shownHelperPath else { return [] }
        let executable = ClientExecutableLocator.executableName(for: client)
        if status.removesWhenUnticked, removes {
            return [
                CommandLineDisplay.rendered(
                    executableName: executable, arguments: AgentToolingConnection.previewRemovalArguments(client: client))
            ]
        }
        switch status {
        case .ready, .connectedElsewhere, .alreadyConnected:
            return Self.commandLines(
                executable: executable, arguments: AgentToolingConnection.previewArguments(client: client, helperPath: path),
                helperPath: path)
        case .waitsForVersion, .notChecked, .notManaged, .notFound:
            return []
        }
    }

    /// The command as a person reads it, then the same with the middle of the
    /// helper's path elided and its tail kept, `"/Applications/…/Helpers/
    /// agent-tooling-mcp"`, quoted as the whole path was.
    static func commandLines(executable: String, arguments: [String], helperPath: String) -> [String] {
        let full = CommandLineDisplay.rendered(executableName: executable, arguments: arguments)
        let parts = helperPath.split(separator: "/")
        guard parts.count > 2 else { return [full] }
        let head = "/" + parts[0]
        let elided = stride(from: min(3, parts.count - 2), through: 1, by: -1).map { kept in
            full.replacingOccurrences(of: helperPath, with: head + "/…/" + parts.suffix(kept).joined(separator: "/"))
        }
        return [full] + elided
    }

    /// What pressing the primary records, or nil when nothing changes: no
    /// connection and no app wanted, or the apps match what this Mac recorded
    /// and its binding names this copy's helper. Throws when the command
    /// refuses this copy's helper path.
    private func pendingCommand() throws -> ConnectAgentToolingCommand? {
        guard let helperPath, let head = document?.revision.id else { return nil }
        let wanted = Set(appsToRecord)
        if ownConnection == nil, wanted.isEmpty { return nil }
        if ownConnection != nil, wanted == recordedApps,
            wanted.isEmpty || boundPath.map({ AgentToolingConnection.sameCommand($0, helperPath) }) == true
        {
            return nil
        }
        return try ConnectAgentToolingCommand(expectedRevisionID: head, helperPath: helperPath, apps: wanted)
    }

    /// What the setup now says about the connection, from the library itself:
    /// the apps this Mac's contributions name, none when nothing is recorded
    /// or this copy cannot hand out its helper.
    private func recordDecisions(in flow: LaunchpadFlow) {
        guard unavailable == nil, let own = ownConnection?.identity.id else {
            flow.decisions.helperApps = []
            flow.outcomes.helperApps = []
            return
        }
        let apps = ClientKind.allCases.filter(recordedApps.contains)
        flow.decisions.helperArtifactID = own
        flow.decisions.helperApps = apps
        flow.outcomes.helperApps = apps
    }

    /// Opens the review of what the setup decided, the connection taken out
    /// of an app unticked here among it (D10).
    private func present(in flow: LaunchpadFlow, workspace: WorkspaceLaunch.Workspace) {
        let own = ownConnection.map { Set([$0.identity.id]) } ?? []
        let review = ScopedPlanReview(
            workspace: workspace, scope: .artifacts(reviewScope(for: flow.decisions)), includingRemovalsOf: own,
            deviceName: reviewDeviceName, libraryDecisions: flow.decisions)
        flow.presentReview(review, returnTo: flow.isDetour ? .arrivals : nil)
    }
}
