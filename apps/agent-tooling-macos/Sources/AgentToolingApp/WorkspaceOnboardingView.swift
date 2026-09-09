import AgentToolingCore
import SwiftUI

/// A first look at a workspace that has nothing assigned yet.
///
/// It offers exactly one path — choose some tools and say where they go — using
/// the same browser, the same review and the same save as everywhere else. It
/// never selects anything on the person's behalf, and it never presents saving
/// an assignment as having installed something.
struct WorkspaceOnboardingView: View {
    let session: WorkspaceLibrarySession
    var onOpenLibrary: () -> Void
    @State private var isAssigning = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Get started", context: "Choose what each app should have") {}
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your library is ready").font(.title2.weight(.semibold))
                        Text(summary).foregroundStyle(.secondary)
                        Text("Nothing is assigned yet. Choosing tools here records where you want them; installing them into your apps stays a separate step you review.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let library = session.state?.library {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(library.rows.prefix(6)) { row in
                                HStack(spacing: 14) {
                                    Image(systemName: row.kind.librarySymbol)
                                        .font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.displayName).fontWeight(.medium)
                                        Text(row.ownershipLabel).font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                Divider()
                            }
                            if library.rows.count > 6 {
                                Text("and \(library.rows.count - 6) more entries")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(18)
                        .standardPanel(cornerRadius: 14)
                    }
                    HStack(spacing: 12) {
                        Button("Choose tools to assign…") {
                            session.discardReview()
                            isAssigning = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy || session.state?.library.rows.isEmpty != false)
                        Button("Skip for now", action: onOpenLibrary)
                        Text("You can do this any time from the library.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .sheet(isPresented: $isAssigning, onDismiss: onOpenLibrary) {
            WorkspaceOnboardingAssignSheet(session: session)
        }
    }

    /// Counts every tool, not just the ones the list below can show.
    ///
    /// A row stands for a top-level entry; a plugin's skills and servers hang
    /// off it as children. Reporting only the rows told someone with 176
    /// skills that their library held 76, because the other 100 arrived inside
    /// plugins. So the headline counts everything and says where the
    /// difference went, which is also what makes the "and N more" line below
    /// add up.
    private var summary: String {
        guard let library = session.state?.library else { return "Reading your library…" }
        let nested = library.nestedToolCount
        let total = library.toolCount
        let holds = total == 1 ? "It holds 1 tool." : "It holds \(total) tools."
        guard nested > 0 else { return holds }
        return nested == 1
            ? "\(holds) One of them comes inside a plugin."
            : "\(holds) \(nested) of them come inside plugins."
    }
}

/// Selecting items during onboarding. Every app starts unselected and nothing
/// is enabled or removed for items the person did not choose.
private struct WorkspaceOnboardingAssignSheet: View {
    let session: WorkspaceLibrarySession
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<ArtifactID> = []
    @State private var isReviewing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose tools to assign").font(.title3.weight(.semibold))
                Spacer()
            }.padding(20)
            Divider()
            if let library = session.state?.library {
                List(library.rows) { row in
                    Toggle(isOn: Binding(
                        get: { selection.contains(row.artifactID) },
                        set: { if $0 { selection.insert(row.artifactID) } else { selection.remove(row.artifactID) } }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.displayName).lineLimit(1)
                            Text(row.ownershipLabel).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!row.isAssignable || session.isBusy)
                    .help(row.assignmentExplanation ?? row.displayName)
                }
                .listStyle(.plain)
            } else {
                ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(selection.isEmpty ? "Nothing selected yet." : "\(selection.count) selected")
                    .foregroundStyle(.secondary)
                Button("Continue") { isReviewing = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || session.isBusy)
            }.padding(20)
        }
        .frame(width: 720, height: 560)
        .sheet(isPresented: $isReviewing, onDismiss: { dismiss() }) {
            WorkspaceAssignmentSheet(session: session, artifactIDs: selection.sorted())
        }
    }
}
