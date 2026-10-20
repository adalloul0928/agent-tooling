import AgentToolingCore
import Foundation
import Observation

/// Reads chosen apps concurrently from the consent manifest before committing.
/// Sign-in and optional project-name reads run alongside them; commit waits for
/// app readings, never sign-in. Late sign-in results join the accounts afterward.
/// Stop discards the entire read. Skip cancels one app and its sign-in, leaving
/// it unchecked. Generation tokens reject results from cancelled readings.
@MainActor @Observable
final class LaunchpadReadSession: LaunchpadInterruptible {
    enum Phase: Equatable, Sendable {
        /// Nothing has been read, or a read was stopped.
        case idle
        case reading
        /// The library is being created, or updated, from the read.
        case committing
        /// The read is done and the library holds it.
        case finished
        /// The read is done but the library could not be created from it.
        /// Try again makes it from the same read.
        case failed(String)
    }

    /// One app's read.
    enum AppRead: Equatable, Sendable {
        /// Under way since this moment on the session's clock.
        case reading(since: TimeInterval)
        /// Read, in `seconds`.
        case read(TargetObservation, seconds: TimeInterval)
        /// Skipped before its read finished: nothing of it is kept.
        case skipped
    }

    /// What a slow or unanswering read says, under the tally.
    enum Notice: Equatable, Sendable {
        /// Still reading after `slowAfter`; it can be skipped.
        case slow(ClientKind)
        /// Still reading after `unansweredAfter`, or a command other than
        /// `--version` ran out of time: its files were read from disk only.
        case unanswered(ClientKind)
        /// Its `--version` ran out of time: installs into it wait.
        case versionUnanswered(ClientKind)
        /// V2: its version is too old to read the account it signs in with.
        case outdated(ClientKind)

        var client: ClientKind {
            switch self {
            case .slow(let client), .unanswered(let client), .versionUnanswered(let client), .outdated(let client): client
            }
        }

        /// Only an app still being read can be skipped.
        var canSkip: Bool {
            if case .slow = self { true } else { false }
        }
    }

    private(set) var phase = Phase.idle
    /// The list the read under way, or the last one, was made from.
    private(set) var manifest: FirstReadManifest?
    /// The apps read, in the app order.
    private(set) var order: [ClientKind] = []
    private(set) var apps: [ClientKind: AppRead] = [:]
    /// Each command's outcome, by the manifest's identifier.
    private(set) var outcomes: [FirstReadManifest.Command.ID: FirstRead.Outcome] = [:]
    /// The first line each app's `--version` printed, as it answered.
    private(set) var versionLines: [ClientKind: String] = [:]
    /// Places read that no list held: "Not listed before".
    private(set) var unlisted: [ClientKind: [URL]] = [:]
    /// The lines of the list each app's read reported, and the commands that
    /// have started. Observed: the lines and the tally are drawn from them.
    private var placeEvents: Set<FirstReadManifest.Place.ID> = []
    private var commandStarts: Set<FirstReadManifest.Command.ID> = []
    /// How many folders Claude Code's history names, once listed. Nil when
    /// the person turned the listing off, or Claude Code was not chosen.
    private(set) var projectFolderCount: Int?
    /// Whether the library already existed: the read updates it rather than
    /// creating it, and the words say so.
    private(set) var updatesLibrary = false
    /// Everything said to VoiceOver as the read went, in order. The screen
    /// posts each as it is added.
    private(set) var spoken: [String] = []
    /// True from Stop until every read has wound down. A new read waits
    /// for it, so the old one's commands are gone first.
    private(set) var isStopping = false
    /// How the chosen apps sign in, read beside them.
    let signIn: SetupSignInRead

    /// Why the library could not be made, while that is so.
    var failure: String? {
        if case .failed(let message) = phase { message } else { nil }
    }

    @ObservationIgnored private let environment: LaunchpadEnvironment
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var readings: [ClientKind: FirstRead.Reading] = [:]
    @ObservationIgnored private var tasks: [ClientKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var projectsTask: Task<Void, Never>?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    /// The seed the read was started with, which the commit records.
    @ObservationIgnored private var seed: LaunchpadSeed?
    @ObservationIgnored private var listsProjects = false
    /// Whether the walk goes on by itself once the library is made: only
    /// for Continue without apps, which has no read to wait on. Try again
    /// keeps it.
    @ObservationIgnored private var advancesWhenCommitted = false

    /// A read past this long says it is taking a while, and can be skipped.
    static let slowAfter: TimeInterval = 10
    /// A read past this long has outlasted every command's time.
    static let unansweredAfter: TimeInterval = 60

    /// `clock` is seconds on a monotonic clock, for how long each read
    /// takes: the system's uptime unless a test hands in its own.
    init(environment: LaunchpadEnvironment, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.environment = environment
        self.clock = clock
        signIn = SetupSignInRead(reader: environment.signInReader, now: environment.now)
    }

    /// The read the stage keeps for `flow`.
    static func of(_ flow: LaunchpadFlow) -> LaunchpadReadSession {
        flow.model(for: .reads) { LaunchpadReadSession(environment: flow.environment) }
    }

    // MARK: What will be read

    /// The apps a read for `flow` reads: once the library exists, the apps
    /// this Mac manages as they stand; before it, the walk's choice.
    static func chosen(for flow: LaunchpadFlow) -> Set<ClientKind> {
        if let workspace = flow.workspace { return Set(workspace.device.managedClients) }
        return flow.seedOverride?.chosen ?? []
    }

    /// Whether the read also lists the folder names in Claude Code's
    /// history: the walk's choice, else what this Mac recorded, else on.
    static func findsProjects(for flow: LaunchpadFlow) -> Bool {
        flow.seedOverride?.findsProjectsFromClaudeHistory ?? flow.workspace?.device.findsProjectsFromClaudeHistory ?? true
    }

    /// The list What Agent Tooling reads shows for `flow`, and the read
    /// reads. Building it reads nothing.
    static func plannedManifest(for flow: LaunchpadFlow) -> FirstReadManifest {
        FirstReadManifest.build(
            chosen: chosen(for: flow), homeURL: flow.environment.homeURL, includeProjectHistory: findsProjects(for: flow))
    }

    // MARK: Reading

    /// Continue on What Agent Tooling reads: reads every chosen app, their
    /// sign-in and, when asked, Claude Code's project names; then makes the
    /// library from the read, or updates it. Nothing advances on its own.
    func start(flow: LaunchpadFlow) {
        guard phase == .idle, !isStopping else { return }
        generation &+= 1
        let token = generation
        let chosen = Self.chosen(for: flow)
        let findsProjects = Self.findsProjects(for: flow)
        var seed = flow.seedOverride ?? LaunchpadSeed(chosen: chosen)
        seed.findsProjectsFromClaudeHistory = findsProjects
        let manifest = FirstReadManifest.build(
            chosen: chosen, homeURL: environment.homeURL, includeProjectHistory: findsProjects)
        clear()
        self.seed = seed
        self.manifest = manifest
        order = ClientKind.allCases.filter(chosen.contains)
        updatesLibrary = flow.isPostCommit
        advancesWhenCommitted = false
        phase = .reading

        signIn.start(apps: chosen)
        listsProjects = findsProjects && chosen.contains(.claude)
        if listsProjects {
            let home = environment.homeURL
            projectsTask = Task { [weak self] in
                // Names only: nothing in the folder is opened, and nothing it
                // names is looked for, so no protected folder is touched.
                let names = await Task.detached(priority: .userInitiated) {
                    ProjectDiscovery.sessionIndexEntryNames(homeURL: home)
                }.value
                // A listing let go of (Claude Code skipped) keeps nothing.
                guard let self, token == self.generation, self.listsProjects, !Task.isCancelled else { return }
                self.projectFolderCount = names.count
                self.settleIfRead(flow: flow, token: token)
            }
        }
        for client in order {
            let reading = environment.firstRead(client, manifest)
            readings[client] = reading
            apps[client] = .reading(since: clock())
            tasks[client] = Task { [weak self] in
                for await event in reading {
                    guard let self, token == self.generation else { return }
                    self.take(event, from: client)
                }
                guard let self, token == self.generation else { return }
                self.readEnded(client, flow: flow, token: token)
            }
        }
        settleIfRead(flow: flow, token: token)
    }

    /// Skip this app: its read and its sign-in read stop and nothing of it
    /// is kept. It reads "Not checked yet" from here on. Skipping Claude Code
    /// also lets go of the folder names in its history: they are not
    /// counted, ticked or kept for Home.
    func skip(_ client: ClientKind, flow: LaunchpadFlow) {
        guard phase == .reading, case .reading = apps[client] else { return }
        apps[client] = .skipped
        tasks.removeValue(forKey: client)?.cancel()
        let reading = readings.removeValue(forKey: client)
        signIn.cancel(client)
        if client == .claude {
            projectsTask?.cancel()
            projectsTask = nil
            listsProjects = false
            projectFolderCount = nil
        }
        spoken.append(LaunchpadCopy.Reads.skippedAnnouncement(client.rawValue))
        Task { await reading?.stop() }
        settleIfRead(flow: flow, token: generation)
    }

    /// Stop: every read ends and nothing is kept. It returns once each read
    /// has stopped, so no command a read started outlives it.
    func stop() async {
        guard phase == .reading else { return }
        generation &+= 1
        let stopping = Array(readings.values)
        for task in tasks.values { task.cancel() }
        tasks = [:]
        readings = [:]
        projectsTask?.cancel()
        projectsTask = nil
        signIn.start(apps: [])
        clear()
        phase = .idle
        isStopping = true
        spoken.append(LaunchpadCopy.Reads.stoppedAnnouncement)
        for reading in stopping { await reading.stop() }
        isStopping = false
    }

    /// Try again, after the library could not be made: makes it from the
    /// same read, reading nothing again.
    func retry(flow: LaunchpadFlow) {
        guard case .failed = phase else { return }
        commit(flow: flow, token: generation)
    }

    /// Back on Your apps after the library could not be made: the read is
    /// let go, so the next Continue reads again, from the choice made
    /// there. Nothing of it was kept.
    func discardFailedRead() {
        guard case .failed = phase else { return }
        generation &+= 1
        signIn.start(apps: [])
        clear()
        phase = .idle
    }

    /// Continue without apps (V01): the library is created at once, empty,
    /// with nothing read, and the walk goes on to the catalogs.
    func commitWithoutApps(flow: LaunchpadFlow) {
        guard phase == .idle, !flow.isPostCommit else { return }
        generation &+= 1
        let token = generation
        clear()
        seed = flow.seedOverride ?? LaunchpadSeed(chosen: [])
        updatesLibrary = false
        advancesWhenCommitted = true
        commit(flow: flow, token: token)
    }

    /// Forgets what a read found and the list it read from.
    private func clear() {
        manifest = nil
        order = []
        apps = [:]
        outcomes = [:]
        versionLines = [:]
        unlisted = [:]
        placeEvents = []
        commandStarts = []
        projectFolderCount = nil
    }

    private func take(_ event: FirstRead.Event, from client: ClientKind) {
        // A skipped app's read may still hand over what it already held.
        guard case .reading(let since) = apps[client] else { return }
        switch event {
        case .placeRead(_, let id):
            placeEvents.insert(id)
        case .unlisted(_, let url):
            if !(unlisted[client] ?? []).contains(url) { unlisted[client, default: []].append(url) }
        case .commandStarted(_, let id):
            commandStarts.insert(id)
        case .commandFinished(_, let id, let outcome):
            outcomes[id] = outcome
            if id == versionCommand(of: client)?.id, case .answered(_, let firstLine?) = outcome {
                versionLines[client] = firstLine
            }
        case .finished(let observation):
            apps[client] = .read(observation, seconds: clock() - since)
            spoken.append(Self.readAnnouncement(for: client, observation: observation))
        }
    }

    /// A read that ended without reporting what it found, other than by
    /// Stop or Skip, kept nothing: it is counted as skipped.
    private func readEnded(_ client: ClientKind, flow: LaunchpadFlow, token: UInt64) {
        tasks[client] = nil
        readings[client] = nil
        if case .reading = apps[client] { apps[client] = .skipped }
        settleIfRead(flow: flow, token: token)
    }

    /// Once every app is read or skipped and the project names are listed,
    /// the library is made from the read.
    private func settleIfRead(flow: LaunchpadFlow, token: UInt64) {
        guard phase == .reading, token == generation, isComplete else { return }
        commit(flow: flow, token: token)
    }

    /// Whether every chosen app has been read or skipped, and the project
    /// names, when asked for, are listed.
    var isComplete: Bool {
        let appsDone = order.allSatisfy { client in
            if case .reading = apps[client] { false } else { apps[client] != nil }
        }
        return appsDone && (!listsProjects || projectFolderCount != nil)
    }

    // MARK: The commit

    private func commit(flow: LaunchpadFlow, token: UInt64) {
        guard let seed else { return }
        phase = .committing
        let observations = order.compactMap(observation(for:))
        let advancesWhenDone = advancesWhenCommitted
        commitTask = Task { [weak self] in
            guard let self else { return }
            do {
                if flow.isPostCommit {
                    await flow.adoptRead(observations: observations)
                    await Self.recordProjectsChoice(seed.findsProjectsFromClaudeHistory, flow: flow)
                } else {
                    try await flow.commitStartHere(observations: observations, seed: seed) { [weak self] workspace in
                        // The library is read first, so the stage audit and
                        // the list on Your library see what was created.
                        await workspace.library.refresh()
                        await self?.joinLanded(into: workspace)
                        self?.recordEvidence(in: workspace, flow: flow)
                    }
                }
            } catch {
                guard token == self.generation else { return }
                self.phase = .failed(LaunchpadCopy.Reads.Failures.notCreated)
                self.spoken.append(LaunchpadCopy.Reads.Failures.notCreated)
                return
            }
            guard token == self.generation else { return }
            self.writeOutcome(to: flow)
            self.phase = .finished
            if !self.order.isEmpty {
                self.spoken.append(
                    self.updatesLibrary
                        ? LaunchpadCopy.Reads.finishedAnnouncementRerun : LaunchpadCopy.Reads.finishedAnnouncement)
            }
            self.awaitSignIn(flow: flow, token: token)
            if advancesWhenDone { flow.advance() }
        }
    }

    /// The sign-in reads that have landed join the library's accounts, so
    /// the stage audit that follows the commit has them.
    private func joinLanded(into workspace: WorkspaceLaunch.Workspace) async {
        let landed = signIn.landed
        guard !landed.isEmpty else { return }
        await workspace.accounts.seed(landed)
    }

    /// Once the sign-in reads have all landed, they join the accounts, and
    /// the stage audit runs again if they changed what it knew.
    private func awaitSignIn(flow: LaunchpadFlow, token: UInt64) {
        guard !signIn.isFinished || !signIn.landed.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.signIn.waitUntilFinished()
            guard token == self.generation, let workspace = flow.workspace else { return }
            await self.joinLanded(into: workspace)
            self.writeOutcome(to: flow)
            await flow.runStageAuditIfChanged()
        }
    }

    /// What Done says about the read: who was read and at which version,
    /// what was not found or skipped, and the tally.
    private func writeOutcome(to flow: LaunchpadFlow) {
        flow.outcomes.read = LaunchpadOutcomes.ReadSummary(
            looked: order.compactMap { client in
                observation(for: client).map { .init(client: client, version: ClientVersionText.number(in: $0.version)) }
            },
            notFound: ClientKind.allCases.filter { environment.locate($0, environment.homeURL) == nil },
            skipped: order.filter { apps[$0] == .skipped },
            places: placesRead.count, commands: commandsRun.count)
    }

    /// A read after the commit point (a rerun's) was read with What Agent
    /// Tooling reads' choice about Claude Code's project history; once the
    /// library has it, that choice is this Mac's, so the next read and
    /// project discovery ask the same. Unchanged, nothing is written (nil
    /// on record means on).
    private static func recordProjectsChoice(_ findsProjects: Bool, flow: LaunchpadFlow) async {
        guard let device = flow.workspace?.device, (device.findsProjectsFromClaudeHistory ?? true) != findsProjects else {
            return
        }
        await device.setFindsProjectsFromClaudeHistory(findsProjects)
    }

    /// A first run keeps how many project folders its read named, for
    /// Home's card. A rerun writes its record only at Done, so its count
    /// stays here for Done to hand over.
    private func recordEvidence(in workspace: WorkspaceLaunch.Workspace, flow: LaunchpadFlow) {
        guard let count = projectFolderCount, case .firstRun = flow.entry else { return }
        workspace.setupProgress.recordEvidence { $0.projectFolderCount = count }
    }

    // MARK: Stopping

    /// Stoppable while anything is read: the apps, or, once the library is
    /// made (or could not be), the sign-in reads still landing. Finishing
    /// while the library is made.
    var interruption: LaunchpadInterruption {
        switch phase {
        case .reading: .stoppable
        case .committing: .finishing(updatesLibrary ? LaunchpadCopy.Footer.updatingLibrary : LaunchpadCopy.Footer.creatingLibrary)
        case .finished, .failed: signIn.isFinished ? .idle : .stoppable
        case .idle: .idle
        }
    }

    /// A quit while reading stops the read and keeps nothing; one while the
    /// library is made waits until it is. Either way, and once the library
    /// is made, the sign-in reads still under way stop, so no command they
    /// started outlives the app.
    func interrupt() async {
        switch phase {
        case .reading: await stop()
        case .committing:
            await commitTask?.value
            stopSignIn()
        case .finished, .failed: stopSignIn()
        case .idle: break
        }
    }

    /// Ends the sign-in reads still under way. Those that landed have joined
    /// the library's accounts already, or will not be needed: the app is
    /// quitting.
    private func stopSignIn() {
        guard !signIn.isFinished else { return }
        signIn.start(apps: [])
    }

    // MARK: What the read shows

    /// The observation `client`'s read produced, once it finished.
    func observation(for client: ClientKind) -> TargetObservation? {
        if case .read(let observation, _)? = apps[client] { observation } else { nil }
    }

    /// Every place of the list that has been read: what each app's read
    /// reported, Claude Code's project names once listed, and the sign-in
    /// places once their read landed. The history's line is the listing's
    /// alone: it is read only while the listing is kept, so skipping Claude
    /// Code takes it back.
    var placesRead: Set<FirstReadManifest.Place.ID> {
        guard let manifest else { return [] }
        let history = Set(manifest.apps.flatMap(\.places).filter { $0.role == .projectHistory }.map(\.id))
        var read = placeEvents.subtracting(history)
        if projectFolderCount != nil { read.formUnion(history) }
        if signIn.observations[.claude] != nil {
            for place in manifest.signIn.places { read.insert(place.id) }
        }
        return read.intersection(Self.placeIDs(of: manifest))
    }

    /// Every command of the list that has run to its end, the sign-in reads'
    /// once they landed.
    var commandsRun: Set<FirstReadManifest.Command.ID> {
        guard let manifest else { return [] }
        var run = Set(outcomes.compactMap { id, outcome in outcome == .cancelled ? nil : id })
        for command in manifest.signIn.commands {
            let landed: Bool =
                switch command.executableName {
                case ClientExecutableLocator.executableName(for: .codex): signIn.observations[.chatGPT] != nil
                case ClientExecutableLocator.executableName(for: .claude): signIn.observations[.claude] != nil
                default: !signIn.observations.isEmpty
                }
            if landed { run.insert(command.id) }
        }
        return run.intersection(Self.commandIDs(of: manifest))
    }

    /// The tally's totals: the places and commands the list holds.
    var placeTotal: Int { manifest?.placeCount ?? 0 }
    var commandTotal: Int { manifest?.commandCount ?? 0 }

    /// Where a line of `client`'s list stands.
    func state(of place: FirstReadManifest.Place, in client: ClientKind) -> ManifestColumn.Line.State {
        if place.isLinked { return .linked }
        if placesRead.contains(place.id) { return .read }
        if case .reading? = apps[client] { return .reading }
        return .idle
    }

    func state(of command: FirstReadManifest.Command, in client: ClientKind) -> ManifestColumn.Line.State {
        switch outcomes[command.id] {
        case .answered?, .notFound?: return .read
        case .timedOut?, .failed?: return .unlisted
        case .cancelled?, nil:
            if commandStarts.contains(command.id), case .reading? = apps[client] { return .reading }
            return .idle
        }
    }

    /// Line A under a tile while reading: "Checking version…" until its
    /// `--version` answers, then the number.
    func versionLine(for client: ClientKind) -> String? {
        switch apps[client] {
        case .reading?:
            if let line = versionLines[client] {
                return ClientVersionText.number(in: line) ?? LaunchpadCopy.Reads.versionUnknown
            }
            if let id = versionCommand(of: client)?.id, outcomes[id] != nil { return LaunchpadCopy.Reads.versionUnknown }
            return LaunchpadCopy.Reads.checkingVersion
        case .read(let observation, _)?:
            return ClientVersionText.number(in: observation.version) ?? LaunchpadCopy.Reads.versionUnknown
        case .skipped?:
            return LaunchpadCopy.Reads.notCheckedYet
        case nil:
            return nil
        }
    }

    /// How long `client`'s read has taken, or took, at `now` on the
    /// session's clock.
    func elapsed(for client: ClientKind, now: TimeInterval) -> TimeInterval? {
        switch apps[client] {
        case .reading(let since)?: now - since
        case .read(_, let seconds)?: seconds
        case .skipped?, nil: nil
        }
    }

    /// The session's clock now.
    func now() -> TimeInterval { clock() }

    /// The one notice the read raises at `now`, the first in the app order:
    /// a read still under way past a minute, or past ten seconds; then, once
    /// read, an app whose commands ran out of time; then one too old to read
    /// its account.
    func notice(now: TimeInterval) -> Notice? {
        for client in order {
            guard case .reading(let since)? = apps[client] else { continue }
            if now - since >= Self.unansweredAfter { return .unanswered(client) }
            if now - since >= Self.slowAfter { return .slow(client) }
        }
        for client in order {
            guard let commands = manifest?.apps.first(where: { $0.client == client })?.commands else { continue }
            let version = versionCommand(of: client)?.id
            if commands.contains(where: { $0.id != version && outcomes[$0.id] == .timedOut }) { return .unanswered(client) }
            if let version, outcomes[version] == .timedOut { return .versionUnanswered(client) }
        }
        for client in order where Self.accountReaderLine(for: client, observation: observation(for: client)) != nil {
            return .outdated(client)
        }
        return nil
    }

    /// The words of a notice.
    static func text(of notice: Notice) -> String {
        let copy = LaunchpadCopy.Reads.self
        switch notice {
        case .slow(let client): return copy.takingAWhile(client.rawValue)
        case .unanswered(let client): return copy.didNotAnswerInAMinute(client.rawValue)
        case .versionUnanswered(let client): return copy.didNotAnswerVersion(client.rawValue)
        case .outdated(let client):
            let account = AccountProvider.provider(for: client)?.accountName ?? client.rawValue
            return copy.updateToReadAccountNotice(client.rawValue, account: account)
        }
    }

    /// V2: the read found a version too old to read the app's account, so
    /// its sign-in line says to update instead of what it could not read.
    static func accountReaderLine(for client: ClientKind, observation: TargetObservation?) -> String? {
        guard let provider = AccountProvider.provider(for: client),
            ClientCompatibility.isBelow(.accountReader, client: client, versionLine: observation?.version)
        else { return nil }
        return LaunchpadCopy.Reads.updateToReadAccount(client.rawValue, account: provider.accountName)
    }

    private func versionCommand(of client: ClientKind) -> FirstReadManifest.Command? {
        manifest?.apps.first { $0.client == client }?.commands.first { $0.arguments == ["--version"] }
    }

    // MARK: What VoiceOver says

    /// One app's list: "Codex reads 4 places and runs 3 commands".
    static func manifestSummary(of app: FirstReadManifest.App, home: URL) -> String {
        let own = app.places.filter { !$0.isLinked }
        let linked = app.places.filter(\.isLinked).map { place in
            "\(place.display) \(LaunchpadCopy.Reads.linkedSuffix(LaunchpadCopy.list(Self.earlierReaders(of: place, in: app))))"
        }
        return LaunchpadCopy.Reads.manifestSummary(
            app.client.rawValue, places: own.count, linked: linked, commands: app.commands.count)
    }

    /// The apps listed before `app` that read `place` too, in the app order.
    static func earlierReaders(of place: FirstReadManifest.Place, in app: FirstReadManifest.App) -> [String] {
        let before = ClientKind.allCases.prefix { $0 != app.client }
        return place.sharedWith.filter(before.contains).map(\.rawValue)
    }

    /// Said as an app's read lands: "Gemini CLI read: version 0.38.2, 1
    /// skill, 0 plugins, 1 connection."
    static func readAnnouncement(for client: ClientKind, observation: TargetObservation) -> String {
        LaunchpadCopy.Reads.readAnnouncement(
            client.rawValue, version: ClientVersionText.number(in: observation.version),
            holdings: LibraryRowPresence.holdings(of: observation).phrases)
    }

    /// Whether nothing more will be read: every app has been read or
    /// skipped, and the sign-in reads have landed or stopped. Until then the
    /// tally's figures can still grow.
    var isTallyFinal: Bool {
        switch phase {
        case .idle, .reading: false
        case .committing, .finished, .failed: signIn.isFinished
        }
    }

    /// The tally's totals, "11 of 14 places read", while anything is still
    /// read; nil once its figures are final.
    var tallyTotals: (places: Int, commands: Int)? {
        isTallyFinal ? nil : (placeTotal, commandTotal)
    }

    /// The tally as VoiceOver reads it once, with its final figures, once
    /// the library holds the read; nil until then.
    var finalTally: String? {
        guard phase == .finished, isTallyFinal else { return nil }
        return Self.tallyWords(places: placesRead.count, commands: commandsRun.count)
    }

    /// A finished tally in words: "14 places read · 9 commands run · 0
    /// changed in your apps".
    static func tallyWords(places: Int, commands: Int) -> String {
        let copy = LaunchpadCopy.Reads.self
        return copy.tallyDone(places: places, commands: commands) + copy.tallySeparator + copy.zeroChanged
    }

    private static func placeIDs(of manifest: FirstReadManifest) -> Set<FirstReadManifest.Place.ID> {
        Set((manifest.apps.flatMap(\.places) + manifest.signIn.places + manifest.shared).map(\.id))
    }

    private static func commandIDs(of manifest: FirstReadManifest) -> Set<FirstReadManifest.Command.ID> {
        Set((manifest.apps.flatMap(\.commands) + manifest.signIn.commands).map(\.id))
    }
}
