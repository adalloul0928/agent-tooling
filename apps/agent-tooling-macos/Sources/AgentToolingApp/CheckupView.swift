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
                    .primaryActionStyle()
                    .disabled(session.isBusy)
                    .help("Runs every fix in the \"To fix\" list, after showing you exactly what will happen.")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
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
            Hairline().frame(height: Size.compactRowHeight)
            bucketCount(decide.count, unit: "to decide", state: decide.isEmpty ? .healthy : .pending)
            Hairline().frame(height: Size.compactRowHeight)
            bucketCount(fine.count, unit: fine.count == 1 ? "fine as it is" : "fine as they are", state: .healthy)
            Hairline().frame(height: Size.compactRowHeight)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    ForEach(checkup.audit.clients) { client in ClientBrandIcon(client: client, size: Size.brandMark) }
                }
                Text(appsLine(checkup)).font(AgentFont.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Space.xl)
        }
        .padding(.vertical, Space.lg)
        .standardPanel()
    }

    private func bucketCount(_ count: Int, unit: String, state: HealthState) -> some View {
        HStack(spacing: Space.lg) {
            StatusGlyph(state: state, size: Size.glyphLarge)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)").font(AgentFont.stat)
                Text(unit).font(AgentFont.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xl)
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
            HStack(spacing: Space.lg) {
                ProgressView().controlSize(.small)
                Text("\(session.reviewClient?.rawValue ?? "Your assistant") is reading the audit and the apps' configuration folders. The list below is ready now; its advice joins it in a few minutes.")
                    .font(AgentFont.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, Space.xl).padding(.vertical, Space.lg).standardPanel()
        } else if let message = session.reviewMessage {
            HStack(alignment: .top, spacing: Space.lg) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(AgentTheme.warning)
                Text(message).font(AgentFont.body).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, Space.xl).padding(.vertical, Space.lg).standardPanel()
        } else if let review = checkup.review {
            let sentences = Self.sentences(review.summary)
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .top, spacing: Space.lg) {
                    ClientBrandIcon(client: review.client, size: Size.brandMark).padding(.top, Space.xxs)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(summaryExpanded ? review.summary : (sentences.first ?? review.summary))
                            .font(AgentFont.body).fixedSize(horizontal: false, vertical: true)
                        if sentences.count > 1 {
                            Button(summaryExpanded ? "Less" : "More") { withAnimation(AgentMotion.quick) { summaryExpanded.toggle() } }
                                .inlineActionStyle().font(AgentFont.caption)
                        }
                    }
                    Spacer()
                    Text(SnapshotTime.compact(review.generatedAt)).font(AgentFont.micro).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Space.xl).padding(.vertical, Space.lg).standardPanel()
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
            HStack(spacing: Space.lg) {
                StatusGlyph(state: .healthy, size: Size.glyphLarge)
                Text("Nothing to fix or decide. Your apps are in the shape you left them.").font(AgentFont.body)
                Spacer()
            }
            .padding(Space.xl).standardPanel()
        }
        if !fix.isEmpty { bucketCard(.fix, fix) }
        if !decide.isEmpty { bucketCard(.decide, decide) }
        if !fine.isEmpty {
            Button(showingFine ? "Hide what is fine" : "Show \(fine.count) that \(fine.count == 1 ? "is" : "are") fine as \(fine.count == 1 ? "it is" : "they are")") {
                withAnimation(AgentMotion.quick) { showingFine.toggle() }
            }
            .inlineActionStyle().font(AgentFont.caption).foregroundStyle(.secondary)
            if showingFine { bucketCard(.fine, fine) }
        }
        if let checkup = session.checkup, !checkup.dismissedFindingIDs.isEmpty || !checkup.dismissedRecommendationIDs.isEmpty {
            Text("\(checkup.dismissedFindingIDs.count + checkup.dismissedRecommendationIDs.count) dismissed. They come back if they change.")
                .font(AgentFont.micro).foregroundStyle(.tertiary)
        }
    }

    private func bucketCard(_ bucket: CheckupItem.Bucket, _ rows: [CheckupItem]) -> some View {
        TitledCard(bucket.title, count: "\(rows.count)") {
            if bucket == .fine {
                Button("Dismiss all") { for row in rows { dismiss(row) } }.inlineActionStyle()
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
                    if index < rows.count - 1 { Hairline(indent: CheckupRow.textIndent) }
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
        HStack(spacing: Space.lg) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 160)
            Text("\(progress.done) of \(progress.total) done").font(AgentFont.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
        .background(AgentTheme.controlBackground.opacity(0.6), in: RoundedRectangle.card)
    }

    private func noticeRow(_ text: String, state: HealthState) -> some View {
        HStack(spacing: Space.lg) {
            StatusGlyph(state: state, size: Size.glyphLarge)
            Text(text).font(AgentFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.lg)
        }
        .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
        .background(AgentTheme.controlBackground.opacity(0.6), in: RoundedRectangle.card)
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

    /// Where the title starts: past the chevron slot and the app mark, so the
    /// hairline under a row and the expanded detail both line up with it.
    static let textIndent = Hairline.afterLeading(Size.glyphSmall + Space.lg + Size.glyphSlot)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.lg) {
                Button(action: onToggle) {
                    HStack(spacing: Space.lg) {
                        Image(systemName: "chevron.right")
                            .font(AgentFont.microBold).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: Size.glyphSmall)
                        if let client = item.client { ClientBrandIcon(client: client, size: Size.brandMark).frame(width: Size.glyphSlot) }
                        else { Image(systemName: "desktopcomputer").font(AgentFont.caption).foregroundStyle(.secondary).frame(width: Size.glyphSlot) }
                        Text(item.title).font(AgentFont.bodyMedium).lineLimit(1)
                        if item.severity >= .medium, item.bucket != .fine { SeverityBadge(severity: item.severity) }
                        if item.recommendation != nil {
                            Image(systemName: "sparkles").font(AgentFont.micro).foregroundStyle(.secondary)
                                .help("Your assistant spoke to this.")
                        }
                        Spacer(minLength: Space.md)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                HStack(spacing: Space.sm) {
                    if item.canRun, let title = item.primaryTitle {
                        Button(title, action: onRun)
                            .primaryActionStyle().controlSize(.small)
                            .disabled(isBusy)
                            .help(item.changesFiles ? "Changes files on this Mac. Removals go to Agent Tooling's trash; configuration files are backed up first." : "Reads only.")
                    } else if let section = item.opens {
                        Button(item.primaryTitle ?? "Open") { onOpen(section) }.secondaryActionStyle().controlSize(.small)
                    }
                    Button(item.bucket == .fine ? "Dismiss" : "Skip", action: onDismiss)
                        .inlineActionStyle().controlSize(.small).foregroundStyle(.secondary)
                        .help("Stop mentioning this. It comes back if it changes.")
                }
            }
            .padding(.horizontal, Space.xl).padding(.vertical, Space.md)

            if isExpanded {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(item.detail).font(AgentFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let recommendation = item.recommendation, !recommendation.rationale.isEmpty, recommendation.rationale != item.detail {
                        Text(recommendation.rationale).font(AgentFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let provenance = item.provenance { ProvenanceLabel(provenance: provenance) }
                    if item.findings.count > 1 || (item.findings.count == 1 && item.recommendation == nil) {
                        findingList
                    }
                }
                .padding(.leading, CheckupRow.textIndent).padding(.trailing, Space.xl).padding(.bottom, Space.lg)
            }
        }
    }

    /// The individual findings behind a group, each with its own button, so a
    /// person can take one without taking them all.
    private var findingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(item.findings.prefix(40).enumerated()), id: \.element.id) { index, finding in
                HStack(spacing: Space.md) {
                    Text(finding.subject).font(AgentFont.mono).lineLimit(1).truncationMode(.middle)
                    if let first = finding.evidence.first, first != finding.subject {
                        Text(first).font(AgentFont.mono).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: Space.md)
                    ForEach(Array(finding.actions.prefix(2).enumerated()), id: \.offset) { _, action in
                        switch action {
                        case .inspectMCPServer, .manageMCPServer:
                            Button(action.title) { onOpen(.mcpServers) }.inlineActionStyle().controlSize(.mini)
                        default:
                            Button(action.title) { onRunOne(action) }.inlineActionStyle().controlSize(.mini).disabled(isBusy)
                        }
                    }
                }
                .padding(.vertical, Space.xxs)
                if index < min(item.findings.count, 40) - 1 { Hairline() }
            }
            if item.findings.count > 40 {
                Text("\(item.findings.count - 40) more of the same.").font(AgentFont.micro).foregroundStyle(.tertiary).padding(.top, Space.xs)
            }
        }
        .padding(Space.lg)
        .background(AgentTheme.fillSubtle, in: RoundedRectangle.control)
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
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.lg) {
                Image(systemName: "checkmark.circle").font(.system(size: Size.heroSymbol)).foregroundStyle(AgentTheme.selection)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Fix \(plan.total) thing\(plan.total == 1 ? "" : "s")").font(AgentFont.title)
                    Text("Each runs through Agent Tooling's own reviewed path. Nothing is deleted: folders move to the workspace trash and configuration files are copied there first.")
                        .font(AgentFont.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(plan.lines, id: \.self) { line in
                    HStack(spacing: Space.md) {
                        Image(systemName: "arrow.turn.down.right").font(AgentFont.caption).foregroundStyle(.tertiary)
                        Text(line).font(AgentFont.body)
                    }
                }
            }
            .padding(Space.xl).frame(maxWidth: .infinity, alignment: .leading).standardPanel()
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Fix all", action: onConfirm).primaryActionStyle().keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xxxl)
        .frame(width: 520)
    }
}

// MARK: - Shared bits

struct SeverityBadge: View {
    let severity: SetupFinding.Severity
    var body: some View {
        Text(severity.rawValue.capitalized)
            .font(AgentFont.microSemibold)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
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
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).font(AgentFont.micro)
            Text(provenance.label).font(AgentFont.micro)
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
