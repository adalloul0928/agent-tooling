import AgentToolingCore
import SwiftUI

/// Where the wizard is, and what each stop is for.
enum SetupWizardStep: Hashable, Identifiable {
    case apps
    case audit
    case review
    case category(SetupRecommendation.Category)
    case done

    var id: String {
        switch self {
        case .apps: "apps"
        case .audit: "audit"
        case .review: "review"
        case .category(let category): "category-\(category.rawValue)"
        case .done: "done"
        }
    }

    var title: String {
        switch self {
        case .apps: "Choose the apps this Mac manages"
        case .audit: "Here is what this Mac found"
        case .review: "What your assistant makes of it"
        case .category(let category): category.title
        case .done: "All set"
        }
    }

    var subtitle: String {
        switch self {
        case .apps: "Only what is checked here is looked after. Nothing already installed changes."
        case .audit: "A deterministic look at every app's folders. Every line is a fact with its evidence."
        case .review: "Your own signed-in assistant reads the audit and the apps' configuration, and proposes what to do. It can read; it cannot change anything."
        case .category(.cleanup): "Broken links, empty folders, and old plugin versions. Removals go to Agent Tooling's trash first."
        case .category(.duplicates): "Skills one app can reach two ways. Keep one; the other is a copy."
        case .category(.unmanaged): "Skills found in an app that this library does not hold. Adopting one copies it in as yours; the app's folder is not changed."
        case .category(.connections): "MCP servers that cannot start or are configured separately in several apps."
        case .category(.settings): "Settings your assistant recommends. These are changed on the Settings tab, where the file is shown."
        case .category(.additions): "Plugins and skills worth adding."
        case .category(.updates): "What changed in your apps since you last looked."
        case .done: "Everything left is on the Checkup tab, which runs again on its own once a week."
        }
    }

    /// The categories a checkup actually has something in, in walking order.
    static func categories(in checkup: SetupCheckup) -> [SetupRecommendation.Category] {
        var present: Set<SetupRecommendation.Category> = []
        for finding in checkup.openFindings { present.insert(finding.kind.category) }
        for recommendation in checkup.openRecommendations { present.insert(recommendation.category) }
        return SetupRecommendation.Category.allCases.filter(present.contains)
    }
}

extension SetupFinding.Kind {
    /// Which stop of the wizard a finding belongs to.
    var category: SetupRecommendation.Category {
        switch self {
        case .brokenSkillLink, .skillWithoutDefinition, .stalePluginCache, .missingPluginInstall: .cleanup
        case .duplicateSkillInClient, .mcpServerDefinedSeveralTimes, .pluginSkillsOverlap: .duplicates
        case .unmanagedSkill: .unmanaged
        case .unreachableMCPCommand, .mcpServerRepeatedAcrossClients: .connections
        case .toolUnavailable, .neverChecked: .settings
        }
    }
}

/// The guided walk: choose apps, audit, have the assistant read it, then one
/// stop per category with every finding and recommendation for it and the
/// actions on each row. Each action is one reviewed change; nothing runs in
/// bulk. Closing at any point keeps what was done; the Checkup tab has the rest.
struct SetupWizardSheet: View {
    let workspace: WorkspaceLaunch.Workspace
    @Bindable var session: WorkspaceSetupSession
    let onClose: () -> Void

    @Environment(\.workspaceNavigate) private var navigate
    @State private var step: SetupWizardStep
    @State private var startedAudit = false
    @State private var startedReview = false
    @State private var expandedRows: Set<String> = []

    /// `initialStep` lets a test or a deep link open on one stop; the app
    /// always starts at the apps.
    init(workspace: WorkspaceLaunch.Workspace, session: WorkspaceSetupSession, onClose: @escaping () -> Void, initialStep: SetupWizardStep = .apps) {
        self.workspace = workspace
        self._session = Bindable(session)
        self.onClose = onClose
        _step = State(initialValue: initialStep)
        // A stop past the audit assumes it ran; do not run it again under a
        // screen that opened directly on a later step.
        _startedAudit = State(initialValue: initialStep != .apps && initialStep != .audit)
        _startedReview = State(initialValue: initialStep != .apps && initialStep != .audit && initialStep != .review)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(step.title).font(AgentFont.pageTitle)
                Text(step.subtitle).font(AgentFont.body).foregroundStyle(.secondary).wrapsLines()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkspaceLayout.pageInset).padding(.top, Space.xxl).padding(.bottom, Space.xl)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Something did not go through", message: message)
                    }
                    if let message = session.lastApplyMessage {
                        HStack(spacing: Space.lg) {
                            StatusGlyph(state: .healthy, size: Size.glyphLarge)
                            Text(message).font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                            Spacer()
                        }
                        .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
                        .background(AgentTheme.controlBackground.opacity(0.6), in: RoundedRectangle.card)
                    }
                    switch step {
                    case .apps: appsStep
                    case .audit: auditStep
                    case .review: reviewStep
                    case .category(let category): categoryStep(category)
                    case .done: doneStep
                    }
                }
                .padding(.horizontal, WorkspaceLayout.pageInset).padding(.bottom, Space.xxxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            footer
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 560, idealHeight: 640)
        .task(id: step) {
            switch step {
            case .audit where !startedAudit:
                startedAudit = true
                await session.audit()
            case .review where !startedReview && session.reviewClient != nil:
                startedReview = true
                await session.review(purpose: .setup)
            default:
                break
            }
        }
    }

    // MARK: Chrome

    private var steps: [SetupWizardStep] {
        var all: [SetupWizardStep] = [.apps, .audit, .review]
        if let checkup = session.checkup { all += SetupWizardStep.categories(in: checkup).map { .category($0) } }
        all.append(.done)
        return all
    }

    private var header: some View {
        HStack(spacing: Space.lg) {
            Image(systemName: "wand.and.stars").font(.system(size: Size.symbol, weight: .medium)).foregroundStyle(.secondary)
            Text("Set up this Mac").font(AgentFont.bodySemibold)
            Spacer()
            let index = steps.firstIndex(of: step) ?? 0
            Text("Step \(index + 1) of \(steps.count)").font(AgentFont.captionMedium).foregroundStyle(.secondary)
            HStack(spacing: Space.xs) {
                ForEach(Array(steps.enumerated()), id: \.element) { position, _ in
                    Capsule().fill(position <= index ? AgentTheme.selection : Color.secondary.opacity(0.18)).frame(width: Size.glyphSlot, height: Space.xs)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, Space.xl)
    }

    private var footer: some View {
        HStack {
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            Spacer()
            if let previous = previousStep {
                Button("Back") { step = previous }
            }
            if step == .done {
                Button("Open Checkup") { navigate(.checkup); onClose() }.primaryActionStyle()
            } else {
                Button(nextTitle) { if let next = nextStep { step = next } }
                    .primaryActionStyle()
                    .disabled(nextStep == nil || (step == .audit && session.isAuditing) || (step == .apps && workspace.device.managedClients.isEmpty))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, Space.xl)
    }

    private var previousStep: SetupWizardStep? {
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        return steps[index - 1]
    }

    private var nextStep: SetupWizardStep? {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    private var nextTitle: String {
        switch step {
        case .apps: "Audit this Mac"
        case .audit: session.reviewClient == nil ? "Continue" : "Ask \(session.reviewClient?.rawValue ?? "")"
        case .review: session.isReviewing ? "Continue without waiting" : "Walk through it"
        default: "Continue"
        }
    }

    // MARK: Steps

    private var appsStep: some View {
        VStack(spacing: 0) {
            ForEach(Array(workspace.device.availableClients.enumerated()), id: \.element) { index, client in
                if index > 0 { Hairline(indent: Hairline.afterLeading(Size.tileLarge, gap: Space.xl)) }
                Toggle(isOn: Binding(get: { workspace.device.isEnabled(client) }, set: { on in Task { await workspace.device.setEnabled(client, on) } })) {
                    HStack(spacing: Space.xl) {
                        ClientBrandIcon(client: client, size: Size.tile).frame(width: Size.tileLarge, height: Size.tileLarge)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(client.rawValue).font(AgentFont.title)
                            Text(workspace.device.verdict(for: client).text).font(AgentFont.body).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusGlyph(state: workspace.device.verdict(for: client).state, size: Size.glyph)
                    }
                }
                .toggleStyle(.checkbox).padding(Space.xxl)
                .accessibilityLabel("Have this Mac manage \(client.rawValue)")
            }
        }
        .standardPanel()
    }

    @ViewBuilder private var auditStep: some View {
        if session.isAuditing || session.checkup == nil {
            HStack(spacing: Space.lg) {
                ProgressView().controlSize(.small)
                Text("Reading what each app holds…").font(AgentFont.body).foregroundStyle(.secondary)
            }
            .padding(Space.xl)
        } else if let checkup = session.checkup {
            let open = checkup.openFindings
            HStack(alignment: .top, spacing: Space.lg) {
                ForEach(checkup.audit.clients) { client in
                    let count = checkup.audit.counts[client]
                    let mine = open.filter { $0.client == client }
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.md) {
                            ClientDisc(client: client, size: Size.disc)
                            Text(client.rawValue).font(AgentFont.bodySemibold)
                        }
                        Text(count.map { "\($0.skills) skills · \($0.plugins) plugins · \($0.mcpServers) servers" } ?? "Not checked")
                            .font(AgentFont.caption).foregroundStyle(.secondary)
                        Text(mine.isEmpty ? "Nothing to fix" : "\(mine.count) to look at").font(AgentFont.captionMedium)
                            .foregroundStyle(mine.isEmpty ? AgentTheme.ok : AgentTheme.warning)
                    }
                    .padding(Space.lg).frame(maxWidth: .infinity, alignment: .leading).standardPanel()
                }
            }
            if open.isEmpty {
                Text("Nothing is broken, duplicated, or unmanaged. Your assistant can still suggest improvements on the next step.")
                    .font(AgentFont.body).foregroundStyle(.secondary)
            } else {
                TitledCard("By kind") {
                    VStack(spacing: 0) {
                        ForEach(SetupFinding.Kind.allCases.filter { kind in open.contains { $0.kind == kind } }, id: \.self) { kind in
                            let count = open.filter { $0.kind == kind }.count
                            HStack {
                                Text(kind.title).font(AgentFont.body)
                                Spacer()
                                Text("\(count)").font(AgentFont.body.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, Space.xl).padding(.vertical, Space.md)
                            Hairline().padding(.leading, Space.xl)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var reviewStep: some View {
        if session.reviewClient == nil {
            Text("A review needs Claude Code or Codex; this Mac is not managing either. The audit's findings are still walked through on the next steps.")
                .font(AgentFont.body).foregroundStyle(.secondary)
        } else if session.isReviewing {
            HStack(spacing: Space.lg) {
                ProgressView().controlSize(.small)
                Text("\(session.reviewClient?.rawValue ?? "") is reading the audit and the apps' configuration folders. This takes a few minutes. You can walk through the findings meanwhile; its recommendations join each step when they land.")
                    .font(AgentFont.body).foregroundStyle(.secondary).wrapsLines()
            }
            .padding(Space.xl)
        } else if let message = session.reviewMessage {
            AttentionBanner(title: "The review did not finish", message: message) {
                Button("Try again") { Task { await session.review(purpose: .setup) } }.secondaryActionStyle().controlSize(.small)
            }
        } else if let review = session.checkup?.review {
            Text(review.summary).font(AgentFont.body).wrapsLines().padding(Space.xl).standardPanel()
            let counts = Dictionary(grouping: session.checkup?.openRecommendations ?? [], by: \.category)
            if !counts.isEmpty {
                TitledCard("Recommendations by step") {
                    VStack(spacing: 0) {
                        ForEach(SetupRecommendation.Category.allCases.filter { counts[$0] != nil }, id: \.self) { category in
                            HStack {
                                Text(category.title).font(AgentFont.body)
                                Spacer()
                                Text("\(counts[category]?.count ?? 0)").font(AgentFont.body.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, Space.xl).padding(.vertical, Space.md)
                            Hairline().padding(.leading, Space.xl)
                        }
                    }
                }
            }
        }
    }

    /// The same grouped rows as the Checkup screen, filtered to one stop, with
    /// one button to take everything the stop can take.
    @ViewBuilder private func categoryStep(_ category: SetupRecommendation.Category) -> some View {
        if let checkup = session.checkup {
            let rows = CheckupTriage.items(from: checkup).filter { item in
                item.recommendation?.category == category || item.findings.contains { $0.kind.category == category }
            }
            let fixable = CheckupTriage.fixAll(rows)
            if rows.isEmpty {
                HStack(spacing: Space.lg) {
                    StatusGlyph(state: .healthy, size: Size.glyphLarge)
                    Text("Nothing left here.").font(AgentFont.body)
                    Spacer()
                }
                .padding(Space.xl).standardPanel()
            } else {
                if !fixable.isEmpty {
                    HStack {
                        Text("\(fixable.total) thing\(fixable.total == 1 ? "" : "s") can be fixed here in one go.").font(AgentFont.body).foregroundStyle(.secondary)
                        Spacer()
                        Button("Fix all \(fixable.total)") {
                            Task { await session.applyAll(fixable.actions, settings: fixable.settings.map { ($0.client, $0.key, $0.value) }) }
                        }
                        .primaryActionStyle().disabled(session.isBusy)
                    }
                    .padding(.horizontal, Space.xl).padding(.vertical, Space.lg).standardPanel()
                }
                if let progress = session.applyProgress {
                    HStack(spacing: Space.lg) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 160)
                        Text("\(progress.done) of \(progress.total) done").font(AgentFont.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                ForEach(CheckupItem.Bucket.allCases, id: \.self) { bucket in
                    let mine = rows.filter { $0.bucket == bucket }
                    if !mine.isEmpty {
                        TitledCard(bucket.title, count: "\(mine.count)") {
                            VStack(spacing: 0) {
                                ForEach(Array(mine.enumerated()), id: \.element.id) { index, item in
                                    CheckupRow(
                                        item: item, isExpanded: expandedRows.contains(item.id), isBusy: session.isApplying,
                                        onToggle: { if expandedRows.contains(item.id) { expandedRows.remove(item.id) } else { expandedRows.insert(item.id) } },
                                        onRun: {
                                            if item.canRun {
                                                Task { await session.applyAll(item.actions, settings: item.settings.map { ($0.client, $0.key, $0.value) }) }
                                            } else if let section = item.opens { navigate(section); onClose() } else { dismiss(item) }
                                        },
                                        onRunOne: { action in Task { await session.apply(action) } },
                                        onDismiss: { dismiss(item) },
                                        onOpen: { section in navigate(section); onClose() })
                                    if index < mine.count - 1 { Hairline(indent: CheckupRow.textIndent) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func dismiss(_ item: CheckupItem) {
        for finding in item.findings { session.dismiss(finding) }
        if let recommendation = item.recommendation { session.dismiss(recommendation) }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if let checkup = session.checkup {
                let open = checkup.openFindings.count + checkup.openRecommendations.count
                HStack(spacing: Space.lg) {
                    StatusGlyph(state: open == 0 ? .healthy : .attention, size: Size.glyphLarge)
                    Text(open == 0 ? "Nothing is left to look at." : "\(open) item\(open == 1 ? "" : "s") left. They stay on the Checkup tab.")
                        .font(AgentFont.body)
                    Spacer()
                }
                .padding(Space.xl).standardPanel()
            }
            Text("The checkup runs again on its own once a week when Agent Tooling opens, and each app's page has a Review button for what has changed upstream.")
                .font(AgentFont.body).foregroundStyle(.secondary).wrapsLines()
        }
    }
}
