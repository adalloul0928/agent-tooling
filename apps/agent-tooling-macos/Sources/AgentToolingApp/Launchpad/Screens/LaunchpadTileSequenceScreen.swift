import AgentToolingCore
import SwiftUI

/// Keeps app tiles stationary across detection, consent, reading, and results.
/// Reading starts only after consent; the completed read creates or updates the
/// library. Progress never advances automatically, except the empty-app path.
struct LaunchpadTileSequenceScreen: LaunchpadScreen {
    let flow: LaunchpadFlow
    @Environment(\.stageMotion) private var stageMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tally
    @FocusState private var focus: Region?
    /// Your apps' lighting: the found tiles go from ghost to lit as the
    /// screen first appears.
    @State private var lit = false
    @State private var highlightedTile: ClientKind?
    /// How much of the read's `spoken` has been said.
    @State private var spokenCount = 0

    init(flow: LaunchpadFlow) {
        self.flow = flow
    }

    /// What the screen shows: one face per step, the read's two.
    enum Face: Equatable, Sendable {
        /// S02, or V01 when no app was found.
        case apps
        /// S04: what will be read, before anything is.
        case consent
        /// S05: the read on S04's frame, then the library made from it.
        case reading
        /// S06: what the library holds.
        case found
    }

    private enum Region: Hashable {
        case tiles
    }

    private enum Matched: Hashable {
        case tally
        case commit
    }

    private var motion: StageMotion { stageMotion.resolved(reduceMotion: reduceMotion) }

    var body: some View {
        let face = Self.face(flow)
        let detection = LaunchpadDetection.of(flow)
        let read = LaunchpadReadSession.of(flow)
        VStack(alignment: .leading, spacing: 0) {
            header(face, detection: detection, read: read)
            well(face, detection: detection, read: read)
            below(face, detection: detection, read: read)
        }
        // The slot is the screen's whole height and no more: content longer
        // than it runs on below rather than pushing the stage, and the tiles
        // stay where they are.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .animation(motion.contentChange, value: face)
        .animation(motion.contentChange, value: read.phase)
        .defaultFocus($focus, Self.region(for: face))
        .onAppear { arrive(face, detection: detection) }
        .onChange(of: face) { _, now in focus = Self.region(for: now) }
        .onChange(of: read.spoken.count) { _, count in speak(read, upTo: count) }
        .task { await detection.loadDeviceName() }
    }

    /// Where the keyboard is on each face: the tiles on Your apps. Your
    /// library's list keeps its own (`LaunchpadFoundList`).
    private static func region(for face: Face) -> Region? {
        face == .apps ? .tiles : nil
    }

    // MARK: - The footer

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let read = LaunchpadReadSession.of(flow)
        let copy = LaunchpadCopy.Footer.self
        switch face(flow) {
        case .apps:
            // Held while the empty library is made; a library that could not
            // be made is tried again from here.
            let count = managed(flow).count
            return StageFooterSpec(
                primary: .init(
                    title: count == 0 ? LaunchpadCopy.Apps.continueWithoutApps : LaunchpadCopy.Apps.manage(count),
                    isEnabled: read.phase == .idle || read.failure != nil
                ) { continueFromApps(flow) })
        case .consent:
            return StageFooterSpec(
                primary: .init(title: copy.continue, isEnabled: !read.isStopping) { read.start(flow: flow) })
        case .reading:
            switch read.phase {
            case .reading, .committing:
                // Stop is the later slot while the read runs; once the library
                // is being made it is finishing, and ⎋ waits for it.
                return StageFooterSpec(
                    later: .stop({ Task { await read.stop() } }), showsBack: false,
                    primary: .init(title: copy.continue, isEnabled: false) {})
            case .failed:
                return StageFooterSpec(primary: .init(title: LaunchpadCopy.Reads.tryAgain) { read.retry(flow: flow) })
            case .finished, .idle:
                return StageFooterSpec(showsBack: false, primary: .init(title: copy.continue) { flow.advance() })
            }
        case .found:
            return StageFooterSpec(primary: .init(title: copy.continue) { flow.advance() })
        }
    }

    /// The read and what it found are passed over when no app is turned on:
    /// there is nothing to read.
    static func skipReason(_ context: LaunchpadTransitionContext) -> String? {
        context.startedEmpty ? LaunchpadCopy.Reads.nothingToRead : nil
    }

    /// The read this screen runs, kept by the flow so it outlives a redraw.
    static func read(_ flow: LaunchpadFlow) -> LaunchpadReadSession {
        LaunchpadReadSession.of(flow)
    }

    /// The face `flow` shows.
    static func face(_ flow: LaunchpadFlow) -> Face {
        switch flow.step {
        case .reads: LaunchpadReadSession.of(flow).phase == .idle ? .consent : .reading
        case .found: .found
        default: .apps
        }
    }

    /// The apps this Mac manages as the screen shows them: once the library
    /// exists, its record; before it, the choice on Your apps.
    static func managed(_ flow: LaunchpadFlow) -> Set<ClientKind> {
        if let workspace = flow.workspace { return Set(workspace.device.managedClients) }
        return LaunchpadDetection.of(flow).chosen
    }

    /// Your apps' primary. Before the library exists it hands the choice to
    /// the walk; with no app chosen, it creates the library at once, empty,
    /// and goes on to the catalogs. After it, the choice is already this
    /// Mac's record, and the walk is handed the tool folders: the ones the
    /// record holds and any the login shell found here, so the stage audit
    /// looks in them too. A read whose library could not be made is let go
    /// first, so the walk reads again from this choice.
    static func continueFromApps(_ flow: LaunchpadFlow) {
        let detection = LaunchpadDetection.of(flow)
        if let workspace = flow.workspace {
            flow.seedOverride = LaunchpadSeed(
                chosen: Set(workspace.device.managedClients), toolDirectories: detection.everyToolDirectory,
                findsProjectsFromClaudeHistory: LaunchpadReadSession.findsProjects(for: flow))
            flow.advance()
            return
        }
        LaunchpadReadSession.of(flow).discardFailedRead()
        let seed = detection.seed(findsProjectsFromClaudeHistory: flow.seedOverride?.findsProjectsFromClaudeHistory ?? true)
        flow.seedOverride = seed
        if seed.chosen.isEmpty {
            LaunchpadReadSession.of(flow).commitWithoutApps(flow: flow)
        } else {
            flow.advance()
        }
    }

    // MARK: - The header

    private func header(_ face: Face, detection: LaunchpadDetection, read: LaunchpadReadSession) -> some View {
        StageHeader(
            .hero, eyebrow: Self.eyebrow(face), title: Self.title(face, detection: detection),
            subtitle: Self.subtitle(face, flow: flow, read: read)
        )
        .contentTransition(.opacity)
        .overlay(alignment: .topLeading) {
            if face == .found {
                foundTally(read)
                    .padding(.top, StageLayout.Found.tallyTop)
            }
        }
    }

    static func eyebrow(_ face: Face) -> String {
        switch face {
        case .apps: LaunchpadCopy.Apps.eyebrow
        case .consent: LaunchpadCopy.Reads.eyebrow
        case .reading: LaunchpadCopy.Reads.readingEyebrow
        case .found: LaunchpadCopy.Found.eyebrow
        }
    }

    static func title(_ face: Face, detection: LaunchpadDetection) -> String {
        switch face {
        case .apps: detection.isEmptyMac ? LaunchpadCopy.Apps.emptyTitle : LaunchpadCopy.Apps.title
        case .consent: LaunchpadCopy.Reads.title
        case .reading: LaunchpadCopy.Reads.readingTitle
        case .found: LaunchpadCopy.Found.title
        }
    }

    /// The subtitle under each face's title. The read's two are two
    /// sentences set as two lines.
    static func subtitle(_ face: Face, flow: LaunchpadFlow, read: LaunchpadReadSession) -> String {
        let reads = LaunchpadCopy.Reads.self
        switch face {
        case .apps:
            return LaunchpadDetection.of(flow).isEmptyMac ? LaunchpadCopy.Apps.emptySubtitle : LaunchpadCopy.Apps.subtitle
        case .consent:
            let manifest = LaunchpadReadSession.plannedManifest(for: flow)
            let lineOne = reads.lineOne(
                places: manifest.placeCount, commands: manifest.commandCount, apps: manifest.apps.count)
            return lineOne + "\n" + (flow.isPostCommit ? reads.lineTwoRerun : reads.lineTwo)
        case .reading:
            return (read.updatesLibrary ? reads.readingLineOneRerun : reads.readingLineOne) + "\n" + reads.readingLineTwo
        case .found:
            let holdings = flow.workspace?.library.state?.library.holdingsSentence
            let rest = flow.path == .rerun ? nil : LaunchpadCopy.Found.nothingAssignedYet
            return [holdings, rest].compactMap { $0 }.joined(separator: " ")
        }
    }

    // MARK: - The well

    private func well(_ face: Face, detection: LaunchpadDetection, read: LaunchpadReadSession) -> some View {
        let extra = extraReadLines(face, read: read)
        let height = Self.wellHeight(face, extraReadLines: extra)
        return HeroWell(height: height, accessibilitySummary: detection.rowSummary) { client in
            column(client, face: face, detection: detection, read: read)
        }
        .overlay(alignment: .topLeading) {
            if face == .consent || face == .reading {
                signInStrip(manifest(face, read: read), extraReadLines: extra)
                    .transition(.opacity)
            }
        }
        .focusable(face == .apps)
        .focused($focus, equals: .tiles)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space], phases: .down) { press in
            moveOrToggle(press.key) ? .handled : .ignored
        }
    }

    /// The well's height on each face. The read's grows by a line for each
    /// Reads line past the five every column reserves, so a list that runs
    /// longer moves Runs and the sign-in strip down rather than over them.
    static func wellHeight(_ face: Face, extraReadLines: Int = 0) -> CGFloat {
        switch face {
        case .apps: StageLayout.Well.agentsHeight
        case .consent, .reading: StageLayout.Well.readsHeight + StageLayout.Reads.manifestLine * CGFloat(extraReadLines)
        case .found: StageLayout.Well.foundHeight
        }
    }

    /// The Reads lines past the five reserved that the face's lists run to.
    private func extraReadLines(_ face: Face, read: LaunchpadReadSession) -> Int {
        guard face == .consent || face == .reading else { return 0 }
        return Self.readLines(manifest(face, read: read), unlisted: face == .reading ? read.unlisted : [:])
            - StageLayout.Reads.readLinesReserved
    }

    /// The list the face draws: the read's own while it reads, else the one
    /// the walk would read now.
    private func manifest(_ face: Face, read: LaunchpadReadSession) -> FirstReadManifest {
        if face == .reading, let manifest = read.manifest { return manifest }
        return LaunchpadReadSession.plannedManifest(for: flow)
    }

    @ViewBuilder
    private func column(
        _ client: ClientKind, face: Face, detection: LaunchpadDetection, read: LaunchpadReadSession
    ) -> some View {
        let isManaged = Self.managed(flow).contains(client)
        let isFound = detection.app(client).isFound
        let order = LaunchpadDetection.keyNumber(of: client) - 1
        VStack(spacing: 0) {
            tile(client, face: face, managed: isManaged, found: isFound, detection: detection, read: read)
            Text(client.rawValue)
                .font(AgentFont.bodySemibold)
                .foregroundStyle(isFound ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(height: StageLayout.Apps.nameLine)
                .padding(.top, StageLayout.Well.nameGap)
                .opacity(arrived(isFound) ? 1 : 0)
                .animation(lighting(order), value: lit)
                // On Your apps the tile's own label says it.
                .accessibilityHidden(face == .apps)
            // "Found at" and the path arrive with their tile as it lights;
            // "Not found" with the empty ring after the last one.
            lines(client, face: face, managed: isManaged, found: isFound, detection: detection, read: read)
                .padding(.top, StageLayout.Well.linesGap)
                .opacity(isLit ? 1 : 0)
                .animation(lighting(order), value: lit)
            if face == .apps {
                KeyCombo(shortcut: Self.tileShortcut(client))
                    .background(LaunchpadFrameReporter(key: LaunchpadFrames.keys(client)))
                    .padding(.top, StageLayout.Well.keysGap)
                    .transition(.opacity)
            }
            if face == .consent || face == .reading {
                manifestColumn(client, managed: isManaged, manifest: manifest(face, read: read), face: face, read: read)
                    .transition(.opacity.animation(columnArrival(order)))
            }
        }
        // On Your library an app is one thing to hear: its name, version,
        // holdings and sign-in. Before that its list is its own group.
        .accessibilityElement(children: face == .found ? .combine : .contain)
    }

    // MARK: Tiles

    @ViewBuilder
    private func tile(
        _ client: ClientKind, face: Face, managed: Bool, found: Bool, detection: LaunchpadDetection,
        read: LaunchpadReadSession
    ) -> some View {
        let state = Self.tileState(
            face: face, managed: managed, found: found, isLit: isLit, read: read.apps[client],
            observation: observation(client))
        // A badge bounces as it arrives: the accent check as Your apps
        // lights, the green one as each read lands.
        let drawn = StageAgentTile(
            client: client, state: state, badgeBounces: motion.animatesDetails && (face == .apps || face == .reading)
        )
        .background(LaunchpadFrameReporter(key: LaunchpadFrames.tile(client)))
        .opacity(arrived(found) ? 1 : 0)
        .animation(lighting(LaunchpadDetection.keyNumber(of: client) - 1), value: lit)
        if face == .apps {
            Button {
                Self.toggle(client, flow: flow)
            } label: {
                drawn
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(Self.tileShortcut(client))
            .softHighlight(
                highlightedTile == client && focus == .tiles, in: RoundedRectangle.tileHighlight,
                inset: StageLayout.Apps.tileHighlightInset
            )
            .accessibilityLabel(detection.tileLabel(client, managed: managed))
            .accessibilityHint(LaunchpadDetection.tileHint(client, managed: managed))
            .accessibilityAddTraits(.isToggle)
        } else {
            drawn
        }
    }

    /// The state a tile is drawn in, for each face.
    static func tileState(
        face: Face, managed: Bool, found: Bool, isLit: Bool, read: LaunchpadReadSession.AppRead?,
        observation: TargetObservation?
    ) -> StageAgentTile.State {
        switch face {
        case .apps, .consent:
            guard found else { return managed ? .absentManaged : .absent }
            return managed && isLit ? .managed : .ghost
        case .reading:
            guard found else { return managed ? .absentManaged : .absent }
            guard managed else { return .ghost }
            switch read {
            case .reading?: return .reading
            case .read?: return .read
            case .skipped?, nil: return .managed
            }
        case .found:
            if managed, let observation, observation.installed || observation.isCommandAvailable { return .read }
            guard found else { return managed ? .absentManaged : .absent }
            return managed ? .managed : .ghost
        }
    }

    /// ⌘1 to ⌘4, in the app order.
    static func tileShortcut(_ client: ClientKind) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character(String(LaunchpadDetection.keyNumber(of: client)))), modifiers: .command)
    }

    /// A tile turned on or off (its click, its ⌘ key or Space). On a first
    /// run the choice is the walk's, handed on as its seed, and nothing is
    /// written. Once the library exists it is this Mac's record, written at
    /// once: the write is returned, for a caller that waits on it. Each
    /// write flips what is recorded when it runs, so two quick presses are
    /// two flips.
    @discardableResult
    static func toggle(_ client: ClientKind, flow: LaunchpadFlow) -> Task<Void, Never>? {
        if let workspace = flow.workspace {
            return Task {
                let on = workspace.device.managedClients.contains(client)
                await workspace.device.setEnabled(client, !on)
            }
        }
        let detection = LaunchpadDetection.of(flow)
        detection.toggle(client)
        flow.seedOverride = detection.seed(findsProjectsFromClaudeHistory: LaunchpadReadSession.findsProjects(for: flow))
        return nil
    }

    /// ←→ moves the keyboard's place along the tiles; Space turns the one
    /// it is on on or off. Only on Your apps.
    private func moveOrToggle(_ key: KeyEquivalent) -> Bool {
        guard Self.face(flow) == .apps else { return false }
        let all = ClientKind.allCases
        switch key {
        case .leftArrow, .rightArrow:
            let step = key == .leftArrow ? -1 : 1
            let index = highlightedTile.flatMap(all.firstIndex(of:)).map { $0 + step } ?? (step > 0 ? 0 : all.count - 1)
            highlightedTile = all[min(max(index, 0), all.count - 1)]
            return true
        case .space:
            guard let client = highlightedTile else { return false }
            Self.toggle(client, flow: flow)
            return true
        default:
            return false
        }
    }

    // MARK: Lines under a tile

    @ViewBuilder
    private func lines(
        _ client: ClientKind, face: Face, managed: Bool, found: Bool, detection: LaunchpadDetection,
        read: LaunchpadReadSession
    ) -> some View {
        let apps = LaunchpadCopy.Apps.self
        VStack(spacing: StageLayout.Well.lineGap) {
            if face == .apps, found {
                caption(apps.foundAt)
                    .accessibilityHidden(true)
            }
            // The path keeps its place from Your apps to What Agent Tooling
            // reads, so it rises into line A as "Found at" leaves. On Your
            // apps the tile's own label says where it was found.
            if found, face == .apps || face == .consent || (face == .reading && !managed) {
                path(detection.displayPath(client) ?? "")
                    .accessibilityHidden(face == .apps)
            }
            if !found, face != .found || !managed || observation(client).map({ !$0.installed && !$0.isCommandAvailable }) ?? true {
                caption(apps.notFound)
                    .accessibilityHidden(face == .apps)
            }
            if face == .apps, !found {
                notFoundLink(client, emptyMac: detection.isEmptyMac)
            }
            if face == .reading, managed, found {
                versionLine(client, read: read)
            }
            if face == .found {
                foundLines(client, managed: managed, found: found, read: read)
            }
        }
        .frame(maxWidth: StageLayout.Well.column)
    }

    /// A caption line under a tile: the whole column is its measure; only a
    /// path is held to the narrower text width.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: StageLayout.Well.column)
            .frame(height: StageLayout.Well.captionLine)
    }

    private func path(_ text: String) -> some View {
        Text(text)
            .font(AgentFont.monoMicro)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: StageLayout.Well.columnText)
            .frame(height: StageLayout.Well.pathLine)
    }

    /// Under an app that was not found: where the locator looked, or on an
    /// empty Mac the app's own install page.
    @ViewBuilder
    private func notFoundLink(_ client: ClientKind, emptyMac: Bool) -> some View {
        if emptyMac {
            LaunchpadInstallLink(client: client, glyph: StageLayout.Apps.lineArrow, font: AgentFont.caption)
                .frame(height: StageLayout.Well.pathLine)
        } else {
            let key = Self.lookedKey(client)
            Button(LaunchpadCopy.Apps.whereLooked) { flow.openPopover = key }
                .buttonStyle(.link)
                .font(AgentFont.caption)
                .lineLimit(1)
                .frame(height: StageLayout.Well.pathLine)
                .popover(isPresented: popoverBinding(key), arrowEdge: .bottom) {
                    LaunchpadLookedPopover(client: client, homeURL: flow.environment.homeURL)
                }
        }
    }

    /// Line A while reading: "Checking version…" until `--version` answers,
    /// then the number, beside how long the read has taken. The time ticks
    /// only while the app is still being read; once it is read or skipped
    /// the line stands still.
    private func versionLine(_ client: ClientKind, read: LaunchpadReadSession) -> some View {
        let isReading = if case .reading? = read.apps[client] { true } else { false }
        return TimelineView(.animation(minimumInterval: LaunchpadReadSession.elapsedTick, paused: !isReading)) { _ in
            HStack(spacing: Space.xs) {
                Text(read.versionLine(for: client) ?? LaunchpadCopy.Reads.checkingVersion)
                    .font(AgentFont.caption)
                    .contentTransition(motion.animatesDetails ? .numericText() : .identity)
                if let seconds = read.elapsed(for: client, now: read.now()) {
                    Text(LaunchpadCopy.Reads.elapsed(seconds))
                        .font(AgentFont.micro)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: StageLayout.Well.columnText)
            .frame(height: StageLayout.Well.captionLine)
        }
    }

    /// S06's lines under a tile: the version, what the app holds, and how it
    /// signs in; or why there is none of that.
    @ViewBuilder
    private func foundLines(_ client: ClientKind, managed: Bool, found: Bool, read: LaunchpadReadSession) -> some View {
        let reads = LaunchpadCopy.Reads.self
        if managed, let observation = observation(client), observation.installed || observation.isCommandAvailable {
            caption(ClientVersionText.number(in: observation.version) ?? reads.versionUnknown)
                .contentTransition(motion.animatesDetails ? .numericText() : .identity)
            caption(LibraryRowPresence.holdings(of: observation).summary)
            if let line = signInLine(client, observation: observation, read: read) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: StageLayout.Found.signInGlyph))
                        .accessibilityHidden(true)
                    Text(line)
                }
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: StageLayout.Well.column)
                .frame(height: StageLayout.Well.captionLine)
            }
        } else if managed, found {
            caption(reads.notCheckedYet)
        } else if found {
            caption(LaunchpadCopy.Found.offNotRead)
        }
    }

    /// How an app signs in, under its tile on S06: the read's line while it
    /// is under way or once it landed, else what the library's accounts
    /// know; an account reader too old to read it says to update instead.
    private func signInLine(_ client: ClientKind, observation: TargetObservation, read: LaunchpadReadSession) -> String? {
        if let update = LaunchpadReadSession.accountReaderLine(for: client, observation: observation) { return update }
        if let line = read.signIn.line(for: client) { return line }
        guard let provider = AccountProvider.provider(for: client),
            let known = flow.workspace?.accounts.observation(provider)
        else { return nil }
        return SetupSignInRead.line(for: known)
    }

    // MARK: The list under each tile, before and while reading

    @ViewBuilder
    private func manifestColumn(
        _ client: ClientKind, managed: Bool, manifest: FirstReadManifest, face: Face, read: LaunchpadReadSession
    ) -> some View {
        if managed, let app = manifest.apps.first(where: { $0.client == client }) {
            let reads = readLines(app, manifest: manifest, face: face, read: read)
            ManifestColumn(
                reads: reads, runs: runLines(app, face: face, read: read),
                reservedReadLines: Self.readLines(manifest, unlisted: face == .reading ? read.unlisted : [:]),
                accessibilitySummary: LaunchpadReadSession.manifestSummary(of: app, home: flow.environment.homeURL))
        } else {
            VStack(spacing: 0) {
                Text(Self.offNotRead(face, flow: flow, read: read))
                Text(LaunchpadCopy.Reads.goBackToTurnOn)
            }
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(width: StageLayout.Well.column)
            .padding(.top, StageLayout.Reads.manifestTop)
            .accessibilityElement(children: .combine)
        }
    }

    /// The column of an app turned off. Only a read that updates a library
    /// already there is not the first read: a first run's own read stays
    /// its first once the library holds it.
    static func offNotRead(_ face: Face, flow: LaunchpadFlow, read: LaunchpadReadSession) -> String {
        let updates = face == .reading ? read.updatesLibrary : flow.isPostCommit
        return updates ? LaunchpadCopy.Reads.offNotReadRerun : LaunchpadCopy.Reads.offNotRead
    }

    /// The Reads lines every column reserves, so Runs lines up across the
    /// well: five, or as many as the longest list, counting the places every
    /// app's read opens under the first app and any place read that no list
    /// held ("Not listed before").
    static func readLines(_ manifest: FirstReadManifest, unlisted: [ClientKind: [URL]] = [:]) -> Int {
        max(StageLayout.Reads.readLinesReserved, mostReadLines(manifest, unlisted: unlisted))
    }

    /// The most Reads lines any chosen app's column has.
    static func mostReadLines(_ manifest: FirstReadManifest, unlisted: [ClientKind: [URL]] = [:]) -> Int {
        manifest.apps.enumerated().map { index, app in
            app.places.count + (index == 0 ? manifest.shared.count : 0) + (unlisted[app.client]?.count ?? 0)
        }.max() ?? 0
    }

    private func readLines(
        _ app: FirstReadManifest.App, manifest: FirstReadManifest, face: Face, read: LaunchpadReadSession
    ) -> [ManifestColumn.Line] {
        let isReading = face == .reading
        var lines = app.places.map { place -> ManifestColumn.Line in
            if place.isLinked {
                let earlier = LaunchpadCopy.list(LaunchpadReadSession.earlierReaders(of: place, in: app))
                return ManifestColumn.Line(
                    id: place.id, text: place.display, state: .linked,
                    accessibilityText: LaunchpadCopy.Reads.linkedLabel(place.display, apps: earlier),
                    suffix: LaunchpadCopy.Reads.linkedSuffix(earlier))
            }
            return ManifestColumn.Line(
                id: place.id, text: place.display, state: isReading ? read.state(of: place, in: app.client) : .idle)
        }
        // A place every app's read opens is listed once, under the first.
        if manifest.apps.first?.client == app.client {
            lines += manifest.shared.map { place in
                ManifestColumn.Line(
                    id: place.id, text: place.display, state: isReading ? read.state(of: place, in: app.client) : .idle)
            }
        }
        if isReading {
            let home = flow.environment.homeURL
            lines += (read.unlisted[app.client] ?? []).map { url in
                let shown = PathDisplay.abbreviatingHome(url.path(percentEncoded: false), home: home)
                return ManifestColumn.Line(
                    id: url.path(percentEncoded: false), text: shown, state: .unlisted,
                    accessibilityText: LaunchpadCopy.Reads.unlistedLabel(shown))
            }
        }
        return lines
    }

    private func runLines(_ app: FirstReadManifest.App, face: Face, read: LaunchpadReadSession) -> [ManifestColumn.Line] {
        app.commands.map { command in
            ManifestColumn.Line(
                id: command.id, text: command.display,
                state: face == .reading ? read.state(of: command, in: app.client) : .idle)
        }
    }

    /// How the apps sign in, inside the well under the columns. Nothing is
    /// shown when no chosen app has an account to read.
    @ViewBuilder
    private func signInStrip(_ manifest: FirstReadManifest, extraReadLines: Int) -> some View {
        let reads = LaunchpadCopy.Reads.self
        let shellNames = [ClientKind.codex, .claude].map(ClientExecutableLocator.executableName(for:))
        let shell = manifest.signIn.commands.first { !shellNames.contains($0.executableName) }
        let reads2 = manifest.signIn.commands.filter { $0.id != shell?.id }.map(\.display) + manifest.signIn.places.map(\.display)
        if !reads2.isEmpty || shell != nil {
            VStack(alignment: .leading, spacing: 0) {
                StageListLabel(reads.signInLabel)
                    .frame(height: StageLayout.Reads.manifestLine, alignment: .leading)
                    .padding(.bottom, StageLayout.Reads.signInLabelGap)
                if !reads2.isEmpty {
                    Text(reads2.joined(separator: reads.tallySeparator))
                        .font(AgentFont.monoMicro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let shell {
                    Text(Self.shellCaption(shell.display))
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, Space.nudge)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, StageLayout.Reads.signInPadding)
            .overlay(alignment: .top) { Hairline() }
            .padding(.top, StageLayout.Reads.signInTop + StageLayout.Reads.manifestLine * CGFloat(extraReadLines))
            .padding(.horizontal, StageLayout.Well.columnInset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(reads.signInLabel)
        }
    }

    /// "Your login shell, zsh -l -i: runs ~/.zshrc and keeps only the names
    /// of 12 sign-in variables, never their values.", the command and the
    /// file in mono.
    static func shellCaption(_ shell: String) -> AttributedString {
        let reads = LaunchpadCopy.Reads.self
        func mono(_ text: String) -> AttributedString {
            var part = AttributedString(text)
            part.font = AgentFont.monoMicro
            return part
        }
        return AttributedString(reads.shellLead) + mono(shell) + AttributedString(reads.shellRuns)
            + mono(reads.shellStartupFile)
            + AttributedString(reads.shellTail(variables: AccountShellOverride.allCases.count))
    }

    // MARK: - Under the well

    @ViewBuilder
    private func below(_ face: Face, detection: LaunchpadDetection, read: LaunchpadReadSession) -> some View {
        switch face {
        case .apps:
            appsActions(detection, failure: read.failure)
                .transition(.opacity)
        case .consent:
            consentRows(detection)
                .transition(.opacity)
        case .reading:
            readingRows(read)
                .transition(.opacity)
        case .found:
            LaunchpadFoundList(flow: flow)
                .transition(.opacity)
        }
    }

    // MARK: Your apps

    /// The actions and fine print under Your apps' well; `failure` is why
    /// the library could not be made, when it could not.
    private func appsActions(_ detection: LaunchpadDetection, failure: String?) -> some View {
        let apps = LaunchpadCopy.Apps.self
        let missing = detection.notFound
        return VStack(spacing: 0) {
            HStack(spacing: Space.xl) {
                Button {
                    Task { await detection.lookAgainWithLoginShell() }
                } label: {
                    HStack(spacing: Space.sm) {
                        Text(detection.isAskingLoginShell ? apps.looking : apps.lookAgainWithLoginShell)
                        KeyCombo(shortcut: Self.loginShellShortcut)
                    }
                }
                .buttonStyle(.glass)
                .keyboardShortcut(Self.loginShellShortcut)
                .disabled(missing.isEmpty || detection.isAskingLoginShell)
                if detection.isEmptyMac {
                    Button {
                        detection.lookAgain()
                        flow.seedOverride = detection.seed(
                            findsProjectsFromClaudeHistory: LaunchpadReadSession.findsProjects(for: flow))
                    } label: {
                        HStack(spacing: Space.sm) {
                            Text(apps.lookAgain)
                            KeyCombo(shortcut: Self.lookAgainShortcut)
                        }
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut(Self.lookAgainShortcut)
                } else if missing.count == 1, let only = missing.first {
                    LaunchpadInstallLink(client: only, glyph: StageLayout.Apps.actionArrow, font: AgentFont.body)
                }
            }
            .padding(.top, StageLayout.Apps.actionsGap)
            VStack(spacing: Space.xs) {
                if detection.isEmptyMac {
                    Text(apps.worksWithout)
                } else {
                    Text(apps.onlyLooked)
                    Text(apps.turningOff)
                }
                if let message = detection.loginShellMessage {
                    Text(message)
                }
                if let error = flow.workspace?.device.errorMessage {
                    Text(error)
                }
                if let failure {
                    failureLine(failure)
                }
            }
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, Space.xl)
        }
        .frame(maxWidth: .infinity)
    }

    /// Why the library could not be made, after the failure glyph.
    private func failureLine(_ failure: String) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: Size.glyphSmall))
                .foregroundStyle(AgentTheme.failure)
                .accessibilityHidden(true)
            Text(failure)
        }
        .font(AgentFont.caption)
        .foregroundStyle(.secondary)
    }

    /// ⌘L: Look again with my login shell.
    static let loginShellShortcut = KeyboardShortcut("l", modifiers: .command)
    /// ⌘R: Look again, on an empty Mac.
    static let lookAgainShortcut = KeyboardShortcut("r", modifiers: .command)

    // MARK: What Agent Tooling reads

    private func consentRows(_ detection: LaunchpadDetection) -> some View {
        let reads = LaunchpadCopy.Reads.self
        return VStack(alignment: .leading, spacing: 0) {
            if !flow.isPostCommit {
                NoteLine(symbol: "info.circle", text: reads.fork(mac: Self.forkName(detection.deviceName)), alignment: .leading)
                    .frame(height: StageLayout.Well.captionLine)
                    .padding(.top, Space.md)
            }
            if LaunchpadReadSession.chosen(for: flow).contains(.claude) {
                projectsRow()
                    .padding(.top, Space.md)
            }
        }
    }

    /// The Mac the fork line names: its name once read, else "this Mac", as
    /// a sentence says it, never the "This Mac" a nameless Mac is given.
    static func forkName(_ deviceName: String?) -> String {
        let thisMac = LaunchpadCopy.Reads.thisMac
        guard let deviceName, deviceName.compare(thisMac, options: .caseInsensitive) != .orderedSame else { return thisMac }
        return deviceName
    }

    /// The one choice before the read: Claude Code's history, folder names
    /// only.
    private func projectsRow() -> some View {
        let reads = LaunchpadCopy.Reads.self
        return HStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(reads.projectsTitle)
                    .font(AgentFont.bodyMedium)
                Text(Self.projectsDetail(flow.environment.homeURL))
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.lg)
            Toggle(reads.projectsTitle, isOn: projectsBinding)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Size.rowHeight)
        .stageCard()
    }

    /// "Reads only the folder names in ~/.claude/projects, never the
    /// conversations in them.", the folder in mono.
    static func projectsDetail(_ home: URL) -> AttributedString {
        let reads = LaunchpadCopy.Reads.self
        var folder = AttributedString(
            PathDisplay.abbreviatingHome(
                home.appending(path: ".claude/projects", directoryHint: .isDirectory).path(percentEncoded: false), home: home))
        folder.font = AgentFont.monoMicro
        return AttributedString(reads.projectsDetailLead) + folder + AttributedString(reads.projectsDetailTail)
    }

    private var projectsBinding: Binding<Bool> {
        Binding {
            LaunchpadReadSession.findsProjects(for: flow)
        } set: { on in
            Self.setFindsProjects(on, flow: flow)
        }
    }

    /// "Also find projects from Claude Code's history": the walk's choice
    /// until the read is made. A rerun's read records it as this Mac's once
    /// the library has taken the read.
    static func setFindsProjects(_ on: Bool, flow: LaunchpadFlow) {
        var seed = flow.seedOverride ?? LaunchpadSeed(chosen: LaunchpadReadSession.chosen(for: flow))
        seed.findsProjectsFromClaudeHistory = on
        flow.seedOverride = seed
    }

    // MARK: The read

    private func readingRows(_ read: LaunchpadReadSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.lg) {
                TallyLine(
                    placesRead: read.placesRead.count, commandsRun: read.commandsRun.count, totals: read.tallyTotals,
                    finalLabel: read.finalTally
                )
                .matchedGeometryEffect(id: Matched.tally, in: tally)
                Spacer(minLength: Space.lg)
                CommitLine(state: Self.commitState(read), updates: read.updatesLibrary)
                    .matchedGeometryEffect(id: Matched.commit, in: tally)
            }
            .frame(height: StageLayout.Well.captionLine)
            .padding(.top, Space.md)
            noticeRow(read)
                .padding(.top, Space.md)
            if let failure = read.failure {
                failureLine(failure)
                    .padding(.top, Space.md)
            }
        }
    }

    static func commitState(_ read: LaunchpadReadSession) -> CommitLine.State {
        switch read.phase {
        case .committing: .committing
        case .finished: .done
        case .idle, .reading, .failed: .pending
        }
    }

    /// A slow read's notice, with Skip while it can still be skipped. It is
    /// looked at again every second while the read runs.
    @ViewBuilder
    private func noticeRow(_ read: LaunchpadReadSession) -> some View {
        if read.phase == .reading {
            TimelineView(.periodic(from: .now, by: LaunchpadReadSession.noticeTick)) { _ in
                notice(read)
            }
        } else {
            notice(read)
        }
    }

    @ViewBuilder
    private func notice(_ read: LaunchpadReadSession) -> some View {
        if let notice = read.notice(now: read.now()) {
            HStack(spacing: Space.sm) {
                Image(systemName: notice.canSkip ? "clock" : "exclamationmark.triangle.fill")
                    .font(.system(size: Size.glyphSmall))
                    .foregroundStyle(notice.canSkip ? Color.secondary : AgentTheme.warning)
                    .accessibilityHidden(true)
                Text(LaunchpadReadSession.text(of: notice))
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                if notice.canSkip {
                    Button(LaunchpadCopy.Reads.skipThisApp) { read.skip(notice.client, flow: flow) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Your library, as read

    @ViewBuilder
    private func foundTally(_ read: LaunchpadReadSession) -> some View {
        let figures = Self.foundFigures(flow, read: read)
        HStack(spacing: Space.xl) {
            if let figures {
                // VoiceOver reads it once its figures are final.
                let words = LaunchpadReadSession.tallyWords(places: figures.places, commands: figures.commands)
                TallyLine(
                    placesRead: figures.places, commandsRun: figures.commands, totals: figures.totals,
                    finalLabel: figures.totals == nil ? words : nil
                )
                .matchedGeometryEffect(id: Matched.tally, in: tally)
            }
            CommitLine(state: .done, updates: flow.path == .rerun)
                .matchedGeometryEffect(id: Matched.commit, in: tally)
        }
        .frame(height: StageLayout.Well.captionLine)
    }

    /// What the read read, for S06's tally: the read's own figures, with its
    /// totals while the sign-in reads are still landing, or what the walk
    /// kept of them when this screen opens on a library read earlier.
    static func foundFigures(
        _ flow: LaunchpadFlow, read: LaunchpadReadSession
    ) -> (places: Int, commands: Int, totals: (places: Int, commands: Int)?)? {
        if read.phase == .finished { return (read.placesRead.count, read.commandsRun.count, read.tallyTotals) }
        return flow.outcomes.read.map { ($0.places, $0.commands, nil) }
    }

    // MARK: - Arrival, motion and speech

    /// The lighting plays once, as Your apps first appears; under Reduce
    /// Motion or in a still the tiles are drawn lit.
    private var isLit: Bool { lit || !motion.animatesDetails }

    /// A found app arrives with its tile; an app that was not found fades in
    /// after the last lit one.
    private func arrived(_ found: Bool) -> Bool { isLit || found }

    private func lighting(_ order: Int) -> Animation? {
        guard motion.animatesDetails else { return nil }
        return AgentMotion.selection.delay(AgentMotion.revealStagger * Double(order))
    }

    private func columnArrival(_ order: Int) -> Animation? {
        motion.animatesDetails ? motion.contentChange?.delay(AgentMotion.columnStagger * Double(order + 1)) : motion.contentChange
    }

    private func arrive(_ face: Face, detection: LaunchpadDetection) {
        lit = true
        if face == .apps, !detection.hasAnnounced {
            detection.hasAnnounced = true
            AccessibilityNotification.Announcement(detection.foundAnnouncement).post()
        }
        focus = Self.region(for: face)
    }

    /// Says what the read has added to its `spoken` since last time.
    private func speak(_ read: LaunchpadReadSession, upTo count: Int) {
        defer { spokenCount = count }
        guard count > spokenCount else { return }
        for sentence in read.spoken[spokenCount..<count] {
            AccessibilityNotification.Announcement(sentence).post()
        }
    }

    private func observation(_ client: ClientKind) -> TargetObservation? {
        flow.workspace?.device.observations.first { $0.surface.client == client }
            ?? LaunchpadReadSession.of(flow).observation(for: client)
    }

    // MARK: - Popovers

    static func lookedKey(_ client: ClientKind) -> String { "apps.looked.\(client.rawValue)" }

    /// A popover shown while the flow says it is open, so ⎋ closes it first.
    private func popoverBinding(_ key: String) -> Binding<Bool> {
        Binding {
            flow.openPopover == key
        } set: { shown in
            if shown {
                flow.openPopover = key
            } else if flow.openPopover == key {
                flow.openPopover = nil
            }
        }
    }
}

// MARK: - Links and popovers

/// A vendor's own install page, as a link: it leaves Agent Tooling, so
/// `arrow.up.right` follows the words.
struct LaunchpadInstallLink: View {
    let client: ClientKind
    let glyph: CGFloat
    let font: Font
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(LaunchpadDetection.installPage(for: client))
        } label: {
            HStack(spacing: Space.xxs) {
                Text(LaunchpadCopy.Apps.howToInstall(client.rawValue))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: glyph))
                    .accessibilityHidden(true)
            }
            .font(font)
            .lineLimit(1)
        }
        .buttonStyle(.link)
        .help(LaunchpadDetection.installPage(for: client).absoluteString)
    }
}

/// Where Agent Tooling looked for an app it did not find: the locator's own
/// folders, in its order, and the app's install page.
struct LaunchpadLookedPopover: View {
    let client: ClientKind
    let homeURL: URL

    var body: some View {
        let apps = LaunchpadCopy.Apps.self
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(apps.whereLookedTitle)
                .font(AgentFont.heading)
            Text(LaunchpadDetection.lookedIn(for: client, homeURL: homeURL))
                .font(AgentFont.caption)
                .wrapsLines()
            Text(apps.nothingFound(client.rawValue))
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
            LaunchpadInstallLink(client: client, glyph: StageLayout.Apps.lineArrow, font: AgentFont.caption)
        }
        .padding(Space.lg)
        .frame(width: Size.infoPopover, alignment: .leading)
    }
}

// MARK: - Where things are drawn

/// Where each tile, each tile's keys, Your library's list and each of its
/// rows are drawn, in the window: `tile(_:)`, `keys(_:)`, `listCard` and
/// `row(_:)`. The screen's render tests hold the tiles still from one face
/// to the next and keep the keyboard's place in the list in view. Reported
/// only when `\.launchpadReportsFrames` asks for it.
struct LaunchpadFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }

    static func tile(_ client: ClientKind) -> String { "tile.\(client.rawValue)" }
    static func keys(_ client: ClientKind) -> String { "keys.\(client.rawValue)" }
    static let listCard = "found.list"
    static func row(_ id: ArtifactID) -> String { "found.row.\(id.rawValue.uuidString)" }
}

/// Reports the frame of what it is the background of under `key`, when the
/// stage is asked to: otherwise it is nothing, so the stage measures
/// nothing for a test that is not looking.
struct LaunchpadFrameReporter: View {
    let key: String
    @Environment(\.launchpadReportsFrames) private var reports

    var body: some View {
        if reports {
            GeometryReader { geometry in
                Color.clear.preference(key: LaunchpadFrames.self, value: [key: geometry.frame(in: .global)])
            }
        }
    }
}

extension EnvironmentValues {
    /// Whether the stage reports where its tiles, keys and list rows are
    /// drawn (`LaunchpadFrames`). Only a render test turns it on.
    @Entry var launchpadReportsFrames = false
}

// MARK: - Layout

extension StageLayout.Apps {
    /// A name under a tile: its line, so the lines under it start at y 266.
    static let nameLine: CGFloat = 16
    /// The arrow after a link under a tile, and after one in the actions.
    static let lineArrow: CGFloat = 9
    static let actionArrow: CGFloat = 10
    /// The keyboard's place on a tile: just outside its plate.
    static let tileHighlightInset = EdgeInsets(top: -Space.xs, leading: -Space.xs, bottom: -Space.xs, trailing: -Space.xs)
}

extension StageLayout.Reads {
    /// The sign-in strip's hairline inside the well (y 434 on the stage),
    /// and the room under it.
    static let signInTop: CGFloat = 284
    static let signInPadding: CGFloat = 10
    static let signInLabelGap: CGFloat = 3
}

extension StageLayout.Found {
    /// The tally and the commit line in the header's second subtitle line
    /// (y 124 on the stage): under the eyebrow, the title and the first
    /// subtitle line, and a nudge.
    static let tallyTop: CGFloat =
        StageLayout.Header.eyebrowLine + StageLayout.Header.heroTitleGap + StageLayout.Header.heroTitleLine
        + StageLayout.Header.heroSubtitleGap + StageLayout.Header.subtitleLine + Space.xxs
    /// The glyph before a sign-in line.
    static let signInGlyph: CGFloat = 11
}

extension RoundedRectangle {
    /// The keyboard's place around a 64 tile: the tile's corner, grown with
    /// the highlight's inset.
    fileprivate static let tileHighlight = RoundedRectangle(cornerRadius: Radius.xl + Space.xs, style: .continuous)
}

extension LaunchpadReadSession {
    /// How often an elapsed time under a tile, and a slow read's notice, are
    /// looked at again.
    static let elapsedTick: TimeInterval = 0.1
    static let noticeTick: TimeInterval = 1
}
