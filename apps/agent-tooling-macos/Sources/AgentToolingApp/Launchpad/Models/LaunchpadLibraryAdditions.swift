import AgentToolingCore
import AppKit
import Foundation
import Observation
import SwiftUI

/// What Start your library reaches outside the library through, each with its
/// live default. A test hands in its own, so no skill is ever fetched from
/// the network and no Git is looked for on the Mac running it.
struct LaunchpadLibraryServices: Sendable {
    /// Fetches a skills.sh skill from its repository: the one network read
    /// the screen makes, and only for a skill the person picked, after they
    /// press Add.
    var fetchSkill: @Sendable (_ repository: String, _ skillID: String, _ cacheURL: URL) async throws -> PreparedStandaloneSkill
    /// Whether this Mac can run Git, which a skill from skills.sh is fetched
    /// with.
    var hasGit: @Sendable () -> Bool

    static let live = LaunchpadLibraryServices(
        fetchSkill: { repository, skillID, cacheURL in
            let binding = try await WorkspaceSkillPreparation.locateUpstream(
                skillID: skillID, repositoryURL: "https://github.com/\(repository)", cacheURL: cacheURL)
            return try await WorkspaceSkillPreparation.fetchUpstream(binding: binding, cacheURL: cacheURL)
        },
        hasGit: { gitIsInstalled() })

    /// Whether `/usr/bin/git` will run Git rather than offer to install the
    /// developer tools: read from the folders alone, so asking runs nothing.
    nonisolated static func gitIsInstalled(fileManager: FileManager = .default) -> Bool {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/git") else { return false }
        var developerFolders = ["/Library/Developer/CommandLineTools"]
        if let selected = try? fileManager.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            developerFolders.append(selected)
        }
        if let chosen = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { developerFolders.append(chosen) }
        return developerFolders.contains { fileManager.isExecutableFile(atPath: $0 + "/usr/bin/git") }
    }
}

extension EnvironmentValues {
    /// How Start your library fetches a skills.sh pick and looks for Git.
    @Entry var launchpadLibraryServices = LaunchpadLibraryServices.live
}

/// Adds selected loose-skill copies and starter listings in one library revision.
/// Selection is explicit; app folders are never changed and no client runs.
/// A skills.sh fetch precedes the revision and can be cancelled without writing.
/// Once the revision begins, cancellation waits for it to finish.
@MainActor @Observable
final class LaunchpadLibraryAdditions: LaunchpadInterruptible {
    /// One loose skill the apps hold.
    struct SkillRow: Identifiable, Equatable {
        /// What the apps' copies have in common.
        enum Copies: Equatable, Sendable {
            /// One copy, in one folder.
            case one
            /// Copies that differ: the person chooses one.
            case different
            /// Copies that hold the same skill.
            case same
        }

        enum State: Hashable, Sendable {
            case ready
            case adding
            /// In the library: made yours by this setup.
            case added
            /// Not added, with the row's own sentence why.
            case refused(String)
        }

        let artifactID: ArtifactID
        let name: String
        /// Its copies, measured, in the app order of each copy's first reader.
        let copies: [ObservedSkillCopy]
        let sameness: Copies
        var state: State

        var id: ArtifactID { artifactID }

        /// Every app that reads one of its copies.
        var holders: Set<ClientKind> { Set(copies.flatMap(\.readers)) }

        /// When its newest copy changed.
        var changedAt: Date? { copies.compactMap(\.changedAt).max() }

        /// The copy the chooser starts on: the one changed last, or the first
        /// in the app order when the dates do not say.
        var newest: ObservedSkillCopy? {
            copies.enumerated().max { lhs, rhs in
                let (left, right) = (lhs.element.changedAt ?? .distantPast, rhs.element.changedAt ?? .distantPast)
                return left == right ? lhs.offset > rhs.offset : left < right
            }?.element
        }
    }

    /// Skills another tool placed and keeps in step, which the screen names
    /// and leaves alone.
    struct LeftAlone: Identifiable, Equatable {
        let manager: String
        let names: [String]

        var id: String { manager }
    }

    /// One tool on the starter shelf.
    struct CatalogPick: Identifiable, Equatable {
        enum State: Equatable, Sendable {
            case available
            case adding
            /// Added by this setup.
            case added
            /// The library holds it already.
            case inLibrary
            /// A skills.sh skill on a Mac without Git.
            case needsGit
            /// Not added, with the card's own sentence why.
            case refused(String)
        }

        let entry: StarterShelf.Entry
        let package: MarketplacePackage
        var state: State

        var id: String { package.id }

        /// Whether the last Add left it out.
        var isRefused: Bool {
            if case .refused = state { true } else { false }
        }
    }

    /// A skill inside a plugin, for the fine print's example.
    struct PluginExample: Equatable {
        let skill: String
        let plugin: String
    }

    enum Phase: Equatable {
        case unloaded
        case loading
        case ready
        case adding
    }

    let flow: LaunchpadFlow
    /// Set by the screen from its environment before anything is added.
    @ObservationIgnored var services: LaunchpadLibraryServices

    private(set) var phase = Phase.unloaded
    private(set) var rows: [SkillRow] = []
    private(set) var leftAlone: [LeftAlone] = []
    private(set) var picks: [CatalogPick] = []
    private(set) var ticked: Set<ArtifactID> = []
    /// The copy chosen for a row, by path, once the person chose one.
    private(set) var chosen: [ArtifactID: String] = [:]
    private(set) var picked: Set<String> = []
    /// Why a copy could not be brought in, by its folder, from the last Add
    /// that tried it. On a row whose apps hold different copies the row stays
    /// open, so another copy can be chosen, and this is said under the
    /// chooser while the copy is chosen.
    private(set) var copyRefusals: [String: String] = [:]
    /// Why the last Add wrote nothing at all, when it could not.
    private(set) var failure: String?
    /// Said under the catalog label when the shelf shows an earlier read.
    private(set) var offlineNote: String?
    private(set) var pluginExample: PluginExample?
    /// What a sheet last added, as the footer says it.
    private(set) var savedLine: String?
    private(set) var isWriting = false
    /// Why the skill written in the editor was not saved.
    private(set) var writeFailure: String?
    /// Whether a skills.sh pick is being fetched: the stoppable part of an
    /// Add.
    private(set) var isFetching = false
    /// The Add under way, from ↩ or ⌘A, which moves the stage on once
    /// everything asked for landed.
    @ObservationIgnored private(set) var commitTask: Task<Void, Never>?
    /// Whether the Add under way has begun writing its revision: past the
    /// point where stopping could keep nothing.
    @ObservationIgnored private var isWritingRevision = false

    init(flow: LaunchpadFlow, services: LaunchpadLibraryServices = .live) {
        self.flow = flow
        self.services = services
    }

    /// The flow's one model for this step, made the first time anything asks.
    static func of(_ flow: LaunchpadFlow) -> LaunchpadLibraryAdditions {
        flow.model(for: .library) { LaunchpadLibraryAdditions(flow: flow) }
    }

    // MARK: Reading what there is

    /// Reads the library, this Mac's last check and the starter shelf, and
    /// measures each skill's copies. Runs no command and asks no catalog.
    func load() async {
        guard phase == .unloaded else { return }
        guard let workspace = flow.workspace else {
            phase = .ready
            return
        }
        phase = .loading
        if workspace.library.state == nil { await workspace.library.refresh() }
        let snapshot = workspace.library.state?.snapshot
        let document = snapshot?.document
        let observations = workspace.device.observations.isEmpty ? snapshot?.device.observations ?? [] : workspace.device.observations
        let managed = Set(workspace.device.managedClients)
        let adoptedHere = Set(flow.decisions.adopted.map(\.artifactID))

        var found: [(artifact: ArtifactRecord, copies: [ObservedSkillCopy])] = []
        var managers: [String: [String]] = [:]
        for artifact in document?.artifacts ?? []
        where artifact.identity.kind == .skill && artifact.identity.parentPackageID == nil {
            guard let declared = artifact.declaredName,
                artifact.authority == .trackedOnly || adoptedHere.contains(artifact.identity.id)
            else { continue }
            let copies = ObservedSkillCopies.group(observations: observations, managed: managed, declaredName: declared)
            if !copies.isEmpty {
                found.append((artifact, copies))
            } else if artifact.authority == .trackedOnly,
                let manager = Self.manager(of: declared, in: observations, managed: managed)
            {
                managers[manager, default: []].append(artifact.identity.displayName)
            }
        }
        let measured = await ObservedSkillCopies.measure(found.flatMap(\.copies))
        let byPath = Dictionary(measured.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        rows = found.map { artifact, copies in
            let copies = copies.map { byPath[$0.path] ?? $0 }
            let sameness: SkillRow.Copies =
                copies.count < 2 ? .one : (ObservedSkillCopies.differ(copies) ? .different : .same)
            return SkillRow(
                artifactID: artifact.identity.id, name: artifact.identity.displayName, copies: copies, sameness: sameness,
                state: adoptedHere.contains(artifact.identity.id) ? .added : .ready)
        }
        .sorted(by: Self.recentFirst)
        leftAlone = managers.keys.sorted().map { LeftAlone(manager: $0, names: (managers[$0] ?? []).sorted()) }
        pluginExample = document.flatMap(Self.pluginExample(in:))
        loadShelf(workspace)
        phase = .ready
    }

    /// The shelf, with each card's state from the library as it stands: a
    /// listing this setup added reads as added, picked, as it did when it
    /// landed, even when the stage comes back to this screen afresh.
    private func loadShelf(_ workspace: WorkspaceLaunch.Workspace) {
        let entries = Dictionary(
            ((try? StarterShelf.entries()) ?? []).map { ($0.packageID, $0) }, uniquingKeysWith: { first, _ in first })
        let hasGit = services.hasGit()
        let addedHere = Set(flow.decisions.added.map(\.artifactID))
        picks = workspace.marketplace.starterShelf().compactMap { package in
            guard let entry = entries[package.id] else { return nil }
            let state: CatalogPick.State
            if let match = workspace.marketplace.libraryMatch(for: package) {
                state = addedHere.contains(match.artifactID) ? .added : .inLibrary
            } else if entry.kind == .skill, !hasGit {
                state = .needsGit
            } else {
                state = .available
            }
            return CatalogPick(entry: entry, package: package, state: state)
        }
        offlineNote = Self.offlineNote(workspace.marketplace, now: flow.environment.now())
    }

    // MARK: Choosing

    /// The rows that can still be ticked.
    var readyRows: [SkillRow] { rows.filter { $0.state == .ready } }

    func isTicked(_ row: SkillRow) -> Bool { ticked.contains(row.id) || row.state == .added }

    func isPicked(_ pick: CatalogPick) -> Bool { picked.contains(pick.id) || pick.state == .added }

    /// The copy a row would bring in: the chosen one, else the newest.
    func chosenCopy(for row: SkillRow) -> ObservedSkillCopy? {
        row.copies.first { $0.path == chosen[row.id] } ?? row.newest
    }

    /// Space or a click on a row's checkbox.
    func toggle(_ id: ArtifactID) {
        guard phase == .ready, rows.contains(where: { $0.id == id && $0.state == .ready }) else { return }
        if ticked.remove(id) == nil { ticked.insert(id) }
    }

    /// A click on a copy, or ←→ in the chooser: that copy, and the row ticked.
    func choose(_ path: String, for id: ArtifactID) {
        guard phase == .ready,
            let row = rows.first(where: { $0.id == id && $0.state == .ready }), row.copies.contains(where: { $0.path == path })
        else { return }
        chosen[id] = path
        ticked.insert(id)
    }

    /// ⌘A, and the button that carries it: every row that can be ticked is
    /// ticked, each with its chosen copy, and added with whatever else is
    /// ticked or picked, in the one revision ↩ writes; then the stage moves on
    /// as it does after ↩.
    func addAll() {
        guard canAddAll else { return }
        ticked.formUnion(readyRows.map(\.id))
        addAndMoveOn()
    }

    /// Whether ⌘A has a row to add.
    var canAddAll: Bool { phase == .ready && commitTask == nil && !readyRows.isEmpty }

    var addAllTitle: String { LaunchpadCopy.Library.addAll(readyRows.count) }

    /// A click on a card.
    func togglePick(_ id: String) {
        guard phase == .ready, picks.contains(where: { $0.id == id && $0.state == .available }) else { return }
        if picked.remove(id) == nil { picked.insert(id) }
    }

    // MARK: The keyboard

    /// Where the keyboard is: a skill's row, or a card.
    enum Focus: Hashable {
        case row(ArtifactID)
        case card(String)
    }

    enum Move {
        case up
        case down
        case left
        case right
    }

    /// Where an arrow key takes the keyboard from `current`: ↑↓ through the
    /// rows, on from the last row to the first card and back up from a card;
    /// ←→ along the cards. Nil where it goes nowhere. ←→ on a row choose a
    /// copy instead (`stepCopy`).
    func focus(after current: Focus, moving move: Move) -> Focus? {
        let rowIDs = rows.map(\.id)
        let cardIDs = picks.map(\.id)
        switch (current, move) {
        case (.row(let id), .up):
            guard let index = rowIDs.firstIndex(of: id), index > 0 else { return nil }
            return .row(rowIDs[index - 1])
        case (.row(let id), .down):
            guard let index = rowIDs.firstIndex(of: id) else { return nil }
            if index + 1 < rowIDs.count { return .row(rowIDs[index + 1]) }
            return cardIDs.first.map(Focus.card)
        case (.card, .up):
            return rowIDs.last.map(Focus.row)
        case (.card(let id), .left):
            guard let index = cardIDs.firstIndex(of: id), index > 0 else { return nil }
            return .card(cardIDs[index - 1])
        case (.card(let id), .right):
            guard let index = cardIDs.firstIndex(of: id), index + 1 < cardIDs.count else { return nil }
            return .card(cardIDs[index + 1])
        case (.card, .down), (.row, .left), (.row, .right):
            return nil
        }
    }

    /// ←→ on a row whose apps hold different copies: the copy before or
    /// after the chosen one, and the row ticked. False where there is no copy
    /// to move to.
    @discardableResult
    func stepCopy(of id: ArtifactID, by offset: Int) -> Bool {
        guard let row = rows.first(where: { $0.id == id }), row.sameness == .different, row.state == .ready,
            let current = chosenCopy(for: row), let index = row.copies.firstIndex(where: { $0.path == current.path })
        else { return false }
        let next = min(max(index + offset, 0), row.copies.count - 1)
        guard next != index else { return false }
        choose(row.copies[next].path, for: id)
        return true
    }

    /// What Add would add: the ticked skills and the picked tools.
    var count: Int {
        rows.filter { $0.state == .ready && ticked.contains($0.id) }.count
            + picks.filter { $0.state == .available && picked.contains($0.id) }.count
    }

    /// "Add 3 to library", or Continue when nothing is ticked or picked.
    var primaryTitle: String { count == 0 ? LaunchpadCopy.Footer.continue : LaunchpadCopy.Library.add(count) }

    /// Whether the screen shows its first section. A Mac that manages no app
    /// (Continue without apps) has no skills to make yours, so only the
    /// catalogs apply there.
    var showsSkills: Bool { !(flow.workspace?.device.managedClients.isEmpty ?? true) }

    // MARK: What a row and a card say

    /// The row's line under its name: its apps and, for one copy, where it
    /// is; or, once Add has run, how it went.
    func detail(for row: SkillRow) -> (clause: String, path: String?) {
        let copy = LaunchpadCopy.Library.self
        switch row.state {
        case .adding: return (copy.adding, nil)
        case .added: return (copy.personalLibrary, nil)
        case .refused(let why): return (why, nil)
        case .ready: break
        }
        let apps = LaunchpadCopy.list(row.copies.compactMap { $0.readers.first?.rawValue })
        switch row.sameness {
        case .one:
            let readers = LaunchpadCopy.list((row.copies.first?.readers ?? []).map(\.rawValue))
            return (copy.onlyIn(readers), row.copies.first.map { displayedPath($0.path) })
        case .different: return (copy.differentCopies(apps), nil)
        case .same: return (copy.sameIn(apps), nil)
        }
    }

    /// The copy chooser's cells, in the app order.
    func options(for row: SkillRow) -> [CopyChooser.Option] {
        row.copies.map { copy in
            let app = copy.readers.first?.rawValue ?? ""
            let changed = copy.changedAt.map(when)
            return CopyChooser.Option(
                id: copy.path, title: LaunchpadCopy.Library.copy(in: app),
                detail: copy.fileCount.map { LaunchpadCopy.Library.copyDetail(files: $0, changed: changed) },
                accessibilityLabel: LaunchpadCopy.Library.copyLabel(in: app, files: copy.fileCount, changed: changed))
        }
    }

    /// Under the chooser: what happens to the copy that is not chosen.
    func chooserCaption(for row: SkillRow) -> String {
        let copy = LaunchpadCopy.Library.self
        guard let chosen = chosenCopy(for: row) else { return copy.otherCopiesStay }
        let others = row.copies.filter { $0.path != chosen.path }
        guard others.count == 1, let other = others.first, let app = other.readers.first?.rawValue else {
            return copy.otherCopiesStay
        }
        guard let files = other.fileCount, let otherDate = other.changedAt, let chosenDate = chosen.changedAt,
            otherDate != chosenDate
        else { return copy.otherCopyStays(in: app) }
        return otherDate < chosenDate
            ? copy.otherCopyIsOlder(in: app, files: files, changed: when(otherDate))
            : copy.otherCopyIsNewer(in: app, files: files, changed: when(otherDate))
    }

    /// Why the copy chosen on a row whose apps hold different copies was not
    /// brought in, while that copy is chosen.
    func copyRefusal(for row: SkillRow) -> String? {
        guard row.sameness == .different, row.state == .ready else { return nil }
        return chosenCopy(for: row).flatMap { copyRefusals[$0.path] }
    }

    /// The row's checkbox, as VoiceOver reads it.
    func accessibilityLabel(for row: SkillRow) -> String {
        let detail = detail(for: row)
        let label = [row.name, detail.clause, detail.path].compactMap(\.self).joined(separator: ", ")
        return copyRefusal(for: row).map { "\(label) \($0)" } ?? label
    }

    /// The row's marks, as VoiceOver reads them: "In Codex, Claude Code and
    /// Gemini CLI".
    func marksLabel(for row: SkillRow) -> String {
        LaunchpadCopy.Library.inApps(LaunchpadCopy.list(ClientKind.allCases.filter(row.holders.contains).map(\.rawValue)))
    }

    /// A card's last line: where it comes from, with the install count a
    /// catalog reported when one was read.
    func source(for pick: CatalogPick) -> String {
        let copy = LaunchpadCopy.Library.self
        switch pick.state {
        case .adding: return copy.adding
        case .added, .inLibrary: return copy.inLibrary
        case .needsGit: return "\(pick.entry.source) · \(copy.needsGit)"
        case .refused: return copy.notAddedMark
        case .available:
            guard let installs = pick.package.installCount else { return pick.entry.source }
            return copy.source(pick.entry.source, installs: installs)
        }
    }

    /// A card's summary.
    func summary(for pick: CatalogPick) -> String { pick.entry.summary }

    /// The card's checkbox, as VoiceOver reads it, with why it was not added
    /// when it was not.
    func accessibilityLabel(for pick: CatalogPick) -> String {
        let last: String
        if case .refused(let why) = pick.state { last = why } else { last = source(for: pick) }
        return LaunchpadCopy.Library.cardLabel(name: pick.entry.name, summary: summary(for: pick), source: last)
    }

    /// Why each card the last Add left out was not added, in the cards'
    /// order: said under the cards, where each sentence names its card.
    var cardRefusals: [String] {
        picks.compactMap { pick in
            guard case .refused(let why) = pick.state else { return nil }
            return why
        }
    }

    var finePrint: String {
        LaunchpadCopy.Library.finePrint(example: pluginExample.map { ($0.skill, $0.plugin) })
    }

    /// Section A's one line, when there is no row.
    var emptyLine: String {
        let personal = flow.workspace?.library.state?.snapshot.document.artifacts.contains {
            $0.identity.kind == .skill && $0.identity.parentPackageID == nil && $0.authority == .centralPersonal
        }
        return personal == true ? LaunchpadCopy.Library.everythingIsYours : LaunchpadCopy.Library.nothingToMakeYours
    }

    private func displayedPath(_ path: String) -> String {
        guard let home = flow.workspace?.homeRoot else { return path }
        return PathDisplay.abbreviatingHome(path, home: home)
    }

    private func when(_ date: Date) -> String {
        SnapshotTime.compact(date, now: flow.environment.now())
    }

    // MARK: Adding

    /// ↩, and ⌘A once it has ticked every row: adds every tick and pick in
    /// one revision, then moves the stage on once everything asked for
    /// landed. With nothing ticked or picked it moves on at once, writing
    /// nothing. A second press while an Add is under way does nothing.
    func addAndMoveOn() {
        guard phase != .adding, commitTask == nil else { return }
        guard count > 0 else {
            flow.advance()
            return
        }
        guard phase == .ready else { return }
        commitTask = Task {
            let landed = await commit()
            commitTask = nil
            guard landed, !Task.isCancelled, flow.step == .library else { return }
            flow.advance()
        }
    }

    /// Stop ⎋ while a skills.sh pick is fetched, and the screen going away
    /// before the revision is written: the Add stops and nothing is written;
    /// every tick and pick stays for the next one. Once the revision is being
    /// written it is not cut short.
    func stopAdding() {
        guard commitTask != nil, !isWritingRevision else { return }
        commitTask?.cancel()
    }

    /// Stoppable while a pick is fetched; nothing else here runs long enough
    /// to wait for.
    var interruption: LaunchpadInterruption { isFetching ? .stoppable : .idle }

    /// A quit: stops a fetch, keeping nothing, and returns once the Add has
    /// ended.
    func interrupt() async {
        let task = commitTask
        stopAdding()
        await task?.value
    }

    /// Adds selected skills and listings in one revision after any skills.sh fetch.
    /// Rejected copies remain selectable with their reasons. Returns true only when
    /// nothing was selected or every requested addition succeeded.
    @discardableResult
    func commit() async -> Bool {
        guard phase == .ready else { return false }
        let rowsToAdd = rows.filter { $0.state == .ready && ticked.contains($0.id) }
        let picksToAdd = picks.filter { $0.state == .available && picked.contains($0.id) }
        guard !rowsToAdd.isEmpty || !picksToAdd.isEmpty else { return true }
        guard let workspace = flow.workspace else { return false }
        phase = .adding
        failure = nil
        defer { phase = .ready }
        let rowIDs = rowsToAdd.map(\.id)
        let pickIDs = picksToAdd.map(\.id)
        for id in rowIDs { setState(.adding, row: id) }
        for id in pickIDs { setState(.adding, pick: id) }

        guard let snapshot = try? await workspace.service.snapshot() else {
            failAll(rowIDs, pickIDs)
            return false
        }
        let head = snapshot.document.revision.id
        var prepared: [ArtifactID: PreparedStandaloneSkill] = [:]
        var adoptions: [WorkspaceLibraryAdditionBatch.Adoption] = []
        var copiedFrom: [ArtifactID: ClientKind] = [:]
        for row in rowsToAdd {
            guard let copy = chosenCopy(for: row) else {
                refuse(row: row.id, LaunchpadCopy.Library.notReadable())
                continue
            }
            // Read afresh: a refusal an earlier Add gave this copy says
            // nothing about a folder renamed or fixed since.
            copyRefusals[copy.path] = nil
            do {
                prepared[row.id] = try await WorkspaceSkillPreparation.capturePersonal(
                    directory: URL(filePath: copy.path, directoryHint: .isDirectory))
                adoptions.append(.init(artifactID: row.id, sourcePath: copy.path))
                if row.sameness == .different, let app = copy.readers.first { copiedFrom[row.id] = app }
            } catch {
                refuse(row: row.id, copy: copy.path, LaunchpadCopy.Library.sentence(forUnreadable: error))
            }
        }
        var catalogAdds: [NativePackageAdoptionCommand] = []
        var intakes: [StandaloneSkillIntakeCommand] = []
        var cards: [ArtifactID: String] = [:]
        for pick in picksToAdd {
            if Task.isCancelled { break }
            switch pick.entry.kind {
            case .plugin:
                guard let client = pick.entry.client else {
                    refuse(pick: pick.id, Self.cardSentence(for: NativePackageAdoptionError.unrecognizedListing, name: pick.entry.name))
                    continue
                }
                do {
                    let command = try NativePackageAdoptionCommand(expectedRevisionID: head, package: pick.package, client: client)
                    catalogAdds.append(command)
                    cards[command.artifactID] = pick.id
                } catch {
                    refuse(pick: pick.id, Self.cardSentence(for: error, name: pick.entry.name))
                }
            case .skill:
                guard let listing = WorkspaceMarketplaceSession.skillsShListing(pick.package) else {
                    refuse(pick: pick.id, LaunchpadCopy.Library.namesNoRepository(pick.entry.name))
                    continue
                }
                isFetching = true
                defer { isFetching = false }
                do {
                    let skill = try await services.fetchSkill(listing.repository, listing.skillID, Self.skillCache(workspace))
                    let source = snapshot.document.sources.first {
                        $0.role == .publisherRepository && $0.repositoryURL == skill.review.upstream?.repositoryURL
                            && $0.requestedRef == skill.review.upstream?.requestedRef
                    }
                    let command = StandaloneSkillIntakeCommand(
                        expectedRevisionID: head, displayName: pick.package.name, prepared: skill,
                        upstreamIDs: .init(sourceID: source?.id ?? WorkspaceObjectID()))
                    intakes.append(command)
                    prepared[command.artifactID] = skill
                    cards[command.artifactID] = pick.id
                } catch {
                    // A stopped fetch is not a failed one: it is said nowhere,
                    // and the pick stays for the next Add.
                    if !Task.isCancelled { refuse(pick: pick.id, LaunchpadCopy.Library.notFetched(pick.entry.name)) }
                }
            }
        }
        guard !Task.isCancelled else {
            restore(rowIDs, pickIDs)
            return false
        }

        var batch = WorkspaceLibraryAdditionBatch(
            expectedRevisionID: head, adoptions: adoptions, catalogAdds: catalogAdds, intakes: intakes)
        guard !batch.isEmpty else { return false }
        isWritingRevision = true
        defer { isWritingRevision = false }
        let paths = Dictionary(adoptions.map { ($0.artifactID, $0.sourcePath) }, uniquingKeysWith: { first, _ in first })
        var landed: Set<ArtifactID> = []
        do {
            let refusals = try await workspace.service.previewLibraryAdditions(batch, prepared: prepared)
            settle(refusals, cards: cards, paths: paths)
            batch = batch.excluding(Set(refusals.map(\.artifactID)))
            if !batch.isEmpty {
                landed = Set(try await workspace.service.applyLibraryAdditions(batch, prepared: prepared).affectedArtifactIDs)
            }
        } catch LibraryAdditionError.nothingToAdd(let refusals) {
            settle(refusals, cards: cards, paths: paths)
        } catch is CancellationError {
            restore(rowIDs, pickIDs)
            return false
        } catch {
            failAll(rowIDs, pickIDs)
            return false
        }
        // A row the library refused only as the revision was written says so
        // in the words a preview against the new head gives.
        let late = batch.excluding(landed)
        if !late.isEmpty {
            let refusals = (try? await workspace.service.previewLibraryAdditions(late, prepared: prepared)) ?? []
            settle(refusals, cards: cards, paths: paths)
            for id in late.artifactIDs where !refusals.contains(where: { $0.artifactID == id }) {
                if let card = cards[id] {
                    refuse(pick: card, LaunchpadCopy.Library.notAdded(naming: name(ofPick: card)))
                } else {
                    refuse(row: id, LaunchpadCopy.Library.notAdded())
                }
            }
        }

        if !landed.isEmpty {
            await workspace.library.refresh()
            workspace.marketplace.reloadSources()
        }
        record(
            rows: rowsToAdd.filter { landed.contains($0.id) }, copiedFrom: copiedFrom,
            catalogAdds: catalogAdds.filter { landed.contains($0.artifactID) },
            intakes: intakes.filter { landed.contains($0.artifactID) })
        await reveal(
            rows: rowsToAdd.map(\.id).filter(landed.contains), picks: landed.compactMap { cards[$0] })
        ticked.subtract(landed)
        picked.subtract(landed.compactMap { cards[$0] })
        let asked = rowsToAdd.count + picksToAdd.count
        return landed.count == asked
    }

    /// What this setup did in the library, for the review and Done.
    private func record(
        rows: [SkillRow], copiedFrom: [ArtifactID: ClientKind], catalogAdds: [NativePackageAdoptionCommand],
        intakes: [StandaloneSkillIntakeCommand]
    ) {
        for row in rows where !flow.decisions.adopted.contains(where: { $0.artifactID == row.id }) {
            flow.decisions.adopted.append(.init(artifactID: row.id, name: row.name, copyFrom: copiedFrom[row.id]))
        }
        for command in catalogAdds {
            add(.init(artifactID: command.artifactID, name: command.displayName, source: .catalog(command.client)))
            if !flow.outcomes.addedPluginsAwaitingCheck.contains(command.displayName) {
                flow.outcomes.addedPluginsAwaitingCheck.append(command.displayName)
            }
        }
        for command in intakes {
            add(.init(artifactID: command.artifactID, name: command.displayName, source: .skillsSh))
        }
    }

    private func add(_ item: LaunchpadLibraryDecisions.Added) {
        guard !flow.decisions.added.contains(where: { $0.artifactID == item.artifactID }) else { return }
        flow.decisions.added.append(item)
    }

    /// Each landed row turns to "Personal library" in turn, 70 ms apart,
    /// unless motion is reduced or still; then the stage waits one beat more,
    /// as a badge lands after its tile, before it moves on.
    private func reveal(rows ids: [ArtifactID], picks cardIDs: [String]) async {
        let animates = flow.environment.motion
            .resolved(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).animatesDetails
        let ordered = rows.map(\.id).filter(ids.contains)
        for (index, id) in ordered.enumerated() {
            if animates, index > 0 { try? await Task.sleep(for: .seconds(AgentMotion.revealStagger)) }
            setState(.added, row: id)
        }
        for id in cardIDs { setState(.added, pick: id) }
        if animates, !ordered.isEmpty || !cardIDs.isEmpty {
            try? await Task.sleep(for: .seconds(AgentMotion.revealStagger + AgentMotion.badgeDelay))
        }
    }

    /// Each refused row and card, with its own sentence: a card's names it,
    /// since it is said under the cards; a row's is about "it", beside its
    /// name.
    private func settle(_ refusals: [LibraryAdditionRefusal], cards: [ArtifactID: String], paths: [ArtifactID: String]) {
        for refusal in refusals {
            if let card = cards[refusal.artifactID] {
                refuse(pick: card, LaunchpadCopy.Library.sentence(for: refusal, naming: name(ofPick: card)))
            } else if Self.isAboutTheCopy(refusal), let path = paths[refusal.artifactID] {
                refuse(row: refusal.artifactID, copy: path, LaunchpadCopy.Library.sentence(for: refusal))
            } else {
                refuse(row: refusal.artifactID, LaunchpadCopy.Library.sentence(for: refusal))
            }
        }
    }

    /// Whether a refusal is about the copy that was offered rather than the
    /// skill's record, so another of its copies may still be brought in.
    private static func isAboutTheCopy(_ refusal: LibraryAdditionRefusal) -> Bool {
        switch refusal {
        case .declaredNameMismatch, .notAdoptable(_, .notRead), .notAdoptable(_, .followsAnUpstream): true
        case .notAdoptable, .catalog, .intake: false
        }
    }

    /// Why a card's listing could not be added, naming the card.
    private static func cardSentence(for error: any Error, name: String) -> String {
        guard let error = error as? NativePackageAdoptionError else { return LaunchpadCopy.Library.notAdded(naming: name) }
        return LaunchpadCopy.Library.sentence(forListing: error, naming: name)
    }

    private func name(ofPick id: String) -> String? {
        picks.first { $0.id == id }?.entry.name
    }

    private func refuse(row id: ArtifactID, _ why: String) {
        setState(.refused(why), row: id)
        ticked.remove(id)
    }

    /// A copy the library would not take. Where the apps hold other copies
    /// the row stays open and unticked, and says why under the chooser while
    /// this copy is chosen; with no other copy to choose, the row is refused.
    private func refuse(row id: ArtifactID, copy path: String, _ why: String) {
        guard let row = rows.first(where: { $0.id == id }), row.sameness == .different else {
            refuse(row: id, why)
            return
        }
        copyRefusals[path] = why
        setState(.ready, row: id)
        ticked.remove(id)
    }

    private func refuse(pick id: String, _ why: String) {
        setState(.refused(why), pick: id)
        picked.remove(id)
    }

    /// An Add that wrote nothing at all: the rows and cards it was adding go
    /// back as they were, ticks and picks kept, and the footnote names them.
    private func failAll(_ rowIDs: [ArtifactID], _ pickIDs: [String]) {
        let names =
            rows.filter { rowIDs.contains($0.id) && $0.state == .adding }.map(\.name)
            + picks.filter { pickIDs.contains($0.id) && $0.state == .adding }.map(\.entry.name)
        failure = names.isEmpty ? nil : LaunchpadCopy.Library.Failures.notAdded(names)
        restore(rowIDs, pickIDs)
    }

    /// Back to as they were, ticks kept, after an Add that wrote nothing.
    private func restore(_ rowIDs: [ArtifactID], _ pickIDs: [String]) {
        for id in rowIDs where rows.first(where: { $0.id == id })?.state == .adding { setState(.ready, row: id) }
        for id in pickIDs where picks.first(where: { $0.id == id })?.state == .adding { setState(.available, pick: id) }
    }

    private func setState(_ state: SkillRow.State, row id: ArtifactID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
    }

    private func setState(_ state: CatalogPick.State, pick id: String) {
        guard let index = picks.firstIndex(where: { $0.id == id }) else { return }
        picks[index].state = state
    }

    // MARK: Written here, or pasted

    /// Every name the library already uses, so the editor catches a
    /// collision on its first page.
    var existingNames: [String] {
        (flow.workspace?.library.state?.snapshot.document.artifacts ?? []).filter { $0.identity.kind == .skill }
            .flatMap { [$0.identity.displayName] + ($0.declaredName.map { [$0] } ?? []) }
    }

    var canWrite: Bool { flow.workspace?.library.access == .writable }

    /// The editor's Create skill: the skill joins the library in its own
    /// revision, and this setup's additions, as written here.
    func write(_ draft: SkillDraft) async -> Bool {
        guard let workspace = flow.workspace, !isWriting else { return false }
        isWriting = true
        writeFailure = nil
        defer { isWriting = false }
        do {
            let identifier = try WorkspaceLibrary.normalizedIdentifier(draft.name)
            let name = SkillTemplate.displayName(for: identifier)
            let prepared = try WorkspaceSkillPreparation.personal(
                tree: try SkillTemplate.tree(identifier: identifier, draft: draft))
            guard let head = try await workspace.service.snapshot()?.document.revision.id else {
                throw WorkspaceRevisionStoreError.notInitialized
            }
            let command = StandaloneSkillIntakeCommand(expectedRevisionID: head, displayName: name, prepared: prepared)
            _ = try await workspace.service.intakeStandaloneSkill(command, prepared: prepared)
            await workspace.library.refresh()
            saved(.init(artifactID: command.artifactID, name: name, source: .written))
            return true
        } catch {
            writeFailure = Self.saveFailure(for: error)
            return false
        }
    }

    /// Why the editor's skill was not saved, in the editor's own banner.
    static func saveFailure(for error: any Error) -> String {
        let failures = LaunchpadCopy.Library.Failures.self
        switch error {
        case WorkspaceSkillCommandError.identityCollision: return failures.nameTaken
        case WorkspaceSkillCommandError.contentStoreUnavailable: return failures.contentUnreachable
        case WorkspaceSkillCommandError.reviewMismatch, WorkspaceRevisionStoreError.staleRevision: return failures.libraryMoved
        case WorkspaceIdentifierError.invalidIdentifier: return failures.notAnIdentifier
        case WorkspaceSkillPreparationError.invalidSkillDefinition: return failures.incompleteDefinition
        default: return failures.notSaved
        }
    }

    /// The paste sheet saved a skill or a connection: exactly that joins this
    /// setup's additions, as pasted.
    func pasteSaved(_ artifactID: ArtifactID, name: String) {
        saved(.init(artifactID: artifactID, name: name, source: .pasted))
    }

    private func saved(_ item: LaunchpadLibraryDecisions.Added) {
        add(item)
        savedLine = flow.decisions.lines.last { line in
            line == LaunchpadCopy.Review.addedWrittenHere(item.name) || line == LaunchpadCopy.Review.addedFromPastedCommand(item.name)
        }
    }

    // MARK: Reading the record

    /// Newest first, so the skills the person is working on lead; then by
    /// name.
    private static func recentFirst(_ lhs: SkillRow, _ rhs: SkillRow) -> Bool {
        let (left, right) = (lhs.changedAt ?? .distantPast, rhs.changedAt ?? .distantPast)
        guard left == right else { return left > right }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// The tool that keeps `name` in step in a managed app, when one does.
    private static func manager(of name: String, in observations: [TargetObservation], managed: Set<ClientKind>) -> String? {
        for client in ClientKind.allCases where managed.contains(client) {
            for observation in observations where observation.surface.client == client {
                if let metadata = observation.skillMetadata[name], metadata.providerPluginID == nil,
                    let manager = metadata.externalManager
                {
                    return manager.tool
                }
            }
        }
        return nil
    }

    /// The first skill inside a plugin, by the plugin's name, for the fine
    /// print.
    private static func pluginExample(in document: PortableWorkspaceDocument) -> PluginExample? {
        let byID = Dictionary(document.artifacts.map { ($0.identity.id, $0) }, uniquingKeysWith: { first, _ in first })
        return document.artifacts
            .filter { $0.identity.kind == .skill }
            .compactMap { skill -> PluginExample? in
                guard let parent = skill.identity.parentPackageID.flatMap({ byID[$0] }) else { return nil }
                return PluginExample(skill: skill.identity.displayName, plugin: parent.identity.displayName)
            }
            .min { ($0.plugin, $0.skill) < ($1.plugin, $1.skill) }
    }

    /// When skills.sh could not be reached and the shelf shows what this Mac
    /// kept from an earlier read.
    private static func offlineNote(_ marketplace: WorkspaceMarketplaceSession, now: Date) -> String? {
        guard marketplace.catalogFailures.contains(where: { $0.name.localizedCaseInsensitiveContains("skills.sh") }) else {
            return nil
        }
        guard let read = marketplace.sources.first(where: { $0.kind == .skillsShRegistry })?.lastRefreshedAt else {
            return LaunchpadCopy.Library.skillsShUnreachable
        }
        return LaunchpadCopy.Library.offline(readOn: SnapshotTime.compact(read, now: now))
    }

    /// Where a skills.sh pick's repository is unpacked while it is fetched,
    /// the same folder Discover fetches into.
    private static func skillCache(_ workspace: WorkspaceLaunch.Workspace) -> URL {
        workspace.store.rootURL.appending(path: "cache/marketplace-skills", directoryHint: .isDirectory)
    }
}
