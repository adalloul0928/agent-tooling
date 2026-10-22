import AgentToolingCore
import Foundation
import Observation

/// Derives Done and its saved progress record from explicit inputs. Shared
/// `FinishSetupChecklist` rules keep Home's remaining count consistent; existing
/// ticks and facts already proving completion are preserved.
struct LaunchpadDoneSummary: Equatable {
    /// Everything Done says comes from these.
    struct Inputs: Equatable {
        var path: LaunchpadPath?
        var decisions = LaunchpadLibraryDecisions()
        var outcomes = LaunchpadOutcomes()
        var facts = FinishSetupFacts()
        /// The library's size, Agent Tooling's own connection left out.
        var tools = 0
        var entries = 0
        /// On a join: what this Mac's read brought that the library it joined
        /// did not have.
        var foundHere: [String] = []
        /// The apps the last check looked at, for a walk with no read of its
        /// own (a join, a revisit).
        var looked: [LaunchpadOutcomes.AppLine] = []
        /// The review's steps left alone, as "Frontend Design in Codex".
        var leftAlone: [String] = []
        /// The apps each item's step was left alone in: they keep a copy of
        /// their own.
        var leftAloneIn: [ArtifactID: Set<ClientKind>] = [:]
        /// Skills setup copied into a folder another app also reads, which
        /// that app's last check has not seen yet.
        var alsoReads: [AlsoReads] = []
        /// The contributions the library holds now, so a placement kept by
        /// an earlier setup and withdrawn since is let go. Nil when not
        /// known: every kept one stays.
        var contributionsInLibrary: Set<WorkspaceObjectID>?
        /// How many project folders this walk's own read named, on a walk
        /// that writes its record only at Done (a rerun). Nil keeps what the
        /// record holds.
        var projectFolderCount: Int?
        var consent = AssistantRunConsent.off
        /// The app that runs the assistant's reviews: Claude Code, else Codex.
        var assistant: ClientKind?
        var checksAppsOnOpen = true
        var updateCadence = UpdateCheckCadence.onOpen
        var deviceName: String?
        var now = Date.now
        /// Whether the Checkup audit Done runs as it appears has returned.
        var auditSettled = true
    }

    /// A skill another app will show after its next check.
    struct AlsoReads: Equatable, Sendable {
        let app: ClientKind
        let skill: String
        let folder: String
    }

    /// One bookend tile.
    struct Tile: Equatable {
        let client: ClientKind
        let state: StageAgentTile.State
        /// The version, "Not found" or "Skipped".
        let line: String
        var isFound: Bool { state == .read }
    }

    /// One line of What happened.
    struct Line: Equatable {
        enum Kind: Equatable {
            /// A result, with its check.
            case done
            /// A result that did not all go through.
            case partial
            /// A caption with an info glyph: what follows from it.
            case info
        }

        let kind: Kind
        let text: String
        var detail: String?
        /// A path or command inside the text, set in the monospaced face.
        var code: String?
    }

    /// One card of Left for later.
    struct Later: Equatable {
        let item: FinishSetupItem
        let state: HealthState
        let title: String
        var detail: String?
    }

    /// One part of what runs on its own: "When it opens:" and what.
    struct Run: Equatable {
        let lead: String
        let text: String
    }

    let tiles: [Tile]
    let tilesLabel: String
    let title: String
    let subtitle: String
    let happened: [Line]
    let leftForLater: [Later]
    let suggestions: Int
    let runs: [Run]
    /// What Go to Home and Open Checkup write.
    let items: [FinishSetupItem]
    let ticks: [SetupProgressRecord.Tick]
    let evidence: SetupProgressRecord.Evidence

    init(_ inputs: Inputs) {
        let copy = LaunchpadCopy.Done.self
        let facts = inputs.facts
        let handOff = Self.handOff(inputs)

        tiles = Self.tiles(inputs)
        tilesLabel = copy.tilesLabel(
            lookedAfter: tiles.filter(\.isFound).map(\.client.rawValue),
            notFound: tiles.filter { $0.state == .absent }.map(\.client.rawValue))

        let items = FinishSetupChecklist.items(facts, handOff: handOff)
        let ticks = FinishSetupChecklist.setupTicks(handOff, items: items, now: inputs.now)
        self.items = items
        self.ticks = ticks
        evidence = Self.evidence(inputs, handOff: handOff)

        // The record as Go to Home writes it (`finish`): a tick already made
        // stays made, so this walk's ticks only add rows not ticked yet.
        var written =
            facts.record ?? SetupProgressRecord(state: .finished, path: .rerun, cursor: .done, startedAt: inputs.now, updatedAt: inputs.now)
        written.state = .finished
        written.items = items
        let kept = written.ticks
        written.ticks = kept + ticks.filter { tick in !kept.contains { $0.item == tick.item } }
        written.evidence = evidence
        // A row the facts already make true is not left for later: Home
        // ticks it on its first look.
        var after = facts
        after.record = written
        let satisfied = FinishSetupChecklist.satisfied(after)
        let later = FinishSetupChecklist.leftForLater(written, satisfied: satisfied)
        suggestions = FinishSetupChecklist.suggestions(written, satisfied: satisfied).count
        leftForLater = later.compactMap { Self.later($0, inputs: inputs, evidence: written.evidence) }

        title = copy.title(left: later.count)
        subtitle = copy.subtitle(
            device: inputs.deviceName, date: inputs.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        happened = Self.happened(inputs, handOff: handOff)
        runs = Self.runs(inputs, shares: inputs.outcomes.sync != nil || facts.sync != nil)
    }

    // MARK: The tiles

    private static func tiles(_ inputs: Inputs) -> [Tile] {
        let copy = LaunchpadCopy.Done.self
        let looked = inputs.outcomes.read?.looked ?? inputs.looked
        let skipped = Set(inputs.outcomes.read?.skipped ?? [])
        return ClientKind.allCases.map { client in
            if let app = looked.first(where: { $0.client == client }) {
                return Tile(client: client, state: .read, line: app.version ?? "")
            }
            if skipped.contains(client) { return Tile(client: client, state: .ghost, line: copy.skipped) }
            return Tile(client: client, state: .absent, line: copy.notFound)
        }
    }

    // MARK: What happened

    private static func happened(_ inputs: Inputs, handOff: FinishSetupChecklist.HandOff) -> [Line] {
        let copy = LaunchpadCopy.Done.self
        var lines: [Line] = []

        let looked = inputs.outcomes.read?.looked ?? inputs.looked
        let lookedClients = Set(looked.map(\.client))
        let skipped = Set(inputs.outcomes.read?.skipped ?? [])
        let notFound = ClientKind.allCases.filter { !lookedClients.contains($0) && !skipped.contains($0) }
        let apps = ClientKind.allCases.compactMap { client in
            looked.first { $0.client == client }.map { (name: client.rawValue, version: $0.version) }
        }
        lines.append(Line(kind: .done, text: copy.appsLookedAfter(apps, notFound: notFound.map(\.rawValue))))

        let library =
            inputs.path == .join && !inputs.foundHere.isEmpty
            ? copy.library(tools: inputs.tools, foundHere: inputs.foundHere)
            : copy.library(tools: inputs.tools, entries: inputs.entries)
        let madeYours = inputs.decisions.adopted.map(\.name)
        let awaiting = inputs.outcomes.addedPluginsAwaitingCheck
        lines.append(
            Line(
                kind: .done, text: madeYours.isEmpty ? library : copy.joined(library, copy.nowYours(madeYours)),
                detail: awaiting.isEmpty ? nil : copy.contentsAfterTheNextCheck(awaiting)))

        if let install = inputs.outcomes.install {
            let unfinished = Self.unfinishedSteps(install)
            var text: String
            if install.succeededSteps == 0 {
                text = copy.nothingInstalled(hasRemoval: install.hasRemoval)
            } else if unfinished > 0 {
                // An app where one step went through and another did not is
                // among those named as not finished, so the apps that took
                // changes are not counted.
                text = copy.installed(changes: install.succeededSteps, hasRemoval: install.hasRemoval)
            } else {
                text = copy.installed(
                    changes: install.succeededSteps, apps: install.installed.count, hasRemoval: install.hasRemoval)
            }
            if unfinished > 0 {
                text = copy.joined(text, copy.didNotFinish(unfinished, in: Self.unfinishedApps(install)))
            }
            if !install.leftAlone.isEmpty {
                text = copy.joined(text, copy.leftAlone(install.leftAlone.count, named: inputs.leftAlone))
            }
            lines.append(
                Line(
                    kind: unfinished > 0 ? .partial : .done, text: text,
                    detail: install.succeededSteps > 0 ? install.receiptLine : nil))
        }

        if !handOff.helperApps.isEmpty {
            lines.append(Line(kind: .done, text: copy.connected(to: FinishSetupChecklist.appList(handOff.helperApps))))
        }

        if let sync = inputs.outcomes.sync {
            // Connected, but the first publish did not go through: it shares
            // the library, and has not synced yet.
            let text =
                sync.publishedAt.map {
                    copy.synced(
                        SnapshotTime.compact($0, now: inputs.now), with: sync.address, readyForOtherMac: inputs.path != .join)
                } ?? copy.shares(with: sync.address)
            lines.append(Line(kind: .done, text: text))
        } else if let sync = inputs.facts.sync {
            let text =
                sync.lastSynced.map {
                    copy.synced(SnapshotTime.compact($0, now: inputs.now), with: sync.remote, readyForOtherMac: false)
                } ?? copy.shares(with: sync.remote)
            lines.append(Line(kind: .done, text: text))
        }

        if let assistant = inputs.assistant {
            lines.append(
                Line(
                    kind: .done,
                    text: copy.assistantRuns(
                        weekly: inputs.consent.weeklyReview, deepDive: inputs.consent.dailyDeepDive, with: assistant.rawValue)))
        }

        for also in inputs.alsoReads {
            lines.append(Line(kind: .info, text: copy.alsoShows(also.app.rawValue, also.skill, reading: also.folder), code: also.folder))
        }
        for step in LaunchpadStep.allCases {
            if let reason = inputs.outcomes.skipped[step] { lines.append(Line(kind: .info, text: reason)) }
        }
        return lines
    }

    // MARK: Left for later

    /// The card for one row left for later. Home's suggestions have none:
    /// Done only counts them.
    private static func later(_ item: FinishSetupItem, inputs: Inputs, evidence: SetupProgressRecord.Evidence) -> Later? {
        let copy = LaunchpadCopy.Done.self
        let finish = LaunchpadCopy.FinishSetup.self
        let facts = inputs.facts
        switch item {
        case .makeSkillsYours:
            return Later(item: item, state: .pending, title: finish.makeSkillsYours)
        case .putToolsInApps:
            let pending = facts.pendingChanges ?? 0
            let install = inputs.outcomes.install
            let unfinished = install.map(unfinishedSteps) ?? 0
            let detail =
                unfinished > 0
                ? copy.didNotFinish(unfinished, in: install.map(unfinishedApps) ?? [])
                : pending > 0 ? copy.waitForReview(pending) : copy.nothingInstalled
            return Later(
                item: item, state: unfinished > 0 ? .attention : .pending, title: finish.putToolsInApps, detail: detail)
        case .connectAgentTooling:
            // Why it could not be connected here, when the step said so.
            return Later(
                item: item, state: .pending, title: copy.notConnected(device: inputs.deviceName),
                detail: inputs.outcomes.helperUnavailable)
        case .signInConnections:
            let who = FinishSetupChecklist.who
            guard let check = facts.connectionCheck else {
                // No check has run, so a connection only may need you.
                let hints = evidence.mayNeedSignIn.map {
                    FinishSetupFacts.Connection(name: $0.connection, serverID: $0.serverID, client: $0.client)
                }
                return Later(item: item, state: .pending, title: finish.signInConnections, detail: finish.notChecked(mayNeed: who(hints)))
            }
            if !check.signInOffers.isEmpty {
                return Later(
                    item: item, state: .attention, title: finish.signInConnections,
                    detail: finish.needSignIn(who(check.signInOffers), count: check.signInOffers.count))
            }
            let elsewhere = check.signInElsewhere
            return Later(
                item: item, state: .attention, title: finish.signInConnections,
                detail: elsewhere.isEmpty ? nil : finish.signInInItsApp(who(elsewhere), count: elsewhere.count))
        case .lookAtCheckup:
            guard inputs.auditSettled else { return Later(item: item, state: .pending, title: copy.checking) }
            let open = facts.openFindings ?? []
            return Later(
                item: item, state: .attention, title: copy.leftOnCheckup(open.count), detail: checkupSubjects(open))
        case .connectOtherMacs, .trySkill, .trackProjects:
            return nil
        }
    }

    /// The steps of `install` that did not finish: each that failed, and
    /// each it was stopped before.
    private static func unfinishedSteps(_ install: DeploymentOutcome) -> Int {
        install.failedSteps + install.stoppedSteps
    }

    /// The apps a step of `install` did not finish in, failed or stopped
    /// before, in the app order.
    private static func unfinishedApps(_ install: DeploymentOutcome) -> [String] {
        ClientKind.allCases.filter { install.failed[$0] != nil || install.unfinished.contains($0) }.map(\.rawValue)
    }

    /// Checkup's findings, one clause per kind and in the order the audit
    /// looks for them (`Finding.inWordingOrder`): each skill not in the
    /// library with the apps it is in, then the connections set up by hand in
    /// several apps, by how many.
    static func checkupSubjects(_ findings: [FinishSetupFacts.Finding]) -> String {
        let copy = LaunchpadCopy.Done.self
        var clauses: [String] = []
        let findings = FinishSetupFacts.Finding.inWordingOrder(findings)
        var seenKinds: [SetupFinding.Kind] = []
        for finding in findings where !seenKinds.contains(finding.kind) { seenKinds.append(finding.kind) }
        for kind in seenKinds {
            let ofKind = findings.filter { $0.kind == kind }
            switch kind {
            case .unmanagedSkill:
                let names = FinishSetupChecklist.distinct(ofKind.map(\.name)).sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
                for name in names {
                    let apps = Set(ofKind.filter { $0.name == name }.flatMap(\.apps))
                    clauses.append(copy.unmanaged(name, in: ClientKind.allCases.filter(apps.contains).map(\.rawValue)))
                }
            case .mcpServerRepeatedAcrossClients:
                let byCount = Dictionary(grouping: ofKind) { $0.apps.count }
                for count in byCount.keys.sorted() {
                    let names = FinishSetupChecklist.distinct((byCount[count] ?? []).map(\.name))
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    clauses.append(copy.configuredSeparately(names, apps: count))
                }
            default:
                clauses += FinishSetupChecklist.distinct(ofKind.map(\.title))
            }
        }
        return copy.subjects(clauses)
    }

    // MARK: What runs on its own

    /// `shares` is whether this Mac shares the library with a repository:
    /// the sync passes run then, whether or not one has finished yet.
    private static func runs(_ inputs: Inputs, shares: Bool) -> [Run] {
        let copy = LaunchpadCopy.Done.self
        var runs: [Run] = []
        var onOpen: [String] = []
        if inputs.checksAppsOnOpen { onOpen.append(copy.checkAppsPart) }
        if inputs.updateCadence == .onOpen { onOpen.append(copy.lookForUpdates) }
        if shares { onOpen.append(copy.syncWithOtherMacs) }
        if !onOpen.isEmpty { runs.append(Run(lead: copy.whenItOpens, text: onOpen.joined(separator: ", "))) }
        if inputs.updateCadence == .daily { runs.append(Run(lead: copy.onceADay, text: copy.lookForUpdates)) }
        if let assistant = inputs.assistant {
            if inputs.consent.weeklyReview { runs.append(Run(lead: copy.weekly, text: copy.checkupReview(with: assistant.rawValue))) }
            if inputs.consent.dailyDeepDive { runs.append(Run(lead: copy.daily, text: copy.deepDive(with: assistant.rawValue))) }
        }
        if shares {
            let minutes = Int((WorkspaceSyncScheduler.interval / 60).rounded())
            runs.append(Run(lead: copy.afterAChange, text: copy.syncAtMost(everyMinutes: minutes)))
        }
        return runs
    }

    // MARK: The record

    /// What this setup did itself, for the rows it ticks and the line that
    /// says so.
    private static func handOff(_ inputs: Inputs) -> FinishSetupChecklist.HandOff {
        let facts = inputs.facts
        let install = inputs.outcomes.install
        // Agent Tooling's own connection counts as connected where setup
        // asked for it and the install reached that app, or a check has seen
        // it there since.
        let helper = ClientKind.allCases.filter { client in
            inputs.outcomes.helperApps.contains(client)
                && (facts.helperConnectedApps.contains(client) || install?.installed.contains(client) == true)
        }
        // Shared in setup only when this walk shared it: its own publish went
        // through, or the join it made has synced. Connected with no pass
        // finished, or a rerun on a Mac that shared already, is Home's to
        // tick once it sees a pass finish.
        let synced = inputs.outcomes.sync?.publishedAt != nil || (inputs.path == .join && facts.sync?.lastSynced != nil)
        return FinishSetupChecklist.HandOff(
            madeYours: inputs.decisions.adopted.map(\.name), installed: install?.succeededSteps,
            installUnfinished: install.map(unfinishedSteps) ?? 0, receipt: install.map(\.receiptLine), helperApps: helper,
            synced: synced, trial: trialTarget(inputs), signInHints: facts.signInCandidates)
    }

    /// The skill Home offers to try: the first skill made yours in this
    /// setup, in the first app that can open it and holds the library's copy
    /// of it: setup's own step put it there, or a check found it there and
    /// every app with it has the same copy. Else the first skill found in
    /// Codex, then in Claude Code.
    static func trialTarget(_ inputs: Inputs) -> SetupProgressRecord.Trial? {
        let facts = inputs.facts
        let apps = FinishSetupChecklist.trialApps(facts)
        for adopted in inputs.decisions.adopted {
            guard let declared = facts.personalSkills.first(where: { $0.id == adopted.artifactID })?.declaredName else { continue }
            let placed = Set(inputs.decisions.placed.first { $0.artifactID == adopted.artifactID }?.apps ?? [])
            let leftAlone = inputs.leftAloneIn[adopted.artifactID] ?? []
            let app = apps.first { app in
                (placed.contains(app) && !leftAlone.contains(app) && inputs.outcomes.install?.installed.contains(app) == true)
                    || (facts.observedSkills[app]?.contains(declared) == true && facts.holdsOneCopy(of: declared))
            }
            if let app { return .init(skillName: adopted.name, skillID: declared, client: app) }
        }
        return FinishSetupChecklist.firstObservedSkill(facts)
    }

    /// What Home's card needs kept, on top of what the setup already kept:
    /// the skills that were yours before this setup, the placements setups
    /// made, the findings left on Checkup, the skill to try, the connections
    /// that may need a sign-in, and a rerun's own count of project folders.
    /// `finish` replaces the whole of it, so everything kept so far is
    /// carried over.
    private static func evidence(_ inputs: Inputs, handOff: FinishSetupChecklist.HandOff) -> SetupProgressRecord.Evidence {
        let facts = inputs.facts
        var evidence = facts.record?.evidence ?? .init()
        let madeYours = Set(inputs.decisions.adopted.map(\.artifactID))
        for skill in facts.personalSkills where !madeYours.contains(skill.id) && !evidence.personalSkillsBefore.contains(skill.id) {
            evidence.personalSkillsBefore.append(skill.id)
        }
        // The placements kept so far that the library still holds (on a
        // rerun, an earlier setup's, which must survive it), then this
        // walk's own, so neither ever reads as arriving from another Mac.
        let inLibrary = { (id: WorkspaceObjectID) in inputs.contributionsInLibrary?.contains(id) ?? true }
        var placed = evidence.placedContributionIDs.filter(inLibrary)
        placed += inputs.decisions.contributionIDs.filter { inLibrary($0) && !placed.contains($0) }
        evidence.placedContributionIDs = placed
        evidence.checkupFindingIDs = (facts.openFindings ?? []).map(\.id)
        evidence.trial = handOff.trial
        evidence.mayNeedSignIn = handOff.signInHints.map {
            .init(connection: $0.name, serverID: $0.serverID, client: $0.client)
        }
        if let count = inputs.projectFolderCount { evidence.projectFolderCount = count }
        return evidence
    }

    // MARK: A setup carried on

    /// Whether Done starts from a walk that did not see the setup's first
    /// half: a first run resumed from Home, or carried on after a relaunch.
    /// Its decisions and outcomes are what this walk did, and what the
    /// library and its receipts say fills in the rest (plan §2.4).
    static func rebuildsEarlierWork(_ entry: SetupEntry) -> Bool {
        switch entry {
        case .resume, .continueFirstRun: true
        case .firstRun, .finishJoin, .rerun, .revisit: false
        }
    }

    /// The skills a carried-on first run made yours before this walk: each
    /// standalone skill that is yours now, was not before this setup, and
    /// was neither made yours nor added by this walk, by name (the order
    /// they were made yours in is not kept).
    static func madeYoursEarlier(_ facts: FinishSetupFacts, walk: LaunchpadLibraryDecisions) -> [LaunchpadLibraryDecisions.Adopted] {
        let before = Set(facts.record?.evidence.personalSkillsBefore ?? [])
        let known = Set(walk.adopted.map(\.artifactID) + walk.added.map(\.artifactID))
        return facts.personalSkills.filter { !before.contains($0.id) && !known.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { .init(artifactID: $0.id, name: $0.name, copyFrom: nil) }
    }
}

// MARK: - From the stage

extension LaunchpadDoneSummary {
    /// Done's inputs as the stage stands: the walk's decisions and outcomes,
    /// and the library, this Mac's check, Checkup and the preferences as
    /// they are, with what `model` read as Done appeared. A first run
    /// carried on fills in what its first half did from the library and the
    /// receipts. Nil before the library exists.
    @MainActor
    static func inputs(_ flow: LaunchpadFlow, model: LaunchpadDoneModel) -> Inputs? {
        guard let workspace = flow.workspace else { return nil }
        var inputs = Inputs(path: flow.path, decisions: flow.decisions, outcomes: flow.outcomes)
        // Done has no Move row, so where this copy runs from is not read:
        // reading it checks the code signature, too slow for every redraw.
        inputs.facts = FinishSetupFacts.live(workspace: workspace)
        inputs.deviceName = model.deviceName
        inputs.now = flow.environment.now()
        inputs.auditSettled = model.auditSettled

        let document = workspace.library.state?.snapshot.document
        inputs.contributionsInLibrary = document.map { Set($0.assignments.map(\.id)) }
        if rebuildsEarlierWork(flow.entry) {
            // Only Start here makes skills yours: a join's skills came across
            // from the other Mac.
            if flow.path == .startHere { inputs.decisions.adopted += madeYoursEarlier(inputs.facts, walk: flow.decisions) }
            if inputs.outcomes.helperApps.isEmpty, let document {
                let recorded = AgentToolingConnection.apps(on: workspace.store.deviceID, in: document)
                inputs.outcomes.helperApps = ClientKind.allCases.filter(recorded.contains)
            }
            if inputs.outcomes.install == nil { inputs.outcomes.install = model.earlierInstall }
        }
        // A rerun writes its record only here, so its read's count of
        // project folders comes along now.
        if flow.entry == .rerun, flow.visited.contains(.reads) {
            inputs.projectFolderCount = LaunchpadReadSession.of(flow).projectFolderCount
        }
        // The library's own counts, which leave Agent Tooling's own
        // connection out (D10): "12 tools in your library (9 entries)".
        let library = workspace.library.state?.library
        inputs.entries = library?.entryCount ?? 0
        inputs.tools = library?.toolCount ?? 0

        let managed = workspace.device.managedClients
        let observations = workspace.device.observations
        inputs.looked = ClientKind.allCases.compactMap { client in
            guard managed.contains(client),
                let observation = observations.first(where: { $0.surface.client == client }),
                observation.installed || observation.commandAvailable
            else { return nil }
            return .init(client: client, version: ClientVersionText.number(in: observation.version))
        }
        if flow.path == .join {
            let seenHere = Set(observations.flatMap { Array($0.skillMetadata.keys) + $0.discoveredMCPServers })
            inputs.foundHere = (document?.artifacts ?? []).filter { artifact in
                artifact.identity.parentPackageID == nil && artifact.authority == .trackedOnly
                    && artifact.declaredName.map(seenHere.contains) == true
            }.map(\.identity.displayName)
        }

        let names = Dictionary(
            (document?.artifacts ?? []).map { ($0.identity.id, $0.identity.displayName) }, uniquingKeysWith: { first, _ in first })
        let planned = workspace.deployment.plan?.items ?? []
        let leftAlone = (flow.outcomes.install?.leftAlone ?? []).map { key in
            (key: key, client: planned.first { WorkspaceDeploymentSession.installKey($0) == key }?.surface.client)
        }
        inputs.leftAlone = leftAlone.compactMap { step in
            guard let name = names[step.key.artifactID] else { return nil }
            return step.client.map { LaunchpadCopy.Done.item(name, in: $0.rawValue) } ?? name
        }
        for step in leftAlone {
            guard let client = step.client else { continue }
            inputs.leftAloneIn[step.key.artifactID, default: []].insert(client)
        }
        inputs.alsoReads = alsoReads(flow, workspace: workspace)

        inputs.consent = workspace.device.effectiveAssistantRuns
        inputs.assistant = WorkspaceInsightsSession.deepDiveClient(managed: managed)
        inputs.checksAppsOnOpen = workspace.device.automaticallyCheckHealth
        inputs.updateCadence = workspace.device.updatePolicy.cadence
        return inputs
    }

    /// Skills setup copied into an app's folder that another managed app
    /// also reads, which that app's last check has not seen yet: after its
    /// next check it shows them too.
    @MainActor
    private static func alsoReads(_ flow: LaunchpadFlow, workspace: WorkspaceLaunch.Workspace) -> [AlsoReads] {
        guard let install = flow.outcomes.install else { return [] }
        let document = workspace.library.state?.snapshot.document
        let artifacts = Dictionary(
            (document?.artifacts ?? []).map { ($0.identity.id, $0) }, uniquingKeysWith: { first, _ in first })
        let leftAlone = Set(install.leftAlone.map(\.artifactID))
        let managed = workspace.device.managedClients
        let home = workspace.homeRoot
        var found: [AlsoReads] = []
        for placed in flow.decisions.placed {
            guard let artifact = artifacts[placed.artifactID], artifact.identity.kind == .skill,
                let declared = artifact.declaredName, !leftAlone.contains(placed.artifactID)
            else { continue }
            for follower in ClientKind.allCases where managed.contains(follower) && !placed.apps.contains(follower) {
                for leader in NativeSkillDestination.alsoReads(follower)
                where placed.apps.contains(leader) && install.installed.contains(leader) {
                    let seen = workspace.device.observations.first { $0.surface.client == follower }?.skillMetadata[declared] != nil
                    guard !seen,
                        let folder = try? NativeSkillDestination.directory(client: leader, homeURL: home, scope: .user, projectRoot: nil)
                    else { continue }
                    found.append(.init(app: follower, skill: placed.name, folder: abbreviated(folder, home: home)))
                }
            }
        }
        return found
    }

    /// `url` from the home folder, as "~/.agents/skills".
    private static func abbreviated(_ url: URL, home: URL) -> String {
        let path = url.path(percentEncoded: false)
        let homePath = home.path(percentEncoded: false)
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let root = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        return trimmed.hasPrefix(root + "/") ? "~" + trimmed.dropFirst(root.count) : trimmed
    }
}

/// What Done holds while it is on screen: this Mac's name, once read,
/// whether the Checkup audit it runs as it appears has returned, and for a
/// first run carried on, what its first half installed.
@MainActor @Observable
final class LaunchpadDoneModel {
    private(set) var deviceName: String?
    /// Whether what Done reads as it appears is in: the audit has returned,
    /// and a carried-on first run's receipts are read. Go to Home and Open
    /// Checkup wait for it, so the record keeps what Checkup shows after it.
    private(set) var auditSettled = false
    /// What a first run resumed or carried on after a relaunch installed
    /// before this walk, which its own outcomes cannot say: the install
    /// receipts the library kept since the setup started. Nil when this walk
    /// installed, or nothing was.
    private(set) var earlierInstall: DeploymentOutcome?

    /// How many receipts the earlier installs are read from: far more than
    /// one setup writes.
    nonisolated static let receiptsRead = 200

    /// Runs the stage audit again if the library, the check or the sign-ins
    /// moved since the last one, and reads this Mac's name beside it. Done's
    /// Checkup card reads "Checking…" until the audit returns, which never
    /// waits on the name.
    func appear(_ flow: LaunchpadFlow) async {
        let readName = flow.environment.deviceName
        async let name = readName()
        if !auditSettled {
            if LaunchpadDoneSummary.rebuildsEarlierWork(flow.entry), flow.outcomes.install == nil,
                let workspace = flow.workspace, let started = workspace.setupProgress.record?.startedAt
            {
                earlierInstall = await Self.installs(since: started, in: workspace.store)
            }
            await flow.runStageAuditIfChanged()
            auditSettled = true
        }
        let read = await name
        if deviceName == nil { deviceName = read }
    }

    /// The installs the library's receipts record since `start`, added up
    /// as a review adds up its own: each operation's steps, charged to the
    /// apps it wrote to. Nil when there were none.
    static func installs(since start: Date, in store: WorkspaceRevisionStore) async -> DeploymentOutcome? {
        let limit = receiptsRead
        let receipts = await Task.detached { (try? store.operationReceipts(limit: limit)) ?? [] }.value
        let installs: Set<OperationKind> = [.installSkill, .updateSkill, .installPlugin, .updatePlugin, .configureMCP, .updateMCP]
        let mine = receipts.filter { $0.createdAt >= start && installs.contains($0.kind) }.sorted { $0.createdAt < $1.createdAt }
        guard let last = mine.last else { return nil }
        let results = mine.map { receipt in
            WorkspaceDeploymentSession.Result(
                title: receipt.title, surfaces: receipt.targetSurfaces, succeeded: receipt.itemCount(.succeeded),
                failed: receipt.itemCount(.failed), outputs: receipt.results.filter { $0.status == .failed }.map(\.output))
        }
        return DeploymentOutcome.from(results: results, leftAlone: [], finishedAt: last.createdAt)
    }
}
