import AgentToolingCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: ActivityFilter = .all
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Activity") {
                Button {
                    selectedID = displayedActivities.first?.id
                } label: {
                    Label("Latest receipt", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(displayedActivities.isEmpty)
            }

            GeometryReader { proxy in
                HSplitView {
                    activityList.frame(
                        minWidth: 390, idealWidth: 470, maxWidth: 560, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                    activityDetail.frame(
                        minWidth: 500, maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { selectFirstVisibleReceiptIfNeeded() }
        .onChange(of: displayedActivities.map(\.id)) { _, _ in selectFirstVisibleReceiptIfNeeded() }
    }

    private var activityList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search activity", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search activity")
                Picker("Filter", selection: $filter) {
                    ForEach(ActivityFilter.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .labelsHidden()
                .accessibilityLabel("Activity filter")
                .frame(width: 142)
            }
            .padding(12)

            if displayedActivities.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: model.activities.isEmpty ? "No activity yet" : "No matching activity",
                    message: model.activities.isEmpty
                        ? "Checks, reviewed changes, and account attestations will appear here."
                        : "Try another kind or clear the search.",
                    actionTitle: model.activities.isEmpty ? nil : "Clear Filters"
                ) {
                    query = ""
                    filter = .all
                }
            } else {
                List(selection: $selectedID) {
                    ForEach(activityGroups) { group in
                        Section(group.title) {
                            ForEach(group.receipts) { receipt in
                                ActivityCollectionRow(receipt: receipt)
                                    .tag(receipt.id)
                                    .listRowBackground(selectedID == receipt.id ? AgentTheme.blue.opacity(0.13) : Color.clear)
                                    .accessibilityLabel(receipt.displayTitle)
                                    .accessibilityValue(selectedID == receipt.id ? "Selected" : "")
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var activityDetail: some View {
        if let receipt = selectedReceipt {
            ActivityReceiptDetail(receipt: receipt)
        } else {
            EmptyStateView(
                symbol: "doc.text", title: "Select a receipt", message: "Review the command, result, duration, and affected local paths.")
        }
    }

    private var filteredActivities: [ActivityReceipt] {
        model.activities.filter { receipt in
            (filter.kind == nil || receipt.kind == filter.kind)
                && (query.isEmpty
                    || [receipt.displayTitle, receipt.detail, receipt.command ?? ""].joined(separator: " ")
                        .localizedCaseInsensitiveContains(query))
        }
    }

    private var displayedActivities: [ActivityReceipt] {
        filteredActivities.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.date > rhs.date
        }
    }

    private var activityGroups: [ActivityDayGroup] {
        let calendar = Calendar.current
        return Dictionary(grouping: displayedActivities) { calendar.startOfDay(for: $0.date) }
            .map { date, receipts in
                ActivityDayGroup(
                    date: date,
                    title: dayTitle(date, calendar: calendar),
                    receipts: receipts
                )
            }
            .sorted { $0.date > $1.date }
    }

    private func dayTitle(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var selectedReceipt: ActivityReceipt? { model.activities.first { $0.id == selectedID } }

    private func selectFirstVisibleReceiptIfNeeded() {
        guard !displayedActivities.contains(where: { $0.id == selectedID }) else { return }
        selectedID = displayedActivities.first?.id
    }
}

private struct ActivityDayGroup: Identifiable {
    let date: Date
    let title: String
    let receipts: [ActivityReceipt]
    var id: Date { date }
}

private enum ActivityFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case sync = "Sync"
    case validation = "Checks"
    case configuration = "Changes"
    var id: String { rawValue }
    var kind: ActivityKind? {
        switch self {
        case .all: nil
        case .sync: .sync
        case .validation: .validation
        case .configuration: .configuration
        }
    }
}

private struct ActivityCollectionRow: View {
    let receipt: ActivityReceipt

    var body: some View {
        HStack(spacing: 11) {
            SymbolTile(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                Text(receipt.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                StatusDot(state: receipt.state, size: 7)
                Text(receipt.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }

    private var symbol: String {
        switch receipt.kind {
        case .sync: "arrow.triangle.2.circlepath"
        case .validation: "checkmark.seal"
        case .authentication: "person.badge.key"
        case .configuration: "slider.horizontal.3"
        case .publication: "arrow.up.doc"
        }
    }

}

private struct ActivityReceiptDetail: View {
    let receipt: ActivityReceipt

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    SymbolTile(symbol: receipt.state == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.displayTitle).font(.title2.weight(.semibold))
                        Text(receipt.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(state: receipt.state, text: statusText)
                }

                GroupBox("Receipt") {
                    VStack(spacing: 0) {
                        LabeledValueRow("Operation") { Text(receipt.kind.rawValue.capitalized) }
                        Divider()
                        LabeledValueRow("Started") { Text(receipt.date.formatted(date: .abbreviated, time: .standard)) }
                        if let duration = receipt.duration {
                            Divider()
                            LabeledValueRow("Duration") { Text(duration.formatted(.number.precision(.fractionLength(1))) + " seconds") }
                        }
                        Divider()
                        LabeledValueRow("Receipt ID") {
                            Text(receipt.id.uuidString.lowercased()).font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                if let command = receipt.command {
                    CommandDisclosure(title: "Executed command", command: command)
                }

                GroupBox("Affected local paths") {
                    if receipt.affectedPaths.isEmpty {
                        HStack {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            Text("No file changes recorded").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(13)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(receipt.affectedPaths.enumerated()), id: \.offset) { index, path in
                                HStack {
                                    Image(systemName: "doc").foregroundStyle(.secondary)
                                    CompactPathText(path: path)
                                    Spacer()
                                }
                                .padding(12)
                                if index < receipt.affectedPaths.count - 1 { Divider() }
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text("Sensitive values were redacted before this receipt was stored.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .standardPanel(cornerRadius: 12)
            }
            .padding(22)
        }
    }

    private var statusText: String {
        switch receipt.state {
        case .healthy: "Completed"
        case .attention: "Needs attention"
        case .pending: "Pending"
        case .unavailable: "Unavailable"
        }
    }
}
