import AgentToolingCore
import SwiftUI

extension StageLayout.Matrix {
    /// The Where row: a regular control's height.
    static let whereRow: CGFloat = Size.glyphSlot + Space.xs
    /// From the Where row to the grid, and from the grid to its captions.
    static let gap: CGFloat = Space.lg
}

/// Put tools in apps (S10): one grid of what goes where, each tool this setup
/// brought into the library against each app this Mac manages, and the Where
/// control above it. Nothing is installed: Continue records the placements as
/// intent in one revision and the review after the next step installs them.
struct LaunchpadPlaceScreen: LaunchpadScreen {
    let flow: LaunchpadFlow
    private let model: LaunchpadPlacement?

    init(flow: LaunchpadFlow) {
        self.flow = flow
        model = Self.placement(for: flow)
    }

    var body: some View {
        let copy = LaunchpadCopy.Place.self
        VStack(alignment: .leading, spacing: 0) {
            StageHeader(.page, eyebrow: copy.eyebrow, title: copy.title, subtitle: copy.subtitle)
            if let model {
                PlaceContent(model: model, decisions: Self.decisions(for: flow))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model?.load(decisions: Self.decisions(for: flow)) }
    }

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let model = placement(for: flow)
        let note: String? =
            switch model?.phase {
            case .ready, .saving: model.map { LaunchpadCopy.Place.changesSoFar($0.changeCount) }
            case .loading, .failed, nil: nil
            }
        let isEnabled: Bool =
            switch model?.phase {
            case .ready: model?.canContinue ?? true
            case .failed, nil: true
            case .loading, .saving: false
            }
        return StageFooterSpec(
            note: note,
            primary: .init(title: LaunchpadCopy.Footer.continue, isEnabled: isEnabled) { proceed(flow) })
    }

    /// Nothing is placed when this Mac manages no app.
    static func skipReason(_ context: LaunchpadTransitionContext) -> String? {
        context.startedEmpty || context.managed.isEmpty ? LaunchpadCopy.Place.skippedNoApps : nil
    }

    /// The grid this stage keeps for the step, once the library exists.
    static func placement(for flow: LaunchpadFlow) -> LaunchpadPlacement? {
        guard let workspace = flow.workspace else { return nil }
        return flow.model(for: .place) { LaunchpadPlacement(workspace: workspace) }
    }

    /// What the grid works from: the walk's decisions, with every placement
    /// this setup saved before as its own. A first run keeps those in its
    /// record as it goes, and a walk relaunched or resumed past this step
    /// starts without the decisions that made them, so the record brings
    /// them back: the grid opens on them, going back changes only what this
    /// setup placed, and the record never loses one. A rerun's record is an
    /// earlier setup's, so nothing in it is this walk's to change.
    static func decisions(for flow: LaunchpadFlow) -> LaunchpadLibraryDecisions {
        var decisions = flow.decisions
        switch flow.entry {
        case .firstRun, .continueFirstRun, .finishJoin, .resume:
            let recorded = flow.progress?.record?.evidence.placedContributionIDs ?? []
            decisions.contributionIDs += recorded.filter { !decisions.contributionIDs.contains($0) }
        case .rerun, .revisit:
            break
        }
        return decisions
    }

    /// Continue: saves the grid, records what it placed, and moves on. A grid
    /// that could not be worked out places nothing and lets the walk go on.
    private static func proceed(_ flow: LaunchpadFlow) {
        guard let model = placement(for: flow) else {
            flow.advance()
            return
        }
        switch model.phase {
        case .failed:
            flow.advance()
        case .ready:
            let visit = model.visit
            let decisions = Self.decisions(for: flow)
            Task { @MainActor in
                guard let saved = await model.commit(decisions: decisions) else { return }
                // Only what the save decided: the rest of the decisions may
                // have changed while it saved.
                flow.decisions.placed = saved.placed
                flow.decisions.contributionIDs = saved.contributionIDs
                // A first run keeps its placements in the record as it goes,
                // so they never read as arrivals from another Mac; a rerun
                // writes the record only at Done. Every walk adds them to
                // the list this Mac keeps of its own, so a rerun left before
                // Done never reads them as arrivals either.
                switch flow.entry {
                case .firstRun, .continueFirstRun, .finishJoin, .resume:
                    flow.progress?.recordEvidence { $0.placedContributionIDs = saved.contributionIDs }
                case .rerun, .revisit:
                    break
                }
                let inLibrary = flow.workspace?.library.state.map { Set($0.snapshot.document.assignments.map(\.id)) }
                flow.progress?.recordPlacementsMadeHere(saved.contributionIDs, inLibrary: inLibrary)
                // The walk moves on only from where Continue was pressed:
                // Back, Set up later or leaving, asked for while it saved,
                // keep the walk where they put it.
                guard flow.step == .place, model.visit == visit, flow.pendingHandOff == nil, !flow.isConfirmingLeave
                else { return }
                flow.advance()
            }
        case .loading, .saving:
            break
        }
    }
}

/// Everything under the header: the Where row, the grid or its empty card,
/// and the captions, 12 under the grid.
private struct PlaceContent: View {
    let model: LaunchpadPlacement
    let decisions: LaunchpadLibraryDecisions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WhereRow(model: model, decisions: decisions)
                .frame(height: StageLayout.Matrix.whereRow)
            Group {
                switch model.phase {
                case .loading where model.items.isEmpty, .failed:
                    EmptyView()
                case .loading, .ready, .saving:
                    if model.items.isEmpty || model.apps.isEmpty {
                        emptyCard
                    } else {
                        PlacementMatrix(model: model)
                    }
                }
            }
            .padding(.top, StageLayout.Matrix.gap)
            captions
                .padding(.top, StageLayout.Matrix.gap)
            Spacer(minLength: 0)
        }
    }

    private var emptyCard: some View {
        Text(model.emptyText)
            .font(AgentFont.body)
            .foregroundStyle(.secondary)
            .wrapsLines()
            .padding(Space.xl)
            .frame(width: StageLayout.Grid.contentWidth, alignment: .leading)
            .stageCard()
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if case .failed(let sentence) = model.phase {
                NoteLine(symbol: "exclamationmark.triangle", text: sentence, alignment: .leading)
            } else {
                if let error = model.saveError {
                    NoteLine(symbol: "exclamationmark.triangle", text: error, alignment: .leading)
                }
                let showsGrid = !model.items.isEmpty && !model.apps.isEmpty
                if showsGrid, let library = model.libraryCaption { caption(library) }
                // With rows but no app to put them in, the card says why
                // already.
                if showsGrid || model.items.isEmpty {
                    ForEach(model.appCaptions, id: \.self) { caption($0) }
                }
                if showsGrid, model.takesOnlyWhatNamesIt { caption(LaunchpadCopy.Place.takesOnlyWhatNamesIt) }
                if showsGrid { caption(LaunchpadCopy.Place.reviewedNext) }
            }
        }
        .font(AgentFont.caption)
        .foregroundStyle(.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text).wrapsLines()
    }
}

/// Where: Every Mac, This Mac only or One project, and a line saying what
/// that means. One project needs a project this Mac tracks; until there is
/// one it cannot be chosen, and says why.
private struct WhereRow: View {
    let model: LaunchpadPlacement
    let decisions: LaunchpadLibraryDecisions

    var body: some View {
        let copy = LaunchpadCopy.Place.self
        HStack(spacing: Space.lg) {
            Text(copy.whereLabel)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            WorkspaceSegmentedPicker(copy.whereLabel, selection: scope) {
                Text(copy.everyMac).tag(LaunchpadPlacement.Scope.everyMac)
                Text(copy.thisMacOnly).tag(LaunchpadPlacement.Scope.thisMacOnly)
                Text(copy.oneProject).tag(LaunchpadPlacement.Scope.oneProject)
                    .selectionDisabled(model.projects.isEmpty)
                    .help(model.projects.isEmpty ? copy.trackProjectFirst : "")
            }
            .fixedSize()
            .disabled(model.phase != .ready)
            if model.scope == .oneProject {
                Menu(copy.chooseProject) {
                    ForEach(model.projects) { project in
                        Button(project.name) {
                            Task { await model.choose(project: project.id, decisions: decisions) }
                        }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
            Text(note)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var scope: Binding<LaunchpadPlacement.Scope> {
        Binding(
            get: { model.scope },
            set: { next in
                guard next != .oneProject || !model.projects.isEmpty else { return }
                Task { await model.choose(next, decisions: decisions) }
            })
    }

    private var note: String {
        let copy = LaunchpadCopy.Place.self
        switch model.scope {
        case .everyMac: return model.hasOtherMacs ? copy.everyMacOthers : copy.everyMacLater
        case .thisMacOnly: return copy.thisMacOnlyNote
        case .oneProject: return model.projectName.map(copy.forProject) ?? copy.trackProjectFirst
        }
    }
}
