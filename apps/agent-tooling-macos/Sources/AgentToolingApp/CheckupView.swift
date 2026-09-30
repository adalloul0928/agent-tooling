import AgentToolingCore
import SwiftUI

/// Checkup: the deterministic audit of this Mac's tooling, the assistant's
/// reading of it, and the actions for each, one reviewed step at a time.
///
/// The audit is fast and always shown first; the review arrives behind it. A
/// finding is a fact with its evidence; a recommendation is the assistant's
/// proposal and says where its claim came from. Nothing on this screen changes
/// an app until a button on one row is pressed, and each press is one action.
struct CheckupView: View {
    let workspace: WorkspaceLaunch.Workspace
    @Bindable var session: WorkspaceSetupSession
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.workspaceNavigate) private var navigate
    @State private var showDismissed = false
    @State private var openingSetup = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Checkup", context: statusLine) {
                Button {
                    Task { await session.audit() }
                } label: {
                    Label(session.isAuditing ? "Auditing…" : "Audit now", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .disabled(session.isBusy)
                .help("Read what each app holds and list what is broken, duplicated, or unmanaged. Nothing is changed.")

                Button {
                    Task {
                        if session.checkup == nil { await session.audit() }
                        await session.review(purpose: .checkup)
                    }
                } label: {
                    Label(session.isReviewing ? "Reviewing…" : reviewTitle, systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(AgentTheme.selection)
                .disabled(session.isBusy || session.reviewClient == nil)
                .help(reviewHelp)

                Button("Set up…", systemImage: "wand.and.stars") { openingSetup = true }
                    .buttonStyle(.glass)
                    .help("Walk through everything the audit found, category by category.")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Something did not go through", message: message)
                    }
                    if let message = session.lastApplyMessage {
                        noticeRow(message, state: .healthy)
                    }
                    if let checkup = session.checkup {
                        summaryCard(checkup)
                        reviewCard(checkup)
                        findingsCards(checkup)
                    } else if session.isAuditing {
                        noticeRow("Reading what each app holds…", state: .pending)
                    } else {
                        EmptyStateView(
                            symbol: "stethoscope", title: "No checkup yet",
                            message: "Audit this Mac to see what is broken, duplicated, or not yet managed, then have your assistant read the results.",
                            actionTitle: "Audit now", action: { Task { await session.audit() } })
                        .frame(height: 220)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WorkspaceLayout.pageInset)
                .padding(.top, WorkspaceLayout.contentTopInset)
                .padding(.bottom, WorkspaceLayout.pageInset)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $openingSetup) {
            SetupWizardSheet(workspace: workspace, session: session, onClose: { openingSetup = false })
        }
    }

    // MARK: Header

    private var statusLine: String {
        guard let checkup = session.checkup else { return "Not checked yet" }
        let open = checkup.openFindings.count
        let when = SnapshotTime.compact(checkup.completedAt)
        if session.isReviewing { return "\(session.reviewClient?.rawValue ?? "Your assistant") is reading the audit…" }
        return open == 0 ? "Nothing needs attention · \(when)" : "\(open) finding\(open == 1 ? "" : "s") · \(when)"
    }

    private var reviewTitle: String {
        session.reviewClient.map { "Review with \($0.rawValue)" } ?? "Review"
    }

    private var reviewHelp: String {
        guard let client = session.reviewClient else { return "A review needs Claude Code or Codex; this Mac is not managing either." }
        return "Has your signed-in \(client.rawValue) read the audit and the apps' own configuration folders, then say what to change. It can read; it cannot change anything. Runs on its own once a week when the app opens."
    }

    private func summaryCard(_ checkup: SetupCheckup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(checkup.audit.clients) { client in
                let count = checkup.audit.counts[client]
                let open = checkup.openFindings.filter { $0.client == client }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ClientDisc(client: client, size: 28)
                        Text(client.rawValue).font(.callout.weight(.semibold))
                        Spacer(minLength: 4)
                        if open.isEmpty {
                            StatusGlyph(state: .healthy, size: 14)
                        } else {
                            Text("\(open.count)").font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background((open.map(\.severity).max() ?? .info) >= .medium ? AgentTheme.warning.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                    Text(count.map { "\($0.skills) skills · \($0.plugins) plugins · \($0.mcpServers) servers" } ?? "Not checked")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .standardPanel()
            }
        }
    }

    // MARK: Review

    @ViewBuilder private func reviewCard(_ checkup: SetupCheckup) -> some View {
        if session.isReviewing {
            TitledCard("What your assistant says") {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("\(session.reviewClient?.rawValue ?? "Your assistant") is reading the audit and the apps' configuration folders. This takes a few minutes; the findings below are ready now.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(14)
            }
        } else if let message = session.reviewMessage {
            TitledCard("What your assistant says") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(AgentTheme.warning)
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(14)
            }
        } else if let review = checkup.review {
            let open = checkup.openRecommendations
            TitledCard("What \(review.client.rawValue) says", count: open.isEmpty ? nil : "\(open.count)") {
                Text(SnapshotTime.compact(review.generatedAt)).foregroundStyle(.tertiary)
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(review.summary).font(.callout).fixedSize(horizontal: false, vertical: true).padding(14)
                    ForEach(open) { recommendation in
                        Divider()
                        RecommendationRowView(
                            recommendation: recommendation, isBusy: session.isApplying,
                            onApply: { Task { await session.apply(recommendation.action) } },
                            onDismiss: { session.dismiss(recommendation) },
                            onOpen: { openScreen(for: recommendation) })
                    }
                }
            }
        }
    }

    // MARK: Findings

    @ViewBuilder private func findingsCards(_ checkup: SetupCheckup) -> some View {
        let open = checkup.openFindings
        if open.isEmpty {
            TitledCard("Findings") {
                HStack(spacing: 10) {
                    StatusGlyph(state: .healthy, size: 16)
                    Text("Nothing is broken, duplicated, or unmanaged in the apps this Mac looks after.").font(.callout)
                    Spacer()
                }
                .padding(14)
            }
        } else {
            ForEach(SetupFinding.Kind.allCases, id: \.self) { kind in
                let matching = open.filter { $0.kind == kind }
                if !matching.isEmpty {
                    TitledCard(kind.title, count: "\(matching.count)") {
                        VStack(spacing: 0) {
                            ForEach(Array(matching.prefix(60).enumerated()), id: \.element.id) { index, finding in
                                FindingRowView(
                                    finding: finding, isBusy: session.isApplying,
                                    onApply: { action in Task { await session.apply(action) } },
                                    onDismiss: { session.dismiss(finding) },
                                    onOpen: { openScreen(for: $0) })
                                if index < min(matching.count, 60) - 1 { Divider().padding(.leading, 14) }
                            }
                            if matching.count > 60 {
                                Divider()
                                Text("\(matching.count - 60) more of the same kind. Handle these and the rest follow.")
                                    .font(.caption).foregroundStyle(.secondary).padding(12)
                            }
                        }
                    }
                }
            }
        }
        if !checkup.dismissedFindingIDs.isEmpty || !checkup.dismissedRecommendationIDs.isEmpty {
            Button(showDismissed ? "Hide dismissed" : "Show \(checkup.dismissedFindingIDs.count + checkup.dismissedRecommendationIDs.count) dismissed") {
                showDismissed.toggle()
            }
            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            if showDismissed {
                TitledCard("Dismissed") {
                    VStack(spacing: 0) {
                        ForEach(checkup.audit.findings.filter { checkup.dismissedFindingIDs.contains($0.id) }) { finding in
                            HStack {
                                Text(finding.title).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button("Bring back") { session.undismiss(finding) }.buttonStyle(.borderless).font(.caption)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    private func noticeRow(_ text: String, state: HealthState) -> some View {
        HStack(spacing: 10) {
            StatusGlyph(state: state, size: 16)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AgentTheme.controlBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Opening

    /// Actions that open a screen rather than change a file.
    private func openScreen(for action: SetupAction) {
        switch action {
        case .inspectMCPServer, .manageMCPServer: navigate(.mcpServers)
        default: break
        }
    }

    private func openScreen(for recommendation: SetupRecommendation) {
        switch recommendation.action {
        case .take(let action): openScreen(for: action)
        case .setSetting: navigate(.appSettings)
        case .disableMCPServer: navigate(.mcpServers)
        case .installPlugin: navigate(.plugins)
        case .readOnly: break
        }
    }
}

extension SetupFinding.Kind {
    var title: String {
        switch self {
        case .brokenSkillLink: "Links that point at nothing"
        case .missingPluginInstall: "Plugins whose files are gone"
        case .duplicateSkillInClient: "Skills an app can reach twice"
        case .unmanagedSkill: "Skills not managed by this app"
        case .unreachableMCPCommand: "MCP servers that cannot start"
        case .stalePluginCache: "Old plugin versions on disk"
        case .toolUnavailable: "Apps whose command could not be run"
        case .neverChecked: "Apps never checked"
        case .skillWithoutDefinition: "Skill folders with no definition"
        case .mcpServerRepeatedAcrossClients: "Servers configured in several apps"
        }
    }
}

/// One finding: what it is, the proof, and the ways to deal with it. The
/// first action is the preferred one and gets the prominent button; anything
/// that changes files says so in its help.
struct FindingRowView: View {
    let finding: SetupFinding
    let isBusy: Bool
    let onApply: (SetupAction) -> Void
    let onDismiss: () -> Void
    let onOpen: (SetupAction) -> Void
    @State private var showingEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if let client = finding.client { ClientBrandIcon(client: client, size: 16).frame(width: 22).padding(.top, 2) }
                else { Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 22).padding(.top, 2) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(finding.title).font(.callout.weight(.medium))
                        SeverityBadge(severity: finding.severity)
                    }
                    Text(finding.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !finding.evidence.isEmpty {
                        Button(showingEvidence ? "Hide evidence" : "Show evidence") { showingEvidence.toggle() }
                            .buttonStyle(.borderless).font(.caption2)
                        if showingEvidence {
                            ForEach(finding.evidence, id: \.self) { line in
                                Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    ForEach(Array(finding.actions.enumerated()), id: \.offset) { index, action in
                        if index == 0 {
                            Button(action.title) { press(action) }
                                .buttonStyle(.borderedProminent).tint(AgentTheme.selection)
                                .controlSize(.small).disabled(isBusy).help(help(for: action))
                        } else {
                            Button(action.title) { press(action) }
                                .buttonStyle(.bordered)
                                .controlSize(.small).disabled(isBusy).help(help(for: action))
                        }
                    }
                    Button("Dismiss", action: onDismiss).buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
                        .help("Stop mentioning this. It comes back if it changes.")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// An action that changes files, checks, or looks for a tool runs; one
    /// that only names a screen opens it.
    private func press(_ action: SetupAction) {
        switch action {
        case .inspectMCPServer, .manageMCPServer: onOpen(action)
        default: onApply(action)
        }
    }

    private func help(for action: SetupAction) -> String {
        switch action {
        case .adoptSkill: "Copies the files into the library as yours. The app's folder is not changed."
        case .removeSkillCopy: "Moves this folder into Agent Tooling's trash so it can be put back. The library's copy, if any, stays."
        case .removeBrokenLink: "Removes the link. Nothing else is touched."
        case .reinstallPlugin: "Runs the app's own plugin install command."
        case .pruneStalePluginCache: "Moves the unused version folders into Agent Tooling's trash."
        case .inspectMCPServer: "Opens Connections, where this server's configuration is shown."
        case .locateTool: "Asks your login shell where the tool lives, and records the folder."
        case .checkClient: "Reads what the app holds. Nothing is changed."
        case .manageMCPServer: "Opens Connections to bring this server into the library once."
        }
    }
}

/// One recommendation: the proposal, why, where the claim came from, and the
/// one action it carries.
struct RecommendationRowView: View {
    let recommendation: SetupRecommendation
    let isBusy: Bool
    let onApply: () -> Void
    let onDismiss: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let client = recommendation.client { ClientBrandIcon(client: client, size: 16).frame(width: 22).padding(.top, 2) }
            else { Image(systemName: "sparkles").foregroundStyle(.secondary).frame(width: 22).padding(.top, 2) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(recommendation.title).font(.callout.weight(.medium))
                    Text(recommendation.category.title).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                }
                Text(recommendation.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                Text(recommendation.rationale).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ProvenanceLabel(provenance: recommendation.provenance)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                switch recommendation.action {
                case .take(let action):
                    Button(action.title) { action.changesFiles ? onApply() : onOpen() }
                        .buttonStyle(.borderedProminent).tint(AgentTheme.selection).controlSize(.small).disabled(isBusy)
                case .installPlugin(_, let pluginID):
                    Button("Install \(pluginID.split(separator: "@").first.map(String.init) ?? pluginID)", action: onApply)
                        .buttonStyle(.borderedProminent).tint(AgentTheme.selection).controlSize(.small).disabled(isBusy)
                case .setSetting(_, let key, let value):
                    Button("Open settings", action: onOpen).buttonStyle(.bordered).controlSize(.small)
                        .help("Set \(key) to \(value). Settings are changed on the Settings tab, where the file is shown.")
                case .disableMCPServer(_, let name):
                    Button("Open connections", action: onOpen).buttonStyle(.bordered).controlSize(.small)
                        .help("Turn \(name) off from Connections.")
                case .readOnly:
                    EmptyView()
                }
                Button("Dismiss", action: onDismiss).buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct SeverityBadge: View {
    let severity: SetupFinding.Severity
    var body: some View {
        Text(severity.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch severity {
        case .high: AgentTheme.failure
        case .medium: AgentTheme.warning
        case .low: Color.secondary
        case .info: Color.secondary.opacity(0.7)
        }
    }
}

/// Where a recommendation's claim came from, in the words the app uses.
struct ProvenanceLabel: View {
    let provenance: SetupRecommendationProvenance
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2)
            Text(provenance.label).font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .help(help)
    }
    private var symbol: String {
        switch provenance {
        case .audit: "checkmark.seal"
        case .investigated: "doc.text.magnifyingglass"
        case .opinion: "quote.bubble"
        }
    }
    private var help: String {
        switch provenance {
        case .audit: "Grounded in a finding the deterministic audit proved."
        case .investigated(let source): "The assistant read this itself: \(source)"
        case .opinion: "The assistant's judgment, with no specific file or finding behind it."
        }
    }
}
