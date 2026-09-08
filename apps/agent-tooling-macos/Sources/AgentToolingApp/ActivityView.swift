import AgentToolingCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Binding var request: ScreenRequest?
    @State private var query = ""
    @State private var filter: ActivityFilter = .all
    @State private var selectedID: UUID?

    init(request: Binding<ScreenRequest?> = .constant(nil)) {
        _request = request
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Activity", context: "\(model.visibleActivities.count) receipts") {
                Button {
                    selectedID = displayedActivities.first?.id
                } label: {
                    Label("Latest receipt", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(displayedActivities.isEmpty)
            }

            if !driftReports.isEmpty {
                InstallDriftNotice(reports: driftReports)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
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
        .onAppear {
            selectFirstVisibleReceiptIfNeeded()
            consumeRequest()
        }
        .onChange(of: displayedActivities.map(\.id)) { _, _ in selectFirstVisibleReceiptIfNeeded() }
        .onChange(of: request) { _, _ in consumeRequest() }
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
                    title: model.visibleActivities.isEmpty ? "No activity yet" : "No matching activity",
                    message: model.visibleActivities.isEmpty
                        ? "Checks, reviewed changes, and account attestations will appear here."
                        : "Try another kind or clear the search.",
                    actionTitle: model.visibleActivities.isEmpty ? nil : "Clear Filters"
                ) {
                    query = ""
                    filter = .all
                }
            } else {
                List(selection: $selectedID) {
                    ForEach(activityGroups) { group in
                        Section(group.title) {
                            ForEach(group.receipts) { receipt in
                                ActivityCollectionRow(receipt: receipt, selected: selectedID == receipt.id)
                                    .tag(receipt.id)
                                    .listRowBackground(SelectionRowBackground(selected: selectedID == receipt.id))
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

    /// Installed copies that no longer match what was reviewed, plus any that
    /// vanished or the app could not read. All three are facts worth stating;
    /// none is an alarm. Hiding the unreadable ones would turn a folder the app
    /// cannot check into a folder that looks unchanged.
    private var driftReports: [InstalledPackageDrift] {
        model.visibleInstallDrift.filter { $0.state != .matchesReview }
    }

    @ViewBuilder
    private var activityDetail: some View {
        if let receipt = selectedReceipt {
            ActivityReceiptDetail(
                receipt: receipt,
                operationReceipt: model.visibleOperationReceipts.first { $0.id == receipt.operationReceiptID }
            )
        } else {
            EmptyStateView(
                symbol: "doc.text", title: "Select a receipt", message: "Review the command, result, duration, and affected local paths.")
        }
    }

    private var filteredActivities: [ActivityReceipt] {
        model.visibleActivities.filter { receipt in
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

    private var selectedReceipt: ActivityReceipt? { model.visibleActivities.first { $0.id == selectedID } }

    private func consumeRequest() {
        guard let request else { return }
        defer { self.request = nil }
        guard case .selectReceipt(let id) = request,
            model.visibleActivities.contains(where: { $0.id == id })
        else { return }
        query = ""
        filter = .all
        selectedID = id
    }

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
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            StatusGlyph(state: receipt.state, size: 16, tint: selected ? Color.white : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.displayTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(receipt.detail)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(receipt.date, style: .relative)
                .font(.caption2)
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
        }
        .padding(.vertical, 6)
    }
}

/// Drift is information, not an accusation. Editing an installed skill in place
/// is a normal thing to do, so this states what changed and stops there.
private struct InstallDriftNotice: View {
    let reports: [InstalledPackageDrift]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                ForEach(reports.prefix(6)) { report in
                    HStack(spacing: 6) {
                        Text(report.packageName)
                            .font(.caption.weight(.medium))
                        Text(report.headline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        PathInfoButton(path: report.destinationPath)
                    }
                }
                if reports.count > 6 {
                    Text("and \(reports.count - 6) more").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(
                    "Re-install from the library whenever you want Agent Tooling's record to match the files again. Nothing was changed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel(cornerRadius: 12)
    }

    private var title: String {
        let count = reports.count
        return "\(count) installed package\(count == 1 ? "" : "s") differ\(count == 1 ? "s" : "") from what you reviewed"
    }
}

private struct ActivityReceiptDetail: View {
    let receipt: ActivityReceipt
    var operationReceipt: OperationReceipt?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    KindTile(kind: .activity, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.displayTitle).font(.title3.weight(.semibold))
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

                if let operationReceipt, !operationReceipt.itemOutcomes.isEmpty {
                    GroupBox("Each item in this batch") {
                        VStack(spacing: 0) {
                            Text(operationReceipt.outcomeTally)
                                .font(.callout.weight(.medium).monospacedDigit())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                            Divider()
                            ForEach(Array(operationReceipt.itemOutcomes.enumerated()), id: \.element.id) { index, outcome in
                                ItemOutcomeRow(outcome: outcome)
                                if index < operationReceipt.itemOutcomes.count - 1 { Divider() }
                            }
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
                                    LocationText(path: path)
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

/// One named item and the reason it ended that way. A batch never collapses
/// into a single verdict here: a skipped step and the reason it was skipped are
/// exactly what a person needs after a partial run.
private struct ItemOutcomeRow: View {
    let outcome: OperationItemOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusGlyph(state: state, size: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(outcome.title).font(.callout.weight(.medium))
                    Text(outcome.status.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(outcome.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var state: HealthState {
        switch outcome.status {
        case .succeeded: .healthy
        case .failed: .attention
        case .skipped, .pending: .unavailable
        case .manual: .pending
        }
    }
}
