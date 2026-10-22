import AgentToolingCore
import Foundation
import Observation

/// One row of Home's Finish setting up card: something setup left for later,
/// or did and names.
enum FinishSetupItem: String, Codable, CaseIterable, Sendable {
    case makeSkillsYours
    case putToolsInApps
    case connectAgentTooling
    case connectOtherMacs
    case signInConnections
    case lookAtCheckup
    case trySkill
    case trackProjects
}

/// Where a row of the card was done, so its caption can name the place.
enum FinishSetupPlace: String, Codable, CaseIterable, Sendable {
    case setup
    case home
    case library
    case discover
    case apps
    case checkup
    case projects
    case settings
    case insights
    case activity
}

/// Device-local progress in `<container>/setup-progress.json`, avoiding portable
/// revisions and History entries for cursor moves. Missing records are legacy.
/// Unknown items and steps are skipped; unknown states defer, unknown paths rerun.
/// Newer formats appear finished so old builds neither resume nor replace them.
struct SetupProgressRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// A first run past its commit point that has not handed off yet. The
        /// only state that takes over a launch.
        case inProgress
        /// Left for later from FooterConfirm's Go to Home: Home offers Resume.
        case deferred
        /// Done reached, on any path.
        case finished
    }

    /// A row of the card that was done, and where.
    struct Tick: Codable, Equatable, Sendable {
        var item: FinishSetupItem
        var place: FinishSetupPlace
        var at: Date
        /// What the caption says about it: "Installed 4 changes · 9:52 AM".
        var summary: String?
    }

    /// A skill tried in an app from setup's checklist.
    struct Trial: Codable, Equatable, Sendable {
        var skillName: String
        var skillID: String
        var client: ClientKind
    }

    /// A connection that may need its app's sign-in.
    struct SignInHint: Codable, Equatable, Sendable {
        var connection: String
        var serverID: String
        var client: ClientKind
    }

    /// What setup saw that the card's rows need later, kept because the
    /// library alone cannot say it.
    struct Evidence: Codable, Equatable, Sendable {
        /// The skills that were already yours before this setup, so a join's
        /// arrivals never tick "Make your skills yours".
        var personalSkillsBefore: [ArtifactID] = []
        /// The placements this setup made, so they never read as arrivals from
        /// another Mac.
        var placedContributionIDs: [WorkspaceObjectID] = []
        /// The Checkup findings left at hand-off.
        var checkupFindingIDs: [String] = []
        var trial: Trial?
        /// How many folders Claude Code's history names, read with consent.
        var projectFolderCount: Int?
        var mayNeedSignIn: [SignInHint] = []

        init(
            personalSkillsBefore: [ArtifactID] = [], placedContributionIDs: [WorkspaceObjectID] = [],
            checkupFindingIDs: [String] = [], trial: Trial? = nil, projectFolderCount: Int? = nil,
            mayNeedSignIn: [SignInHint] = []
        ) {
            self.personalSkillsBefore = personalSkillsBefore
            self.placedContributionIDs = placedContributionIDs
            self.checkupFindingIDs = checkupFindingIDs
            self.trial = trial
            self.projectFolderCount = projectFolderCount
            self.mayNeedSignIn = mayNeedSignIn
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            personalSkillsBefore = container.lenient([ArtifactID].self, .personalSkillsBefore) ?? []
            placedContributionIDs = container.lenient([WorkspaceObjectID].self, .placedContributionIDs) ?? []
            checkupFindingIDs = container.lenient([String].self, .checkupFindingIDs) ?? []
            trial = container.lenient(Trial.self, .trial)
            projectFolderCount = container.lenient(Int.self, .projectFolderCount)
            mayNeedSignIn = (container.lenient([Lenient<SignInHint>].self, .mayNeedSignIn) ?? []).compactMap(\.value)
        }
    }

    static let fileName = "setup-progress.json"
    static let currentFormatVersion = 1

    var formatVersion: Int
    var state: State
    var path: LaunchpadPath
    /// The step a resume opens at.
    var cursor: LaunchpadStep?
    /// Every step this setup has shown, so "has the person seen How Agent
    /// Tooling behaves" can be answered.
    var seen: Set<LaunchpadStep>
    var startedAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    /// The card's rows, in its order.
    var items: [FinishSetupItem]
    /// The rows done, each once: a tick latches.
    var ticks: [Tick]
    /// When the card was hidden, or nil while it shows.
    var hiddenAt: Date?
    var evidence: Evidence

    init(
        formatVersion: Int = SetupProgressRecord.currentFormatVersion, state: State, path: LaunchpadPath,
        cursor: LaunchpadStep?, seen: Set<LaunchpadStep> = [], startedAt: Date, updatedAt: Date,
        finishedAt: Date? = nil, items: [FinishSetupItem] = [], ticks: [Tick] = [], hiddenAt: Date? = nil,
        evidence: Evidence = Evidence()
    ) {
        self.formatVersion = formatVersion
        self.state = state
        self.path = path
        self.cursor = cursor
        self.seen = seen
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.items = items
        self.ticks = ticks
        self.hiddenAt = hiddenAt
        self.evidence = evidence
    }

    /// The record a first run writes at its commit point, before the library's
    /// own locator record: in progress at `cursor`, every step up to it seen.
    static func started(
        path: LaunchpadPath, cursor: LaunchpadStep, evidence: Evidence = Evidence(), now: Date = .now
    ) -> SetupProgressRecord {
        let order = LaunchpadStep.sequence(for: path)
        let seen = order.firstIndex(of: cursor).map { Set(order[...$0]) } ?? [cursor]
        return SetupProgressRecord(
            state: .inProgress, path: path, cursor: cursor, seen: seen, startedAt: now, updatedAt: now,
            evidence: evidence)
    }

    /// Whether this setup has shown How Agent Tooling behaves, where the
    /// person chose when to look for updates.
    var hasSeenPreferences: Bool { seen.contains(.behave) }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case formatVersion, state, path, cursor, seen, startedAt, updatedAt, finishedAt, items, ticks, hiddenAt, evidence
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = container.lenient(Int.self, .formatVersion) ?? Self.currentFormatVersion
        formatVersion = version
        let decodedState = container.lenient(String.self, .state).flatMap(State.init(rawValue:)) ?? .deferred
        // A newer build's record is shown as finished: no resume and no card,
        // rather than a guess at what its newer fields meant.
        state = version > Self.currentFormatVersion ? .finished : decodedState
        path = container.lenient(String.self, .path).flatMap(LaunchpadPath.init(rawValue:)) ?? .rerun
        cursor = container.lenient(String.self, .cursor).flatMap(LaunchpadStep.init(rawValue:))
        seen = Set((container.lenient([String].self, .seen) ?? []).compactMap(LaunchpadStep.init(rawValue:)))
        guard let started = container.lenient(Date.self, .startedAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startedAt, in: container, debugDescription: "A setup record names when it started.")
        }
        startedAt = started
        updatedAt = container.lenient(Date.self, .updatedAt) ?? started
        finishedAt = container.lenient(Date.self, .finishedAt)
        items = (container.lenient([String].self, .items) ?? []).compactMap(FinishSetupItem.init(rawValue:))
        ticks = (container.lenient([Lenient<Tick>].self, .ticks) ?? []).compactMap(\.value)
        hiddenAt = container.lenient(Date.self, .hiddenAt)
        evidence = container.lenient(Evidence.self, .evidence) ?? Evidence()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(state, forKey: .state)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        // In the steps' own order, so the same record always writes the same
        // bytes.
        try container.encode(LaunchpadStep.allCases.filter(seen.contains), forKey: .seen)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try container.encode(items, forKey: .items)
        try container.encode(ticks, forKey: .ticks)
        try container.encodeIfPresent(hiddenAt, forKey: .hiddenAt)
        try container.encode(evidence, forKey: .evidence)
    }
}

/// A value decoded where it can be and skipped where it cannot: a tick or a
/// hint naming a place or an app this build does not know.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// The value under `key`, or nil when it is absent or does not decode.
    fileprivate func lenient<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: - The file

/// Where a workspace's setup record is kept, and beside it the placements
/// this Mac's setup made.
protocol SetupProgressStoring: Sendable {
    /// The record, or nil when there is none or it cannot be read at all.
    func load() -> SetupProgressRecord?
    func save(_ record: SetupProgressRecord) throws
    /// The placements this Mac's setup made, by contribution, whichever walk
    /// made them; empty when none were kept or they cannot be read.
    func loadPlacementsMadeHere() -> [WorkspaceObjectID]
    func savePlacementsMadeHere(_ contributionIDs: [WorkspaceObjectID]) throws
}

extension SetupProgressStoring {
    /// A store that keeps no such list: the session holds it for the launch.
    func loadPlacementsMadeHere() -> [WorkspaceObjectID] { [] }
    func savePlacementsMadeHere(_ contributionIDs: [WorkspaceObjectID]) throws {}
}

/// Local setup assignments in `<container>/setup-placements.json`. This includes
/// rerun placements before Done, allowing incoming-sync review to exclude local
/// intent. Invalid IDs are skipped. Newer formats can be read but never overwritten.
struct SetupPlacementsMadeHere: Codable, Equatable, Sendable {
    static let fileName = "setup-placements.json"
    static let currentFormatVersion = 1

    var contributionIDs: [WorkspaceObjectID]
    var formatVersion = Self.currentFormatVersion

    init(contributionIDs: [WorkspaceObjectID]) {
        self.contributionIDs = contributionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case contributionIDs, formatVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = container.lenient(Int.self, .formatVersion) ?? Self.currentFormatVersion
        contributionIDs = (container.lenient([Lenient<WorkspaceObjectID>].self, .contributionIDs) ?? []).compactMap(\.value)
    }

    /// Whether a newer build wrote it.
    var isNewer: Bool { formatVersion > Self.currentFormatVersion }
}

/// The record as a file beside the store: ISO 8601 dates, sorted keys, written
/// whole by a rename and readable by this Mac's user only.
struct LiveSetupProgressStore: SetupProgressStoring {
    let fileURL: URL
    /// The placements this Mac's setup made, beside the record.
    let placementsURL: URL

    /// The most a record is read: far more than any record writes, so a file
    /// that is not one is never read into memory whole.
    static let byteLimit = 262_144

    init(container: URL) {
        fileURL = container.appending(path: SetupProgressRecord.fileName)
        placementsURL = container.appending(path: SetupPlacementsMadeHere.fileName)
    }

    func load() -> SetupProgressRecord? {
        guard let data = Self.contents(of: fileURL) else { return nil }
        return try? Self.decoder().decode(SetupProgressRecord.self, from: data)
    }

    func save(_ record: SetupProgressRecord) throws {
        try Self.write(try Self.encoder().encode(record), to: fileURL)
    }

    func loadPlacementsMadeHere() -> [WorkspaceObjectID] {
        placementsFile()?.contributionIDs ?? []
    }

    /// Writes the list, unless a newer build's list is there: that one is
    /// only read.
    func savePlacementsMadeHere(_ contributionIDs: [WorkspaceObjectID]) throws {
        guard placementsFile()?.isNewer != true else { return }
        try Self.write(
            try Self.encoder().encode(SetupPlacementsMadeHere(contributionIDs: contributionIDs)), to: placementsURL)
    }

    /// The list on disk, or nil when it is missing or cannot be read, which
    /// reads as an empty list.
    private func placementsFile() -> SetupPlacementsMadeHere? {
        guard let data = Self.contents(of: placementsURL) else { return nil }
        return try? Self.decoder().decode(SetupPlacementsMadeHere.self, from: data)
    }

    /// A file's bytes, unless it is missing or larger than any this store
    /// writes.
    private static func contents(of url: URL) -> Data? {
        let path = url.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int, size <= byteLimit
        else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// Writes `data` beside `url` and makes it private before it takes the
    /// file's place, so the file is never seen half written or readable by
    /// anyone else.
    private static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let staged = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: staged, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path(percentEncoded: false))
        guard rename(staged.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - What the shell reads

/// Where this Mac's setup stands, as the shell's launch work and Home read it.
enum SetupStatus: Equatable, Sendable {
    /// No record: a workspace made before Launchpad.
    case legacy
    /// A first run not yet handed off, at its cursor.
    case inProgress(LaunchpadStep)
    /// Left for later at its cursor. `seenPreferences` says whether the
    /// person reached How Agent Tooling behaves.
    case deferred(LaunchpadStep, path: LaunchpadPath, seenPreferences: Bool)
    case finished(path: LaunchpadPath, seenPreferences: Bool)

    init(_ record: SetupProgressRecord?) {
        guard let record else {
            self = .legacy
            return
        }
        let cursor = record.cursor ?? .found
        switch record.state {
        case .inProgress: self = .inProgress(cursor)
        case .deferred: self = .deferred(cursor, path: record.path, seenPreferences: record.hasSeenPreferences)
        case .finished: self = .finished(path: record.path, seenPreferences: record.hasSeenPreferences)
        }
    }
}

/// The record as one workspace's session: what the stage writes as a setup
/// moves, and what Home's card ticks.
///
/// Every change is saved before it is shown as kept. A save that fails puts
/// the record back as it was and says so with the stage's one sentence for a
/// choice that did not save. A record a newer build wrote is only read: no
/// change is made to it, here or on disk.
@MainActor @Observable
final class WorkspaceSetupProgressSession {
    private(set) var record: SetupProgressRecord?
    private(set) var errorMessage: String?
    /// The placements this Mac's setup made on any walk, as each Put in apps
    /// saved them (`SetupPlacementsMadeHere`).
    private(set) var placementsMadeHere: Set<WorkspaceObjectID>
    @ObservationIgnored private let store: any SetupProgressStoring

    init(store: any SetupProgressStoring) {
        self.store = store
        record = store.load()
        placementsMadeHere = Set(store.loadPlacementsMadeHere())
    }

    /// Every placement this Mac's setup made that it knows of: the record's,
    /// and the ones each walk kept as it went. None of them is an arrival
    /// from another Mac.
    var ownPlacements: Set<WorkspaceObjectID> {
        placementsMadeHere.union(record?.evidence.placedContributionIDs ?? [])
    }

    /// Adds the placements a walk just saved, on any path, keeping only the
    /// ones the library still holds (`inLibrary`, when known), so a placement
    /// a later walk took back leaves the list. The save vouches for the ones
    /// it returned, which stay even when `inLibrary` was read before it: a
    /// save whose library could not refresh afterwards still made them. A
    /// save that fails keeps them for this launch; only a later launch would
    /// miss them. Beside a newer build's record, nothing is written: its
    /// files are only read.
    func recordPlacementsMadeHere(_ contributionIDs: [WorkspaceObjectID], inLibrary: Set<WorkspaceObjectID>?) {
        var next = placementsMadeHere.union(contributionIDs)
        if let inLibrary { next.formIntersection(inLibrary.union(contributionIDs)) }
        guard next != placementsMadeHere else { return }
        placementsMadeHere = next
        guard !isReadOnly else { return }
        try? store.savePlacementsMadeHere(next.sorted())
    }

    var status: SetupStatus { SetupStatus(record) }

    /// Moves the cursor to `step` and marks it seen. Only a first run in
    /// progress, or one left for later and resumed, has a cursor to move: a
    /// rerun or a revisit writes nothing until Done.
    func move(to step: LaunchpadStep, now: Date = .now) {
        guard var next = record, next.state != .finished else { return }
        next.cursor = step
        next.seen.insert(step)
        next.updatedAt = now
        save(next)
    }

    /// Leaves a first run for later at `step`: Home shows Resume. A record
    /// that is already finished is left alone.
    func deferSetup(at step: LaunchpadStep, now: Date = .now) {
        guard var next = record, next.state != .finished else { return }
        next.state = .deferred
        next.cursor = step
        next.seen.insert(step)
        next.updatedAt = now
        save(next)
    }

    /// Done. A Mac with no record (a rerun on a workspace made before
    /// Launchpad) gets a finished `rerun` record. One that has a record keeps
    /// its path and when it started, and gets this setup's rows: ticks already
    /// made stay made, the card shows again, and `evidence`, when given,
    /// replaces what was kept.
    func finish(
        items: [FinishSetupItem], ticks: [SetupProgressRecord.Tick] = [], evidence: SetupProgressRecord.Evidence? = nil,
        seen: Set<LaunchpadStep> = [], now: Date = .now
    ) {
        var next =
            record
            ?? SetupProgressRecord(state: .finished, path: .rerun, cursor: nil, startedAt: now, updatedAt: now)
        next.state = .finished
        next.cursor = .done
        next.seen.formUnion(seen)
        next.seen.insert(.done)
        next.finishedAt = now
        next.updatedAt = now
        next.items = items
        let latched = Set(next.ticks.map(\.item))
        next.ticks += ticks.filter { !latched.contains($0.item) }
        next.hiddenAt = nil
        if let evidence { next.evidence = evidence }
        save(next)
    }

    /// Hides Home's card, or shows it again.
    func setChecklistHidden(_ hidden: Bool, now: Date = .now) {
        guard var next = record else { return }
        next.hiddenAt = hidden ? now : nil
        next.updatedAt = now
        save(next)
    }

    /// Ticks one row of the card. A row ticks once: a later tick of the same
    /// row keeps the first, so the caption keeps naming where it was done.
    func tick(_ item: FinishSetupItem, place: FinishSetupPlace, summary: String? = nil, now: Date = .now) {
        guard var next = record, !next.ticks.contains(where: { $0.item == item }) else { return }
        next.ticks.append(.init(item: item, place: place, at: now, summary: summary))
        next.updatedAt = now
        save(next)
    }

    /// Changes what is kept about this setup for the card's rows.
    func recordEvidence(_ change: (inout SetupProgressRecord.Evidence) -> Void) {
        guard var next = record else { return }
        change(&next.evidence)
        guard next != record else { return }
        save(next)
    }

    /// Whether the record on disk is a newer build's. This build reads it as
    /// finished and never writes it: writing would drop every field it does
    /// not know and force the newer build's state.
    private var isReadOnly: Bool {
        guard let record else { return false }
        return record.formatVersion > SetupProgressRecord.currentFormatVersion
    }

    private func save(_ next: SetupProgressRecord) {
        guard !isReadOnly else { return }
        let previous = record
        record = next
        do {
            try store.save(next)
            errorMessage = nil
        } catch {
            record = previous
            errorMessage = LaunchpadCopy.Footer.Failures.notRecorded
        }
    }
}
