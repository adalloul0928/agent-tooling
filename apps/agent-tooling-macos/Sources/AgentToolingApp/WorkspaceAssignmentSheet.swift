import AgentToolingCore
import SwiftUI

/// Reviews and saves where selected library items should be used.
struct WorkspaceAssignmentSheet: View {
    let session: WorkspaceLibrarySession
    let artifactIDs: [ArtifactID]
    var presetID: ArtifactID?
    var initialProjectID: ArtifactID?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedClients: Set<ClientKind> = []
    @State private var scope: ToolingScope
    @State private var selectedProjectID: ArtifactID?
    @State private var request: Request?
    @State private var isShowingAllItems = false

    init(
        session: WorkspaceLibrarySession,
        artifactIDs: [ArtifactID],
        presetID: ArtifactID? = nil,
        initialProjectID: ArtifactID? = nil
    ) {
        self.session = session
        self.artifactIDs = artifactIDs
        self.presetID = presetID
        self.initialProjectID = initialProjectID
        _scope = State(initialValue: initialProjectID == nil ? .user : .project)
        _selectedProjectID = State(initialValue: initialProjectID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if session.state == nil, session.isBusy {
                    ProgressView("Loading library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let state = session.state {
                    content(state.library)
                } else {
                    ContentUnavailableView(
                        "Library unavailable",
                        systemImage: "books.vertical",
                        description: Text(session.errorMessage ?? "Refresh the workspace and try again."))
                }
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 680)
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled(session.isBusy)
        .task(id: loadID) {
            if session.state == nil { await session.refresh() }
        }
        .task(id: request) {
            guard let request else { return }
            switch request {
            case .review(let destinations):
                if let presetID {
                    await session.reviewPreset(presetID: presetID, destinations: destinations)
                } else {
                    await session.reviewAssignments(artifactIDs: artifactIDs, destinations: destinations)
                }
            case .save:
                await session.applyReviewedAssignments()
            }
            if !Task.isCancelled { self.request = nil }
        }
        .onDisappear {
            request = nil
            if session.review != nil, !session.isBusy { session.discardReview() }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            SymbolTile(symbol: presetID == nil ? "arrow.triangle.branch" : "square.stack.3d.up", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.lastReceipt == nil ? "Assign library items" : "Assignments saved")
                    .font(.title2.weight(.semibold))
                Text("Choose where to use these items.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 82)
    }

    @ViewBuilder
    private func content(_ library: WorkspaceLibraryReadModel) -> some View {
        if session.lastReceipt != nil {
            let itemSummaries = summaries(in: library)
            VStack(spacing: 16) {
                selectedItems(itemSummaries, library: library)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                success
                if let error = session.errorMessage {
                    AttentionBanner(title: "Saved with a refresh issue", message: error)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
            }
        } else {
            let itemSummaries = summaries(in: library)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    selectedItems(itemSummaries, library: library)
                    if let review = session.review {
                        reviewSummary(review)
                    } else {
                        destinationEditor(library)
                    }
                    if let error = session.errorMessage {
                        AttentionBanner(title: "Couldn’t prepare assignments", message: error)
                    }
                }
                .padding(24)
            }
        }
    }

    private func selectedItems(
        _ itemSummaries: [ItemSummary],
        library: WorkspaceLibraryReadModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(presetID == nil ? "Selected items" : "Preset items")
                    .font(.headline)
                Spacer()
                Text("\(itemSummaries.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                if let presetID, let preset = library.presets.first(where: { $0.id == presetID }) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                        Text(preset.name).font(.callout.weight(.semibold))
                        Spacer()
                        Text("Revision \(preset.revision)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    Divider().opacity(0.45)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(
                            Array((isShowingAllItems ? itemSummaries : Array(itemSummaries.prefix(2))).enumerated()),
                            id: \.element.id
                        ) { index, item in
                            HStack(spacing: 10) {
                                KindTile(kind: toolingKind(item.kind), size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.callout.weight(.medium))
                                    Text(item.detail)
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            if index < (isShowingAllItems ? itemSummaries.count : min(2, itemSummaries.count)) - 1 {
                                Divider().opacity(0.45)
                            }
                        }
                    }
                }
                .frame(maxHeight: isShowingAllItems ? 160 : nil)

                if itemSummaries.count > 2 {
                    Divider().opacity(0.45)
                    Button(isShowingAllItems ? "Show fewer items" : "Show all \(itemSummaries.count) items") {
                        isShowingAllItems.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AgentTheme.selection)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .disabled(draftLocked)
                }
            }
            .standardPanel()
        }
    }

    private func destinationEditor(_ library: WorkspaceLibraryReadModel) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            field(
                title: "Apps",
                detail: "Choose each app explicitly."
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(ClientKind.allCases.enumerated()), id: \.element) { index, client in
                        Toggle(isOn: clientBinding(client)) {
                            HStack(spacing: 10) {
                                ClientBrandIcon(client: client, size: 20).frame(width: 24, height: 24)
                                Text(surface(client).displayName).font(.callout.weight(.medium))
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        if index < ClientKind.allCases.count - 1 { Divider().opacity(0.45) }
                    }
                }
                .standardPanel()
            }

            field(title: "Scope", detail: "Assignments are limited to this Mac.") {
                WorkspaceSegmentedPicker("Assignment scope", selection: $scope) {
                    Text("This Mac").tag(ToolingScope.user)
                    Text("Project").tag(ToolingScope.project)
                }
                .frame(maxWidth: 320)
            }

            if scope == .project {
                field(title: "Project", detail: "Choose the project for every selected app.") {
                    Picker("Project", selection: $selectedProjectID) {
                        Text("Choose a project").tag(nil as ArtifactID?)
                        ForEach(library.projects) { project in
                            Text(project.name).tag(project.id as ArtifactID?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 420, alignment: .leading)
                }
            }
        }
        .disabled(draftLocked)
    }

    private func reviewSummary(_ review: WorkspaceAssignmentReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review assignments").font(.headline)
                Text(reviewTargetSummary(review))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                reviewCount("Additions", count: review.preview.additions.count, symbol: "plus.circle")
                if !review.preview.removals.isEmpty {
                    reviewCount("Removals", count: review.preview.removals.count, symbol: "minus.circle")
                }
            }
            Text("Saves these choices to your workspace. Installing them in apps is a separate step.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !isWritable {
                AttentionBanner(
                    title: "Read-only workspace",
                    message: "You can review this assignment batch here, but this session cannot save it."
                )
            }
        }
        .padding(16)
        .standardPanel()
    }

    private func reviewCount(_ title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(count.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(AgentTheme.controlBackground, in: Capsule())
        .overlay { Capsule().strokeBorder(AgentTheme.separator.opacity(0.35), lineWidth: 0.5) }
    }

    private var success: some View {
        ContentUnavailableView {
            Label("Assignments saved", systemImage: "checkmark.circle")
        } description: {
            Text("Your assignments are saved. Review installation changes to make them available in your apps.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if session.review != nil {
                Button("Back") {
                    request = nil
                    session.discardReview()
                }
                .buttonStyle(.glass)
                .disabled(session.isBusy)
            } else {
                Button(session.lastReceipt == nil ? "Cancel" : "Close") { dismiss() }
                    .buttonStyle(.glass)
                    .disabled(session.isBusy)
            }
            Spacer()
            if session.lastReceipt == nil {
                GlassEffectContainer(spacing: 8) {
                    if session.review != nil {
                        Button("Save assignments") { request = .save }
                            .buttonStyle(.glassProminent)
                            .tint(AgentTheme.selection)
                            .disabled(session.isBusy || !isWritable)
                    } else {
                        Button("Review assignments") { request = .review(destinations) }
                            .buttonStyle(.glassProminent)
                            .tint(AgentTheme.selection)
                            .disabled(!canReview || session.isBusy)
                    }
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(nil as Color?)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 72)
    }

    private func field<Content: View>(
        title: String, detail: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.body).foregroundStyle(.secondary)
            content()
        }
    }

    private var canReview: Bool {
        guard !selectedClients.isEmpty else { return false }
        if scope == .project {
            guard let selectedProjectID,
                  session.state?.library.projects.contains(where: { $0.id == selectedProjectID }) == true else {
                return false
            }
        }
        return true
    }

    private var destinations: [PortableDestination] {
        selectedClients.sorted { $0.rawValue < $1.rawValue }.map { client in
            .init(
                surface: surface(client), scope: scope,
                logicalProjectID: scope == .project ? selectedProjectID : nil,
                deviceIDs: [session.deviceID])
        }
    }

    private var draftLocked: Bool { session.review != nil || session.isBusy || request != nil }

    private var isWritable: Bool {
        switch session.access {
        case .readOnly: false
        case .writable: true
        }
    }

    private var loadID: String {
        "\(session.workspaceID.rawValue.uuidString.lowercased()):\(session.deviceID.rawValue.uuidString.lowercased())"
    }

    private func clientBinding(_ client: ClientKind) -> Binding<Bool> {
        Binding(
            get: { selectedClients.contains(client) },
            set: { selected in
                guard !draftLocked else { return }
                if selected { selectedClients.insert(client) } else { selectedClients.remove(client) }
            })
    }

    private func reviewTargetSummary(_ review: WorkspaceAssignmentReview) -> String {
        let values = Set(review.command.additions.map { assignment in
            let client = assignment.destination.surface.displayName
            if assignment.destination.scope == .project,
               let id = assignment.destination.logicalProjectID,
               let project = session.state?.library.projects.first(where: { $0.id == id }) {
                return "\(client) · \(project.name)"
            }
            return "\(client) · This Mac"
        }).sorted()
        return values.isEmpty ? "No destinations will be added." : values.joined(separator: "  •  ")
    }

    private func summaries(in library: WorkspaceLibraryReadModel) -> [ItemSummary] {
        let ids: [ArtifactID]
        if let presetID, let preset = library.presets.first(where: { $0.id == presetID }) {
            ids = preset.memberArtifactIDs
        } else {
            ids = artifactIDs
        }
        let roots = Dictionary(uniqueKeysWithValues: library.rows.map { ($0.artifactID, $0) })
        let children = Dictionary(uniqueKeysWithValues: library.rows.flatMap(\.includedChildren).map { ($0.artifactID, $0) })
        return ids.compactMap { id in
            if let row = roots[id] {
                let children = row.childCount == 0 ? "" : " · Includes \(row.childCount) bundled item\(row.childCount == 1 ? "" : "s")"
                return .init(id: id, name: row.displayName, kind: row.kind,
                    detail: "\(ownershipLabel(row.ownership))\(children)")
            }
            if let child = children[id] {
                return .init(id: id, name: child.displayName, kind: child.kind,
                    detail: "Included with \(child.parentPluginLabel ?? "plugin")")
            }
            return nil
        }
    }

    private func toolingKind(_ kind: ArtifactKind) -> ToolingKind {
        switch kind {
        case .skill: .skill
        case .mcpServer: .mcpServer
        case .package, .nativePlugin: .plugin
        case .preset: .profile
        case .logicalProject: .library
        }
    }

    private func ownershipLabel(_ ownership: WorkspaceLibraryOwnership) -> String {
        switch ownership {
        case .centralPersonal: "Personal library"
        case .centralUpstream: "Upstream linked"
        case .nativeOwned: "Native plugin"
        case .attachedAuthoring: "Attached authoring source"
        case .trackedOnly: "Tracked only"
        }
    }

    private func surface(_ client: ClientKind) -> TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }

    private struct ItemSummary: Identifiable {
        let id: ArtifactID
        let name: String
        let kind: ArtifactKind
        let detail: String
    }

    private enum Request: Hashable {
        case review([PortableDestination])
        case save
    }
}
