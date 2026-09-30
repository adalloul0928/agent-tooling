import AgentToolingCore
import SwiftUI

/// Checkup: what is wrong with this Mac's AI tooling, in a short list you can
/// clear from the top.
///
/// The audit finds hundreds of facts; the assistant speaks for groups of them;
/// this screen shows one row per group in three buckets — to fix, to decide,
/// fine as they are — with one button per row and one button for the lot. A
/// row is one line until it is opened. Every fix goes through the app's own
/// reviewed paths and is backed up or moved to the trash, never deleted.
struct CheckupView: View {
    let workspace: WorkspaceLaunch.Workspace
    @Bindable var session: WorkspaceSetupSession
    @Environment(\.workspaceNavigate) private var navigate
    @State private var expanded: Set<String> = []
    @State private var summaryExpanded = false
    @State private var confirmingFixAll = false
    @State private var openingSetup = false
    @State private var showingFine = false

    private var items: [CheckupItem] { session.checkup.map(CheckupTriage.items) ?? [] }
    private var fixAll: CheckupTriage.FixAllPlan { CheckupTriage.fixAll(items) }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Checkup", context: statusLine) {
                Button {
                    Task { await session.audit() }
                } label: {
                    Label(session.isAuditing ? "Auditing…" : "Audit", systemImage: "magnifyingglass")
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
                    Label(session.isReviewing ? "Reviewing…" : "Ask \(session.reviewClient?.rawValue ?? "assistant")", systemImage: "sparkles")
                }
                .buttonStyle(.glass)
                .disabled(session.isBusy || session.reviewClient == nil)
                .help(reviewHelp)

                Button("Walk through…", systemImage: "wand.and.stars") { openingSetup = true }
                    .buttonStyle(.glass)
                    .help("One step per category, with the findings and recommendations for it.")

                if !fixAll.isEmpty {
                    Button {
                        confirmingFixAll = true
                    } label: {
                        Label("Fix all \(fixAll.total)", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .disabled(session.isBusy)
                    .help("Runs every fix in the \"To fix\" list, after showing you exactly what will happen.")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Something did not go through", message: message)
                    }
                    if let progress = session.applyProgress {
                        progressRow(progress)
                    } else if let message = session.lastApplyMessage {
                        noticeRow(message, state: .healthy)
                    }
                    if let checkup = session.checkup {
                        headline(checkup)
                        assistantLine(checkup)
                        buckets
                    } else if session.isAuditing {
                        noticeRow("Reading what each app holds…", state: .pending)
                    } else {
                        EmptyStateView(
                            symbol: "stethoscope", title: "No checkup yet",
                            message: "Find what is broken, duplicated, or not yet managed, then have your assistant say what to do.",
                            actionTitle: "Audit this Mac", action: { Task { await session.audit() } })
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
        .sheet(isPresented: $confirmingFixAll) {
            FixAllSheet(plan: fixAll, onCancel: { confirmingFixAll = false }) {
                confirmingFixAll = false
                let plan = fixAll
                Task { await session.applyAll(plan.actions, settings: plan.settings.map { ($0.client, $0.key, $0.value) }) }
            }
        }
    }

    // MARK: Top

    private var statusLine: String {
        guard let checkup = session.checkup else { return "Not checked yet" }
        if session.isReviewing { return "\(session.reviewClient?.rawValue ?? "Your assistant") is reading the audit…" }
        return "Checked \(SnapshotTime.compact(checkup.completedAt))"
    }

    private var reviewHelp: String {
        guard let client = session.reviewClient else { return "A review needs Claude Code or Codex; this Mac is not managing either." }
        return "\(client.rawValue) reads the audit and the apps' configuration folders, then says what to change. It can read; it cannot change anything."
    }

    /// The whole picture in one line: how much is left in each bucket.
    private func headline(_ checkup: SetupCheckup) -> some View {
        let fix = items.filter { $0.bucket == .fix }
        let decide = items.filter { $0.bucket == .decide }
        let fine = items.filter { $0.bucket == .fine }
        return HStack(spacing: 0) {
            bucketCount(fix.count, unit: "to fix", state: fix.isEmpty ? .healthy : ((fix.map(\.severity).max() ?? .info) >= .medium ? .attention : .pending))
            Divider().frame(height: 34)
            bucketCount(decide.count, unit: "to decide", state: decide.isEmpty ? .healthy : .pending)
            Divider().frame(height: 34)
            bucketCount(fine.count, unit: fine.count == 1 ? "fine as it is" : "fine as they are", state: .healthy)
            Divider().frame(height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ForEach(checkup.audit.clients) { client in ClientBrandIcon(client: client, size: 14) }
                }
                Text(appsLine(checkup)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
        }
        .padding(.vertical, 12)
        .standardPanel()
    }

    private func bucketCount(_ count: Int, unit: String, state: HealthState) -> some View {
        HStack(spacing: 10) {
            StatusGlyph(state: state, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(unit)")
    }

    private func appsLine(_ checkup: SetupCheckup) -> String {
        let skills = checkup.audit.counts.values.reduce(0) { $0 + $1.skills }
        let plugins = checkup.audit.counts.values.reduce(0) { $0 + $1.plugins }
        let servers = checkup.audit.counts.values.reduce(0) { $0 + $1.mcpServers }
        return "\(skills) skills · \(plugins) plugins · \(servers) servers"
    }

    /// What the assistant said, one sentence at a time.
    @ViewBuilder private func assistantLine(_ checkup: SetupCheckup) -> some View {
        if session.isReviewing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("\(session.reviewClient?.rawValue ?? "Your assistant") is reading the audit and the apps' configuration folders. The list below is ready now; its advice joins it in a few minutes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12).standardPanel()
        } else if let message = session.reviewMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(AgentTheme.warning)
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12).standardPanel()
        } else if let review = checkup.review {
            let sentences = Self.sentences(review.summary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    ClientBrandIcon(client: review.client, size: 16).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summaryExpanded ? review.summary : (sentences.first ?? review.summary))
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        if sentences.count > 1 {
                            Button(summaryExpanded ? "Less" : "More") { withAnimation(AgentMotion.quick) { summaryExpanded.toggle() } }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    Spacer()
                    Text(SnapshotTime.compact(review.generatedAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).standardPanel()
        }
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current.trimmingCharacters(in: .whitespaces)) }
        return out
    }

    // MARK: Buckets

    @ViewBuilder private var buckets: some View {
        let fix = items.filter { $0.bucket == .fix }
        let decide = items.filter { $0.bucket == .decide }
        let fine = items.filter { $0.bucket == .fine }
        if fix.isEmpty && decide.isEmpty {
            HStack(spacing: 10) {
                StatusGlyph(state: .healthy, size: 18)
                Text("Nothing to fix or decide. Your apps are in the shape you left them.").font(.callout)
                Spacer()
            }
            .padding(16).standardPanel()
        }
        if !fix.isEmpty { bucketCard(.fix, fix) }
        if !decide.isEmpty { bucketCard(.decide, decide) }
        if !fine.isEmpty {
            Button(showingFine ? "Hide what is fine" : "Show \(fine.count) that \(fine.count == 1 ? "is" : "are") fine as \(fine.count == 1 ? "it is" : "they are")") {
                withAnimation(AgentMotion.quick) { showingFine.toggle() }
            }
            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            if showingFine { bucketCard(.fine, fine) }
        }
        if let checkup = session.checkup, !checkup.dismissedFindingIDs.isEmpty || !checkup.dismissedRecommendationIDs.isEmpty {
            Text("\(checkup.dismissedFindingIDs.count + checkup.dismissedRecommendationIDs.count) dismissed. They come back if they change.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func bucketCard(_ bucket: CheckupItem.Bucket, _ rows: [CheckupItem]) -> some View {
        TitledCard(bucket.title, count: "\(rows.count)") {
            if bucket == .fine {
                Button("Dismiss all") { for row in rows { dismiss(row) } }.buttonStyle(.borderless)
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    CheckupRow(
                        item: item, isExpanded: expanded.contains(item.id), isBusy: session.isApplying,
                        onToggle: { withAnimation(AgentMotion.quick) { toggle(item) } },
                        onRun: { run(item) },
                        onRunOne: { action in Task { await session.apply(action) } },
                        onDismiss: { dismiss(item) },
                        onOpen: { section in navigate(section) })
                    if index < rows.count - 1 { Divider().padding(.leading, 46) }
                }
            }
        }
    }

    private func toggle(_ item: CheckupItem) {
        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
    }

    private func run(_ item: CheckupItem) {
        if item.canRun {
            Task { await session.applyAll(item.actions, settings: item.settings.map { ($0.client, $0.key, $0.value) }) }
        } else if let section = item.opens {
            navigate(section)
        } else {
            dismiss(item)
        }
    }

    private func dismiss(_ item: CheckupItem) {
        for finding in item.findings { session.dismiss(finding) }
        if let recommendation = item.recommendation { session.dismiss(recommendation) }
    }

    // MARK: Small rows

    private func progressRow(_ progress: (done: Int, total: Int)) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 160)
            Text("\(progress.done) of \(progress.total) done").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AgentTheme.controlBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
}

// MARK: - One row

/// One line: app, what, how many, one button. Open it for the why, where the
/// claim came from, and the individual findings with their own buttons.
struct CheckupRow: View {
    let item: CheckupItem
    let isExpanded: Bool
    let isBusy: Bool
    let onToggle: () -> Void
    let onRun: () -> Void
    let onRunOne: (SetupAction) -> Void
    let onDismiss: () -> Void
    let onOpen: (AppSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onToggle) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        if let client = item.client { ClientBrandIcon(client: client, size: 16).frame(width: 20) }
                        else { Image(systemName: "desktopcomputer").font(.caption).foregroundStyle(.secondary).frame(width: 20) }
                        Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                        if item.severity >= .medium, item.bucket != .fine { SeverityBadge(severity: item.severity) }
                        if item.recommendation != nil {
                            Image(systemName: "sparkles").font(.caption2).foregroundStyle(.secondary)
                                .help("Your assistant spoke to this.")
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                HStack(spacing: 6) {
                    if item.canRun, let title = item.primaryTitle {
                        Button(title, action: onRun)
                            .buttonStyle(.borderedProminent).tint(AgentTheme.selection).controlSize(.small)
                            .disabled(isBusy)
                            .help(item.changesFiles ? "Changes files on this Mac. Removals go to Agent Tooling's trash; configuration files are backed up first." : "Reads only.")
                    } else if let section = item.opens {
                        Button(item.primaryTitle ?? "Open") { onOpen(section) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Button(item.bucket == .fine ? "Dismiss" : "Skip", action: onDismiss)
                        .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
                        .help("Stop mentioning this. It comes back if it changes.")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let recommendation = item.recommendation, !recommendation.rationale.isEmpty, recommendation.rationale != item.detail {
                        Text(recommendation.rationale).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let provenance = item.provenance { ProvenanceLabel(provenance: provenance) }
                    if item.findings.count > 1 || (item.findings.count == 1 && item.recommendation == nil) {
                        findingList
                    }
                }
                .padding(.leading, 46).padding(.trailing, 14).padding(.bottom, 12)
            }
        }
    }

    /// The individual findings behind a group, each with its own button, so a
    /// person can take one without taking them all.
    private var findingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(item.findings.prefix(40).enumerated()), id: \.element.id) { index, finding in
                HStack(spacing: 8) {
                    Text(finding.subject).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    if let first = finding.evidence.first, first != finding.subject {
                        Text(first).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    ForEach(Array(finding.actions.prefix(2).enumerated()), id: \.offset) { _, action in
                        switch action {
                        case .inspectMCPServer, .manageMCPServer:
                            Button(action.title) { onOpen(.mcpServers) }.buttonStyle(.borderless).controlSize(.mini)
                        default:
                            Button(action.title) { onRunOne(action) }.buttonStyle(.borderless).controlSize(.mini).disabled(isBusy)
                        }
                    }
                }
                .padding(.vertical, 3)
                if index < min(item.findings.count, 40) - 1 { Divider().opacity(0.4) }
            }
            if item.findings.count > 40 {
                Text("\(item.findings.count - 40) more of the same.").font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Fix all

/// What "Fix all" will do, counted, before it does it. Nothing is deleted:
/// folders go to the trash and configuration files are backed up.
struct FixAllSheet: View {
    let plan: CheckupTriage.FixAllPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(AgentTheme.selection)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fix \(plan.total) thing\(plan.total == 1 ? "" : "s")").font(.title3.weight(.semibold))
                    Text("Each runs through Agent Tooling's own reviewed path. Nothing is deleted: folders move to the workspace trash and configuration files are copied there first.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.lines, id: \.self) { line in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                        Text(line).font(.callout)
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).standardPanel()
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Fix all", action: onConfirm).buttonStyle(.borderedProminent).tint(AgentTheme.selection).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

// MARK: - Shared bits

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
