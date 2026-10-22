import AgentToolingCore
import SwiftUI

/// Restore-point browser backed by `WorkspaceHistorySession`.
/// Restoring changes the library; client installations remain a separate step.
struct HistorySection: View {
    let workspace: WorkspaceLaunch.Workspace
    @State private var isConfirming = false

    private var session: WorkspaceHistorySession { workspace.history }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: AppSection.history.navigationTitle, context: context) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.refresh() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .disabled(session.isBusy)
            }

            if session.points.isEmpty, session.isBusy {
                ProgressView("Reading earlier versions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.points.isEmpty {
                EmptyStateView(
                    symbol: AppSection.history.symbol,
                    title: "No earlier versions",
                    message: "Versions appear here as you change your library.")
            } else {
                HSplitView {
                    versionList.frame(minWidth: Size.versionListMin, idealWidth: Size.versionListIdeal)
                    detail.frame(minWidth: Size.versionDetailMin, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await session.refresh() }
        .confirmationDialog("Go back to this version?", isPresented: $isConfirming) {
            Button("Restore") { Task { await session.restore() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current version is kept in this list, so you can come back to it. Nothing in your apps changes until you install.")
        }
    }

    private var versionList: some View {
        VStack(spacing: 0) {
            PanelHeader("Versions") {
                Text(session.points.count == 1 ? "1 kept" : "\(session.points.count) kept")
            }
            List(
                session.points, id: \.revisionID,
                selection: Binding(
                    get: { session.selectedID },
                    set: { session.select($0) })
            ) { point in
                let selected = session.selectedID == point.revisionID
                HStack(spacing: Space.lg) {
                    Image(systemName: point.isCurrent ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: Size.glyphLarge))
                        .foregroundStyle(
                            selected
                                ? AnyShapeStyle(AgentTheme.onSelection)
                                : point.isCurrent ? AnyShapeStyle(AgentTheme.selection) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(point.isCurrent ? "Now" : point.createdAt.formatted(.relative(presentation: .named)))
                            .font(AgentFont.bodyMedium)
                            .foregroundStyle(selected ? AgentTheme.onSelection : Color.primary)
                        Text(summary(point))
                            .font(AgentFont.caption)
                            .foregroundStyle(selected ? AgentTheme.onSelection.opacity(Opacity.secondaryOnSelection) : Color.secondary)
                    }
                }
                .padding(.vertical, Space.sm)
                .tag(point.revisionID)
                .collectionRowChrome(selected: selected)
                .help(point.createdAt.formatted(date: .abbreviated, time: .standard))
            }
            .collectionListChrome()
            .collectionSurface()
        }
        .paneMaterial()
    }

    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                if let message = session.errorMessage {
                    AttentionBanner(title: "History needs attention", message: message)
                }
                if let point = session.selected {
                    if point.isCurrent {
                        TitledCard("This is where you are") {
                            Text("Pick an earlier version on the left to see what going back to it would change.")
                                .font(AgentFont.body)
                                .foregroundStyle(.secondary)
                                .padding(Space.xl)
                        }
                    } else if let preview = session.preview {
                        changes(preview, at: point)
                    } else if session.isBusy {
                        ProgressView("Reading that version…")
                    }
                } else {
                    TitledCard("Choose a version") {
                        Text(
                            "Each entry is a version of your library and where you asked each tool to go. Going back to one adds it as a new version rather than erasing what came after."
                        )
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                        .padding(Space.xl)
                    }
                }
            }
            .padding(WorkspaceLayout.pageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func changes(_ preview: WorkspaceRestorePreview, at point: WorkspaceRestorePoint) -> some View {
        TitledCard(point.createdAt.formatted(date: .abbreviated, time: .shortened)) {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text(
                    preview.isEmpty
                        ? "This version matches what you have now. Going back to it would change nothing."
                        : "Going back to this version would make these changes to your library."
                )
                .font(AgentFont.body)
                .foregroundStyle(.secondary)

                if !preview.isEmpty {
                    group("Comes back", preview.restoredItems, "arrow.uturn.backward")
                    group("Goes away", preview.removedItems, "minus.circle")
                    group("Changes", preview.changedItems, "pencil")
                    if preview.assignmentDifference != 0 {
                        let difference = abs(preview.assignmentDifference)
                        Label(
                            "\(difference) \(preview.assignmentDifference > 0 ? "more" : "fewer") "
                                + "\(Self.place.word(for: difference)) a tool is asked for",
                            systemImage: "square.grid.2x2"
                        )
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                    }
                }
                if !preview.deletedSinceItems.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Label("Deleted since, and staying deleted", systemImage: "trash")
                            .font(AgentFont.bodyMedium)
                        Text(preview.deletedSinceItems.formatted(.list(type: .and)))
                            .font(AgentFont.body)
                            .foregroundStyle(.secondary)
                        Text(
                            "These were in that version and have been deleted since. Going back does not bring them back, so a deletion you made on another Mac is not quietly undone."
                        )
                        .font(AgentFont.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: Space.lg) {
                    Button("Go back to this version…") { isConfirming = true }
                        .primaryActionStyle()
                        .disabled(!session.canRestore || preview.isEmpty)
                    Text(restoreExplanation(preview))
                        .font(AgentFont.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Space.xl)
        }
    }

    @ViewBuilder private func group(_ title: String, _ names: [String], _ symbol: String) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Label("\(title) (\(names.count))", systemImage: symbol)
                    .font(AgentFont.bodyMedium)
                Text(names.formatted(.list(type: .and))).font(AgentFont.body).foregroundStyle(.secondary)
            }
        }
    }

    private func restoreExplanation(_ preview: WorkspaceRestorePreview) -> String {
        if preview.isEmpty { return "There is nothing to change." }
        if !session.canRestore { return "This workspace is open for reading only." }
        return "Your apps are not touched. Install is still the only step that writes anything."
    }

    /// The counted nouns a version is described by.
    private static let tool = CountNoun("tool")
    private static let place = CountNoun("place")

    private func summary(_ point: WorkspaceRestorePoint) -> String {
        "\(Self.tool.phrase(point.itemCount)) · \(Self.place.phrase(point.assignmentCount))"
    }

    private var context: String {
        guard let restored = session.lastRestoredID,
            session.points.contains(where: { $0.revisionID == restored })
        else {
            if session.points.isEmpty { return "Earlier versions of this workspace" }
            return "\(CountNoun("version").phrase(session.points.count)) kept on this Mac"
        }
        return "Restored an earlier version. Install to put it into your apps."
    }
}
