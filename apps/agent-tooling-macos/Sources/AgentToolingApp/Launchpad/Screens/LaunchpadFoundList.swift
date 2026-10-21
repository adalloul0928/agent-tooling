import AgentToolingCore
import SwiftUI

/// Lists observed library entries, client presence, and audit findings. Its card
/// scrolls internally and keeps keyboard selection visible. Space opens the
/// selected entry's copy and location details.
struct LaunchpadFoundList: View {
    let flow: LaunchpadFlow
    @Environment(\.stageMotion) private var stageMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var notRecorded: [String] = []
    @State private var measuredCopies: [ArtifactID: [ObservedSkillCopy]] = [:]
    @State private var checkingAgain: ArtifactID?

    private var motion: StageMotion { stageMotion.resolved(reduceMotion: reduceMotion) }

    var body: some View {
        content
            .defaultFocus($isFocused, true)
            .onAppear { isFocused = true }
            .task { await prepareLibrary() }
    }

    private var content: some View {
        let rows = foundRows
        let found = LaunchpadCopy.Found.self
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.lg) {
                HStack(spacing: Space.xs) {
                    Text(found.listHeading)
                        .font(AgentFont.heading)
                    Text(found.listCount(rows.count))
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(found.listHeadingSpoken(rows.count))
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.lg)
                if let things = LibraryRowPresence.thingsToLookAt(flow.workspace?.setup.checkup) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "stethoscope")
                            .font(.system(size: Size.glyphSmall))
                            .accessibilityHidden(true)
                        Text(found.thingsToLookAt(things))
                    }
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: StageLayout.Found.sectionHead)
            .padding(.top, StageLayout.Found.listTop)
            if rows.isEmpty {
                Text(found.empty)
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, Space.sm)
            } else {
                listCard(rows)
                    .padding(.top, Space.sm)
            }
            if !notRecorded.isEmpty {
                let key = Self.notRecordedKey
                Button(found.notRecordedLink) { flow.openPopover = key }
                    .buttonStyle(.link)
                    .font(AgentFont.caption)
                    .padding(.top, Space.md)
                    .popover(isPresented: popoverBinding(key), arrowEdge: .bottom) {
                        notRecordedPopover
                    }
            }
        }
    }

    /// The library's entries, as the read found them in this Mac's apps.
    private var foundRows: [LibraryRowPresence] {
        guard let workspace = flow.workspace, let state = workspace.library.state else { return [] }
        return LibraryRowPresence.rows(
            in: state, observations: workspace.device.observations, managed: workspace.device.managedClients)
    }

    private var highlight: LaunchpadFoundHighlight { LaunchpadFoundHighlight.of(flow) }

    private func listCard(_ rows: [LibraryRowPresence]) -> some View {
        let columns = LibraryRowPresence.columns(rows)
        let perColumn = max(columns.leading.count, 1)
        let ordered = columns.leading + columns.trailing
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    rowsColumn(columns.leading, offset: 0)
                    Hairline(.vertical)
                    rowsColumn(columns.trailing, offset: columns.leading.count)
                }
            }
            .scrollDisabled(perColumn <= StageLayout.Found.visibleRows)
            // The keyboard's place stays in view as ↑↓ moves it past the
            // rows the card shows.
            .onChange(of: highlight.row) { _, row in reveal(row, with: proxy) }
        }
        .frame(height: StageLayout.Found.row * CGFloat(min(perColumn, StageLayout.Found.visibleRows)))
        .background(LaunchpadFrameReporter(key: LaunchpadFrames.listCard))
        .stageCard()
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .space], phases: .down) { press in
            moveOrOpen(press.key, rows: ordered) ? .handled : .ignored
        }
    }

    /// Scrolls the list as little as shows `row` whole.
    private func reveal(_ row: ArtifactID?, with proxy: ScrollViewProxy) {
        guard let row else { return }
        guard let animation = motion.contentChange else {
            proxy.scrollTo(row)
            return
        }
        withAnimation(animation) { proxy.scrollTo(row) }
    }

    private func rowsColumn(_ rows: [LibraryRowPresence], offset: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // The hairline lies along the row's top edge, inside it, so
                // every row is the row's height and four of them fill the card.
                rowView(row)
                    .overlay(alignment: .top) {
                        if index > 0 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                    }
                    .background(LaunchpadFrameReporter(key: LaunchpadFrames.row(row.id)))
                    .id(row.id)
                    .transition(.opacity.animation(rowArrival(offset + index)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func rowView(_ row: LibraryRowPresence) -> some View {
        let key = Self.rowKey(row.id)
        return Button {
            highlight.select(row.id)
            flow.openPopover = key
        } label: {
            HStack(spacing: Space.lg) {
                rowArt(row)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.md) {
                        Text(row.name)
                            .font(AgentFont.bodyMedium)
                            .lineLimit(1)
                            .layoutPriority(1)
                        rowDetail(row)
                    }
                    .frame(height: StageLayout.Found.nameLine)
                    Text(row.ownership)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // The words are offered the row before the gap is, so a name
                // and its chip share the row rather than the gap's half.
                .layoutPriority(1)
                Spacer(minLength: 0)
                ClientMarks(present: Set(row.apps))
            }
            .padding(.horizontal, Space.xl)
            .frame(height: StageLayout.Found.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .softHighlight(highlight.row == row.id && isFocused, inset: StageLayout.Found.rowHighlightInset)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(LaunchpadCopy.Found.rowHint)
        .popover(isPresented: popoverBinding(key), arrowEdge: .bottom) {
            rowPopover(row)
        }
    }

    @ViewBuilder
    private func rowArt(_ row: LibraryRowPresence) -> some View {
        switch row.kind {
        case .nativePlugin, .package:
            ToolIdentityIcon(packageID: row.declaredName ?? "", fallback: .plugin, size: Size.tile)
        default:
            KindTile(kind: ToolingKind(row.kind), size: Size.tile)
        }
    }

    @ViewBuilder
    private func rowDetail(_ row: LibraryRowPresence) -> some View {
        if case .copies(let summary) = row.detail {
            Chip(text: summary.compactLabel, style: row.copiesDiffer ? .warning : .neutral)
        } else if let text = row.detailText {
            Text(text)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// A row's popover, with its copies measured once it opens.
    private func rowPopover(_ row: LibraryRowPresence) -> some View {
        let measured = measuredCopies[row.id]
        return LaunchpadFoundRowPopover(
            row: row, copies: measured ?? row.copies, home: flow.environment.homeURL,
            isMeasured: measured != nil, isChecking: checkingAgain == row.id, canCheck: checkingAgain == nil
        ) {
            Task { await checkAgain(row) }
        }
        .task(id: row.id) {
            guard row.kind == .skill, measuredCopies[row.id] == nil else { return }
            measuredCopies[row.id] = await LibraryRowPresence.measured(row.copies)
        }
    }

    /// Check again: the apps that hold the entry are read again, and its
    /// copies, as they read them now, measured afresh.
    private func checkAgain(_ row: LibraryRowPresence) async {
        guard let workspace = flow.workspace, checkingAgain == nil else { return }
        checkingAgain = row.id
        defer { checkingAgain = nil }
        let apps = row.apps.isEmpty ? workspace.device.managedClients : row.apps
        await workspace.device.refresh(only: Set(apps))
        let fresh = foundRows.first { $0.id == row.id } ?? row
        measuredCopies[row.id] = fresh.kind == .skill ? await LibraryRowPresence.measured(fresh.copies) : nil
    }

    private var notRecordedPopover: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(LaunchpadCopy.Found.notRecordedTitle)
                .font(AgentFont.heading)
            ForEach(notRecorded, id: \.self) { reason in
                Text(reason)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
        }
        .padding(Space.lg)
        .frame(width: Size.infoPopover, alignment: .leading)
    }

    /// ↑↓ moves the keyboard's place down the list, column by column; Space
    /// opens the entry it is on.
    private func moveOrOpen(_ key: KeyEquivalent, rows: [LibraryRowPresence]) -> Bool {
        guard !rows.isEmpty else { return false }
        switch key {
        case .upArrow, .downArrow:
            highlight.move(by: key == .upArrow ? -1 : 1, in: rows)
            return true
        case .space:
            guard let id = highlight.row else { return false }
            flow.openPopover = Self.rowKey(id)
            return true
        default:
            return false
        }
    }

    /// Makes sure the library is read before its list is drawn, then finds
    /// what the read saw and did not record.
    private func prepareLibrary() async {
        guard let workspace = flow.workspace else { return }
        if workspace.library.state == nil { await workspace.library.refresh() }
        guard let document = workspace.library.state?.snapshot.document else { return }
        notRecorded = await LibraryRowPresence.notRecorded(
            document: document, observations: workspace.device.observations, homeURL: flow.environment.homeURL)
    }

    private func rowArrival(_ index: Int) -> Animation? {
        guard motion.animatesDetails else { return motion.contentChange }
        return motion.contentChange?.delay(min(AgentMotion.rowStagger * Double(index), AgentMotion.rowStaggerCap))
    }

    static func rowKey(_ id: ArtifactID) -> String { "found.row.\(id.rawValue.uuidString)" }
    static let notRecordedKey = "found.notRecorded"

    /// A popover shown while the flow says it is open, so ⎋ closes it first.
    private func popoverBinding(_ key: String) -> Binding<Bool> {
        Binding {
            flow.openPopover == key
        } set: { shown in
            if shown {
                flow.openPopover = key
            } else if flow.openPopover == key {
                flow.openPopover = nil
            }
        }
    }
}

/// Where the keyboard is on Your library's list (S06): the row the soft
/// highlight is on. The flow keeps it, so the list draws it wherever it is
/// moved from, and scrolls to it.
@MainActor @Observable
final class LaunchpadFoundHighlight {
    private(set) var row: ArtifactID?

    /// The one `flow` keeps for its Your library.
    static func of(_ flow: LaunchpadFlow) -> LaunchpadFoundHighlight {
        flow.model(for: .found) { LaunchpadFoundHighlight() }
    }

    /// ↑ (`step` -1) or ↓ (+1) along `rows`, in the order the card fills
    /// them: down the first column, then the second. The first press lands
    /// on the first row, and either end holds.
    func move(by step: Int, in rows: [LibraryRowPresence]) {
        guard !rows.isEmpty else { return }
        let index = row.flatMap { id in rows.firstIndex { $0.id == id } }.map { $0 + step } ?? 0
        row = rows[min(max(index, 0), rows.count - 1)].id
    }

    /// A row clicked: the keyboard's place moves there too.
    func select(_ id: ArtifactID) {
        row = id
    }
}

/// One entry's popover on Your library: a skill's copies, each folder with
/// the apps that read it and how many files it holds; anything else, the
/// apps that hold it; and Check again, which reads those apps again.
struct LaunchpadFoundRowPopover: View {
    let row: LibraryRowPresence
    let copies: [ObservedSkillCopy]
    let home: URL
    /// Whether the copies' files have been counted yet. Until they are, no
    /// count is shown, rather than one that says they were not counted.
    var isMeasured = true
    var isChecking = false
    var canCheck = true
    let checkAgain: () -> Void

    var body: some View {
        let found = LaunchpadCopy.Found.self
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(row.name)
                .font(AgentFont.heading)
            if row.kind == .skill, !copies.isEmpty {
                ForEach(copies) { copy in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(PathDisplay.abbreviatingHome(copy.path, home: home))
                            .font(AgentFont.mono)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        let readBy = found.readBy(LaunchpadCopy.list(copy.readers.map(\.rawValue)))
                        let files = isMeasured ? copy.fileCount.map(found.files) ?? found.filesUnknown : nil
                        Text([readBy, files].compactMap { $0 }.joined(separator: LaunchpadCopy.Reads.tallySeparator))
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(row.apps.isEmpty ? found.heldByNone : found.heldBy(LaunchpadCopy.list(row.apps.map(\.rawValue))))
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            }
            Button(isChecking ? found.checkingAgain : found.checkAgain, action: checkAgain)
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(!canCheck)
        }
        .padding(Space.lg)
        .frame(width: Size.infoPopover, alignment: .leading)
    }
}

extension StageLayout.Found {
    /// The list's head, and a row's first line.
    static let sectionHead: CGFloat = 16
    static let nameLine: CGFloat = 18
    /// How many rows a column shows before the list scrolls: four, so the
    /// list ends at y 544.
    static let visibleRows = 4
    /// The keyboard's place on a row, inset from its edges.
    static let rowHighlightInset = EdgeInsets(top: Space.xxs, leading: Space.sm, bottom: Space.xxs, trailing: Space.sm)
}
