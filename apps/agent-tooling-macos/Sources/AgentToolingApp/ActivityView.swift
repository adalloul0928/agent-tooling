import AgentToolingCore
import SwiftUI

/// The journal, the receipts and the drift this Mac has recorded.
///
/// Ported from the pre-versioned app: the layout, the day grouping, the
/// filters, the redaction caption and the drift wording are all the
/// original's. What changed is the data source — `AppModel.visibleActivities`,
/// `visibleOperationReceipts` and `visibleInstallDrift` are now one
/// `WorkspaceActivitySession`, reading the same journal, receipts and install
/// ledger through the workspace's own store — and the two boxed sections in
/// the receipt detail, which now use `TitledCard` rather than a native
/// `GroupBox`, so this screen and its `History` sibling tab share one card
/// language instead of two.
struct ActivityView: View {
    let session: WorkspaceActivitySession
    @Environment(AppNavigationState.self) private var navigation
    @State private var query = ""
    @State private var filter: ActivityFilter = .all
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: AppSection.activity.navigationTitle, context: activityContext) {
                Button {
                    selectedID = displayedActivities.first?.id
                } label: {
                    Label("Latest receipt", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.glass)
                .disabled(displayedActivities.isEmpty)
            }

            if !driftReports.isEmpty {
                InstallDriftNotice(reports: driftReports)
                    .padding(.horizontal, WorkspaceLayout.pageInset)
                    .padding(.bottom, Space.lg)
            }

            if selectedID == nil {
                activityList
            } else {
                HSplitView {
                    activityList.frame(minWidth: 320, idealWidth: 500)
                    VStack(spacing: 0) {
                        InspectorHeader(title: "Activity details") { selectedID = nil }
                        activityDetail
                    }.frame(minWidth: 400, idealWidth: 620)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            clearHiddenReceipt()
            consumeRequest()
        }
        .onChange(of: displayedActivities.map(\.id)) { _, _ in clearHiddenReceipt() }
        .onChange(of: navigation.revision) { _, _ in consumeRequest() }
        .onExitCommand { selectedID = nil }
    }

    private var activityList: some View {
        VStack(spacing: 0) {
            PanelHeader("Receipts") {
                Text(mergedActivities.count == 1 ? "1 total" : "\(mergedActivities.count) total")
            }
            HStack(spacing: Space.md) {
                InventorySearchField(placeholder: "Search activity", text: $query)
                    .accessibilityLabel("Search activity")
                WorkspaceSegmentedPicker("Activity filter", selection: $filter) {
                    ForEach(ActivityFilter.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .fixedSize()
                .accessibilityLabel("Activity filter")
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.vertical, Space.lg)

            if displayedActivities.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: mergedActivities.isEmpty ? "No activity yet" : "No matching activity",
                    message: mergedActivities.isEmpty
                        ? "Checks, reviewed changes, and account attestations will appear here."
                        : "Try another kind or clear the search.",
                    actionTitle: mergedActivities.isEmpty ? nil : "Clear Filters"
                ) {
                    query = ""
                    filter = .all
                }
            } else {
                // The day titles are rows of the list rather than native
                // section headers: a `List` section header draws its own
                // rule and ground, which is what put black lines between
                // the days on this screen and nowhere else in the app.
                List(selection: $selectedID) {
                    ForEach(activityGroups) { group in
                        CollectionSectionHeader(title: group.title)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .selectionDisabled()
                        ForEach(group.receipts) { receipt in
                            ActivityCollectionRow(receipt: receipt, selected: selectedID == receipt.id)
                                .tag(receipt.id)
                                .collectionRowChrome(selected: selectedID == receipt.id)
                                .accessibilityLabel(receipt.displayTitle)
                                .accessibilityValue(selectedID == receipt.id ? "Selected" : "")
                        }
                    }
                }
                .collectionListChrome()
                .collectionSurface()
            }
        }
        .paneMaterial()
    }

    /// Installed copies that no longer match what was reviewed, plus any that
    /// vanished or the app could not read. All three are facts worth stating;
    /// none is an alarm. Hiding the unreadable ones would turn a folder the app
    /// cannot check into a folder that looks unchanged.
    private var driftReports: [InstalledPackageDrift] {
        session.drift.filter { $0.state != .matchesReview }
    }

    @ViewBuilder
    private var activityDetail: some View {
        if let receipt = selectedReceipt {
            ActivityReceiptDetail(
                receipt: receipt,
                operationReceipt: session.operationReceipt(for: receipt.operationReceiptID))
        } else {
            EmptyStateView(
                symbol: "doc.text", title: "Select a receipt", message: "Review the command, result, duration, and affected local paths.")
        }
    }

    /// The journal and the synthesized operation-receipt rows as one list, the
    /// collection every count, filter, and selection on this screen reads from.
    private var mergedActivities: [ActivityReceipt] { session.mergedActivities }

    private var activityContext: String {
        let count = mergedActivities.count
        return count == 1 ? "1 receipt" : "\(count) receipts"
    }

    private var filteredActivities: [ActivityReceipt] {
        mergedActivities.filter { receipt in
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

    private var selectedReceipt: ActivityReceipt? { mergedActivities.first { $0.id == selectedID } }

    /// A palette result that named one receipt reveals it and nothing more;
    /// consuming the request is how this screen tells the shell it arrived.
    private func consumeRequest() {
        guard let id = navigation.requestedItemID,
            let uuid = UUID(uuidString: id),
            mergedActivities.contains(where: { $0.id == uuid })
        else { return }
        query = ""
        filter = .all
        selectedID = uuid
        navigation.consumeRequestedItem(id)
    }

    private func clearHiddenReceipt() {
        guard !displayedActivities.contains(where: { $0.id == selectedID }) else { return }
        selectedID = nil
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
        HStack(spacing: Space.lg) {
            StatusGlyph(state: receipt.state, size: Size.glyphLarge, tint: selected ? Color.white : nil)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(receipt.displayTitle)
                    .font(AgentFont.bodyMedium)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(receipt.detail)
                    .font(AgentFont.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.lg)
            Text(SnapshotTime.standalone(receipt.date))
                .font(AgentFont.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
        }
        .padding(.vertical, Space.sm)
    }
}

/// Drift is information, not an accusation. Editing an installed skill in place
/// is a normal thing to do, so this states what changed and stops there.
private struct InstallDriftNotice: View {
    let reports: [InstalledPackageDrift]

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "square.and.pencil")
                .font(AgentFont.body)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(AgentFont.bodyMedium)
                ForEach(reports.prefix(6)) { report in
                    HStack(spacing: Space.sm) {
                        Text(report.packageName)
                            .font(AgentFont.captionMedium)
                        Text(report.headline)
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                        PathInfoButton(path: report.destinationPath)
                    }
                }
                if reports.count > 6 {
                    Text("and \(reports.count - 6) more").font(AgentFont.micro).foregroundStyle(.tertiary)
                }
                Text(
                    "Re-install from the library whenever you want Agent Tooling's record to match the files again. Nothing was changed."
                )
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel()
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
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(spacing: Space.lg) {
                    KindTile(kind: .activity, size: Size.tileLarge)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(receipt.displayTitle).font(AgentFont.title)
                        Text(receipt.detail).font(AgentFont.body).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(state: receipt.state, text: statusText)
                }

                TitledCard("Receipt") {
                    LabeledValueRow("Operation") { Text(receipt.kind.rawValue.capitalized) }
                    Hairline()
                    LabeledValueRow("Started") { Text(receipt.date.formatted(date: .abbreviated, time: .standard)) }
                    if let duration = receipt.duration {
                        Hairline()
                        LabeledValueRow("Duration") {
                            Text(duration.formatted(.number.precision(.fractionLength(1))) + " seconds")
                        }
                    }
                    Hairline()
                    LabeledValueRow("Receipt ID") {
                        Text(receipt.id.uuidString.lowercased()).font(AgentFont.mono)
                    }
                }

                if let operationReceipt, !operationReceipt.itemOutcomes.isEmpty {
                    TitledCard("Each item in this batch", count: "\(operationReceipt.itemOutcomes.count)") {
                        Text(operationReceipt.outcomeTally)
                            .font(AgentFont.bodyMedium.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.xl)
                        Hairline()
                        ForEach(Array(operationReceipt.itemOutcomes.enumerated()), id: \.element.id) { index, outcome in
                            ItemOutcomeRow(outcome: outcome)
                            if index < operationReceipt.itemOutcomes.count - 1 { Hairline() }
                        }
                    }
                }

                if let command = receipt.command {
                    CommandDisclosure(title: "Executed command", command: command)
                }

                TitledCard(
                    "Affected local paths", count: receipt.affectedPaths.isEmpty ? nil : "\(receipt.affectedPaths.count)"
                ) {
                    if receipt.affectedPaths.isEmpty {
                        HStack {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            Text("No file changes recorded").font(AgentFont.body).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(Space.xl)
                    } else {
                        ForEach(Array(receipt.affectedPaths.enumerated()), id: \.offset) { index, path in
                            HStack {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                LocationText(path: path)
                                Spacer()
                            }
                            .padding(Space.lg)
                            if index < receipt.affectedPaths.count - 1 { Hairline() }
                        }
                    }
                }

                HStack(spacing: Space.md) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text("Sensitive values were redacted before this receipt was stored.").font(AgentFont.caption).foregroundStyle(.secondary)
                }
                .padding(Space.lg)
                .standardPanel()
            }
            .padding(WorkspaceLayout.paneInset)
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
        HStack(alignment: .top, spacing: Space.lg) {
            StatusGlyph(state: state, size: Size.glyph)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    Text(outcome.title).font(AgentFont.bodyMedium)
                    Text(outcome.status.displayName)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                }
                Text(outcome.reason)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.lg)
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
