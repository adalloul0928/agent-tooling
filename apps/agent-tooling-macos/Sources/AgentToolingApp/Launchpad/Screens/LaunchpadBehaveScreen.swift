import AgentToolingCore
import SwiftUI

/// Edits appearance, menu-bar presence, health checks, and update preferences.
/// Device preferences save immediately through the write queue and revert with
/// an error if saving fails. Keyboard navigation mirrors each row's control.
struct LaunchpadBehaveScreen: LaunchpadScreen {
    let flow: LaunchpadFlow
    @AppStorage(AppPreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppPreferenceKey.showMenuBarItem) private var showsMenuBarItem = true
    @State private var focused: Row = .appearance
    /// The row changed last, which a failure is shown under.
    @State private var lastChanged: Row?
    @State private var fade = StageAppearanceFade()
    @FocusState private var hasKeyboard: Bool

    init(flow: LaunchpadFlow) {
        self.flow = flow
    }

    /// The card's rows, in its order.
    enum Row: CaseIterable, Hashable, Sendable {
        case appearance
        case menuBar
        case checkOnOpen
        case updateCheck
        case skills
        case plugins
        case connections

        var symbol: String {
            switch self {
            case .appearance: "sun.max"
            case .menuBar: "menubar.rectangle"
            case .checkOnOpen: "stethoscope"
            case .updateCheck: "arrow.down.circle"
            case .skills: "doc.text"
            case .plugins: "puzzlepiece.extension"
            case .connections: "server.rack"
            }
        }

        var title: String {
            let copy = LaunchpadCopy.Preferences.self
            return switch self {
            case .appearance: copy.appearance
            case .menuBar: copy.menuBar
            case .checkOnOpen: copy.checkOnOpen
            case .updateCheck: copy.checkForUpdates
            case .skills: copy.skills
            case .plugins: copy.plugins
            case .connections: copy.connections
            }
        }

        var detail: String? {
            let copy = LaunchpadCopy.Preferences.self
            return switch self {
            case .appearance: copy.appearanceDetail
            case .menuBar: copy.menuBarDetail
            case .checkOnOpen: copy.checkOnOpenDetail
            case .updateCheck: copy.checkForUpdatesDetail
            case .skills, .plugins, .connections: nil
            }
        }

        /// The kind of tool an install-policy row decides for.
        var kind: ToolingItemKind? {
            switch self {
            case .skills: .skill
            case .plugins: .plugin
            case .connections: .mcpServer
            default: nil
            }
        }
    }

    var body: some View {
        let copy = LaunchpadCopy.Preferences.self
        VStack(alignment: .leading, spacing: 0) {
            StageHeader(.page, eyebrow: copy.eyebrow, title: copy.behaveTitle, subtitle: copy.behaveSubtitle)
            rows
                .stageCard()
                .focusable()
                .focusEffectDisabled()
                .focused($hasKeyboard)
                .onKeyPress(.upArrow) { moveFocus(by: -1) }
                .onKeyPress(.downArrow) { moveFocus(by: 1) }
                // A change takes one press. A held key's repeats are taken
                // and change nothing: they would step through every choice,
                // or flip a switch back and forth, each change a write.
                // Moving the highlight may repeat.
                .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in
                    step(focused, by: -1, changes: press.phase == .down)
                }
                .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in
                    step(focused, by: 1, changes: press.phase == .down)
                }
                .onKeyPress(.space, phases: [.down, .repeat]) { press in flip(focused, changes: press.phase == .down) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(copy.behaveLabel)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(copy.decidesArrivals).wrapsLines()
                Text(copy.connectionsWait).wrapsLines()
            }
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .padding(.top, Space.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StageAppearanceFade.Anchor(fade: fade))
        .onAppear { hasKeyboard = true }
    }

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        StageFooterSpec(primary: .init(title: LaunchpadCopy.Footer.continue) { flow.advance() })
    }

    // MARK: The card

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Row.allCases, id: \.self) { row in
                if row == .updateCheck { updatesLabel }
                // A row's line is drawn along its own top edge, so the lines
                // take no room of their own, and never beside the soft
                // highlight.
                rowView(row)
                    .overlay(alignment: .top) {
                        if showsLine(above: row) { Hairline(indent: StageLayout.Behave.rowIndent) }
                    }
            }
        }
    }

    /// Whether `row` has a line above it: not the first row, not the first
    /// row under the Updates label (which has its own across the card), and
    /// not beside the row the keyboard is on.
    private func showsLine(above row: Row) -> Bool {
        guard let previous = Self.row(before: row), row != .updateCheck else { return false }
        return focused != row && focused != previous
    }

    /// The Updates section's label, with a line across the card above it.
    private var updatesLabel: some View {
        Eyebrow(LaunchpadCopy.Preferences.updatesSection)
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.xs)
            .frame(maxWidth: .infinity, minHeight: StageLayout.Behave.sectionBand, alignment: .bottomLeading)
            .overlay(alignment: .top) { Hairline() }
            .accessibilityAddTraits(.isHeader)
    }

    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            InfoRow(row.title, detail: row.detail) {
                Image(systemName: row.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: Size.glyphSlot)
                    .accessibilityHidden(true)
            } trailing: {
                control(row)
            }
            if let failure = Self.failure(under: row, lastChanged: lastChanged, message: flow.workspace?.device.errorMessage) {
                SaveFailureLine(text: failure)
                    .padding(.leading, StageLayout.Behave.rowIndent)
                    .padding(.trailing, Space.xl)
                    .padding(.bottom, Space.md)
            }
        }
        .softHighlight(
            focused == row, inset: EdgeInsets(top: Space.xxs, leading: Space.sm, bottom: Space.xxs, trailing: Space.sm))
    }

    @ViewBuilder private func control(_ row: Row) -> some View {
        let device = flow.workspace?.device
        switch row {
        case .appearance:
            Picker(row.title, selection: appearanceBinding) {
                ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        case .menuBar:
            Toggle(row.title, isOn: menuBarBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        case .checkOnOpen:
            Toggle(row.title, isOn: checkOnOpenBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(device == nil || device?.isChecking == true)
        case .updateCheck:
            Picker(row.title, selection: cadenceBinding) {
                ForEach(UpdateCheckCadence.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: Size.fieldNarrow)
            .disabled(device == nil)
        case .skills, .plugins, .connections:
            Picker(row.title, selection: policyBinding(row)) {
                ForEach(UpdateInstallPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: Size.fieldNarrow)
            .disabled(device == nil)
        }
    }

    /// The sentence shown under `row`: the stage's one sentence for a choice
    /// that did not save, under the row changed last.
    static func failure(under row: Row, lastChanged: Row?, message: String?) -> String? {
        lastChanged == row && message == LaunchpadCopy.Footer.Failures.notRecorded ? message : nil
    }

    private static func row(before row: Row) -> Row? {
        let all = Row.allCases
        guard let index = all.firstIndex(of: row), index > 0 else { return nil }
        return all[index - 1]
    }

    // MARK: The choices

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(get: { AppAppearance(appearance) }, set: { choose($0) })
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { showsMenuBarItem },
            set: { value in
                focused = .menuBar
                showsMenuBarItem = value
            })
    }

    private var checkOnOpenBinding: Binding<Bool> {
        Binding(
            get: { flow.workspace?.device.automaticallyCheckHealth ?? true },
            set: { value in
                guard let device = flow.workspace?.device else { return }
                focused = .checkOnOpen
                lastChanged = .checkOnOpen
                Task { await device.setAutomaticallyCheckHealth(value) }
            })
    }

    private var cadenceBinding: Binding<UpdateCheckCadence> {
        Binding(
            get: { flow.workspace?.device.updatePolicy.cadence ?? UpdatePolicy().cadence },
            set: { value in
                updatePolicy(.updateCheck) { $0.cadence = value }
            })
    }

    private func policyBinding(_ row: Row) -> Binding<UpdateInstallPolicy> {
        let kind = row.kind ?? .skill
        return Binding(
            get: { (flow.workspace?.device.updatePolicy ?? UpdatePolicy()).policy(for: kind) },
            set: { value in
                updatePolicy(row) { $0.setPolicy(value, for: kind) }
            })
    }

    private func choose(_ choice: AppAppearance) {
        focused = .appearance
        guard choice != AppAppearance(appearance) else { return }
        fade.apply(choice) { appearance = choice.rawValue }
    }

    private func updatePolicy(_ row: Row, _ change: (inout UpdatePolicy) -> Void) {
        guard let device = flow.workspace?.device else { return }
        focused = row
        lastChanged = row
        var policy = device.updatePolicy
        change(&policy)
        Task { await device.setUpdatePolicy(policy) }
    }

    // MARK: Keys

    private func moveFocus(by offset: Int) -> KeyPress.Result {
        let all = Row.allCases
        guard let index = all.firstIndex(of: focused) else { return .ignored }
        focused = all[min(max(index + offset, 0), all.count - 1)]
        return .handled
    }

    /// ←→ on a segment or a pop-up: the choice before or after, unless
    /// `changes` is false (a held key's repeat), which is taken and changes
    /// nothing.
    private func step(_ row: Row, by offset: Int, changes: Bool) -> KeyPress.Result {
        switch row {
        case .appearance:
            if changes, let next = Self.neighbour(of: AppAppearance(appearance), by: offset) { choose(next) }
        case .updateCheck:
            let current = flow.workspace?.device.updatePolicy.cadence ?? UpdatePolicy().cadence
            if changes, let next = Self.neighbour(of: current, by: offset) { cadenceBinding.wrappedValue = next }
        case .skills, .plugins, .connections:
            let binding = policyBinding(row)
            if changes, let next = Self.neighbour(of: binding.wrappedValue, by: offset) { binding.wrappedValue = next }
        case .menuBar, .checkOnOpen:
            return .ignored
        }
        return .handled
    }

    /// Space on a switch flips it, unless `changes` is false (a held key's
    /// repeat), which is taken and flips nothing.
    private func flip(_ row: Row, changes: Bool) -> KeyPress.Result {
        switch row {
        case .menuBar: if changes { menuBarBinding.wrappedValue.toggle() }
        case .checkOnOpen: if changes { checkOnOpenBinding.wrappedValue.toggle() }
        default: return .ignored
        }
        return .handled
    }

    /// The case `offset` places from `value`, or nil past either end.
    private static func neighbour<Value: CaseIterable & Equatable>(of value: Value, by offset: Int) -> Value? {
        let all = Array(Value.allCases)
        guard let index = all.firstIndex(of: value) else { return nil }
        let next = index + offset
        return all.indices.contains(next) ? all[next] : nil
    }
}
