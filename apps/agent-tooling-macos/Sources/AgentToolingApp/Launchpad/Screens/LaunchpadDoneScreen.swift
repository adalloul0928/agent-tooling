import AgentToolingCore
import SwiftUI

/// Shows observed setup outcomes and remaining work. Re-audits changed state
/// before enabling hand-off so the finished progress record matches Checkup.
/// The record saves checklist rows, ticks, and evidence together.
struct LaunchpadDoneScreen: LaunchpadScreen {
    let flow: LaunchpadFlow

    init(flow: LaunchpadFlow) {
        self.flow = flow
    }

    var body: some View {
        let model = Self.model(flow)
        Group {
            if let inputs = LaunchpadDoneSummary.inputs(flow, model: model) {
                LaunchpadDoneContent(summary: LaunchpadDoneSummary(inputs))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.appear(flow) }
    }

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let isReady = model(flow).auditSettled
        return StageFooterSpec(
            later: .none,
            secondary: .init(title: LaunchpadCopy.Done.openCheckup, isEnabled: isReady) { finish(flow, handOffTo: .checkup) },
            primary: .init(title: LaunchpadCopy.Footer.goToHome, isEnabled: isReady) { finish(flow, handOffTo: .overview) })
    }

    /// What Done keeps while it is on screen.
    static func model(_ flow: LaunchpadFlow) -> LaunchpadDoneModel {
        flow.model(for: .done) { LaunchpadDoneModel() }
    }

    /// Writes the finished record, with Home's rows, the ones done in setup
    /// ticked and what the card needs, then hands off to `section`. Nothing
    /// happens until what Done reads as it appears is in.
    static func finish(_ flow: LaunchpadFlow, handOffTo section: AppSection) {
        let model = model(flow)
        guard model.auditSettled else { return }
        guard let inputs = LaunchpadDoneSummary.inputs(flow, model: model) else {
            flow.finish(handOffTo: section)
            return
        }
        let summary = LaunchpadDoneSummary(inputs)
        flow.finish(handOffTo: section, items: summary.items, ticks: summary.ticks, evidence: summary.evidence)
    }
}

/// Done's layout, from the top of the content slot: the bookend well, the
/// title and its line, What happened beside Left for later, and the key
/// strip on the slot's bottom edge. Drawn from a summary alone, so the
/// gallery draws the fragment's own moment.
struct LaunchpadDoneContent: View {
    let summary: LaunchpadDoneSummary
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilesShown = false

    var body: some View {
        let resolved = motion.resolved(reduceMotion: reduceMotion)
        VStack(spacing: 0) {
            HeroWell(
                height: StageLayout.Well.doneHeight, topInset: StageLayout.Done.tileTop,
                accessibilitySummary: summary.tilesLabel
            ) { client in
                if let tile = summary.tiles.first(where: { $0.client == client }) {
                    DoneTileColumn(tile: tile)
                }
            }
            // The tiles come back already lit: they fade in, and never light
            // again.
            .opacity(tilesShown || resolved != .full ? 1 : 0)

            Text(summary.title)
                .font(AgentFont.hero)
                .contentTransition(resolved == .full ? .numericText() : .identity)
                .lineLimit(1)
                .frame(height: StageLayout.Header.heroTitleLine)
                .padding(.top, StageLayout.Done.titleGap)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            Text(summary.subtitle)
                .font(AgentFont.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .balancesLines()
                .frame(maxWidth: Size.proseMaxWidth)
                .padding(.top, StageLayout.Done.subtitleGap)

            ScrollView {
                HStack(alignment: .top, spacing: StageLayout.Done.columnGap) {
                    happened.frame(width: StageLayout.Done.leftColumn, alignment: .topLeading)
                    later.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.top, StageLayout.Done.columnsGap)
            }
            // When the columns still outgrow the stage, the system's scroller
            // says there is more below the key strip.
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)

            DoneKeyStrip()
        }
        .animation(resolved.contentChange, value: summary.leftForLater.count)
        .onAppear {
            guard resolved == .full else { return }
            withAnimation(AgentMotion.selection) { tilesShown = true }
        }
    }

    private var happened: some View {
        VStack(alignment: .leading, spacing: StageLayout.Done.lineSpacing) {
            Eyebrow(LaunchpadCopy.Done.eyebrow)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, StageLayout.Done.labelGap)
            ForEach(Array(summary.happened.enumerated()), id: \.offset) { index, line in
                DoneOutcomeRow(line: line, index: index)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var later: some View {
        let copy = LaunchpadCopy.Done.self
        return VStack(alignment: .leading, spacing: StageLayout.Done.laterSpacing) {
            DoneColumnLabel(
                label: copy.leftForLater(summary.leftForLater.count),
                qualifier: summary.suggestions > 0 ? copy.homeAdds(summary.suggestions) : nil
            )
            .contentTransition(motion.resolved(reduceMotion: reduceMotion) == .full ? .numericText() : .identity)
            .padding(.bottom, StageLayout.Done.labelGap)
            ForEach(summary.leftForLater, id: \.item) { later in
                DoneLaterCard(later: later)
            }
            DoneColumnLabel(label: copy.runsOnItsOwn, qualifier: copy.onlyWhileOpen)
                .padding(.top, StageLayout.Done.runsGap)
            DoneRunsBlock(runs: summary.runs)
        }
        .accessibilityElement(children: .contain)
    }
}
