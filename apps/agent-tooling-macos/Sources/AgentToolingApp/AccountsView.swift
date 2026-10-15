import AgentToolingCore
import SwiftUI

/// The Apps family's Accounts tab: what the claude.ai and ChatGPT accounts
/// put in front of this Mac's clients, and the choices every Mac shares.
struct AccountsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        AccountsView(session: workspace.accounts, library: workspace.library)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reading is the default, and nothing here changes a client without a
/// review. A row's menu records a choice for every Mac; the banner under each
/// account then offers the reviewed edit that makes this Mac follow it.
struct AccountsView: View {
    let session: WorkspaceAccountsSession
    let library: WorkspaceLibrarySession

    @State private var reviewing: ReviewRequest?
    @State private var sharing: AccountProvider?

    struct ReviewRequest: Identifiable {
        let plan: AccountPreferencePlan
        var id: AccountProvider { plan.provider }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Apps", context: statusLine) {
                Button {
                    Task { await session.read(depth: .contents) }
                } label: {
                    Label(session.isReading ? "Reading…" : "Check accounts", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(session.isReading || session.providers.isEmpty)
                .help("Asks Claude Code and Codex what your accounts give them on this Mac. Reads only; Claude Code checks its connections while it answers.")
            }
            content
        }
        .task {
            // The first visit reads the contents; later visits keep what was
            // read until somebody checks again.
            await session.readContentsIfMissing()
        }
        .onChange(of: library.state?.snapshot.document.revision.id) { _, _ in
            // Another Mac's choices arrive by sync; what this Mac must change
            // to follow them changes with them.
            Task { await session.replan() }
        }
        .sheet(item: $reviewing) { request in
            AccountChangesReviewSheet(session: session, plan: request.plan) { reviewing = nil }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if session.providers.isEmpty {
            EmptyStateView(
                symbol: "person.badge.key",
                title: "No account to read",
                message: "Accounts are read through Claude Code and Codex, and this Mac manages neither. Turn one on in Apps › Clients.")
        } else if session.lastReadAt == nil {
            EmptyStateView(
                symbol: "person.badge.key",
                title: session.isReading ? "Reading your accounts…" : "Accounts have not been read yet",
                message: "Agent Tooling asks Claude Code and Codex what your claude.ai and ChatGPT accounts give them. Nothing on this Mac changes.",
                actionTitle: session.isReading ? nil : "Check accounts",
                isActionEnabled: !session.isReading,
                action: { Task { await session.read(depth: .contents) } })
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxxl) {
                    explainer
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Something did not go through", message: message)
                    }
                    if let message = session.lastApplyMessage {
                        InfoRow(message, leading: { StatusGlyph(state: .healthy) })
                            .standardPanel()
                    }
                    ForEach(session.providers, id: \.self) { provider in
                        AccountCard(
                            provider: provider, session: session,
                            onReview: { plan in reviewing = .init(plan: plan) },
                            onShare: { sharing = provider })
                    }
                    if session.providers.contains(.claude) {
                        PublishingCard(status: session.publishing, onOpen: { session.openSite(.claude, kind: .plugin) })
                    }
                }
                .padding(WorkspaceLayout.pageInset)
            }
            .popover(item: $sharing, arrowEdge: .top) { provider in
                ShareSettingsConfirmation(
                    provider: provider, settings: session.shareableSettings(provider),
                    onConfirm: {
                        sharing = nil
                        Task { await session.shareThisMacsSettings(provider) }
                    },
                    onCancel: { sharing = nil })
            }
        }
    }

    private var explainer: some View {
        Text("Your claude.ai and ChatGPT accounts sync themselves to every place you sign in. This tab shows what they give Claude Code and Codex on this Mac. Add, connect and remove things on the vendor's site; the switches here decide what each app loads, and apply the same way on every Mac.")
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .wrapsLines()
    }

    private var statusLine: String {
        if session.isReading { return "Reading accounts…" }
        guard let read = session.lastReadAt else { return "Accounts have not been read yet." }
        let pending = session.providers.compactMap { session.plan($0)?.outOfStep }.reduce(0, +)
        let checked = "Read \(SnapshotTime.compact(read))"
        return pending == 0 ? checked : "\(checked) · \(pending) shared choice\(pending == 1 ? "" : "s") not applied here"
    }
}

// MARK: - One account

private struct AccountCard: View {
    let provider: AccountProvider
    let session: WorkspaceAccountsSession
    let onReview: (AccountPreferencePlan) -> Void
    let onShare: () -> Void

    private var observation: AccountObservation? { session.observation(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            header
            if let observation {
                if let reason = observation.unavailableReason {
                    AttentionBanner(title: "\(provider.accountName) could not be read", message: reason)
                } else {
                    banners(observation)
                    SharedChoicesCard(provider: provider, session: session, onShare: onShare)
                    ForEach(kinds, id: \.self) { kind in
                        ItemsCard(kind: kind, observation: observation, session: session)
                    }
                    if !observation.notes.isEmpty {
                        DisclosureGroup("About what was read") {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                ForEach(observation.notes, id: \.self) { note in
                                    Text(note).font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                                }
                            }
                            .padding(.top, Space.sm)
                        }
                        .font(AgentFont.caption)
                    }
                }
            } else if session.readingProviders.contains(provider) {
                InfoRow("Reading \(provider.accountName)…", leading: { ProgressView().controlSize(.small) })
                    .standardPanel()
            }
        }
    }

    private var kinds: [AccountItemKind] {
        provider == .claude ? [.connector, .plugin, .skill] : [.app]
    }

    private var header: some View {
        HStack(spacing: Space.lg) {
            ClientBrandIcon(client: provider.client, size: Size.tile)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(provider.accountName).font(AgentFont.title)
                Text(signInLine).font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
            }
            Spacer(minLength: Space.lg)
            Button("Open \(provider.accountName)") { session.openSite(provider) }
                .secondaryActionStyle()
                .controlSize(.small)
                .help("Opens \(provider.manageURL.absoluteString), where the account's contents are added, connected and removed.")
        }
    }

    private var signInLine: String {
        guard let observation else { return "Not read yet." }
        guard let signIn = observation.signIn else {
            return "\(provider.client.rawValue) did not say how it signs in."
        }
        var line = "\(provider.client.rawValue)\(observation.clientVersion.map { " \($0)" } ?? "") signs in with \(signIn.summary(for: provider))"
        if signIn.method == .subscription, let email = signIn.email { line += " as \(email)" }
        return line + "."
    }

    @ViewBuilder
    private func banners(_ observation: AccountObservation) -> some View {
        if let signIn = observation.signIn, !signIn.method.reachesAccount {
            AttentionBanner(
                title: "\(provider.client.rawValue) is not signed in with \(provider.accountName)",
                message: "Only a subscription sign-in brings your account's \(provider == .claude ? "connectors, skills and plugins" : "apps") to \(provider.client.rawValue). Run \(provider == .claude ? "`claude auth login`" : "`codex login`") in a terminal, then check again.")
        }
        if !observation.shellOverrides.isEmpty {
            AttentionBanner(
                title: "Your login shell changes how \(provider.client.rawValue) signs in",
                message: observation.shellOverrides.map { "\($0.variable): \($0.consequence)" }.joined(separator: "\n")
                    + "\nAgent Tooling read only the variable names.")
        }
        if let blocker = observation.writeBlocker {
            AttentionBanner(title: "Shared choices cannot be applied on this Mac", message: blocker)
        }
        if let plan = session.plan(provider), plan.outOfStep > 0 {
            AttentionBanner(
                title: "This Mac does not follow \(plan.outOfStep) shared choice\(plan.outOfStep == 1 ? "" : "s")",
                message: plan.changes.isEmpty
                    ? plan.held.map { "\($0.key.label.capitalizedFirst): \($0.reason)" }.joined(separator: "\n")
                    : "Applying changes \(plan.file.relativePath) after copying it to Agent Tooling's trash."
                        + (plan.held.isEmpty ? "" : " \(plan.held.count) more cannot be applied here; see each row.")
            ) {
                if !plan.changes.isEmpty {
                    Button(session.applyingProvider == provider ? "Applying…" : "Review changes…") { onReview(plan) }
                        .primaryActionStyle()
                        .controlSize(.small)
                        .disabled(session.applyingProvider != nil || !session.canWrite)
                }
            }
        }
    }
}

// MARK: - Account-wide switches

private struct SharedChoicesCard: View {
    let provider: AccountProvider
    let session: WorkspaceAccountsSession
    let onShare: () -> Void

    var body: some View {
        TitledCard("On every Mac") {
            if !session.shareableSettings(provider).isEmpty {
                Button("Use this Mac's settings everywhere…", action: onShare)
                    .inlineActionStyle()
                    .disabled(session.isSaving || !session.canWrite)
                    .help("Records the account switches this Mac's own settings file sets as choices every Mac follows.")
            }
        } content: {
            ForEach(Array(settings.enumerated()), id: \.offset) { index, setting in
                if index > 0 { Hairline() }
                ChoiceRow(
                    key: AccountPreferenceKey(setting), title: Self.title(setting), detail: Self.detail(setting),
                    session: session)
            }
        }
    }

    private var settings: [AccountSetting] {
        provider == .claude
            ? [.connectors, .pluginSync, .skillSync]
            : [.apps, .approvalMode, .destructiveTools, .openWorldTools]
    }

    static func title(_ setting: AccountSetting) -> String {
        switch setting {
        case .connectors: "Connectors from claude.ai"
        case .pluginSync: "Plugins from claude.ai"
        case .skillSync: "Skills from claude.ai"
        case .apps: "ChatGPT apps in Codex"
        case .approvalMode: "When Codex asks before an app tool runs"
        case .destructiveTools: "App tools that delete or change things"
        case .openWorldTools: "App tools that reach the open web"
        case .plugin, .connector, .app: ""
        }
    }

    static func detail(_ setting: AccountSetting) -> String {
        switch setting {
        case .connectors: "Terminal and IDE sessions fetch your claude.ai connectors (disableClaudeAiConnectors). The desktop app's Code tab gets them from claude.ai either way."
        case .pluginSync: "Claude Code loads the plugins on your account as <name>@synced (syncClaudeAiPlugins). Off moves the downloaded ones to Claude Code's trash."
        case .skillSync: "Claude Code downloads your account's skills into ~/.claude/skills/synced (syncClaudeAiSkills). Off moves them to Claude Code's trash."
        case .apps: "Codex lists and calls the apps connected to your ChatGPT account ([features] apps)."
        case .approvalMode: "The default for every app's tools, unless an app sets its own (apps._default.default_tools_approval_mode)."
        case .destructiveTools: "Whether tools an app marks destructive may run at all (apps._default.destructive_enabled)."
        case .openWorldTools: "Whether tools that reach beyond the app's own service may run (apps._default.open_world_enabled)."
        case .plugin, .connector, .app: ""
        }
    }
}

/// One switch: what this Mac does now, and the choice every Mac shares.
private struct ChoiceRow: View {
    let key: AccountPreferenceKey
    let title: String
    let detail: String
    let session: WorkspaceAccountsSession

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(AgentFont.bodyMedium)
                Text(detail).font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                LocalValueLine(key: key, session: session)
            }
            Spacer(minLength: Space.lg)
            ChoiceMenu(key: key, session: session)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
    }
}

/// "On this Mac: off · not applied yet", from the same plan the banner uses.
private struct LocalValueLine: View {
    let key: AccountPreferenceKey
    let session: WorkspaceAccountsSession

    var body: some View {
        let observation = session.observation(key.provider)
        let local = observation?.effectiveValue(of: key)
        let plan = session.plan(key.provider)
        let held = plan?.held.first { $0.key == key }
        let pending = plan?.changes.contains { $0.key == key } == true
        HStack(spacing: Space.xs) {
            if pending || held != nil {
                StatusGlyph(state: .attention, size: Size.glyphSmall)
            }
            Text(text(local: local, constrained: observation?.constrained[key], pending: pending, held: held))
                .font(AgentFont.micro)
                .foregroundStyle(pending || held != nil ? AgentTheme.warning : .secondary)
                .wrapsLines()
        }
    }

    private func text(
        local: AccountPreferenceValue?, constrained: String?, pending: Bool, held: AccountPreferencePlan.Held?
    ) -> String {
        var parts = ["On this Mac: \(local?.label.lowercased() ?? "not set")"]
        if let constrained { parts.append(constrained.lowercased()) }
        if pending { parts.append("the shared choice is not applied yet") }
        if let held { parts.append("cannot be applied here: \(held.reason)") }
        return parts.joined(separator: " · ")
    }
}

private struct ChoiceMenu: View {
    let key: AccountPreferenceKey
    let session: WorkspaceAccountsSession

    var body: some View {
        let shared = session.sharedValue(key)
        Menu {
            ForEach(key.setting.acceptedValues, id: \.self) { value in
                Button {
                    Task { await session.setChoice(key, to: value) }
                } label: {
                    if shared == value { Label(Self.label(value, setting: key.setting), systemImage: "checkmark") }
                    else { Text(Self.label(value, setting: key.setting)) }
                }
            }
            Divider()
            Button {
                Task { await session.setChoice(key, to: nil) }
            } label: {
                if shared == nil { Label("Each Mac decides", systemImage: "checkmark") } else { Text("Each Mac decides") }
            }
        } label: {
            Text(shared.map { Self.label($0, setting: key.setting) } ?? "Each Mac decides")
                .font(AgentFont.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(session.isSaving || !session.canWrite)
        .help("The choice every Mac follows. Choosing records it for every Mac; each Mac then applies it to its own settings after you review the change there.")
        .accessibilityLabel("Every Mac: \(key.label)")
    }

    static func label(_ value: AccountPreferenceValue, setting: AccountSetting) -> String {
        switch setting {
        case .approvalMode: "\(value.label) on every Mac"
        case .destructiveTools, .openWorldTools: value == .on ? "Allowed on every Mac" : "Blocked on every Mac"
        default: value == .on ? "On on every Mac" : "Off on every Mac"
        }
    }
}

// MARK: - What the account holds

private struct ItemsCard: View {
    let kind: AccountItemKind
    let observation: AccountObservation
    let session: WorkspaceAccountsSession

    private var items: [AccountItem] { observation.items(kind) }

    var body: some View {
        TitledCard(kind.pluralName, count: observation.contentsRead ? "\(items.count)" : nil) {
            Button("Manage on \(observation.provider.accountName)") { session.openSite(observation.provider, kind: kind) }
                .inlineActionStyle()
        } content: {
            if !observation.contentsRead {
                InfoRow("Not read yet", detail: "Check accounts to list them.", leading: { StatusGlyph(state: .pending) })
            } else if items.isEmpty {
                InfoRow(emptyTitle, detail: emptyDetail, leading: { StatusGlyph(state: .pending) })
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Hairline() }
                    ItemRow(item: item, session: session)
                }
            }
        }
    }

    private var emptyTitle: String {
        "No \(kind.pluralName.lowercased()) reach \(observation.provider.client.rawValue) on this Mac"
    }

    private var emptyDetail: String? {
        if !observation.reachesAccount {
            return "\(observation.provider.client.rawValue) is not signed in with \(observation.provider.accountName)."
        }
        if kind == .app, observation.directoryCount > 0 {
            return "None is connected to your account. The directory lists \(observation.directoryCount) more."
        }
        return nil
    }
}

private struct ItemRow: View {
    let item: AccountItem
    let session: WorkspaceAccountsSession

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            StatusGlyph(state: item.state.healthState)
                .padding(.top, Space.xxs)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.md) {
                    Text(item.name).font(AgentFont.bodyMedium).lineLimit(1)
                    Text(item.state.label)
                        .font(AgentFont.microMedium)
                        .foregroundStyle(item.state.tone == .attention ? AgentTheme.warning : .secondary)
                        .lineLimit(1)
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).font(AgentFont.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                ForEach(item.facts, id: \.self) { fact in
                    Text(fact).font(AgentFont.micro).foregroundStyle(.tertiary).lineLimit(1)
                }
                if let key = item.preferenceKey, session.sharedValue(key) != nil || session.plan(item.provider)?.held.contains(where: { $0.key == key }) == true {
                    LocalValueLine(key: key, session: session)
                }
            }
            Spacer(minLength: Space.lg)
            HStack(spacing: Space.md) {
                if let key = item.preferenceKey {
                    ChoiceMenu(key: key, session: session)
                }
                Button {
                    session.open(item)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open \(item.name) on \(item.provider.accountName).")
                .accessibilityLabel("Open \(item.name) on \(item.provider.accountName)")
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .frame(minHeight: Size.rowHeight)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Publishing this repository's plugins

private struct PublishingCard: View {
    let status: WorkspaceAccountsSession.PublishingStatus
    let onOpen: () -> Void

    var body: some View {
        TitledCard("Your plugins on claude.ai") {
            Button("Open claude.ai plugins", action: onOpen).inlineActionStyle()
        } content: {
            VStack(alignment: .leading, spacing: Space.md) {
                Text(instructions)
                    .font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                    .padding(.horizontal, Space.xl).padding(.top, Space.lg)
                if status.plugins.isEmpty {
                    Text("The library holds no plugin from the agent-tooling catalog yet.")
                        .font(AgentFont.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.xl).padding(.bottom, Space.lg)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(status.plugins.enumerated()), id: \.element.id) { index, plugin in
                            if index > 0 { Hairline() }
                            InfoRow(plugin.name, detail: detail(plugin)) {
                                StatusGlyph(state: plugin.isOnAccount ? (plugin.isProjectScoped ? .attention : .healthy) : .pending)
                            } trailing: {
                                Text(plugin.isOnAccount ? "On your account" : "Not on your account")
                                    .font(AgentFont.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var instructions: String {
        let source = status.marketplaceSource.map { "`\($0)`" } ?? "this repository"
        return "Add \(source) once at claude.ai › Customize › Plugins › Add › Add marketplace, and turn on Sync automatically. A private GitHub repository needs the Claude GitHub App. After that, each merge to main reaches claude.ai, the Claude desktop app, and Claude Code on every Mac signed in to your account. Add only plugins meant for every project: an account plugin loads everywhere."
    }

    private func detail(_ plugin: WorkspaceAccountsSession.PublishingStatus.Plugin) -> String {
        switch (plugin.isOnAccount, plugin.isProjectScoped) {
        case (true, true): "Assigned to a project here, but on the account it loads in every project. Remove it on claude.ai to keep it scoped."
        case (true, false): "Claude Code loads it from your account as \(plugin.name)@synced, unless a local copy of the same name is enabled."
        case (false, true): "Assigned to a project; leave it off your account so it stays scoped."
        case (false, false): "Add it on claude.ai to have it in chat, Cowork and every Claude Code session."
        }
    }
}

// MARK: - Sharing this Mac's settings

private struct ShareSettingsConfirmation: View {
    let provider: AccountProvider
    let settings: [AccountPreference]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Use this Mac's \(provider.client.rawValue) settings everywhere").font(AgentFont.heading)
            Text("These become choices every Mac follows. Each Mac applies them after you review the change there.")
                .font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(settings, id: \.key) { setting in
                        Text("\(setting.key.label.capitalizedFirst): \(setting.value.label.lowercased())")
                            .font(AgentFont.body)
                    }
                }
            }
            .frame(maxHeight: 200)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Share \(settings.count)", action: onConfirm).keyboardShortcut(.defaultAction).primaryActionStyle()
            }
        }
        .padding(Space.xxl)
        .frame(width: 420)
    }
}

// MARK: - Review

/// The exact edits applying would make, and what will not change and why.
/// Approving runs the same plan, checked again against the file first.
struct AccountChangesReviewSheet: View {
    let session: WorkspaceAccountsSession
    let plan: AccountPreferencePlan
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Apply shared \(plan.provider.accountName) choices to \(plan.provider.client.rawValue)")
                    .font(AgentFont.titleLarge)
                Text("Changes \(plan.file.relativePath) on this Mac. The file is copied into Agent Tooling's trash first, and sessions already open keep their old settings until they restart.")
                    .font(AgentFont.body).foregroundStyle(.secondary).wrapsLines()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.xxxl)

            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Nothing was changed", message: message)
                    }
                    TitledCard("Changes", count: "\(plan.changes.count)") {
                        ForEach(Array(plan.changes.enumerated()), id: \.element.id) { index, change in
                            if index > 0 { Hairline() }
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(change.summary).font(AgentFont.bodyMedium).wrapsLines()
                                ForEach(change.edits, id: \.self) { edit in
                                    Text(edit.summary).font(AgentFont.mono).foregroundStyle(.secondary)
                                        .textSelection(.enabled).wrapsLines()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
                        }
                    }
                    if !plan.held.isEmpty {
                        TitledCard("Not changed here", count: "\(plan.held.count)") {
                            ForEach(Array(plan.held.enumerated()), id: \.element.id) { index, held in
                                if index > 0 { Hairline() }
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text(held.key.label.capitalizedFirst).font(AgentFont.bodyMedium)
                                    Text(held.reason).font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
                            }
                        }
                    }
                }
                .padding(Space.xxxl)
            }

            Hairline()

            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(session.applyingProvider == plan.provider ? "Applying…" : "Apply \(plan.changes.count) change\(plan.changes.count == 1 ? "" : "s")") {
                    Task {
                        if await session.apply(plan.provider, reviewed: plan) != nil { onClose() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .primaryActionStyle()
                .disabled(session.applyingProvider != nil || plan.changes.isEmpty)
            }
            .padding(Space.xxl)
        }
        .frame(width: SheetSize.medium.width, height: SheetSize.medium.height)
    }
}

extension String {
    /// The first letter capitalised, the rest left as written.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

// MARK: - Library strip

/// A line under a Library tab saying what the accounts add that the library
/// does not hold. Account items are read on Accounts, never recorded here: the
/// account keeps them in step itself, and an edit here would be overwritten.
struct AccountContentsStrip: View {
    let session: WorkspaceAccountsSession
    let kinds: [AccountItemKind]
    @Environment(\.workspaceNavigate) private var navigate

    var body: some View {
        let parts = phrases
        if !parts.isEmpty {
            HStack(spacing: Space.md) {
                Image(systemName: "person.badge.key")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                Text("Your accounts also give \(parts.joined(separator: " and ")). They stay in step with the account, so they are not part of this library.")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: Space.lg)
                Button("Show in Accounts") { navigate(.accounts) }
                    .inlineActionStyle()
                    .font(AgentFont.caption)
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Hairline() }
        }
    }

    private var phrases: [String] {
        session.providers.compactMap { provider -> String? in
            guard let observation = session.observation(provider), observation.contentsRead else { return nil }
            let counts = kinds.compactMap { kind -> String? in
                let count = observation.items(kind).count
                guard count > 0 else { return nil }
                return "\(count) \(count == 1 ? kind.singularName : kind.pluralName.lowercased())"
            }
            guard !counts.isEmpty else { return nil }
            return "\(provider.client.rawValue) \(counts.joined(separator: ", "))"
        }
    }
}
