import AgentToolingCore
import SwiftUI

/// Let your apps ask Agent Tooling (S11).
///
/// What Agent Tooling's own connection lets an app do, in two lists: what it
/// can look up, and what it can only ask for. Then one row per app, in the
/// app order: a checkbox, the app's mark, and the exact command it would run,
/// or why it has none. The primary records the choice for this Mac and opens
/// the review of everything the setup decided; nothing reaches an app until
/// that review installs. On Join's detour the review returns to You joined.
struct LaunchpadAskScreen: LaunchpadScreen {
    let flow: LaunchpadFlow
    @FocusState private var listFocused: Bool

    init(flow: LaunchpadFlow) {
        self.flow = flow
    }

    var body: some View {
        let model = AgentToolingHookUp.of(flow)
        // Under the review panel only the cards' edges show beside it, in the
        // 16 pt strips: the header, the fine print and what the cards hold
        // would show there cut off.
        let isUnderPanel = Self.isUnderPanel(flow)
        VStack(alignment: .leading, spacing: 0) {
            StageHeader(
                .page, eyebrow: LaunchpadCopy.Helper.askEyebrow, title: LaunchpadCopy.Helper.askTitle,
                subtitle: LaunchpadCopy.Helper.askSubtitle
            )
            .opacity(isUnderPanel ? 0 : 1)
            LaunchpadAskExplainer(hidesContent: isUnderPanel)
            apps(model, hidesContent: isUnderPanel)
                .padding(.top, Space.xl)
            LaunchpadAskCaption(model: model, moveToApplications: { LaunchpadMoveModel.open(from: flow) })
                .padding(.top, Space.md)
                .opacity(isUnderPanel ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(isUnderPanel)
        .task { await model.load(decisions: flow.decisions) }
    }

    /// Whether the review panel is up over this screen, so only its cards'
    /// edges show.
    static func isUnderPanel(_ flow: LaunchpadFlow) -> Bool {
        flow.presentedReview != nil
    }

    private func apps(_ model: AgentToolingHookUp, hidesContent: Bool) -> some View {
        let rows = model.rows
        let available = model.unavailable == nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                AgentToolingAppMark(size: Size.tileSmall)
                StageListLabel(LaunchpadCopy.Helper.addTo)
            }
            .padding(.horizontal, Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: StageLayout.Ask.appsHeader)
            .hairlineBottom()
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                LaunchpadAskRow(row: row, isFocused: model.focused == row.client) {
                    model.toggle(row.client)
                    listFocused = true
                }
                .opacity(available ? 1 : Opacity.unavailable)
                // The separator is drawn over the row's top edge, so it adds
                // no height and every row keeps its own.
                .overlay(alignment: .top) {
                    if index > 0 { Hairline(indent: StageLayout.Ask.rowIndent) }
                }
            }
        }
        .opacity(hidesContent ? 0 : 1)
        .stageCard()
        .disabled(!available || model.isRecording)
        .focusable(available)
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) {
            model.moveFocus(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveFocus(by: 1)
            return .handled
        }
        .onKeyPress(.space) {
            guard let focused = model.focused else { return .ignored }
            model.toggle(focused)
            return .handled
        }
        .onChange(of: listFocused) { _, focused in
            if !focused { model.focused = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LaunchpadCopy.Helper.addTo)
    }

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let model = AgentToolingHookUp.of(flow)
        return StageFooterSpec(
            primary: .init(title: model.primaryTitle, isEnabled: !model.isRecording) { model.review(in: flow) })
    }

    /// Passed over when no app is managed here: there is nothing to connect.
    static func skipReason(_ context: LaunchpadTransitionContext) -> String? {
        LaunchpadCopy.Helper.skippedNoApps
    }
}

// MARK: - The explainer

/// What an app can look up beside what it can only ask for, each list led by
/// its glyph and count, its items in two columns.
private struct LaunchpadAskExplainer: View {
    /// Under the review panel: the card's edges only.
    var hidesContent = false

    var body: some View {
        StageTwoColumnCard(hidesContent: hidesContent) {
            cell(
                symbol: "eye", label: LaunchpadCopy.Helper.canLookUp(AgentToolingConnection.lookUpTools.count),
                items: AgentToolingConnection.lookUpTools.map(\.words))
        } trailing: {
            cell(
                symbol: "text.bubble", label: LaunchpadCopy.Helper.canOnlyAsk(AgentToolingConnection.askTools.count),
                items: AgentToolingConnection.askTools.map(\.words), caption: LaunchpadCopy.Helper.queuedRequest)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LaunchpadCopy.Helper.explainerLabel)
    }

    private func cell(symbol: String, label: String, items: [String], caption: String? = nil) -> some View {
        let half = (items.count + 1) / 2
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Image(systemName: symbol)
                    .font(.system(size: StageLayout.Ask.headGlyph))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                StageListLabel(label)
            }
            HStack(alignment: .top, spacing: Space.xl) {
                column(Array(items.prefix(half)))
                column(Array(items.dropFirst(half)))
            }
            .padding(.top, Space.md)
            if let caption {
                Text(caption)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    .padding(.top, Space.md)
            }
        }
        .padding(.top, StageLayout.Ask.cellTop)
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.lg)
        // Inside the card, so the card itself is at least the explainer's
        // height (y 140–272), whatever its lists need.
        .frame(maxWidth: .infinity, minHeight: StageLayout.Ask.explainerHeight, alignment: .topLeading)
    }

    private func column(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: StageLayout.Well.captionLine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - One app

/// Shows each client's available connection action. Manual registrations are
/// read-only. An owned connection can be unchecked to review its removal; the
/// command label changes accordingly. Unavailable clients have no checkbox.
private struct LaunchpadAskRow: View {
    let row: AgentToolingHookUp.Row
    let isFocused: Bool
    let toggle: () -> Void
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.lg) {
            leading
                .frame(width: StageLayout.Ask.checkSlot)
            HStack(spacing: Space.lg) {
                mark
                if row.isQuiet {
                    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                        Text(row.client.rawValue)
                            .font(AgentFont.bodyMedium)
                            .foregroundStyle(.secondary)
                        Text(row.status.words ?? "")
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(row.client.rawValue)
                            .font(AgentFont.bodyMedium)
                            .lineLimit(1)
                        detail
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { if row.canTick { toggle() } }
            // A row that can be ticked is its checkbox to VoiceOver, which
            // says the name and, as its hint, the command.
            .accessibilityHidden(row.canTick)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .frame(minHeight: row.isQuiet ? Size.rowHeight : Size.rowHeightTall)
        .softHighlight(
            isFocused && row.canTick,
            inset: EdgeInsets(top: Space.xxs, leading: Space.sm, bottom: Space.xxs, trailing: Space.sm)
        )
        // A tick and the keyboard's place change at selection; under Reduce
        // Motion they cross at quick, and a still draws the end.
        .animation(motion.resolved(reduceMotion: reduceMotion).contentChange, value: row.isTicked)
        .animation(motion.resolved(reduceMotion: reduceMotion).contentChange, value: isFocused)
        .help(row.command ?? "")
        .modifier(LaunchpadAskRowAccessibility(row: row))
    }

    @ViewBuilder private var leading: some View {
        if row.canTick {
            Toggle(isOn: Binding(get: { row.isTicked }, set: { _ in toggle() })) {
                Text(row.client.rawValue)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .focusable(false)
            .accessibilityLabel(row.client.rawValue)
            .accessibilityHint([row.status.words, row.command].compactMap(\.self).joined(separator: ". "))
        } else if row.showsConnectedGlyph {
            StatusGlyph(state: .healthy, size: Size.glyph)
        } else {
            Color.clear.frame(height: Size.glyph)
        }
    }

    @ViewBuilder private var mark: some View {
        if row.status == .notFound {
            AbsentMark(size: Size.symbol, lineWidth: Hairline.ring)
        } else {
            ClientBrandIcon(client: row.client, size: Size.symbol)
                .opacity(row.isTicked || row.showsConnectedGlyph ? 1 : Opacity.inactive)
        }
    }

    @ViewBuilder private var detail: some View {
        switch row.status {
        case .ready:
            command
        case .alreadyConnected(provenOurs: true) where row.canTick && !row.isTicked:
            command
        case .connectedElsewhere(_, let proven):
            Text(row.status.words ?? "")
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !proven {
                Text(LaunchpadCopy.Helper.notOurs)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        default:
            Text(row.status.words ?? "")
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The command on one line: the whole of it when it fits, otherwise the
    /// longest form that does, with the middle of the helper's path elided.
    @ViewBuilder private var command: some View {
        if row.commandLines.isEmpty {
            EmptyView()
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(row.commandLines, id: \.self) { line in
                    Text(line)
                        .font(AgentFont.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// A row with nothing to tick is one phrase to VoiceOver: "Kiro CLI, not
/// found on this Mac". One that can be ticked is its checkbox.
private struct LaunchpadAskRowAccessibility: ViewModifier {
    let row: AgentToolingHookUp.Row

    func body(content: Content) -> some View {
        if row.canTick {
            content.accessibilityElement(children: .contain)
        } else {
            let state = row.status.words ?? row.command
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.map { LaunchpadCopy.Helper.rowLabel(row.client.rawValue, $0) } ?? row.client.rawValue)
        }
    }
}

// MARK: - The caption

/// Why the rows start as they do and where the apps find Agent Tooling; or,
/// when this copy cannot hand out its helper, why, with the move when it is
/// offered.
private struct LaunchpadAskCaption: View {
    let model: AgentToolingHookUp
    let moveToApplications: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            switch model.unavailable {
            case .outsideApplications(let offersMove):
                HStack(spacing: Space.md) {
                    Text(LaunchpadCopy.Helper.moveFirst)
                        .wrapsLines()
                    if offersMove {
                        Button(LaunchpadCopy.Helper.moveToApplications, action: moveToApplications)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            case .developmentBuild:
                Text(LaunchpadCopy.Helper.noHelper)
                    .wrapsLines()
            case nil:
                let answered = model.startingTicksSentence.map { $0 + " " } ?? ""
                HelperBalancedCaption(
                    [
                        .init(text: answered + LaunchpadCopy.Helper.findsItAt + " "), .init(text: model.bundlePath, isPath: true),
                        .init(text: LaunchpadCopy.Helper.ifItMoves),
                    ], maxWidth: StageLayout.Grid.contentWidth, alignment: .leading)
            }
            if let error = model.errorMessage {
                NoteLine(symbol: "exclamationmark.triangle.fill", text: error, alignment: .leading)
            }
        }
        .font(AgentFont.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Layout

extension StageLayout.Ask {
    /// The explainer's cells start 14 under the card's top edge.
    static let cellTop: CGFloat = 14
    /// The glyph before each explainer list's label.
    static let headGlyph: CGFloat = 11
    /// The checkbox column: the row's marks line up past it.
    static let checkSlot: CGFloat = 14
}
