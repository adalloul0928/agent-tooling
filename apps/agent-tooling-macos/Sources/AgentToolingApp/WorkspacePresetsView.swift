import AgentToolingCore
import SwiftUI

/// Presets this Mac follows, and what catching up with one would change.
///
/// Linking records a standing choice and moves nothing. Catching up shows every
/// change first, including the ones that turn out to change nothing because
/// something else still asks for that destination.
struct WorkspacePresetsView: View {
    let session: WorkspacePresetsSession
    let library: WorkspaceLibrarySession
    @State private var linking: ArtifactID?

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Presets", context: context) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.refresh() } }
                    .labelStyle(.iconOnly).buttonStyle(.glass).disabled(session.isBusy)
            }
            Divider()
            if session.rows.isEmpty, session.isBusy {
                ProgressView("Reading presets…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.rows.isEmpty {
                ContentUnavailableView("No presets yet", systemImage: "square.stack",
                    description: Text("A preset is a named set of tools you can put in place together."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let message = session.errorMessage {
                            AttentionBanner(title: "Presets need attention", message: message)
                        }
                        Text("Following a preset keeps its tools where you put them, even when whoever maintains it adds or removes one. It never changes anything without showing you first.")
                            .foregroundStyle(.secondary)
                        ForEach(session.rows) { row in card(row) }
                    }
                    .padding(28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .task { await session.refresh() }
        .sheet(isPresented: Binding(get: { linking != nil }, set: { if !$0 { linking = nil } })) {
            if let presetID = linking,
               let row = session.rows.first(where: { $0.id == presetID }) {
                WorkspacePresetLinkSheet(session: session, library: library,
                                         presetID: presetID, name: row.name)
            }
        }
    }

    private func card(_ row: WorkspacePresetsSession.Row) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.title3.weight(.semibold))
                    Text(row.memberCount == 1 ? "1 tool" : "\(row.memberCount) tools")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if row.isLinked {
                    Label("Following", systemImage: "link").foregroundStyle(.secondary)
                }
            }
            if let subscription = row.subscription {
                Text("In \(destinationText(subscription.destinations))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let update = row.update {
                changes(update)
            } else if row.isLinked {
                Text("This preset is no longer in your library, so there is nothing to follow.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if row.isLinked {
                    Button("Catch up") { Task { await session.catchUp(row.id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy || !session.canWrite || !row.needsCatchUp)
                    Button("Stop following") { Task { await session.unlink(row.id) } }
                        .disabled(session.isBusy || !session.canWrite)
                } else {
                    Button("Follow this preset…") { linking = row.id }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy || !session.canWrite)
                }
                if !session.canWrite {
                    Text("This workspace is open for reading only.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    @ViewBuilder private func changes(_ update: LinkedPresetUpdate) -> some View {
        let added = update.changes.filter { $0.kind == .add }
        let removed = update.changes.filter { $0.kind == .removeContribution }
        let kept = update.changes.filter { $0.kind == .retainedByOtherReason }
        if update.changes.isEmpty {
            Text("Up to date with this preset.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !added.isEmpty {
                    Label(added.count == 1 ? "1 tool would be added"
                          : "\(added.count) tools would be added", systemImage: "plus.circle")
                }
                if !removed.isEmpty {
                    Label(removed.count == 1 ? "1 tool would be taken back out"
                          : "\(removed.count) tools would be taken back out", systemImage: "minus.circle")
                }
                if !kept.isEmpty {
                    Label(kept.count == 1
                          ? "1 tool left the preset but stays, because you asked for it another way"
                          : "\(kept.count) tools left the preset but stay, because you asked for them another way",
                          systemImage: "hand.raised")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private func destinationText(_ destinations: [PortableDestination]) -> String {
        let names = destinations
            .map { "\($0.surface.displayName) · \($0.scope.displayName)" }
            .sorted()
        return names.isEmpty ? "no destinations" : names.formatted(.list(type: .and))
    }

    private var context: String {
        if let name = session.lastAppliedName {
            return "Caught up with \(name). Install to put it into your apps."
        }
        let following = session.rows.filter(\.isLinked).count
        let pending = session.rows.filter(\.hasPendingChanges).count
        if pending > 0 { return pending == 1 ? "1 preset has changes to review" : "\(pending) presets have changes to review" }
        return following == 0 ? "Not following any preset on this Mac"
            : "Following \(following == 1 ? "1 preset" : "\(following) presets") on this Mac"
    }
}

/// Choosing where a preset's tools should go before following it.
private struct WorkspacePresetLinkSheet: View {
    let session: WorkspacePresetsSession
    let library: WorkspaceLibrarySession
    let presetID: ArtifactID
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var clients: Set<ClientKind> = []
    @State private var scope: ToolingScope = .user
    @State private var projectID: ArtifactID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Follow \(name)").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose where this preset's tools belong. Agent Tooling keeps them there as the preset changes, and shows you each change before applying it.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apps").font(.headline)
                    ForEach(ClientKind.allCases) { client in
                        Toggle(client.rawValue, isOn: Binding(
                            get: { clients.contains(client) },
                            set: { if $0 { clients.insert(client) } else { clients.remove(client) } }
                        )).toggleStyle(.checkbox)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where").font(.headline)
                    Picker("Where", selection: $scope) {
                        Text("Everywhere on this Mac").tag(ToolingScope.user)
                        Text("One project").tag(ToolingScope.project)
                    }.labelsHidden().pickerStyle(.radioGroup)
                    if scope == .project {
                        Picker("Project", selection: $projectID) {
                            Text("Choose a project").tag(ArtifactID?.none)
                            ForEach(library.state?.library.projects ?? []) { project in
                                Text(project.name).tag(ArtifactID?.some(project.id))
                            }
                        }.frame(maxWidth: 320)
                    }
                }
                Spacer(minLength: 0)
            }.padding(20)
            Divider()
            HStack {
                Text("Following records the choice. Nothing moves until you catch up.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Follow") {
                    Task {
                        await session.link(presetID, destinations: destinations)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canFollow || session.isBusy)
            }.padding(20)
        }
        .frame(width: 560, height: 500)
        .background(AgentTheme.contentBackground)
    }

    private var canFollow: Bool {
        guard !clients.isEmpty else { return false }
        return scope != .project || projectID != nil
    }

    private var destinations: [PortableDestination] {
        clients.sorted { $0.rawValue < $1.rawValue }.map { client in
            .init(surface: client.primarySurface, scope: scope,
                  logicalProjectID: scope == .project ? projectID : nil,
                  deviceIDs: [library.deviceID])
        }
    }
}

private extension ClientKind {
    var primarySurface: TargetSurface {
        switch self {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }
}
