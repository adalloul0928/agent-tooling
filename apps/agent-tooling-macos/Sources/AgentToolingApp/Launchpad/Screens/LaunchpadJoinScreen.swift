import AgentToolingCore
import SwiftUI

extension StageLayout.Join {
    /// The read count's line: the strip's left column and the gap before
    /// the tiles. The fragment sets the count on one line that runs a few
    /// points into that gap ("Reads 9 places and runs 8 commands here" is
    /// wider than the 220 column); a longer count wraps.
    static let readCountWidth: CGFloat = about + Space.xl
    /// The What it reads… popover: Codex and Claude Code side by side.
    static let popoverWidth: CGFloat = 424
    /// The brand mark beside an app's name in the popover.
    static let popoverMark: CGFloat = 13
}

/// Shows read scope and remote checks before joining. Fresh ⌘Return starts the
/// join; Escape stops it only before registration. Failures offer retry or Finish
/// joining when a store already exists. Completed joins advance to arrivals.
struct LaunchpadJoinScreen: LaunchpadScreen {
    let flow: LaunchpadFlow
    private let model: LaunchpadJoin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(flow: LaunchpadFlow) {
        self.flow = flow
        model = Self.join(for: flow)
    }

    var body: some View {
        if flow.isPostCommit {
            // Joined already: a launch found this Mac's record still at Join,
            // because the app ended between the library record and its
            // cursor. The form is not shown.
            Color.clear.task { await model.carryOn(flow: flow) }
        } else {
            form
        }
    }

    private var form: some View {
        let copy = LaunchpadCopy.Join.self
        return VStack(alignment: .leading, spacing: 0) {
            StageHeader(.page, eyebrow: copy.eyebrow, title: copy.title, subtitle: copy.subtitle)
            AppsStrip(model: model, flow: flow)
            RepositoryFields(
                address: Binding(get: { model.address }, set: { model.update(address: $0) }),
                branch: Binding(get: { model.branch }, set: { model.update(branch: $0) }), isLocked: !model.isEditable,
                focusesAddress: model.isEditable,
                onSubmit: {
                    // ↩ in a field: where only ⌘↩ joins, the keycaps say so.
                    if LaunchpadStageView.footer(for: flow).primary?.key == .commandReturn { flow.showCommandReturnHint() }
                }
            )
            .padding(.top, Space.xl)
            AddressHelp(problem: model.addressProblem, isEmpty: model.address.isEmpty) { model.useSuggestion() }
                .padding(.top, Space.sm)
                .padding(.leading, StageLayout.Macs.helpIndent)
            Group {
                if let banner = model.banner ?? Self.checkBanner(model) {
                    StageBanner(title: banner.title, message: banner.message)
                } else {
                    Text(copy.consent(mac: model.deviceName.isEmpty ? nil : model.deviceName))
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
            }
            .padding(.top, Space.lg)
            ProgressCard(model: model)
                .padding(.top, Space.xl)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The rows make room for a banner at the stage's content change:
        // selection, or quick under Reduce Motion, where the banner itself
        // only fades in (StageBanner).
        .animation(flow.environment.motion.resolved(reduceMotion: reduceMotion).contentChange, value: model.banner)
        .task { await model.load() }
        .onDisappear { model.stop() }
    }

    /// V08: the checks stopped at a problem with the repository as typed.
    private static func checkBanner(_ model: LaunchpadJoin) -> LaunchpadJoin.Banner? {
        guard let problem = model.checkProblem else { return nil }
        return .init(title: LaunchpadJoin.title(for: problem), message: problem.errorDescription ?? "")
    }

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let copy = LaunchpadCopy.Join.self
        let model = join(for: flow)
        if flow.isPostCommit {
            return StageFooterSpec(
                later: .none,
                primary: .init(title: LaunchpadCopy.Footer.continue) { Task { await model.carryOn(flow: flow) } })
        }
        let later: StageFooterSpec.Later =
            switch model.phase {
            case .joining: .stop({ model.stop() })
            case .finishing, .joined: .none
            case .editing: .setUpLater
            }
        let primary: StageFooterSpec.Primary =
            switch model.primary {
            case .join(let name):
                .init(title: copy.joinAs(name), key: .commandReturn, commandReturnHint: .join) { model.join(flow: flow) }
            case .notReady(let name):
                .init(
                    title: name.map(copy.joinAs) ?? copy.joinUnnamed, key: .commandReturn, isEnabled: false,
                    commandReturnHint: .join
                ) {}
            case .tryAgain:
                .init(title: copy.tryAgain) { model.tryAgain() }
            case .finish:
                .init(title: copy.finishJoining, key: .commandReturn, commandReturnHint: .join) {
                    model.finishJoining(flow: flow)
                }
            case .busy:
                .init(title: copy.joiningBusy, isEnabled: false, busyTitle: copy.joiningBusy, showsKeycap: false) {}
            }
        return StageFooterSpec(later: later, primary: primary)
    }

    /// The join this stage keeps for the step, for as long as the stage is
    /// open: a Back to Welcome and a second visit find it as it was.
    static func join(for flow: LaunchpadFlow) -> LaunchpadJoin {
        flow.model(for: .join) { LaunchpadJoin(entry: flow.entry, environment: flow.environment) }
    }
}

// MARK: - The apps strip

/// What the join reads (left) and the four compact tiles in the app order
/// (right), each with its caption and its ⌘ key.
private struct AppsStrip: View {
    let model: LaunchpadJoin
    let flow: LaunchpadFlow

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        let manifest = model.manifest
        HStack(spacing: Space.xl) {
            VStack(alignment: .leading, spacing: 0) {
                StageListLabel(copy.appsLabel)
                    .padding(.bottom, Space.xs)
                Text(copy.readsOnlyThese)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // The count is one line, which may run into the gap before
                // the tiles; a count with more digits may take two.
                Text(copy.reads(places: manifest.placeCount, commands: manifest.commandCount))
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    .frame(width: StageLayout.Join.readCountWidth, alignment: .leading)
                    .padding(.top, Space.md)
                Button(copy.whatItReads) { flow.openPopover = Self.popover }
                    .buttonStyle(.link)
                    .font(AgentFont.captionMedium)
                    .padding(.top, Space.xxs)
                    .popover(isPresented: isShowingReads, arrowEdge: .bottom) {
                        ReadsPopover(manifest: manifest)
                    }
            }
            .frame(width: StageLayout.Join.about, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(Array(ClientKind.allCases.enumerated()), id: \.element) { index, client in
                    TileColumn(model: model, client: client, number: index + 1)
                        .frame(width: StageLayout.Join.tileColumn)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(copy.tilesLabel(chosen: ClientKind.allCases.filter(model.chosen.contains).map(\.rawValue)))
        }
        .padding(.vertical, Space.lg)
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stageCard()
    }

    private static let popover = "join.reads"

    private var isShowingReads: Binding<Bool> {
        Binding(
            get: { flow.openPopover == Self.popover },
            set: { flow.openPopover = $0 ? Self.popover : nil })
    }
}

/// One app on the strip: a toggle, ⌘1–⌘4, read when it is chosen and only
/// before anything is read.
private struct TileColumn: View {
    let model: LaunchpadJoin
    let client: ClientKind
    let number: Int

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        let found = model.found.contains(client)
        let chosen = model.chosen.contains(client)
        let shortcut = KeyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
        Button {
            guard !LaunchpadKeyRouter.isRepeatKeyEvent() else { return }
            model.toggle(client)
        } label: {
            VStack(spacing: 0) {
                StageAgentTile(client: client, state: tileState(found: found, chosen: chosen), compact: true)
                    .overlay {
                        // Read while it is managed: the ring stays with the
                        // spinner, as the second beat draws it.
                        if model.reading.contains(client) {
                            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                                .strokeBorder(AgentTheme.selection.opacity(Opacity.selectedStroke), lineWidth: Hairline.ring)
                        }
                    }
                    .padding(.bottom, Space.sm)
                Text(found ? client.rawValue : copy.notFound(client.rawValue))
                    .font(found ? AgentFont.captionMedium : AgentFont.caption)
                    .foregroundStyle(found ? .primary : .secondary)
                    .lineLimit(1)
                KeyCombo(shortcut: shortcut)
                    .opacity(model.isEditable ? 1 : Opacity.inactive)
                    .padding(.top, Space.sm)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .accessibilityLabel(copy.tileLabel(client.rawValue, found: found, chosen: chosen))
        .accessibilityHint(model.isEditable ? copy.tileHint(KeyCombo.spoken(shortcut), chosen: chosen) : "")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func tileState(found: Bool, chosen: Bool) -> StageAgentTile.State {
        if model.read.contains(client) { return .read }
        if model.reading.contains(client) { return .reading }
        if found { return chosen ? .managed : .ghost }
        return chosen ? .absentManaged : .absent
    }
}

/// What the join reads, app by app, as S04's manifest lists it: each app's
/// places and commands, then how the apps sign in.
private struct ReadsPopover: View {
    let manifest: FirstReadManifest

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        VStack(alignment: .leading, spacing: Space.md) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Space.xl, alignment: .top), GridItem(.flexible(), alignment: .top)],
                alignment: .leading, spacing: Space.lg
            ) {
                ForEach(manifest.apps) { app in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack(spacing: Space.sm) {
                            ClientBrandIcon(client: app.client, size: StageLayout.Join.popoverMark)
                            Text(app.client.rawValue).font(AgentFont.bodySemibold)
                        }
                        .padding(.bottom, Space.xs)
                        StageListLabel(copy.readsList)
                        ForEach(app.places) { place in mono(place.display) }
                        StageListLabel(copy.runsList)
                            .padding(.top, Space.sm)
                        ForEach(app.commands) { command in mono(command.display) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(copy.signInList)
                    .font(AgentFont.captionSemibold)
                    .padding(.bottom, Space.xxs)
                ForEach(signInCommands, id: \.id) { command in mono(command.display) }
                ForEach(manifest.signIn.places) { place in
                    Text(place.display)
                        .font(AgentFont.monoMicro)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
                if let shell = shellCommand {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(shell.display).font(AgentFont.monoMicro)
                        Text(copy.shellVariablesOnly(AccountShellOverride.allCases.count)).font(AgentFont.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                Text(copy.fetchesAfter)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    .padding(.top, Space.xs)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(Space.lg)
        .frame(width: StageLayout.Join.popoverWidth, alignment: .leading)
    }

    private func mono(_ text: String) -> some View {
        Text(text)
            .font(AgentFont.monoMicro)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// The sign-in commands each app runs, before the login shell.
    private var signInCommands: [FirstReadManifest.Command] {
        manifest.signIn.commands.filter { $0.executableName != Self.shell }
    }

    private var shellCommand: FirstReadManifest.Command? {
        manifest.signIn.commands.first { $0.executableName == Self.shell }
    }

    private static let shell = "zsh"
}

// MARK: - The checks and the steps

/// Before joining beside Joining: the four checks and the five steps, split
/// by a hairline. When a check stopped the join from starting, the steps read
/// Not started.
private struct ProgressCard: View {
    let model: LaunchpadJoin

    var body: some View {
        let copy = LaunchpadCopy.Join.self
        StageTwoColumnCard {
            ProgressStepList(label: copy.beforeJoining, steps: Self.checks(model))
                .padding(.vertical, Space.lg)
                .padding(.horizontal, Space.xl)
        } trailing: {
            ProgressStepList(label: copy.joining, steps: Self.steps(model))
                .padding(.vertical, Space.lg)
                .padding(.horizontal, Space.xl)
        }
    }

    /// The four checks as the last run, or this one, left them.
    static func checks(_ model: LaunchpadJoin) -> [ProgressStep] {
        let copy = LaunchpadCopy.Join.self
        let check = model.check
        let current = check.checked == model.request
        let result = model.passed
        let problem = model.checkProblem
        let host = GitRemoteAddress.host(of: model.address)
        return GitRemotePreflight.Check.allCases.map { item in
            let state: GitRemotePreflight.CheckState? = current ? check.checks[item] : nil
            var title: String =
                switch item {
                case .gitInstalled: copy.gitInstalled
                case .reachable: copy.answered(host: host)
                case .holdsLibrary: result.map { copy.holdsLibrary(tools: $0.toolCount) } ?? copy.holdsLibrary
                case .readable: copy.buildCanRead
                }
            let shown: ProgressStep.State
            switch state {
            case .started?: shown = .running
            case .passed?: shown = .done
            case .failed?:
                shown = .failed
                if let problem { title = LaunchpadJoin.title(for: problem) }
            case nil: shown = .notChecked
            }
            return ProgressStep(id: "check-\(item.rawValue)", title: title, state: shown)
        }
    }

    /// The five steps, or Not started when the checks stopped the join.
    static func steps(_ model: LaunchpadJoin) -> [ProgressStep] {
        let copy = LaunchpadCopy.Join.self
        if model.phase == .editing, model.mode == .join, model.checkProblem != nil {
            return [ProgressStep(id: "not-started", title: copy.notStarted, state: .note)]
        }
        let tools = model.passed?.toolCount
        return WorkspaceJoin.Step.allCases.map { step in
            let title: String =
                switch step {
                case .reachingRepository: copy.reachingRepository
                case .readingLibrary: tools.map(copy.readingLibrary(tools:)) ?? copy.readingLibrary
                case .checkingApps: copy.checkingApps
                case .registering: copy.registering(model.joinName)
                case .sharing: copy.sharing
                }
            let state: ProgressStep.State =
                switch model.steps[step] ?? .waiting {
                case .waiting: .waiting(step.rawValue)
                case .running: .running
                case .done: .done
                case .failed: .failed
                }
            return ProgressStep(id: "step-\(step.rawValue)", title: title, state: state)
        }
    }
}
