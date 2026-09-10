import AgentToolingCore
import SwiftUI

/// One library row, offered for assignment during onboarding.
///
/// The row grammar matches every other list in the app: a tile identifies the
/// kind, a name and one clause describe it, marks say which apps already carry
/// it natively, and a disabled checkbox carries its own verdict — why a row
/// cannot be picked, when it cannot. Nothing here reads or writes the
/// workspace; the checkbox is the only state it shows, and the binding owns it.
struct OnboardingChoiceRow: View {
    let row: WorkspaceLibraryReadModelRow
    @Binding var isSelected: Bool
    @State private var showingIncluded = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(!row.isAssignable)
                .accessibilityLabel("Assign \(row.displayName)")
            KindTile(kind: toolingKind(row.kind), size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.displayName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if row.childCount > 0 {
                    Button {
                        showingIncluded = true
                    } label: {
                        Text(contentsSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show tools included with \(row.displayName)")
                } else {
                    Text(row.assignmentExplanation ?? row.ownershipLabel)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ClientMarks(present: Set(row.nativeRoutes.map(\.client)), size: 14)
        }
        .frame(height: 58)
        .padding(.horizontal, 2)
        .help(row.assignmentExplanation ?? row.displayName)
        .popover(isPresented: $showingIncluded) { includedContents }
    }

    private var contentsSummary: String {
        let skills = row.includedChildren.count { $0.kind == .skill }
        let servers = row.includedChildren.count { $0.kind == .mcpServer }
        var parts: [String] = []
        if skills > 0 { parts.append("\(skills) \(skills == 1 ? "skill" : "skills")") }
        if servers > 0 { parts.append("\(servers) \(servers == 1 ? "connection" : "connections")") }
        return parts.isEmpty ? "Bundle" : "Includes " + parts.joined(separator: " · ")
    }

    private var includedContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.displayName).font(.system(size: 15, weight: .semibold))
            Text("Included with this plugin").font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(row.includedChildren) { child in
                        Label(child.displayName, systemImage: child.kind.librarySymbol)
                            .font(.system(size: 13))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(width: 320, height: min(320, CGFloat(row.includedChildren.count * 26 + 90)))
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
}
