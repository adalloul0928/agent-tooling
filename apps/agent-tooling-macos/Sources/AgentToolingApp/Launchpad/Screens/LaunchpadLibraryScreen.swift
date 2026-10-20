import AgentToolingCore
import SwiftUI

extension StageLayout.Library {
    /// A section's head: its title and its small buttons, a small button tall
    /// (`--at-button-h-small`).
    static let sectionHead: CGFloat = 19
    /// A chooser row's first line, which its checkbox, tile and marks centre
    /// on, and the room above it.
    static let nameLine: CGFloat = 18
    static let chooserTop: CGFloat = 10
    /// The caption under the chooser.
    static let captionLine: CGFloat = 14
}

/// Selects loose-skill copies and bundled starter tools for one library revision.
/// The copy chooser resolves differing client copies. Empty selections advance
/// without writing. Creating or pasting skills uses separate sheets. Rendering
/// runs no client commands and fetches no catalogs.
struct LaunchpadLibraryScreen: LaunchpadScreen {
    let flow: LaunchpadFlow
    @Environment(\.launchpadLibraryServices) private var services
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.availableClients) private var managedClients
    @State private var writing = false
    @State private var pasting = false
    @FocusState private var focus: LaunchpadLibraryAdditions.Focus?

    /// ⌘A: tick every skill and add.
    static let addAllShortcut = KeyboardShortcut("a", modifiers: .command)

    private typealias Copy = LaunchpadCopy.Library
    private typealias Layout = StageLayout.Library

    init(flow: LaunchpadFlow) {
        self.flow = flow
    }

    private var model: LaunchpadLibraryAdditions { LaunchpadLibraryAdditions.of(flow) }

    /// Fill and ring change at selection; under Reduce Motion, and in a
    /// still, at once.
    private var change: Animation? {
        motion.resolved(reduceMotion: reduceMotion) == .full ? AgentMotion.selection : nil
    }

    var body: some View {
        let model = self.model
        VStack(alignment: .leading, spacing: 0) {
            StageHeader(.page, eyebrow: Copy.eyebrow, title: Copy.title, subtitle: Copy.subtitle)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if model.showsSkills {
                        skills(model)
                            .padding(.bottom, Space.xl)
                    }
                    catalogs(model)
                    footnote(model)
                        .padding(.top, Space.md)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
        }
        .task {
            model.services = services
            await model.load()
        }
        // Back, or leaving for Home, while a skills.sh pick is fetched stops
        // the fetch, and nothing is written.
        .onDisappear { model.stopAdding() }
        .sheet(isPresented: $writing) {
            SkillEditorSheet(
                existingNames: model.existingNames, isBusy: model.isWriting, canWrite: model.canWrite,
                errorMessage: model.writeFailure, size: SheetSize.stageSheet, offersPlacementNext: false
            ) { draft, _ in
                Task { if await model.write(draft) { writing = false } }
            }
        }
        .sheet(isPresented: $pasting) {
            if let workspace = flow.workspace {
                PasteImportSheet(workspace: workspace) { artifactID, name in model.pasteSaved(artifactID, name: name) }
            }
        }
    }

    // MARK: Make your skills yours

    private func skills(_ model: LaunchpadLibraryAdditions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            skillsHead(model)
            if !model.rows.isEmpty || !model.leftAlone.isEmpty {
                skillsCard(model)
                    .padding(.top, Space.sm)
            }
        }
    }

    /// The section's head: its title, and ⌘A's button, or the one line that
    /// says there is nothing to make yours.
    private func skillsHead(_ model: LaunchpadLibraryAdditions) -> some View {
        HStack(spacing: Space.lg) {
            Text(Copy.makeYoursHeading)
                .font(AgentFont.heading)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.lg)
            if model.phase != .unloaded, model.phase != .loading, model.rows.isEmpty, model.leftAlone.isEmpty {
                Text(model.emptyLine)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !model.readyRows.isEmpty {
                Button {
                    model.addAll()
                } label: {
                    HStack(spacing: Space.xs) {
                        Text(model.addAllTitle)
                        KeyCombo(shortcut: Self.addAllShortcut)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .keyboardShortcut(Self.addAllShortcut)
                .disabled(!model.canAddAll)
            }
        }
        .frame(height: Layout.sectionHead)
    }

    /// One card of rows, each after the first under a hairline that starts
    /// at its text.
    private func skillsCard(_ model: LaunchpadLibraryAdditions) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                Group {
                    // A row that was added or refused has nothing left to
                    // choose: it says how it went on the tall row's line.
                    if row.sameness == .different, row.state == .ready || row.state == .adding {
                        chooserRow(row, model)
                    } else {
                        tallRow(row, model)
                    }
                }
                .modifier(KeyboardRow(row: row.id, model: model, focus: $focus))
                .overlay(alignment: .top) {
                    // The soft highlight stands on its own, without the
                    // hairlines either side of it.
                    if index > 0, focus != .row(row.id), focus != .row(model.rows[index - 1].id) {
                        Hairline(indent: Layout.rowIndent)
                    }
                }
            }
            ForEach(Array(model.leftAlone.enumerated()), id: \.element.id) { index, group in
                leftAloneRow(group)
                    .overlay(alignment: .top) {
                        if index > 0 || !model.rows.isEmpty { Hairline(indent: Layout.rowIndent) }
                    }
            }
        }
        .stageCard()
        .animation(change, value: model.rows)
    }

    private func tallRow(_ row: LaunchpadLibraryAdditions.SkillRow, _ model: LaunchpadLibraryAdditions) -> some View {
        HStack(spacing: Space.lg) {
            checkbox(row, model)
            KindTile(kind: .skill, size: Size.tile)
            // The words take the row's width up to the marks, so a refusal
            // wraps only where it has to.
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(row.name)
                    .font(AgentFont.bodySemibold)
                    .lineLimit(1)
                detail(row, model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: Space.lg)
            marks(row, model)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Size.rowHeightTall)
    }

    private func chooserRow(_ row: LaunchpadLibraryAdditions.SkillRow, _ model: LaunchpadLibraryAdditions) -> some View {
        HStack(alignment: .top, spacing: Space.lg) {
            checkbox(row, model)
                .frame(height: Layout.nameLine)
            KindTile(kind: .skill, size: Size.tile)
                .frame(height: Layout.nameLine)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.md) {
                    Text(row.name)
                        .font(AgentFont.bodySemibold)
                        .lineLimit(1)
                        .layoutPriority(1)
                    detail(row, model)
                }
                .frame(height: Layout.nameLine)
                CopyChooser(
                    label: Copy.chooserLabel(row.name), options: model.options(for: row),
                    selection: model.chosenCopy(for: row)?.path, isEnabled: row.state == .ready && model.phase == .ready
                ) { path in
                    model.choose(path, for: row.id)
                }
                .padding(.top, Space.md)
                chooserCaption(row, model)
                    .padding(.top, Space.sm)
            }
            // Up to the marks, so the caption is cut by nothing but them.
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: Space.lg)
            marks(row, model)
                .frame(height: Layout.nameLine)
        }
        .padding(.top, Layout.chooserTop)
        .padding(.bottom, Space.md)
        .padding(.horizontal, Space.xl)
        // The drawn 108 holds two copies side by side; each further row of
        // copies, and a refusal that takes a second line, makes it taller.
        .frame(
            minHeight: Layout.chooserRow + StageLayout.CopyChooser.extraHeight(forCopies: row.copies.count),
            alignment: .top)
    }

    /// Under the chooser: what happens to the copies not chosen, or, while a
    /// copy the library would not take is chosen, why.
    @ViewBuilder private func chooserCaption(_ row: LaunchpadLibraryAdditions.SkillRow, _ model: LaunchpadLibraryAdditions)
        -> some View
    {
        if let refusal = model.copyRefusal(for: row) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AgentTheme.warning)
                Text(refusal)
                    .lineLimit(2)
            }
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .frame(minHeight: Layout.captionLine, alignment: .leading)
            .accessibilityHidden(true)
        } else {
            Text(model.chooserCaption(for: row))
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: Layout.captionLine, alignment: .leading)
        }
    }

    private func checkbox(_ row: LaunchpadLibraryAdditions.SkillRow, _ model: LaunchpadLibraryAdditions) -> some View {
        Toggle(isOn: Binding(get: { model.isTicked(row) }, set: { _ in model.toggle(row.id) })) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            // The box itself is a status glyph wide; the system adds a margin
            // around it that would push the row's tile and words off their
            // column.
            .frame(width: Size.glyph, height: Size.glyph)
            .disabled(row.state != .ready || model.phase != .ready)
            .accessibilityLabel(model.accessibilityLabel(for: row))
    }

    /// The line under a row's name, or beside it on a chooser row: its apps
    /// and where it is, then how Add went for it.
    @ViewBuilder private func detail(_ row: LaunchpadLibraryAdditions.SkillRow, _ model: LaunchpadLibraryAdditions) -> some View {
        let detail = model.detail(for: row)
        Group {
            switch row.state {
            case .adding:
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.mini)
                    Text(detail.clause)
                }
            case .added:
                HStack(spacing: Space.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AgentTheme.ok)
                        .transition(.symbolEffect(.drawOn))
                    Text(detail.clause)
                }
            case .refused:
                // A refusal takes the line's room and a second line under
                // it, so its words are never cut short.
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AgentTheme.warning)
                    Text(detail.clause)
                        .lineLimit(2)
                }
            case .ready:
                Text(Self.clause(detail.clause, path: detail.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(AgentFont.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .id(row.state)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    /// "Only in Claude Code · ~/.claude/skills/release-notes", the path in
    /// mono.
    private static func clause(_ clause: String, path: String?) -> AttributedString {
        var text = AttributedString(clause)
        guard let path else { return text }
        text += AttributedString(" · ")
        var mono = AttributedString(path)
        mono.font = AgentFont.mono
        text += mono
        return text
    }

    /// The managed apps' marks, the empty ring where an app holds none of the
    /// skill's copies.
    private func marks(_ row: LaunchpadLibraryAdditions.SkillRow, _ model: LaunchpadLibraryAdditions) -> some View {
        HStack(spacing: Space.sm) {
            ForEach(managedClients) { client in
                if row.holders.contains(client) {
                    ClientBrandIcon(client: client, size: Size.brandMark)
                } else {
                    AbsentMark(size: Size.brandMark)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.marksLabel(for: row))
    }

    private func leftAloneRow(_ group: LaunchpadLibraryAdditions.LeftAlone) -> some View {
        HStack(spacing: Space.lg) {
            Color.clear
                .frame(width: Size.glyph, height: Size.glyph)
            KindTile(kind: .skill, size: Size.tile, ghost: true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(LaunchpadCopy.list(group.names))
                    .font(AgentFont.bodySemibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(Copy.keptInStep(by: group.manager))
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Size.rowHeightTall)
        .accessibilityElement(children: .combine)
    }

    // MARK: From your apps' catalogs

    private func catalogs(_ model: LaunchpadLibraryAdditions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            catalogsHead(model)
            if let note = model.offlineNote {
                Text(note)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    .padding(.top, Space.sm)
            }
            cards(model)
                .padding(.top, Space.sm)
        }
    }

    private func catalogsHead(_ model: LaunchpadLibraryAdditions) -> some View {
        HStack(spacing: Space.lg) {
            Text(Copy.catalogsHeading)
                .font(AgentFont.heading)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.lg)
            HStack(spacing: Space.md) {
                Button(Copy.writeYourOwn) { writing = true }
                Button(Copy.pasteCommand) { pasting = true }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!model.canWrite || model.phase != .ready)
        }
        .frame(height: Layout.sectionHead)
    }

    private func cards(_ model: LaunchpadLibraryAdditions) -> some View {
        HStack(alignment: .top, spacing: StageLayout.Catalog.gap) {
            ForEach(model.picks) { pick in
                CatalogCard(
                    art: pick.entry.kind == .plugin ? .package(pick.package.id) : .skill, name: pick.entry.name,
                    summary: model.summary(for: pick), source: model.source(for: pick), isPicked: model.isPicked(pick),
                    isEnabled: pick.state == .available && model.phase == .ready, isRefused: pick.isRefused,
                    accessibilityLabel: model.accessibilityLabel(for: pick)
                ) {
                    model.togglePick(pick.id)
                }
                .modifier(KeyboardCard(card: pick.id, model: model, focus: $focus))
            }
        }
        .animation(change, value: model.picks)
    }

    /// Under the cards: the fine print, or, after an Add that left
    /// something out, why, in its place: each card's own sentence, and the
    /// whole Add's when it wrote nothing. The fine print is about section A,
    /// so it goes with it.
    @ViewBuilder private func footnote(_ model: LaunchpadLibraryAdditions) -> some View {
        if model.cardRefusals.isEmpty, model.failure == nil {
            if model.showsSkills {
                Text(model.finePrint)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
        } else {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(model.cardRefusals, id: \.self) { refusal in
                    NoteLine(symbol: "exclamationmark.triangle", text: refusal, alignment: .leading)
                }
                if let failure = model.failure {
                    NoteLine(symbol: "exclamationmark.triangle", text: failure, alignment: .leading)
                }
            }
        }
    }

    // MARK: The footer

    /// "Add 3 to library ↩", which adds and then moves on, or Continue ↩,
    /// which writes nothing and moves on at once. While the one revision is
    /// written it reads "Adding…" and takes no second press; while a skills.sh
    /// pick is fetched first, Stop ⎋ stops it, writing nothing.
    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let model = LaunchpadLibraryAdditions.of(flow)
        return StageFooterSpec(
            note: model.savedLine,
            later: model.isFetching ? .stop { model.stopAdding() } : .setUpLater,
            primary: .init(
                title: model.primaryTitle, isEnabled: model.phase != .adding,
                busyTitle: model.phase == .adding ? Copy.adding : nil
            ) {
                model.addAndMoveOn()
            })
    }
}

/// A row the keyboard can be on: Space ticks it, ↑↓ move to the row above or
/// below (and on to the cards), and ←→ choose a copy where the apps hold
/// different ones. The soft highlight shows where the keyboard is; nothing is
/// highlighted until it gets there.
private struct KeyboardRow: ViewModifier {
    let row: ArtifactID
    let model: LaunchpadLibraryAdditions
    let focus: FocusState<LaunchpadLibraryAdditions.Focus?>.Binding

    func body(content: Content) -> some View {
        content
            .softHighlight(
                focus.wrappedValue == .row(row),
                inset: EdgeInsets(top: Space.xxs, leading: Space.sm, bottom: Space.xxs, trailing: Space.sm)
            )
            .contentShape(Rectangle())
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused(focus, equals: .row(row))
            .onKeyPress(.space) {
                model.toggle(row)
                return .handled
            }
            .onKeyPress(.upArrow) { move(.up) }
            .onKeyPress(.downArrow) { move(.down) }
            .onKeyPress(.leftArrow) { model.stepCopy(of: row, by: -1) ? .handled : .ignored }
            .onKeyPress(.rightArrow) { model.stepCopy(of: row, by: 1) ? .handled : .ignored }
    }

    private func move(_ move: LaunchpadLibraryAdditions.Move) -> KeyPress.Result {
        guard let next = model.focus(after: .row(row), moving: move) else { return .ignored }
        focus.wrappedValue = next
        return .handled
    }
}

/// A card the keyboard can be on: Space picks it, ←→ move along the cards,
/// ↑ goes back to the rows. A focus ring, just outside the card, shows where
/// the keyboard is, apart from the soft highlight a picked card takes.
private struct KeyboardCard: ViewModifier {
    let card: String
    let model: LaunchpadLibraryAdditions
    let focus: FocusState<LaunchpadLibraryAdditions.Focus?>.Binding

    func body(content: Content) -> some View {
        content
            .overlay {
                if focus.wrappedValue == .card(card) {
                    RoundedRectangle(cornerRadius: Radius.lg + Hairline.focus, style: .continuous)
                        .strokeBorder(AgentTheme.selection, lineWidth: Hairline.focus)
                        .padding(-Hairline.focus)
                }
            }
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused(focus, equals: .card(card))
            .onKeyPress(.space) {
                model.togglePick(card)
                return .handled
            }
            .onKeyPress(.upArrow) { move(.up) }
            .onKeyPress(.leftArrow) { move(.left) }
            .onKeyPress(.rightArrow) { move(.right) }
    }

    private func move(_ move: LaunchpadLibraryAdditions.Move) -> KeyPress.Result {
        guard let next = model.focus(after: .card(card), moving: move) else { return .ignored }
        focus.wrappedValue = next
        return .handled
    }
}
