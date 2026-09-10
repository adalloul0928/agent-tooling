import AgentToolingCore
import Foundation

/// One skill as the list draws it, whether it stands on its own or arrives
/// inside a plugin.
///
/// A skill inside a plugin is still a skill somebody looks for by name, so it
/// gets a row. What it does not get is a plugin's authority: `isAssignable`,
/// `assignmentExplanation` and `ownership` are the ones the read model gave the
/// row it actually belongs to, so nothing here can offer an action the
/// workspace forbids.
struct SkillEntry: Identifiable, Equatable {
    let id: ArtifactID
    let displayName: String
    /// The name the skill goes by on disk, which is also the identifier a scan
    /// reports. It is how a row is matched to what the last check found.
    let declaredName: String?
    let summary: String
    let ownership: WorkspaceLibraryOwnership
    let authority: ContentAuthority?
    let contentDigest: ContentDigest?
    /// The plugin this skill came in, if it came in one.
    let parentID: ArtifactID?
    let parentPluginLabel: String?
    /// The native `plugin@marketplace` identifier of the package that delivers
    /// it. Not a publisher claim: see `SkillOrganization`.
    let providerPluginID: String?
    let sourceLabel: String?
    let requestedAssignments: [WorkspaceLibraryRequestedAssignment]
    let isAssignable: Bool
    let assignmentExplanation: String?

    /// Whether the editable copy is in this library rather than somewhere else.
    /// A personal skill and an attached folder are both yours to change; a
    /// repository's, an app's, and a merely tracked one are not.
    var isMaintainedHere: Bool {
        switch ownership {
        case .centralPersonal, .attachedAuthoring: true
        case .centralUpstream, .nativeOwned, .trackedOnly: false
        }
    }

    /// Whether this workspace holds the bytes, and so can show and replace them.
    var hasCentralContent: Bool {
        switch ownership {
        case .centralPersonal, .centralUpstream: contentDigest != nil
        case .attachedAuthoring, .nativeOwned, .trackedOnly: false
        }
    }

    /// Standalone or inside a plugin, in the words the filter uses.
    var installation: String { parentID == nil ? "Standalone" : "Plugin" }

    /// Every client this skill was asked for, however many places asked.
    var requestedClients: Set<ClientKind> {
        Set(requestedAssignments.filter(\.desiredPresence).compactMap { $0.destination.surface.client })
    }
}

/// Derived once at the library boundary. Search, selection, and scrolling read
/// these values instead of repeatedly walking observations and decoding saved
/// classification JSON for each row.
///
/// Two claims are kept apart everywhere below. `requestedClients` is where
/// somebody asked for a skill; `observedClients` is where the last check of this
/// Mac actually found one. Neither is ever presented as the other.
struct SkillInventoryIndex: Equatable {
    let skills: [SkillEntry]
    let ownership: [String: String]
    let presentations: [ArtifactID: SkillPresentation]
    let classifications: [ArtifactID: SkillOrganization.Classification]
    /// Where the last check of this Mac found a skill with this name.
    let observedClients: [ArtifactID: Set<ClientKind>]
    /// Where the last check found it, in enough detail to say which file.
    let observedPaths: [ArtifactID: String]
    /// The folder an attached skill is authored in, on this Mac.
    let authoringPaths: [ArtifactID: String]
    let marketplaces: [SourceOption]
    let plugins: [SourceOption]
    let mineCount: Int
    let unknownCount: Int

    struct SourceOption: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// A workspace that has not been read yet indexes to nothing rather than to
    /// a guess, so a screen that opens before its first read shows an empty
    /// library instead of a wrong one.
    init(
        library: WorkspaceLibraryReadModel?,
        snapshot: WorkspaceApplicationSnapshot?,
        observations: [TargetObservation],
        ownershipJSON: String
    ) {
        let artifacts = Dictionary(
            (snapshot?.document.artifacts ?? []).map { ($0.identity.id, $0) }, uniquingKeysWith: { first, _ in first })
        let checkouts = Dictionary(
            (snapshot?.device.sourceLocations ?? []).map { ($0.sourceRootID, $0.checkoutPath) },
            uniquingKeysWith: { first, _ in first })
        var entries: [SkillEntry] = []
        for row in library?.rows ?? [] {
            switch row.kind {
            case .skill:
                entries.append(Self.entry(row: row, artifact: artifacts[row.artifactID]))
            case .nativePlugin, .package:
                // A plugin's own skills are things a person searches for by
                // name, so they are listed rather than hidden inside it.
                let provider = artifacts[row.artifactID]?.declaredName ?? row.nativeRoutes.first?.externalPluginID
                for child in row.includedChildren where child.kind == .skill {
                    entries.append(
                        Self.entry(
                            child: child, parent: row, provider: provider,
                            artifact: artifacts[child.artifactID]))
                }
            case .mcpServer, .preset, .logicalProject:
                continue
            }
        }
        entries.sort {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        skills = entries

        let saved = (try? JSONDecoder().decode([String: String].self, from: Data(ownershipJSON.utf8))) ?? [:]
        ownership = saved
        var presentations: [ArtifactID: SkillPresentation] = [:]
        var classifications: [ArtifactID: SkillOrganization.Classification] = [:]
        var marketplaceNames: [String: String] = [:]
        var pluginNames: [String: String] = [:]
        var mine = 0
        var unknown = 0
        for skill in entries {
            let origin = SkillPresentation(pluginID: skill.providerPluginID, pluginDisplayName: skill.parentPluginLabel)
            presentations[skill.id] = origin
            let key = SkillOrganization.ownershipKey(
                skillID: skill.id.rawValue.uuidString.lowercased(), pluginID: skill.providerPluginID)
            let classification = SkillOrganization.classify(
                maintainedHere: skill.isMaintainedHere, pluginID: skill.providerPluginID, override: saved[key])
            classifications[skill.id] = classification
            if classification.owner == "mine" { mine += 1 }
            if classification.owner == "unknown" { unknown += 1 }
            if let id = origin.marketplaceID { marketplaceNames[id] = SkillOrganization.SourceIdentity.title(id) }
            if let id = origin.pluginID, let name = origin.pluginName {
                pluginNames[id] = [name, origin.marketplaceName].compactMap { $0 }.joined(separator: " · ")
            }
        }
        self.presentations = presentations
        self.classifications = classifications
        mineCount = mine
        unknownCount = unknown
        marketplaces = marketplaceNames.map { SourceOption(id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        plugins = pluginNames.map { SourceOption(id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        // What the last check of this Mac found, joined to a row by the name the
        // skill declares. A row with no declared name is joined to nothing: a
        // guess by display name would put another skill's marks on it.
        var found: [ArtifactID: Set<ClientKind>] = [:]
        var paths: [ArtifactID: String] = [:]
        var byName: [String: [SkillEntry]] = [:]
        for skill in entries {
            guard let declared = skill.declaredName, !declared.isEmpty else { continue }
            byName[declared, default: []].append(skill)
        }
        for observation in observations.sorted(by: { $0.surface.rawValue < $1.surface.rawValue }) {
            guard let client = observation.surface.client else { continue }
            for (name, metadata) in observation.skillMetadata {
                for skill in byName[name] ?? [] {
                    found[skill.id, default: []].insert(client)
                    if paths[skill.id] == nil { paths[skill.id] = metadata.path }
                }
            }
        }
        observedClients = found
        observedPaths = paths

        var authoring: [ArtifactID: String] = [:]
        for skill in entries {
            guard case .attachedAuthoring(let sourceRootID)? = skill.authority,
                let path = checkouts[sourceRootID]
            else { continue }
            authoring[skill.id] = path
        }
        authoringPaths = authoring
    }

    func presentation(for skill: SkillEntry) -> SkillPresentation {
        presentations[skill.id] ?? SkillPresentation(pluginID: nil)
    }

    func classification(for skill: SkillEntry) -> SkillOrganization.Classification {
        classifications[skill.id]
            ?? SkillOrganization.classify(maintainedHere: skill.isMaintainedHere, pluginID: nil, override: nil)
    }

    func owner(of skill: SkillEntry) -> String { classification(for: skill).owner }

    func ownershipKey(for skill: SkillEntry) -> String {
        SkillOrganization.ownershipKey(
            skillID: skill.id.rawValue.uuidString.lowercased(), pluginID: skill.providerPluginID)
    }

    private static func entry(row: WorkspaceLibraryReadModelRow, artifact: ArtifactRecord?) -> SkillEntry {
        SkillEntry(
            id: row.artifactID, displayName: row.displayName, declaredName: artifact?.declaredName,
            summary: row.observedDescription ?? "", ownership: row.ownership, authority: artifact?.authority,
            contentDigest: artifact?.contentDigest, parentID: nil, parentPluginLabel: nil,
            providerPluginID: nil, sourceLabel: row.sourceLabel,
            requestedAssignments: row.requestedAssignments, isAssignable: row.isAssignable,
            assignmentExplanation: row.assignmentExplanation)
    }

    private static func entry(
        child: WorkspaceLibraryIncludedItem, parent: WorkspaceLibraryReadModelRow,
        provider: String?, artifact: ArtifactRecord?
    ) -> SkillEntry {
        SkillEntry(
            id: child.artifactID, displayName: child.displayName, declaredName: artifact?.declaredName,
            summary: child.observedDescription ?? "", ownership: child.ownership, authority: artifact?.authority,
            contentDigest: artifact?.contentDigest, parentID: parent.artifactID,
            parentPluginLabel: child.parentPluginLabel ?? parent.displayName, providerPluginID: provider,
            sourceLabel: parent.sourceLabel,
            requestedAssignments: child.requestedAssignments,
            // A member is assigned the way its package is: the package is what
            // a client installs, so nothing here may offer more than it can.
            isAssignable: parent.isAssignable, assignmentExplanation: parent.assignmentExplanation)
    }
}
