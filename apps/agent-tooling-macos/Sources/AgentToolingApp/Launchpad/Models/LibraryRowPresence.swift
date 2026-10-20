import AgentToolingCore
import Foundation

/// Observed presence and copy comparisons for a library row. Assignments do not
/// prove presence. Marks include only managed apps. Equal `definitionDigest`s
/// identify matching skills; an unhashed copy remains unverified.
struct LibraryRowPresence: Equatable, Identifiable, Sendable {
    /// The clause beside a row's name.
    enum Detail: Equatable, Sendable {
        /// A skill held as more than one copy: the copies chip.
        case copies(SkillCopySummary)
        /// Held by one app only.
        case onlyIn(ClientKind)
        /// What a plugin bundles: "Includes 1 skill · 1 connection".
        case includes(String)
        /// A connection configured in more than one app.
        case configuredIn(Int)
    }

    let id: ArtifactID
    let name: String
    let kind: ArtifactKind
    /// The name the apps know it by: a skill's folder name, a plugin's
    /// `plugin@marketplace`, a connection's server name.
    let declaredName: String?
    /// Whose it is, in the Library's words: "Unmanaged", "Managed by its
    /// app".
    let ownership: String
    let detail: Detail?
    /// The managed apps that hold it, in the app order.
    let apps: [ClientKind]
    /// A skill's copies on this Mac, for its popover; empty for anything
    /// else.
    let copies: [ObservedSkillCopy]

    /// The detail as a row says it.
    var detailText: String? {
        switch detail {
        case .copies(let summary): summary.compactLabel
        case .onlyIn(let client): LaunchpadCopy.Found.onlyIn(client.rawValue)
        case .includes(let words): words
        case .configuredIn(let count): LaunchpadCopy.Found.configuredIn(count)
        case nil: nil
        }
    }

    /// Whether the detail is the copies chip, and the copies differ.
    var copiesDiffer: Bool {
        if case .copies(let summary) = detail { summary.versions > 1 } else { false }
    }

    /// The row to VoiceOver: "Frontend Design, skill, 2 copies · 2 versions,
    /// Unmanaged, in Codex, Claude Code and Gemini CLI".
    var accessibilityLabel: String {
        LaunchpadCopy.Found.rowLabel(
            name, kind: LaunchpadCopy.Found.kindName(kind), detail: detailText, ownership: ownership,
            apps: apps.isEmpty ? nil : LaunchpadCopy.list(apps.map(\.rawValue)))
    }

    // MARK: Building the list

    /// Every entry of the library `state` holds, as the read found it in the
    /// `managed` apps: skills first, then plugins, then connections; within
    /// each, the entry most apps hold first, then by name.
    ///
    /// Agent Tooling's own connection is not one of them (D10): it is bound
    /// to each Mac, not a tool the library carries.
    static func rows(
        in state: WorkspaceLibraryState, observations: [TargetObservation], managed: [ClientKind]
    ) -> [LibraryRowPresence] {
        let order = ClientKind.allCases.filter(managed.contains)
        let byClient = Dictionary(grouping: observations) { $0.surface.client }
        func observed(_ client: ClientKind) -> [TargetObservation] { byClient[client] ?? [] }
        let own = ownConnections(in: state.snapshot.document)

        let rows = state.library.rows.filter { !own.contains($0.artifactID) }.map { row -> LibraryRowPresence in
            let declared = row.declaredName ?? ""
            let apps: [ClientKind]
            var copies: [ObservedSkillCopy] = []
            let detail: Detail?
            switch row.kind {
            case .skill:
                apps = order.filter { client in
                    observed(client).contains { $0.skillMetadata[declared] != nil || $0.discoveredSkills.contains(declared) }
                }
                copies = ObservedSkillCopies.group(observations: observations, managed: Set(order), declaredName: declared)
                if let summary = SkillCopySummary(copies: copies.count, versions: versions(among: copies)) {
                    detail = .copies(summary)
                } else {
                    detail = apps.count == 1 ? .onlyIn(apps[0]) : nil
                }
            case .nativePlugin, .package:
                let routed = Set(row.nativeRoutes.map(\.client))
                apps = order.filter { client in
                    routed.contains(client) || observed(client).contains { $0.discoveredPlugins.contains(declared) }
                }
                detail = row.includedSummary.map(Detail.includes)
            case .mcpServer:
                apps = order.filter { client in
                    observed(client).contains { $0.discoveredMCPServers.contains(declared) || $0.mcpMetadata[declared] != nil }
                }
                detail = apps.count > 1 ? .configuredIn(apps.count) : apps.first.map(Detail.onlyIn)
            case .preset, .logicalProject:
                apps = []
                detail = nil
            }
            return LibraryRowPresence(
                id: row.artifactID, name: row.displayName, kind: row.kind, declaredName: row.declaredName,
                ownership: row.ownershipLabel, detail: detail, apps: apps, copies: copies)
        }
        return rows.sorted { lhs, rhs in
            if rank(lhs.kind) != rank(rhs.kind) { return rank(lhs.kind) < rank(rhs.kind) }
            if lhs.apps.count != rhs.apps.count { return lhs.apps.count > rhs.apps.count }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// Agent Tooling's own connection, as the library records it: a server
    /// of the person's own, bound to each Mac.
    static func ownConnections(in document: PortableWorkspaceDocument) -> Set<ArtifactID> {
        let definitions = document.mcpDefinitions ?? []
        return Set(
            document.artifacts.filter { AgentToolingConnection.isOwnConnection($0, definitions: definitions) }.map(\.identity.id))
    }

    /// The list in two columns of equal length, filled down the first, as
    /// the card draws it.
    static func columns(_ rows: [LibraryRowPresence]) -> (leading: [LibraryRowPresence], trailing: [LibraryRowPresence]) {
        let half = (rows.count + 1) / 2
        return (Array(rows.prefix(half)), Array(rows.dropFirst(half)))
    }

    /// How many different contents the copies hold. A copy that could not be
    /// compared is counted as its own, so it is never said to be the same.
    private static func versions(among copies: [ObservedSkillCopy]) -> Int {
        guard ObservedSkillCopies.differ(copies) else { return 1 }
        return copies.allSatisfy({ $0.definitionDigest != nil })
            ? Set(copies.compactMap(\.definitionDigest)).count : copies.count
    }

    private static func rank(_ kind: ArtifactKind) -> Int {
        switch kind {
        case .skill: 0
        case .nativePlugin, .package: 1
        case .mcpServer: 2
        case .preset, .logicalProject: 3
        }
    }

    // MARK: What the read says about each app

    /// What one app's read found, in the Library's nouns and order: "2
    /// skills · 1 plugin · 1 connection". Agent Tooling's own connection is
    /// not one of the app's holdings (D10).
    static func holdings(of observation: TargetObservation) -> LibraryCounts {
        LibraryCounts(
            skills: Set(observation.discoveredSkills).count, plugins: Set(observation.discoveredPlugins).count,
            connections: Set(observation.discoveredMCPServers).subtracting([AgentToolingConnection.declaredName]).count)
    }

    /// The stage audit's count, as Home and Checkup count things to look at:
    /// the open findings and recommendations. A difference from another
    /// Mac's accounts is left out on the stage (D34). Nil before an audit.
    static func thingsToLookAt(_ checkup: SetupCheckup?) -> Int? {
        guard let checkup else { return nil }
        let findings = checkup.openFindings.filter { $0.kind != .accountDiffersFromOtherMacs }
        return findings.count + checkup.openRecommendations.count
    }

    /// What the read saw that the library did not record, each with why
    /// (`WorkspaceObservationReconciliation`'s own reasons), led by the name
    /// a person knows it by rather than the identifier the apps report.
    /// Empty when everything was recorded. It reads the skills' definitions
    /// again, as the commit did, off the main actor.
    static func notRecorded(
        document: PortableWorkspaceDocument, observations: [TargetObservation], homeURL: URL
    ) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let inventory = InventoryCompiler.compile(observations: observations, homeURL: homeURL)
            let skipped = WorkspaceObservationReconciliation.plan(
                document: document, observations: observations, inventory: inventory
            ).skipped
            let names =
                inventory.skills.map { ($0.id, $0.displayName) } + inventory.plugins.map { ($0.id, $0.name) }
                + inventory.mcpServers.map { ($0.id, $0.name) }
            return skipped.map { named($0, names: names) }
        }.value
    }

    /// A reason as the reconciliation words it, "<identifier>: why", with
    /// the identifier given its name. The longest identifier that leads the
    /// reason wins, since one may hold another: `sentry:loose-notes`.
    private nonisolated static func named(_ reason: String, names: [(id: String, name: String)]) -> String {
        let leading = names.filter { !$0.name.isEmpty && reason.hasPrefix($0.id + ": ") }
        guard let match = leading.max(by: { $0.id.count < $1.id.count }) else { return reason }
        return match.name + reason.dropFirst(match.id.count)
    }

    /// `copies` with each folder's file count, for the popover. A folder
    /// that cannot be listed keeps no count.
    static func measured(_ copies: [ObservedSkillCopy]) async -> [ObservedSkillCopy] {
        await Task.detached(priority: .userInitiated) {
            copies.map { copy in
                var measured = copy
                measured.fileCount = fileCount(at: URL(filePath: copy.path, directoryHint: .isDirectory))
                return measured
            }
        }.value
    }

    /// The most files a copy is counted to: a skill's folder holds a few.
    static let countedFilesLimit = 1_024

    private nonisolated static func fileCount(at folder: URL) -> Int? {
        guard
            let walk = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return nil }
        var count = 0
        for case let file as URL in walk {
            guard count < countedFilesLimit else { break }
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
        }
        return count
    }
}
