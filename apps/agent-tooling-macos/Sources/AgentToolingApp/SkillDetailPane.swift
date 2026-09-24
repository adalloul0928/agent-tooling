import AgentToolingCore
import AppKit
import SwiftUI

struct SkillDetailView: View {
    @Environment(AppNavigationState.self) private var navigation: AppNavigationState?
    let skill: SkillEntry
    let workspace: WorkspaceLaunch.Workspace
    let content: SkillContentSession
    let inventory: SkillInventoryIndex
    let availableClients: [ClientKind]
    let onEditSource: () -> Void
    let onAssign: () -> Void
    let onExport: () -> Void
    let onOpenPlugin: (ArtifactID) -> Void

    private var upstream: SkillUpstreamBinding.Resolved? {
        SkillUpstreamBinding.resolve(skill, in: workspace.library.state?.snapshot.document)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heading
                actions
                if let explanation = skill.assignmentExplanation {
                    Text(explanation)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SkillRepositorySection(
                    skill: skill, binding: upstream?.binding, approvedRevision: upstream?.approvedRevision,
                    authoringPath: inventory.authoringPaths[skill.id], session: content, workspace: workspace)
                apps
                sourceFiles
            }
            .padding(22)
        }
    }

    private var heading: some View {
        HStack(spacing: 13) {
            KindTile(kind: .skill, size: 40, ghost: !skill.isMaintainedHere)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.displayName).font(.system(size: 20, weight: .semibold))
                HStack(spacing: 6) {
                    Text(skill.ownership.libraryLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    SkillInfoButton(
                        text: skill.isMaintainedHere
                            ? "The source is yours. Save an edit here, then review where the change should be used."
                            : "This skill is maintained where it came from. This library records that it exists and where it is used.",
                        label: "About maintenance")
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if skill.ownership == .centralPersonal, skill.hasCentralContent {
                Button("Edit Source…", systemImage: "doc.text", action: onEditSource)
                    .buttonStyle(.bordered)
                    .disabled(content.isBusy || !content.canWrite)
                    .accessibilityHint("Edits the complete SKILL.md while preserving scripts, references, and assets")
            }
            if skill.isAssignable {
                Button("Choose where to use it…", systemImage: "arrow.turn.up.right", action: onAssign)
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .disabled(workspace.library.isBusy || workspace.library.access != .writable)
                    .accessibilityHint("Saves where this skill should be used. Installing is reviewed on the Apps screen")
            }
            if skill.hasCentralContent {
                Button("Export…", systemImage: "square.and.arrow.up", action: onExport)
                    .buttonStyle(.bordered)
            }
            if skill.ownership == .attachedAuthoring {
                Button("Stop managing this folder", systemImage: "folder.badge.minus") {
                    Task { await workspace.authoring.detach(skill.id, named: skill.displayName) }
                }
                .buttonStyle(.bordered)
                .disabled(workspace.authoring.isBusy || !workspace.authoring.canWrite)
                .help("Removes the registration. Nothing in the folder is changed.")
            }
            if let parent = skill.parentID {
                Button("Show plugin", systemImage: "puzzlepiece.extension") { onOpenPlugin(parent) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var apps: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(availableClients.enumerated()), id: \.element) { index, client in
                    HStack(spacing: 10) {
                        ClientBrandIcon(client: client, size: 18).frame(width: 24)
                        Text(client.rawValue).font(.callout.weight(.medium))
                        Spacer()
                        // A verdict only where there is one. "This app does not
                        // have it" is the ordinary case for most skills, so it
                        // gets a word rather than a mark that reads as a fault.
                        if let state = state(for: client) {
                            StatusBadge(state: state, text: detail(for: client))
                        } else {
                            Text(detail(for: client)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 9)
                    if index < availableClients.count - 1 { Divider() }
                }
                if navigation != nil, availableClients.contains(where: isAskedForButAbsent) {
                    Divider()
                    HStack(spacing: 10) {
                        Text("Asked for, but not installed yet.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Install…", systemImage: "arrow.down.circle") {
                            navigation?.openScreenRequest(.reviewChanges)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Install this skill from the Apps screen")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 9)
                }
                if availableClients.isEmpty {
                    Text("This Mac is not managing any apps.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            .padding(6)
        } label: {
            HStack(spacing: 6) {
                Text("Apps")
                SkillInfoButton(
                    text:
                        "Found means the last check of this Mac saw this skill in that app. Asked for means somebody saved that choice here; installing it is a separate, reviewed step on the Apps screen.",
                    label: "About app availability")
            }
        }
    }

    /// Found beats asked for: what is actually there is the stronger claim, and
    /// the two are never blended into one word. Nil is neither — an app that
    /// simply does not have this skill is not a problem to be flagged.
    private func state(for client: ClientKind) -> HealthState? {
        if inventory.observedClients[skill.id]?.contains(client) == true { return .healthy }
        return skill.requestedClients.contains(client) ? .pending : nil
    }

    private func isAskedForButAbsent(_ client: ClientKind) -> Bool {
        inventory.observedClients[skill.id]?.contains(client) != true && skill.requestedClients.contains(client)
    }

    private func detail(for client: ClientKind) -> String {
        let found = inventory.observedClients[skill.id]?.contains(client) == true
        let asked = skill.requestedClients.contains(client)
        switch (found, asked) {
        case (true, true): return "Found · asked for"
        case (true, false): return "Found here"
        case (false, true): return "Asked for, not found"
        case (false, false): return workspace.device.observations.isEmpty ? "Not checked yet" : "Not here"
        }
    }

    @ViewBuilder private var sourceFiles: some View {
        if content.isLoading {
            ProgressView("Reading the stored files…").controlSize(.small)
        } else if skill.hasCentralContent, content.loadedID != skill.id, let message = content.errorMessage {
            Text(message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if content.loadedID == skill.id, !content.files.isEmpty {
            DisclosureGroup("Source files") {
                VStack(spacing: 0) {
                    ForEach(content.files, id: \.self) { file in
                        LabeledValueRow(file == "SKILL.md" ? "Definition" : "Bundled file") {
                            Text(file).font(.system(.caption, design: .monospaced))
                        }
                        if file != content.files.last { Divider() }
                    }
                }
            }
        } else if let path = inventory.authoringPaths[skill.id] ?? inventory.observedPaths[skill.id] {
            LabeledValueRow(skill.ownership == .attachedAuthoring ? "Your folder" : "Found at") {
                LocationText(path: path)
            }
            .standardPanel(cornerRadius: 13)
        }
    }
}

struct SkillInfoButton: View {
    let text: String
    let label: String
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(text)
        .popover(isPresented: $presented) {
            Text(text).font(.callout).padding(14).frame(width: 290, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
