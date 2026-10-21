import AgentToolingCore
import SwiftUI

extension StageLayout.Macs {
    /// The result card's height: three lines between its 16 pt insets.
    static let resultCard: CGFloat = 80
}

/// Connects and publishes this library through an app-owned Git checkout after
/// explicit ⌘Return confirmation. Blank addresses allow skipping. Failed external
/// checks can be retried; connected libraries show their current result.
struct LaunchpadMacsScreen: LaunchpadScreen {
    let flow: LaunchpadFlow

    init(flow: LaunchpadFlow) {
        self.flow = flow
    }

    var body: some View {
        let copy = LaunchpadCopy.Macs.self
        VStack(alignment: .leading, spacing: 0) {
            StageHeader(.page, eyebrow: copy.eyebrow, title: copy.title, subtitle: copy.subtitle)
            if let model = Self.connect(for: flow) {
                MacsContent(model: model, flow: flow)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let copy = LaunchpadCopy.Macs.self
        guard let model = connect(for: flow) else {
            return StageFooterSpec(primary: .init(title: copy.skipForNow) { flow.advance() })
        }
        switch model.phase {
        case .connected:
            return StageFooterSpec(primary: .init(title: LaunchpadCopy.Footer.continue) { model.proceed(flow: flow) })
        case .checking:
            return StageFooterSpec(later: .stop({ model.stop() }), primary: busy(copy.connecting))
        case .connecting:
            return StageFooterSpec(later: .none, primary: busy(copy.connecting))
        case .publishing:
            return StageFooterSpec(later: .none, primary: busy(copy.publishing))
        case .editing:
            if model.isEmpty || model.unavailableReason != nil {
                return StageFooterSpec(primary: .init(title: copy.skipForNow) { model.skip(flow: flow) })
            }
            if model.canTryAgain {
                return StageFooterSpec(
                    secondary: .init(title: copy.notNow) { model.skip(flow: flow) },
                    primary: .init(title: copy.tryAgain) { model.tryAgain() })
            }
            return StageFooterSpec(
                secondary: .init(title: copy.notNow) { model.skip(flow: flow) },
                primary: .init(
                    title: copy.connectAndShare, key: .commandReturn, isEnabled: model.canConnect, commandReturnHint: .connect
                ) {
                    model.connect(flow: flow)
                })
        }
    }

    /// The primary while Connect and share runs: its busy words, and no key.
    private static func busy(_ title: String) -> StageFooterSpec.Primary {
        .init(
            title: LaunchpadCopy.Macs.connectAndShare, isEnabled: false, busyTitle: title, showsKeycap: false, action: {})
    }

    /// The step's model, once the library exists.
    static func connect(for flow: LaunchpadFlow) -> LaunchpadSyncConnect? {
        guard let workspace = flow.workspace else { return nil }
        return flow.model(for: .macs) { LaunchpadSyncConnect(workspace: workspace, environment: flow.environment) }
    }
}

/// Everything under the header: the form card, the two columns, the warning
/// and, under it, the result or what stopped the connection.
private struct MacsContent: View {
    let model: LaunchpadSyncConnect
    let flow: LaunchpadFlow

    /// ↩ in a field: where only ⌘↩ connects, the keycaps say so; where ↩
    /// is the primary's (Skip for now), it is left to the primary.
    static func submitted(_ flow: LaunchpadFlow) {
        if LaunchpadStageView.footer(for: flow).primary?.key == .commandReturn { flow.showCommandReturnHint() }
    }
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let copy = LaunchpadCopy.Macs.self
        VStack(alignment: .leading, spacing: 0) {
            FormCard(model: model, onSubmit: { MacsContent.submitted(flow) })
            TravelsCard()
                .padding(.top, Space.xl)
            NoteLine(symbol: "lock.shield", text: copy.warning, alignment: .leading)
                .padding(.top, Space.lg)
            Group {
                if case .connected(let result) = model.phase {
                    ResultCard(model: model, result: result)
                        .transition(rise)
                } else if let failure = model.failure {
                    StageBanner(title: failure.title, message: failure.message)
                } else if let problem = model.checkProblem {
                    StageBanner(title: LaunchpadSyncConnect.title(for: problem), message: problem.errorDescription ?? "")
                } else if let unavailable = model.unavailableReason {
                    StageBanner(title: copy.couldNotConnect, message: unavailable)
                }
            }
            .padding(.top, Space.xl)
            Spacer(minLength: 0)
        }
        .animation(animation, value: model.phase)
        .task { await model.load() }
        .onDisappear { model.stop() }
    }

    /// The result card rises 8 pt with its opacity; under Reduce Motion it
    /// only fades, and a still draws it in place.
    private var rise: AnyTransition {
        motion.resolved(reduceMotion: reduceMotion).animatesDetails
            ? .opacity.combined(with: .offset(y: AgentMotion.cardRise)) : .opacity
    }

    private var animation: Animation? { motion.resolved(reduceMotion: reduceMotion).contentChange }
}

/// The address and Branch on one row, the line under the address, and this
/// Mac's name, with the labels beside their fields.
private struct FormCard: View {
    let model: LaunchpadSyncConnect
    /// ↩ in a field.
    let onSubmit: () -> Void

    var body: some View {
        let copy = LaunchpadCopy.Macs.self
        let isEditing = model.phase == .editing
        VStack(alignment: .leading, spacing: 0) {
            RepositoryFields(
                address: Binding(get: { model.address }, set: { model.update(address: $0) }),
                branch: Binding(get: { model.branch }, set: { model.update(branch: $0) }), isLocked: !isEditing,
                focusesAddress: isEditing, onSubmit: onSubmit)
            AddressHelp(problem: model.addressProblem, isEmpty: model.isEmpty) { model.useSuggestion() }
                .padding(.top, Space.sm)
                .padding(.leading, StageLayout.Macs.helpIndent)
            FormRow(copy.nameLabel) {
                StageField(
                    label: copy.nameLabel, text: Binding(get: { model.name }, set: { model.update(name: $0) }),
                    isLocked: !isEditing, onSubmit: onSubmit
                )
                .frame(width: Size.fieldShort)
                if let numbered = model.numberedName {
                    Text(copy.nameTaken(model.name.trimmingCharacters(in: .whitespacesAndNewlines), savedAs: numbered))
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
            }
            .padding(.top, Space.lg)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stageCard()
    }
}

/// The line under the address: "An HTTPS address" beside a green check once
/// it is one; why it cannot be used, with the HTTPS form to use instead, when
/// it is not; and nothing, holding its line, while the field is empty.
struct AddressHelp: View {
    let problem: GitRemoteProblem?
    let isEmpty: Bool
    let useSuggestion: () -> Void

    var body: some View {
        Group {
            if let problem {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    StageFieldHelp(.problem, problem.errorDescription ?? "")
                    if case .invalidAddress(let suggestion?, _) = problem {
                        // On a line of its own, under the words, so the
                        // address it offers is never broken.
                        Button(LaunchpadCopy.Macs.use(suggestion), action: useSuggestion)
                            .buttonStyle(.link)
                            .font(AgentFont.captionMedium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, Size.glyphSmall + Space.xs)
                    }
                }
            } else if !isEmpty {
                StageFieldHelp(.ok, LaunchpadCopy.Macs.httpsAddress)
            } else {
                Color.clear
                    .frame(height: StageLayout.Well.captionLine)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What travels beside what stays on this Mac: one card, split by a hairline,
/// each column a heading over three lines, each led by a 12 pt symbol in a
/// 16 pt slot.
private struct TravelsCard: View {
    var body: some View {
        let copy = LaunchpadCopy.Macs.self
        StageTwoColumnCard(trailingWidth: StageLayout.Macs.staysColumn) {
            column(
                copy.travelsTitle,
                [
                    ("books.vertical", copy.travelsLibrary), ("doc.text", copy.travelsSkillFiles),
                    ("laptopcomputer", copy.travelsStatus),
                ])
        } trailing: {
            column(
                copy.staysTitle,
                [("gearshape", copy.staysChoices), ("folder", copy.staysProjects), ("key", copy.staysKeys)])
        }
    }

    private func column(_ title: String, _ lines: [(symbol: String, text: String)]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(AgentFont.heading)
                .padding(.bottom, Space.xxs)
                .accessibilityAddTraits(.isHeader)
            ForEach(lines, id: \.text) { line in
                HStack(alignment: .top, spacing: Space.sm) {
                    // A 12 pt symbol centred in a 16 pt slot, as tall as the
                    // line it leads, so wide symbols keep one edge.
                    Image(systemName: line.symbol)
                        .font(.system(size: Size.glyphSmall))
                        .frame(width: Size.glyphLarge, height: StageLayout.Well.captionLine)
                        .accessibilityHidden(true)
                    Text(line.text)
                        .wrapsLines()
                }
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, Space.lg)
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.xl)
        .accessibilityElement(children: .contain)
    }
}

/// Connected: a check drawn on, what the first pass did, the address with
/// Copy ⌘C, and what to do on the other Mac. A Mac that shares its library
/// through a folder names the folder instead, with nothing to copy: Join
/// takes a repository.
private struct ResultCard: View {
    let model: LaunchpadSyncConnect
    let result: LaunchpadSyncConnect.Result
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        let copy = LaunchpadCopy.Macs.self
        HStack(alignment: .top, spacing: Space.lg) {
            ZStack {
                if drawn || !animates {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, AgentTheme.ok)
                        .font(.system(size: Size.glyphLarge, weight: .medium))
                        .transition(AnyTransition(.symbolEffect(.drawOn)))
                }
            }
            .frame(width: Size.glyphLarge, height: Size.glyphLarge)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(LaunchpadSyncConnect.line(for: result))
                    .font(AgentFont.bodyMedium)
                    .lineLimit(1)
                if let address = connection {
                    Text(address)
                        .font(AgentFont.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if !isFolder {
                    Text(copy.joinNext)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.lg)
            if model.connectedAddress != nil {
                Button {
                    model.copyAddress()
                } label: {
                    HStack(spacing: Space.sm) {
                        Text(copy.copy)
                        KeyCombo(shortcut: Self.copyShortcut)
                    }
                }
                .buttonStyle(.glass)
                .keyboardShortcut(Self.copyShortcut)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, minHeight: StageLayout.Macs.resultCard, alignment: .topLeading)
        .stageCard()
        .accessibilityElement(children: .contain)
        .task {
            guard animates, !drawn else { return }
            withAnimation(AgentMotion.selection) { drawn = true }
        }
    }

    private var animates: Bool { motion.resolved(reduceMotion: reduceMotion).animatesDetails }

    /// The connection's second line: the repository's address, or the
    /// folder's path from home.
    private var connection: String? {
        if case .sharesThroughFolder(let folder) = result {
            return PathDisplay.abbreviatingHome(folder, home: model.homeURL)
        }
        return model.connectedAddress
    }

    private var isFolder: Bool {
        if case .sharesThroughFolder = result { true } else { false }
    }

    /// ⌘C copies the repository's address: the fields above are locked once
    /// connected, so the key has nothing else to copy.
    static let copyShortcut = KeyboardShortcut("c", modifiers: .command)
}
