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
        HStack(spacing: Space.lg) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(!row.isAssignable)
                .accessibilityLabel("Assign \(row.displayName)")
            KindTile(kind: ToolingKind(row.kind), size: Size.tile)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(row.displayName).font(AgentFont.bodyMedium).lineLimit(1)
                if let included = row.includedSummary {
                    Button {
                        showingIncluded = true
                    } label: {
                        Text(included).font(AgentFont.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show tools included with \(row.displayName)")
                } else {
                    Text(row.assignmentExplanation ?? row.ownershipLabel)
                        .font(AgentFont.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ClientMarks(present: Set(row.nativeRoutes.map(\.client)), size: Size.brandMark)
        }
        .frame(height: Size.rowHeightTall)
        .padding(.horizontal, Space.xxs)
        .help(row.assignmentExplanation ?? row.displayName)
        .popover(isPresented: $showingIncluded) { includedContents }
    }

    private var includedContents: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(row.displayName).font(AgentFont.title)
            Text("Included with this plugin").font(AgentFont.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.lg) {
                    ForEach(row.includedChildren) { child in
                        Label(child.displayName, systemImage: child.kind.librarySymbol)
                            .font(AgentFont.body)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Space.xxl)
        .frame(width: Size.fieldStandard, height: includedContentsHeight)
    }

    /// The popover's chrome and one row per included tool, up to the height
    /// where the list starts to scroll.
    private var includedContentsHeight: CGFloat {
        min(Size.popoverListMaxHeight, CGFloat(row.includedChildren.count) * Size.popoverListRow + Size.popoverListChrome)
    }

}
