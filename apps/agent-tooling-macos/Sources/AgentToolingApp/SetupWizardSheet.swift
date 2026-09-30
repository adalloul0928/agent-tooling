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
        case .duplicateSkillInClient: .duplicates
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
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.system(size: 20, weight: .semibold))
                Text(step.subtitle).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkspaceLayout.pageInset).padding(.top, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Something did not go through", message: message)
                    }
                    if let message = session.lastApplyMessage {
                        HStack(spacing: 10) {
                            StatusGlyph(state: .healthy, size: 16)
                            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(AgentTheme.controlBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    switch step {
                    case .apps: appsStep
                    case .audit: auditStep
                    case .review: reviewStep
                    case .category(let category): categoryStep(category)
                    case .done: doneStep
                    }
                }
                .padding(.horizontal, WorkspaceLayout.pageInset).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
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
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
            Text("Set up this Mac").font(.system(size: 14, weight: .semibold))
            Spacer()
            let index = steps.firstIndex(of: step) ?? 0
            Text("Step \(index + 1) of \(steps.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.element) { position, _ in
                    Capsule().fill(position <= index ? AgentTheme.selection : Color.secondary.opacity(0.18)).frame(width: 18, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            Spacer()
            if let previous = previousStep {
                Button("Back") { step = previous }
            }
            if step == .done {
                Button("Open Checkup") { navigate(.checkup); onClose() }.buttonStyle(.borderedProminent).tint(AgentTheme.selection)
            } else {
                Button(nextTitle) { if let next = nextStep { step = next } }
                    .buttonStyle(.borderedProminent).tint(AgentTheme.selection)
                    .disabled(nextStep == nil || (step == .audit && session.isAuditing) || (step == .apps && workspace.device.managedClients.isEmpty))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, 14)
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
                if index > 0 { Divider().padding(.leading, 64) }
                Toggle(isOn: Binding(get: { workspace.device.isEnabled(client) }, set: { on in Task { await workspace.device.setEnabled(client, on) } })) {
                    HStack(spacing: 14) {
                        ClientBrandIcon(client: client, size: 28).frame(width: 36, height: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.rawValue).font(.system(size: 16, weight: .semibold))
                            Text(workspace.device.verdict(for: client).text).font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusGlyph(state: workspace.device.verdict(for: client).state, size: 14)
                    }
                }
                .toggleStyle(.checkbox).padding(18)
                .accessibilityLabel("Have this Mac manage \(client.rawValue)")
            }
        }
        .standardPanel()
    }

    @ViewBuilder private var auditStep: some View {
        if session.isAuditing || session.checkup == nil {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Reading what each app holds…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(14)
        } else if let checkup = session.checkup {
            let open = checkup.openFindings
            HStack(alignment: .top, spacing: 12) {
                ForEach(checkup.audit.clients) { client in
                    let count = checkup.audit.counts[client]
                    let mine = open.filter { $0.client == client }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ClientDisc(client: client, size: 28)
                            Text(client.rawValue).font(.callout.weight(.semibold))
                        }
                        Text(count.map { "\($0.skills) skills · \($0.plugins) plugins · \($0.mcpServers) servers" } ?? "Not checked")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(mine.isEmpty ? "Nothing to fix" : "\(mine.count) to look at").font(.caption.weight(.medium))
                            .foregroundStyle(mine.isEmpty ? AgentTheme.ok : AgentTheme.warning)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).standardPanel()
                }
            }
            if open.isEmpty {
                Text("Nothing is broken, duplicated, or unmanaged. Your assistant can still suggest improvements on the next step.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TitledCard("By kind") {
                    VStack(spacing: 0) {
                        ForEach(SetupFinding.Kind.allCases.filter { kind in open.contains { $0.kind == kind } }, id: \.self) { kind in
                            let count = open.filter { $0.kind == kind }.count
                            HStack {
                                Text(kind.title).font(.callout)
                                Spacer()
                                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var reviewStep: some View {
        if session.reviewClient == nil {
            Text("A review needs Claude Code or Codex; this Mac is not managing either. The audit's findings are still walked through on the next steps.")
                .font(.callout).foregroundStyle(.secondary)
        } else if session.isReviewing {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("\(session.reviewClient?.rawValue ?? "") is reading the audit and the apps' configuration folders. This takes a few minutes. You can walk through the findings meanwhile; its recommendations join each step when they land.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        } else if let message = session.reviewMessage {
            AttentionBanner(title: "The review did not finish", message: message) {
                Button("Try again") { Task { await session.review(purpose: .setup) } }.buttonStyle(.bordered).controlSize(.small)
            }
        } else if let review = session.checkup?.review {
            Text(review.summary).font(.callout).fixedSize(horizontal: false, vertical: true).padding(14).standardPanel()
            let counts = Dictionary(grouping: session.checkup?.openRecommendations ?? [], by: \.category)
            if !counts.isEmpty {
                TitledCard("Recommendations by step") {
                    VStack(spacing: 0) {
                        ForEach(SetupRecommendation.Category.allCases.filter { counts[$0] != nil }, id: \.self) { category in
                            HStack {
                                Text(category.title).font(.callout)
                                Spacer()
                                Text("\(counts[category]?.count ?? 0)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func categoryStep(_ category: SetupRecommendation.Category) -> some View {
        if let checkup = session.checkup {
            let recommendations = checkup.openRecommendations.filter { $0.category == category }
            let findings = checkup.openFindings.filter { $0.kind.category == category }
            if !recommendations.isEmpty {
                TitledCard("Your assistant recommends", count: "\(recommendations.count)") {
                    VStack(spacing: 0) {
                        ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, recommendation in
                            RecommendationRowView(
                                recommendation: recommendation, isBusy: session.isApplying,
                                onApply: { Task { await session.apply(recommendation.action) } },
                                onDismiss: { session.dismiss(recommendation) },
                                onOpen: { openScreen(for: recommendation) })
                            if index < recommendations.count - 1 { Divider().padding(.leading, 14) }
                        }
                    }
                }
            }
            if !findings.isEmpty {
                TitledCard("Findings", count: "\(findings.count)") {
                    VStack(spacing: 0) {
                        ForEach(Array(findings.prefix(80).enumerated()), id: \.element.id) { index, finding in
                            FindingRowView(
                                finding: finding, isBusy: session.isApplying,
                                onApply: { action in Task { await session.apply(action) } },
                                onDismiss: { session.dismiss(finding) },
                                onOpen: { openScreen(for: $0) })
                            if index < min(findings.count, 80) - 1 { Divider().padding(.leading, 14) }
                        }
                    }
                }
            }
            if recommendations.isEmpty && findings.isEmpty {
                HStack(spacing: 10) {
                    StatusGlyph(state: .healthy, size: 16)
                    Text("Nothing left here.").font(.callout)
                    Spacer()
                }
                .padding(14).standardPanel()
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let checkup = session.checkup {
                let open = checkup.openFindings.count + checkup.openRecommendations.count
                HStack(spacing: 10) {
                    StatusGlyph(state: open == 0 ? .healthy : .attention, size: 18)
                    Text(open == 0 ? "Nothing is left to look at." : "\(open) item\(open == 1 ? "" : "s") left. They stay on the Checkup tab.")
                        .font(.callout)
                    Spacer()
                }
                .padding(14).standardPanel()
            }
            Text("The checkup runs again on its own once a week when Agent Tooling opens, and each app's page has a Review button for what has changed upstream.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openScreen(for action: SetupAction) {
        switch action {
        case .inspectMCPServer, .manageMCPServer: navigate(.mcpServers); onClose()
        default: break
        }
    }

    private func openScreen(for recommendation: SetupRecommendation) {
        switch recommendation.action {
        case .take(let action): openScreen(for: action)
        case .setSetting: navigate(.appSettings); onClose()
        case .disableMCPServer: navigate(.mcpServers); onClose()
        case .installPlugin: navigate(.plugins); onClose()
        case .readOnly: break
        }
    }
}
