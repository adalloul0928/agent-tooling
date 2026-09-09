import AgentToolingCore
import SwiftUI

/// Earlier versions of this workspace, and what going back to one would change.
///
/// Nothing is restored by looking. The preview is read from history, and the
/// restore is a separate confirmed step that says plainly what it will and will
/// not bring back.
struct WorkspaceHistoryView: View {
    let session: WorkspaceHistorySession
    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "History", context: context) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.refresh() } }
                    .labelStyle(.iconOnly).buttonStyle(.glass).disabled(session.isBusy)
            }
            Divider()
            if session.points.isEmpty, session.isBusy {
                ProgressView("Reading earlier versions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.points.isEmpty {
                ContentUnavailableView("No earlier versions", systemImage: "clock.arrow.circlepath",
                    description: Text("Versions appear here as you change your library."))
            } else {
                HSplitView {
                    versionList
                    detail.frame(minWidth: 340)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .task { await session.refresh() }
        .confirmationDialog("Go back to this version?", isPresented: $isConfirming) {
            Button("Restore") { Task { await session.restore() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current version is kept in this list, so you can come back to it. Nothing in your apps changes until you install.")
        }
    }

    private var versionList: some View {
        List(session.points, id: \.revisionID, selection: Binding(
            get: { session.selectedID },
            set: { session.select($0) }
        )) { point in
            HStack(spacing: 12) {
                Image(systemName: point.isCurrent ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(point.isCurrent ? AnyShapeStyle(AgentTheme.selection) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(point.isCurrent ? "Now" : point.createdAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 14, weight: .medium))
                    Text(summary(point)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5)
            .tag(point.revisionID)
            .help(point.createdAt.formatted(date: .abbreviated, time: .standard))
        }
        .listStyle(.sidebar)
        .frame(minWidth: 240, idealWidth: 280)
    }

    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let message = session.errorMessage {
                    AttentionBanner(title: "History needs attention", message: message)
                }
                if let point = session.selected {
                    if point.isCurrent {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This is where you are").font(.title3.weight(.semibold))
                            Text("Pick an earlier version on the left to see what going back to it would change.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(18).standardPanel(cornerRadius: 14)
                    } else if let preview = session.preview {
                        changes(preview, at: point)
                    } else if session.isBusy {
                        ProgressView("Reading that version…")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose a version").font(.title3.weight(.semibold))
                        Text("Each entry is a version of your library and where you asked each tool to go. Going back to one adds it as a new version rather than erasing what came after.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(18).standardPanel(cornerRadius: 14)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func changes(_ preview: WorkspaceRestorePreview, at point: WorkspaceRestorePoint) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(point.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.title3.weight(.semibold))
                Text(preview.isEmpty
                     ? "This version matches what you have now. Going back to it would change nothing."
                     : "Going back to this version would make these changes to your library.")
                    .foregroundStyle(.secondary)
            }
            if !preview.isEmpty {
                group("Comes back", preview.restoredItems, "arrow.uturn.backward")
                group("Goes away", preview.removedItems, "minus.circle")
                group("Changes", preview.changedItems, "pencil")
                if preview.assignmentDifference != 0 {
                    Label(preview.assignmentDifference > 0
                          ? "\(preview.assignmentDifference) more \(preview.assignmentDifference == 1 ? "place" : "places") a tool is asked for"
                          : "\(-preview.assignmentDifference) fewer \(preview.assignmentDifference == -1 ? "place" : "places") a tool is asked for",
                          systemImage: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                }
            }
            if !preview.deletedSinceItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Deleted since, and staying deleted", systemImage: "trash")
                        .font(.system(size: 14, weight: .medium))
                    Text(preview.deletedSinceItems.formatted(.list(type: .and)))
                        .foregroundStyle(.secondary)
                    Text("These were in that version and have been deleted since. Going back does not bring them back, so a deletion you made on another Mac is not quietly undone.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button("Go back to this version") { isConfirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canRestore || preview.isEmpty)
                Text(restoreExplanation(preview))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    @ViewBuilder private func group(_ title: String, _ names: [String], _ symbol: String) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(title) (\(names.count))", systemImage: symbol)
                    .font(.system(size: 14, weight: .medium))
                Text(names.formatted(.list(type: .and))).foregroundStyle(.secondary)
            }
        }
    }

    private func restoreExplanation(_ preview: WorkspaceRestorePreview) -> String {
        if preview.isEmpty { return "There is nothing to change." }
        if !session.canRestore { return "This workspace is open for reading only." }
        return "Your apps are not touched. Install is still the only step that writes anything."
    }

    private func summary(_ point: WorkspaceRestorePoint) -> String {
        let items = point.itemCount == 1 ? "1 tool" : "\(point.itemCount) tools"
        let places = point.assignmentCount == 1 ? "1 place" : "\(point.assignmentCount) places"
        return "\(items) · \(places)"
    }

    private var context: String {
        guard let restored = session.lastRestoredID,
              session.points.contains(where: { $0.revisionID == restored }) else {
            return session.points.isEmpty
                ? "Earlier versions of this workspace"
                : "\(session.points.count) versions kept on this Mac"
        }
        return "Restored an earlier version. Install to put it into your apps."
    }
}
