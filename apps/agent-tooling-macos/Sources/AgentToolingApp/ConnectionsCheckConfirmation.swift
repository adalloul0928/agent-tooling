import AgentToolingCore
import SwiftUI

/// Previews connection checks and any required sign-in commands. Return checks;
/// a fresh ⌘Return signs in through reviewed health operations. Agent Tooling
/// opens the client's login page without reading its token. `ConnectionsCheckFlow`
/// drives this view from a `ConnectionsCheckRun`.
struct ConnectionsCheckConfirmation: View {
    enum Phase: Equatable, Sendable {
        /// Before the check: what it runs, and the sign-ins it may lead to.
        case confirm
        case checking
        /// After a check that found connections to sign in to.
        case signIn
        case signingIn
        /// After a check with nothing to sign in to.
        case finished
    }

    /// A sign-in, by the connection it is for and the command it runs.
    struct SignIn: Equatable, Sendable, Identifiable {
        let connection: String
        let command: String
        var id: String { command }
    }

    let phase: Phase
    /// The list commands the check runs, in the order it runs them.
    let listCommands: [String]
    /// Before the check: the sign-ins it may lead to. After it: the ones it
    /// found, with the commands they will run.
    let signIns: [SignIn]
    /// Who needs a sign-in, after a check: "Sentry in Claude Code".
    var who: String?
    /// After a check: the connections that need a sign-in only their own
    /// app can run, in the sentence that says so and points to Apps ›
    /// Health. Nil when there are none.
    var signInElsewhere: String?
    /// What the last sign-in said, when it did not finish.
    var message: String?
    /// A plain ↩ reached the sign-in, where only ⌘↩ acts.
    var showsHint = false
    var onCheck: () -> Void = {}
    var onSignIn: () -> Void = {}
    var onCancel: () -> Void = {}
    var onPlainReturn: () -> Void = {}

    var body: some View {
        let copy = LaunchpadCopy.FinishSetup.self
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .confirm, .checking:
                title(copy.checkTitle)
                paragraph(copy.checkRuns)
                command(listCommands.joined(separator: " · "))
                if signIns.isEmpty {
                    paragraph(copy.signInComesNextIfAny)
                } else {
                    paragraph(copy.signInComesNext(copy.either(signIns.map(\.connection))))
                    ForEach(signIns) { command($0.command) }
                    paragraph(signIns.count == 1 ? copy.signInRuns : copy.signInRunsEach)
                }
            case .signIn, .signingIn:
                title(copy.signInTitle)
                if let who { paragraph(copy.needSignIn(who, count: signIns.count)) }
                ForEach(signIns) { command($0.command) }
                paragraph(signIns.count == 1 ? copy.signInRuns : copy.signInRunsEach)
            case .finished:
                title(copy.checkedTitle)
                paragraph(signInElsewhere ?? copy.nothingToSignIn)
            }
            if let message {
                Text(message)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    .padding(.top, Space.xs)
            }
            buttons
                .padding(.top, Space.md)
        }
        .padding(.vertical, Space.md)
        .padding(.horizontal, Space.lg)
        .frame(width: Size.fieldWide, alignment: .leading)
        .commandReturnAction(
            isActive: phase == .signIn, isReady: phase == .signIn, perform: onSignIn, onPlainReturn: onPlainReturn,
            spokenHint: copy.pressCommandReturnSpoken
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        let copy = LaunchpadCopy.FinishSetup.self
        HStack(spacing: Space.sm) {
            if showsHint {
                Text(copy.pressCommandReturn)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            switch phase {
            case .confirm, .checking:
                Button(action: onCancel) { label(copy.cancel, keys: .cancelAction) }
                    .keyboardShortcut(.cancelAction)
                Button(action: onCheck) {
                    label(phase == .checking ? copy.checking : copy.check, keys: .defaultAction)
                }
                .primaryActionStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(phase == .checking)
            case .signIn, .signingIn:
                Button(action: onCancel) { label(copy.cancel, keys: .cancelAction) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase == .signingIn)
                Button(action: onSignIn) {
                    label(phase == .signingIn ? copy.signingIn : copy.signInButton, keys: StageShortcut.commandReturn)
                }
                .primaryActionStyle()
                .disabled(phase == .signingIn)
                .accessibilityHint(copy.pressCommandReturnSpoken)
            case .finished:
                Button(action: onCancel) { label(copy.close, keys: .defaultAction) }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
    }

    private func label(_ title: String, keys: KeyboardShortcut) -> some View {
        HStack(spacing: Space.xs) {
            Text(title)
            KeyCombo(shortcut: keys)
        }
        .environment(\.keycapOnAccent, keys != .cancelAction)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(AgentFont.captionSemibold)
            .padding(.bottom, Space.xxs)
            .accessibilityAddTraits(.isHeader)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .wrapsLines()
            .padding(.top, Space.xs)
    }

    private func command(_ text: String) -> some View {
        Text(text)
            .font(AgentFont.mono)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .wrapsLines()
            .padding(.top, Space.xxs)
    }
}

/// The confirmation as Home runs it, over a `ConnectionsCheckRun` made when
/// it opens.
struct ConnectionsCheckFlow: View {
    let workspace: WorkspaceLaunch.Workspace
    let dismiss: () -> Void
    @State private var run: ConnectionsCheckRun

    /// `hints` are the sign-ins setup expected before any check: what the
    /// confirmation names first.
    init(workspace: WorkspaceLaunch.Workspace, hints: [FinishSetupFacts.Connection], dismiss: @escaping () -> Void) {
        self.workspace = workspace
        self.dismiss = dismiss
        _run = State(initialValue: ConnectionsCheckRun(health: workspace.health, hints: hints))
    }

    var body: some View {
        let run = run
        ConnectionsCheckConfirmation(
            phase: run.phase, listCommands: Self.listCommands(for: workspace.device.managedClients), signIns: run.signIns,
            who: run.who, signInElsewhere: run.signInElsewhere, message: run.message, showsHint: run.showsHint,
            onCheck: { Task { await run.check() } }, onSignIn: { Task { await run.signIn() } }, onCancel: dismiss,
            onPlainReturn: { run.plainReturn() })
    }

    /// Each managed app's list command, in the order the check runs them.
    static func listCommands(for managed: [ClientKind]) -> [String] {
        managed.compactMap(ConnectionHealthProbe.listCommandText(for:))
    }
}

/// The confirmation's work: Check runs the health session's check once, a
/// read; Sign in runs each sign-in the check offers, one at a time, through
/// `WorkspaceHealthSession.reauthenticate`, which checks again after each,
/// so what is left to sign in to is what the confirmation shows next, with
/// its real command. Nothing runs from a plain ↩ at the sign-in.
@MainActor @Observable
final class ConnectionsCheckRun {
    private(set) var phase: ConnectionsCheckConfirmation.Phase
    /// What the last sign-in said, when it did not finish.
    private(set) var message: String?
    /// A plain ↩ reached the sign-in, where only ⌘↩ acts.
    private(set) var showsHint = false
    @ObservationIgnored private let health: WorkspaceHealthSession
    /// The sign-ins setup expected before any check, by the names it gave
    /// them.
    @ObservationIgnored private let hints: [FinishSetupFacts.Connection]

    /// Opens at the sign-in when the last check already offered one, else at
    /// the check.
    init(health: WorkspaceHealthSession, hints: [FinishSetupFacts.Connection]) {
        self.health = health
        self.hints = hints
        phase = health.lastCheckedAt != nil && !health.reauthenticatableEntries.isEmpty ? .signIn : .confirm
    }

    /// The sign-ins the confirmation shows, each with the command it runs:
    /// before the check, the ones setup expected; once the check has offered
    /// some, those, with the commands the check found.
    var signIns: [ConnectionsCheckConfirmation.SignIn] {
        guard phase == .signIn || phase == .signingIn else {
            return hints.compactMap { hint in
                health.loginCommandText(client: hint.client, serverID: hint.serverID).map {
                    .init(connection: hint.name, command: $0)
                }
            }
        }
        return health.reauthenticatableEntries.compactMap { entry in
            health.loginCommandText(for: entry).map { .init(connection: entry.displayName, command: $0) }
        }
    }

    /// Who the check found needing a sign-in, named as setup named them:
    /// "Sentry in Claude Code".
    var who: String? {
        guard phase == .signIn || phase == .signingIn else { return nil }
        return FinishSetupChecklist.who(health.reauthenticatableEntries.map(connection))
    }

    /// After the check: what needs a sign-in only its own app can run, and
    /// where Agent Tooling shows how.
    var signInElsewhere: String? {
        guard phase == .finished, let check = FinishSetupFacts.connectionCheck(health, naming: names) else { return nil }
        let elsewhere = check.signInElsewhere
        guard !elsewhere.isEmpty else { return nil }
        return LaunchpadCopy.FinishSetup.signInFromApps(FinishSetupChecklist.who(elsewhere), count: elsewhere.count)
    }

    /// Check ↩: runs the check once.
    func check() async {
        guard phase == .confirm else { return }
        phase = .checking
        message = nil
        await health.check()
        phase = health.reauthenticatableEntries.isEmpty ? .finished : .signIn
    }

    /// Sign in ⌘↩: each sign-in the check offers, in turn. A sign-in that
    /// did not finish says what it printed.
    func signIn() async {
        guard phase == .signIn else { return }
        phase = .signingIn
        showsHint = false
        message = nil
        for entry in health.reauthenticatableEntries {
            await health.reauthenticate(entry)
            if case .failed(let words)? = health.actionState[entry.id] { message = words }
        }
        phase = health.reauthenticatableEntries.isEmpty ? .finished : .signIn
    }

    /// A plain ↩ at the sign-in: the hint shows, and nothing runs.
    func plainReturn() {
        guard phase == .signIn else { return }
        showsHint = true
    }

    /// The names setup gave the connections, for naming what the check found.
    private var names: FinishSetupFacts {
        var facts = FinishSetupFacts()
        facts.signInCandidates = hints
        return facts
    }

    /// A listed connection under the name setup gave it, matched by the name
    /// the app knows it by, else by the name a person reads.
    private func connection(_ entry: ConnectionHealthEntry) -> FinishSetupFacts.Connection {
        let mine = hints.filter { $0.client == entry.client }
        let known =
            mine.first { $0.serverID == entry.name }?.name
            ?? mine.first { $0.name.caseInsensitiveCompare(entry.displayName) == .orderedSame }?.name
        return .init(name: known ?? entry.displayName, serverID: entry.name, client: entry.client)
    }
}
