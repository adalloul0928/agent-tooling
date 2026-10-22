import AgentToolingCore
import SwiftUI

extension StageLayout.Arrivals {
    /// The Rename… popover: this Mac's name in a system text field.
    static let renameWidth: CGFloat = 260
    /// The library glyph between the two Macs.
    static let libraryGlyph: CGFloat = Size.brandMark
}

/// Shows the joined library and changes available from other Macs after one sync
/// pass. Installation requires review; deferral leaves it on Home. The optional
/// local MCP setup returns here when complete.
struct LaunchpadArrivalsScreen: LaunchpadScreen {
    let flow: LaunchpadFlow

    init(flow: LaunchpadFlow) {
        self.flow = flow
    }

    var body: some View {
        if let model = Self.arrivals(for: flow) {
            ArrivalsContent(model: model, flow: flow)
        }
    }

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let copy = LaunchpadCopy.Join.self
        guard let model = arrivals(for: flow) else {
            return StageFooterSpec(primary: .init(title: LaunchpadCopy.Footer.continue) { flow.advance() })
        }
        let installLater = StageFooterSpec.Secondary(title: copy.installLater, help: copy.installLaterHelp) {
            flow.advance()
        }
        switch model.phase {
        case .checking:
            return StageFooterSpec(
                secondary: installLater, primary: .init(title: LaunchpadCopy.Footer.continue, isEnabled: false) {})
        case .ready where model.reviewProblem != nil:
            // What arrived is not known: it waits on Home, and the walk goes on.
            return StageFooterSpec(
                secondary: installLater, primary: .init(title: LaunchpadCopy.Footer.continue) { flow.advance() })
        case .ready where model.installCount == 0:
            return StageFooterSpec(primary: .init(title: LaunchpadCopy.Footer.continue) { flow.advance() })
        case .ready:
            return StageFooterSpec(
                secondary: installLater,
                primary: .init(title: copy.review(model.installCount)) {
                    flow.presentReview(model.review(), returnTo: nil)
                })
        }
    }

    /// The step's model, once the library exists. A join that just ran
    /// makes it first, with what the other Macs had published.
    static func arrivals(for flow: LaunchpadFlow) -> LaunchpadArrivals? {
        guard let workspace = flow.workspace else { return nil }
        return flow.model(for: .arrivals) { LaunchpadArrivals(workspace: workspace) }
    }

    /// Connect it here too: Let your apps ask, for this Mac, then back here.
    static func connectHere(_ flow: LaunchpadFlow) {
        flow.go(to: .ask)
    }
}

private struct ArrivalsContent: View {
    let model: LaunchpadArrivals
    let flow: LaunchpadFlow

    var body: some View {
        // Under the review panel only the cards' edges show beside it: their
        // words would show cut off in the slivers.
        let isUnderPanel = flow.presentedReview != nil
        VStack(spacing: 0) {
            MacsWell(model: model, flow: flow, isUnderPanel: isUnderPanel)
            Greeting(model: model, flow: flow)
                .padding(.top, Space.xl)
                .opacity(isUnderPanel ? 0 : 1)
            ArrivalsCard(model: model, flow: flow, isUnderPanel: isUnderPanel)
                .padding(.top, Space.xl)
                .layoutPriority(1)
            ForEach([model.passProblem, model.reviewProblem].compactMap(\.self), id: \.self) { problem in
                // The first pass did not run: what arrived is what the join
                // itself brought. Or the plan could not be made: nothing is
                // listed. Either way the line says why.
                NoteLine(symbol: "exclamationmark.triangle", text: problem, alignment: .leading)
                    .padding(.top, Space.md)
                    .opacity(isUnderPanel ? 0 : 1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(isUnderPanel)
        .task { await model.load() }
    }
}

/// The two Macs on one library: the other Mac, the library between them, and
/// this one, which lights as it appears.
private struct MacsWell: View {
    let model: LaunchpadArrivals
    let flow: LaunchpadFlow
    let isUnderPanel: Bool

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        let family = flow.environment.macModelFamily()
        let thisCaption = copy.thisMac(family: family, systemVersion: MacModel.systemMajorVersion())
        HStack(alignment: .top, spacing: 0) {
            MacTile(symbol: MacModel.symbol(forFamily: nil), name: model.otherMacName, caption: copy.otherMac)
                .frame(width: StageLayout.Arrivals.macColumn)
            VStack(spacing: Space.xs) {
                Image(systemName: "books.vertical")
                    .font(.system(size: StageLayout.Arrivals.libraryGlyph))
                Text(copy.sameLibrary(tools: model.toolCount))
                    .font(AgentFont.captionMedium)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.secondary)
            .frame(width: StageLayout.Arrivals.middle, height: Size.stageTile)
            MacTile(symbol: MacModel.symbol(forFamily: family), name: model.thisMacName, caption: thisCaption, lightsIn: true)
                .frame(width: StageLayout.Arrivals.macColumn)
        }
        .opacity(isUnderPanel ? 0 : 1)
        .padding(.top, Space.xxxl)
        .frame(maxWidth: .infinity)
        .frame(height: StageLayout.Well.macsHeight, alignment: .top)
        .background { WellSurface() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.macsLabel(other: model.otherMacName, this: model.thisMacName, tools: model.toolCount))
    }
}

/// "You joined as Cedar", how many of your own skills came across with
/// Rename…, and what each other Mac last published.
private struct Greeting: View {
    let model: LaunchpadArrivals
    let flow: LaunchpadFlow

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        VStack(spacing: 0) {
            Text(copy.joinedAs(model.thisMacName))
                .font(AgentFont.hero)
                .lineLimit(1)
                .frame(height: StageLayout.Header.heroTitleLine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            HStack(spacing: Space.xs) {
                Text(copy.skillsCameAcross(model.personalSkillCount))
                    .foregroundStyle(.secondary)
                RenameLink(model: model, flow: flow)
                    .disabled(!model.canRename)
            }
            .font(AgentFont.body)
            .padding(.top, Space.sm)
            ForEach(model.otherMacs) { mac in
                Text(model.line(for: mac, now: flow.environment.now()))
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
    }

}

/// Rename…: this Mac's name in a system text field, Cancel ⎋ and Rename ↩.
private struct RenameLink: View {
    let model: LaunchpadArrivals
    let flow: LaunchpadFlow
    @State private var draft = ""

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        Button(copy.rename) {
            draft = model.thisMacName
            flow.openPopover = Self.popover
        }
        .buttonStyle(.link)
        .popover(isPresented: isShowing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(copy.renameTitle).font(AgentFont.bodySemibold)
                TextField(copy.renameTitle, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit {
                        if model.canRename(to: draft) { rename() }
                    }
                if let problem = model.renameProblem {
                    Text(problem)
                        .font(AgentFont.caption)
                        .foregroundStyle(AgentTheme.failure)
                        .wrapsLines()
                }
                HStack(spacing: Space.md) {
                    Spacer(minLength: 0)
                    Button {
                        flow.openPopover = nil
                    } label: {
                        HStack(spacing: Space.sm) {
                            Text(copy.cancel)
                            KeyCombo(shortcut: .cancelAction)
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(action: rename) {
                        HStack(spacing: Space.sm) {
                            Text(copy.renameConfirm)
                            KeyCombo(shortcut: .defaultAction)
                        }
                        .environment(\.keycapOnAccent, true)
                    }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
                    // A name, and a new one: an empty or unchanged one
                    // renames nothing.
                    .disabled(!model.canRename(to: draft))
                }
                .controlSize(.small)
            }
            .padding(Space.lg)
            .frame(width: StageLayout.Arrivals.renameWidth, alignment: .leading)
            .onDisappear { model.dismissRenameProblem() }
        }
    }

    private func rename() {
        let name = draft
        Task {
            if await model.rename(to: name) { flow.openPopover = nil }
        }
    }

    private static let popover = "arrivals.rename"

    private var isShowing: Binding<Bool> {
        Binding(
            get: { flow.openPopover == Self.popover },
            set: { flow.openPopover = $0 ? Self.popover : nil })
    }
}

/// What the other Mac shares with every Mac: a heading with the policy line,
/// one row per arrival with where it goes, and Agent Tooling's own connection
/// under a full-width hairline.
private struct ArrivalsCard: View {
    let model: LaunchpadArrivals
    let flow: LaunchpadFlow
    let isUnderPanel: Bool
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                // While it is worked out, or when it could not be, the heading
                // names no count: an unknown is never zero.
                Text(
                    model.phase == .ready && model.reviewProblem == nil
                        ? copy.shares(model.otherMacName, tools: model.rows.count) : copy.whatIsShared(model.otherMacName)
                )
                .font(AgentFont.heading)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                HStack(spacing: Space.xs) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: Size.glyphSmall))
                        .accessibilityHidden(true)
                    Text(copy.policy)
                }
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xl)
            .frame(maxWidth: .infinity, minHeight: StageLayout.Arrivals.header, alignment: .leading)
            Hairline()
            switch model.phase {
            case .checking:
                HStack(spacing: Space.md) {
                    ProgressView().controlSize(.small)
                    Text(copy.checkingShared(model.otherMacName))
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Space.xl)
                .frame(maxWidth: .infinity, minHeight: Size.rowHeight, alignment: .leading)
            case .ready:
                // More arrivals than the stage has room for scroll inside the
                // card, under its heading and over Agent Tooling's own row.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                        ArrivalRow(row: row)
                            .modifier(Rise(index: index, isOn: animates && !risen))
                    }
                    ForEach(Array(model.leftOut.enumerated()), id: \.element.id) { index, item in
                        if !model.rows.isEmpty || index > 0 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                        LeftOutRow(item: item)
                    }
                }
                .scrollsWhenFull()
            }
            if let helper = model.helper {
                Hairline()
                HelperRow(helper: helper) { LaunchpadArrivalsScreen.connectHere(flow) }
                    .modifier(Rise(index: model.rows.count, isOn: animates && !risen))
            }
        }
        .opacity(isUnderPanel ? 0 : 1)
        .stageCard()
        // Shown again with what arrived already worked out, the rows are in
        // place; they rise each time it is worked out.
        .onAppear { risen = model.phase == .ready }
        .onChange(of: model.phase) { _, phase in
            switch phase {
            case .checking:
                risen = false
            case .ready:
                guard animates else {
                    risen = true
                    return
                }
                withAnimation(AgentMotion.selection) { risen = true }
            }
        }
    }

    private var animates: Bool { motion.resolved(reduceMotion: reduceMotion).animatesDetails }
}

/// A row rising 8 pt into place with its opacity, 40 ms after the one above.
private struct Rise: ViewModifier {
    let index: Int
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isOn ? 0 : 1)
            .offset(y: isOn ? AgentMotion.cardRise : 0)
            .animation(AgentMotion.selection.delay(Double(index) * AgentMotion.columnStagger), value: isOn)
    }
}

/// One arrival: its tile or artwork, its name over where it goes, the apps
/// as discs, and how many installs that is.
private struct ArrivalRow: View {
    let row: LaunchpadArrivals.Row

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        HStack(spacing: Space.lg) {
            if let packageID = row.packageID, row.kind == .plugin {
                ToolIdentityIcon(packageID: packageID, fallback: .plugin, size: Size.tile)
            } else {
                KindTile(kind: ToolingKind(row.kind), size: Size.tile)
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(row.name)
                    .font(AgentFont.bodyMedium)
                    .lineLimit(1)
                Text(copy.into(row.apps.map(\.rawValue)))
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.md)
            ArrivalDiscs(apps: row.apps)
            Text(copy.installs(row.apps.count))
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: StageLayout.Arrivals.count, alignment: .trailing)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Size.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(copy.into(row.apps.map(\.rawValue))), \(copy.installs(row.apps.count))")
    }
}

/// The apps an arrival goes into, as overlapping 20 pt discs in the app
/// order: each on a plate one step above the card, with a ring in the
/// card's colour where the next one tucks under it.
private struct ArrivalDiscs: View {
    let apps: [ClientKind]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: -(Size.tileSmall * Proportion.discOverlap)) {
            ForEach(apps) { client in
                ZStack {
                    Circle().fill(AgentTheme.plateOnCard)
                    Circle().strokeBorder(
                        HairlineStyle(base: colorScheme == .dark ? AgentTheme.hairlineStroke : AgentTheme.hairline),
                        lineWidth: Hairline.width)
                    ClientBrandIcon(client: client, size: Size.tileSmall * Proportion.discMark)
                }
                .frame(width: Size.tileSmall, height: Size.tileSmall)
                .background { Circle().fill(AgentTheme.controlBackground).padding(-Hairline.ring) }
            }
        }
        .accessibilityHidden(true)
    }
}

/// An arrival whose files are not in the library: left out, and why.
private struct LeftOutRow: View {
    let item: LaunchpadArrivals.LeftOut

    var body: some View {
        HStack(spacing: Space.lg) {
            KindTile(kind: ToolingKind(item.kind), size: Size.tile, ghost: true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(item.name)
                    .font(AgentFont.bodyMedium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(LaunchpadCopy.Join.noVerifiedCopy)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Size.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// Agent Tooling's own connection: where it is set up, and Connect it here
/// too while this Mac does not have it.
private struct HelperRow: View {
    let helper: LaunchpadArrivals.Helper
    let connect: () -> Void

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        HStack(spacing: Space.lg) {
            AgentToolingAppMark(size: Size.tile)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(copy.ownConnection)
                    .font(AgentFont.bodyMedium)
                    .lineLimit(1)
                Text(helper.line)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.md)
            if !helper.isSetUpHere {
                Button(copy.connectHereToo, action: connect)
                    .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Size.rowHeight)
        .accessibilityElement(children: .contain)
    }
}

extension ToolingKind {
    /// How an arrival's kind is drawn.
    fileprivate init(_ kind: ToolingItemKind) {
        switch kind {
        case .skill: self = .skill
        case .plugin: self = .plugin
        case .mcpServer: self = .mcpServer
        }
    }
}
