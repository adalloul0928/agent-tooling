import AgentToolingCore
import SwiftUI

protocol OperationReceiptReading: Sendable {
    func recentReceipts(store: WorkspaceRevisionStore, limit: Int) throws -> [OperationReceipt]
}

struct LiveOperationReceiptReader: OperationReceiptReading {
    func recentReceipts(store: WorkspaceRevisionStore, limit: Int) throws -> [OperationReceipt] {
        try store.operationReceipts(limit: limit)
    }
}

extension EnvironmentValues {
    @Entry var operationReceiptReader: any OperationReceiptReading = LiveOperationReceiptReader()
}

/// Shows observed client installations alongside proposed changes.
/// Counts come from read-only observations, not library assignments.
/// Selecting an app filters the lists; mutations require the reviewed plan.
struct SyncCenterView: View {
    let workspace: WorkspaceLaunch.Workspace
    let requests: WorkspaceRequestSession
    /// The one client this visit is narrowed to, or every client.
    let client: ClientKind?
    let onShowAllClients: () -> Void
    let onReviewChanges: () -> Void
    let onReviewRequest: (PendingAgentRequest) -> Void

    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.availableClients) private var enabledClients
    @Environment(\.workspaceNavigate) private var navigate
    @Environment(\.operationReceiptReader) private var receiptReader
    @State private var showingClientSelection = false
    @State private var expandedReviewRows: Set<String> = []
    @State private var isChoosingDestination = false
    @State private var receipts: [OperationReceipt] = []

    var body: some View {
        VStack(spacing: 0) {
            // One app chosen: this is that app's page, and says so. No app
            // chosen: every app, and the way to choose which ones are managed.
            PageToolbar(title: client?.rawValue ?? "Apps", context: statusLine, usesSectionTitle: client == nil) {
                if client != nil {
                    Button("All apps", systemImage: "chevron.left", action: onShowAllClients)
                        .buttonStyle(.glass)
                        .help("Back to every app on this Mac")
                } else {
                    Button("Choose apps…") { showingClientSelection = true }
                        .buttonStyle(.glass)
                        .popover(isPresented: $showingClientSelection) {
                            ManagedClientsPopover(device: workspace.device).frame(width: Size.managedClientsPopover)
                        }
                    SetUpThisMacButton()
                        .buttonStyle(.glass)
                }
                Button {
                    Task { await workspace.device.refresh() }
                } label: {
                    Label(
                        workspace.device.isChecking ? "Checking…" : ActionTitles.checkApps,
                        systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(workspace.device.isChecking)
                .help("Read what each app holds on this Mac. Nothing is changed.")
                .accessibilityLabel(ActionTitles.checkApps)

                if hasMissingManagedTool {
                    Button {
                        Task { await workspace.device.smartFindTools() }
                    } label: {
                        Label(
                            workspace.device.isFindingTools ? "Finding…" : "Find missing tools",
                            systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.glass)
                    .disabled(workspace.device.isFindingTools || workspace.device.isChecking)
                    .help(
                        "Asks your login shell where the missing tools live — the same answer your terminal gives — and records the folder so future checks look there."
                    )
                    .accessibilityLabel("Find missing tools")
                }

                Button(action: onReviewChanges) {
                    Label(
                        workspace.deployment.isBusy ? "Preparing…" : reviewTitle,
                        systemImage: "arrow.down.circle")
                }
                .primaryActionStyle()
                .disabled(workspace.deployment.isBusy)
                .help("See exactly what would change in each app before anything is written.")
                .accessibilityLabel(reviewTitle)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        AttentionBanner(title: "Apps need attention", message: problem)
                    }
                    if let added = workspace.device.libraryUpdateMessage {
                        // A check that found something the library lacked has
                        // grown the library. It is news rather than a fault,
                        // so it is said plainly and goes away on the next check.
                        HStack(spacing: Space.lg) {
                            StatusGlyph(state: .healthy, size: Size.glyphLarge)
                            Text(added).font(AgentFont.caption).foregroundStyle(.secondary)
                                .wrapsLines()
                            Spacer(minLength: Space.lg)
                        }
                        .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
                        .background(AgentTheme.controlBackground.opacity(Opacity.insetGround), in: RoundedRectangle.card)
                        .accessibilityLabel(added)
                    }

                    if let client {
                        clientHeader(client)
                        clientReviewCard(client)
                    } else {
                        appTiles
                    }

                    if workspace.deployment.plan != nil {
                        // What is ready to install: a step left alone is never
                        // counted as waiting (D6).
                        let items = scoped(workspace.deployment.pendingItems)
                        if !items.isEmpty { changesCard(items) }
                    }

                    if !scopedRequests.isEmpty { pendingRequestsCard }

                    receiptsCard

                    linkedDestinationsCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WorkspaceLayout.pageInset)
                .padding(.top, WorkspaceLayout.contentTopInset)
                .padding(.bottom, WorkspaceLayout.pageInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isChoosingDestination) {
            WorkspaceLinkDestinationSheet(session: workspace.deployment, clients: enabledClients)
        }
        .task {
            // The shell opens the workspace without reading its library, so a
            // screen that arrives first has to read it or it would report a
            // full library as an empty one. A library another screen already
            // read is left alone.
            if workspace.library.state == nil { await workspace.library.refresh() }
            await requests.refresh()
        }
        // Re-read after a run, so "Recent changes" is what just happened rather
        // than what happened before it.
        .task(id: workspace.deployment.results.count) { await loadReceipts() }
        // What would change is a read, so it is worked out as soon as a check
        // has landed in the library, and again after every later check, rather
        // than waiting for somebody to ask. Asking opens the review; this only
        // fills the tiles and the line under the title.
        .task(id: scanStamp) {
            guard scanStamp != nil else { return }
            await workspace.deployment.prepare()
        }
        .onChange(of: workspace.device.enabledClients) { _, _ in
            if let client, !workspace.device.isEnabled(client) { onShowAllClients() }
        }
    }

    // MARK: - Header

    /// One line under the title. It says the most useful true thing and nothing
    /// else: what is waiting, or that nothing is, and when this Mac last looked.
    private var statusLine: String {
        if workspace.device.observations.isEmpty { return "Check your apps to see what they hold" }
        guard workspace.deployment.plan != nil else {
            if workspace.deployment.isBusy { return "Working out what would change…" }
            return lastChecked.map { "Checked \(SnapshotTime.compact($0))" } ?? "Checked"
        }
        let waiting = scoped(workspace.deployment.pendingItems)
        if !waiting.isEmpty {
            return PlanReviewLabels.readyLine(count: waiting.count, hasRemoval: waiting.contains(where: \.isRemoval))
        }
        if !scopedRequests.isEmpty {
            return "\(CountNoun.request.phrase(scopedRequests.count)) waiting for review"
        }
        let attention = workspace.device.attentionCount
        if attention > 0 {
            return "\(CountNoun("app").phrase(attention)) \(attention == 1 ? "needs" : "need") attention"
        }
        return lastChecked.map { "Up to date · checked \(SnapshotTime.compact($0))" } ?? "Up to date"
    }

    private var reviewTitle: String {
        let deployment = workspace.deployment
        return Self.reviewTitle(
            for: deployment.plan, scopedTo: client,
            leavingOut: Set(deployment.plan.map(deployment.heldBack(in:))?.map(WorkspaceDeploymentSession.installKey) ?? []))
    }

    /// Titles both review buttons from the whole runnable plan, excluding held-back
    /// steps. A client-filtered page says "all" when the review includes other apps;
    /// its local detail counts remain scoped to the selected client.
    static func reviewTitle(
        for plan: WorkspaceDeploymentPlan?, scopedTo client: ClientKind?,
        leavingOut heldBack: Set<WorkspaceDeploymentInstallKey> = []
    ) -> String {
        guard let plan else { return ActionTitles.reviewChanges(count: nil) }
        let items = plan.items.filter { !heldBack.contains(WorkspaceDeploymentSession.installKey($0)) }
        let whole = items.count
        guard client != nil, scoped(items, to: client).count < whole else {
            return ActionTitles.reviewChanges(count: whole)
        }
        return ActionTitles.reviewAllChanges(count: whole)
    }

    // MARK: - Tiles

    /// Each app this Mac manages, once. The tile is the app's whole verdict:
    /// whether its tool answered, when, what it holds, and what is waiting for
    /// it. Choosing one narrows the rest of the screen to it.
    private var appTiles: some View {
        Group {
            if enabledClients.isEmpty {
                EmptyStateView(
                    symbol: "macwindow.badge.plus",
                    title: "No apps chosen",
                    message: "Choose which apps this Mac looks after. Their software and configuration stay as they are.",
                    actionTitle: "Choose apps…",
                    action: { showingClientSelection = true }
                )
                .frame(height: Size.emptyStatePanelHeight)
            } else {
                HStack(alignment: .top, spacing: Space.lg) {
                    ForEach(enabledClients) { app in
                        AppTile(
                            client: app,
                            verdict: workspace.device.verdict(for: app),
                            version: version(for: app),
                            held: held(for: app),
                            waiting: workspace.deployment.pendingItems.filter { $0.surface.client == app },
                            selected: client == app
                        ) {
                            if client == app { onShowAllClients() } else { navigation.openClient(app) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - One app's page

    /// The top of one app's page: what this Mac knows about that app from its
    /// last check. Every value here is read from the observation; nothing is
    /// asked of the app to draw it.
    private func clientHeader(_ app: ClientKind) -> some View {
        let verdict = workspace.device.verdict(for: app)
        let observations = workspace.device.observations.filter { $0.surface.client == app }
        let held = held(for: app)
        let paths = Array(Set(observations.flatMap(\.configurationPaths))).sorted()
        let notes = Array(Set(observations.flatMap(\.notes))).sorted()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.xl) {
                ClientDisc(client: app, size: Size.discLarge)
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.md) {
                        Text(app.rawValue).font(AgentFont.title)
                        if let version = version(for: app) {
                            Text(version).font(AgentFont.body).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: Space.sm) {
                        StatusGlyph(state: verdict.state, size: Size.glyph)
                        Text(verdict.text).font(AgentFont.body)
                        if let checked = observations.map(\.lastScannedAt).max() {
                            Text("· checked \(SnapshotTime.compact(checked))").font(AgentFont.body).foregroundStyle(.secondary)
                        }
                    }
                    if !verdict.detail.isEmpty {
                        Text(verdict.detail).font(AgentFont.caption).foregroundStyle(.secondary)
                            .wrapsLines()
                    }
                }
                Spacer(minLength: Space.lg)
                if !workspace.device.isEnabled(app) {
                    Text("Not managed here").font(AgentFont.captionMedium).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.md).padding(.vertical, Space.xs)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(Space.xl)

            Hairline()

            // What the app holds, as the check saw it. Counts, not claims: an
            // app that has not been checked has no numbers, and says so. The
            // columns go in the Library's order, as every holdings line does.
            HStack(spacing: 0) {
                heldColumn(.skill, count: held?.skills)
                Hairline(.vertical).frame(height: Size.controlHeight)
                heldColumn(.plugin, count: held?.plugins)
                Hairline(.vertical).frame(height: Size.controlHeight)
                heldColumn(.connection, count: held?.connections)
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.lg)

            if !paths.isEmpty || !notes.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: Space.md) {
                    if !paths.isEmpty {
                        Text("Keeps its configuration in").font(AgentFont.captionSemibold).foregroundStyle(.secondary)
                        ForEach(paths, id: \.self) { path in
                            Text(path).font(AgentFont.mono).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(path)
                        }
                    }
                    ForEach(notes, id: \.self) { note in
                        Text(note).font(AgentFont.caption).foregroundStyle(.secondary)
                            .wrapsLines()
                    }
                }
                .padding(Space.xl)
            }
        }
        .standardPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.rawValue), \(verdict.text)")
    }

    /// What has changed in this app since the installed version and what the
    /// assistant recommends adopting. Asked for from here; nothing runs until
    /// the button is pressed, and the assistant only reads.
    @ViewBuilder private func clientReviewCard(_ app: ClientKind) -> some View {
        let setup = workspace.setup
        let review = setup.clientReviews[app]
        let running = setup.reviewingClient == app
        TitledCard(
            "What's new in \(app.rawValue)",
            count: review.map { r in r.openRecommendations.isEmpty ? nil : "\(r.openRecommendations.count)" } ?? nil
        ) {
            Button {
                Task { await setup.reviewClient(app) }
            } label: {
                Label(running ? "Reviewing…" : (review == nil ? "Review \(app.rawValue)" : "Review again"), systemImage: "sparkles")
            }
            .inlineActionStyle()
            .disabled(running || setup.reviewClient == nil || setup.isBusy)
            .help(reviewHelp(app))
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if running {
                    HStack(spacing: Space.lg) {
                        ProgressView().controlSize(.small)
                        Text(
                            "Fetching \(app.rawValue)'s release notes, then having \(setup.reviewClient?.rawValue ?? "your assistant") read them against your setup. A few minutes."
                        )
                        .font(AgentFont.body).foregroundStyle(.secondary).wrapsLines()
                        Spacer()
                    }
                    .padding(Space.xl)
                } else if let review {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.sm) {
                            Text(versionLine(review)).font(AgentFont.bodyMedium)
                            Spacer()
                            Text(SnapshotTime.compact(review.completedAt)).font(AgentFont.micro).foregroundStyle(.tertiary)
                        }
                        if let summary = review.review?.summary { Text(summary).font(AgentFont.body).wrapsLines() }
                        if let message = setup.clientReviewMessage {
                            Text(message).font(AgentFont.caption).foregroundStyle(AgentTheme.warning).wrapsLines()
                        }
                    }
                    .padding(Space.xl)
                    if !review.notes.isEmpty {
                        Hairline()
                        DisclosureGroup("Release notes read · \(review.notes.count)") {
                            ForEach(review.notes, id: \.version) { note in
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text("\(note.version)").font(AgentFont.captionSemibold)
                                    Link(note.source, destination: URL(string: note.source) ?? URL(filePath: "/")).font(AgentFont.micro)
                                        .lineLimit(1)
                                    Text(note.body.prefix(600) + (note.body.count > 600 ? "…" : "")).font(AgentFont.micro).foregroundStyle(
                                        .secondary
                                    )
                                    .wrapsLines()
                                }
                                .padding(.vertical, Space.sm)
                            }
                        }
                        .font(AgentFont.caption)
                        .padding(.horizontal, Space.xl).padding(.vertical, Space.md)
                    }
                    // The same compact rows the Checkup uses, one per recommendation.
                    ForEach(review.openRecommendations) { recommendation in
                        Hairline()
                        let item = CheckupTriage.item(for: recommendation, audit: setup.checkup?.audit)
                        CheckupRow(
                            item: item, isExpanded: expandedReviewRows.contains(item.id), isBusy: setup.isApplying,
                            onToggle: {
                                if expandedReviewRows.contains(item.id) {
                                    expandedReviewRows.remove(item.id)
                                } else {
                                    expandedReviewRows.insert(item.id)
                                }
                            },
                            onRun: {
                                if item.canRun {
                                    Task {
                                        await setup.applyAll(item.actions, settings: item.settings.map { ($0.client, $0.key, $0.value) })
                                    }
                                } else if let section = item.opens {
                                    navigate(section)
                                } else {
                                    setup.dismiss(recommendation, in: app)
                                }
                            },
                            onRunOne: { action in Task { await setup.apply(action) } },
                            onDismiss: { setup.dismiss(recommendation, in: app) },
                            onOpen: { section in navigate(section) })
                    }
                } else if let message = setup.clientReviewMessage {
                    Text(message).font(AgentFont.body).foregroundStyle(.secondary).padding(Space.xl)
                } else {
                    Text(
                        "Fetches what \(app.rawValue) has published since the version on this Mac and has your assistant read it against your configuration: settings the docs now recommend, hooks, skills, plugins, and connections worth adding, and what is deprecated. Every claim names its source."
                    )
                    .font(AgentFont.body).foregroundStyle(.secondary).wrapsLines().padding(Space.xl)
                }
            }
        }
    }

    private func versionLine(_ review: ClientReview) -> String {
        switch (review.installedVersion, review.latestVersion) {
        case (let installed?, let latest?) where installed != latest: "Installed \(installed) · latest \(latest)"
        case (let installed?, _): "Installed \(installed) · up to date"
        case (nil, let latest?): "Latest \(latest) · installed version unknown"
        default: "Versions unknown"
        }
    }

    private func reviewHelp(_ app: ClientKind) -> String {
        guard let assistant = workspace.setup.reviewClient else {
            return "A review needs Claude Code or Codex; this Mac is not managing either."
        }
        return
            "Fetches \(app.rawValue)'s release notes and has your signed-in \(assistant.rawValue) read them, your configuration, and \(app.rawValue)'s documentation on the web. It can read; it cannot change anything."
    }

    /// One count under an app's header, titled with the library's own noun and
    /// read out in the singular for one.
    private func heldColumn(_ noun: CountNoun, count: Int?) -> some View {
        let title = noun.plural.capitalizedFirst
        return VStack(spacing: Space.xxs) {
            Text(count.map(String.init) ?? "—").font(AgentFont.titleLarge).monospacedDigit()
            Text(title).font(AgentFont.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count.map(noun.phrase) ?? "\(title): not checked yet")
    }

    // MARK: - Cards

    /// What a prepared plan would put where, by app. Reading, not doing: the
    /// review is where each step is approved.
    private func changesCard(_ items: [WorkspaceDeploymentItem]) -> some View {
        TitledCard(PlanReviewLabels.readyTitle(hasRemoval: items.contains(where: \.isRemoval)), count: "\(items.count)") {
            Button(reviewTitle, action: onReviewChanges)
                .inlineActionStyle()
                .disabled(workspace.deployment.isBusy)
        } content: {
            let groups = grouped(items)
            ForEach(groups) { group in
                InfoRow(group.client.rawValue, detail: summary(of: group.items)) {
                    ClientDisc(client: group.client, size: Size.disc)
                } trailing: {
                    Text("\(group.items.count)")
                        .font(AgentFont.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if group.id != groups.last?.id { Hairline() }
            }
            Text("Nothing has been written. The review shows each step, and what is not being installed.")
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.lg)
                .padding(.top, Space.xs)
        }
    }

    private var pendingRequestsCard: some View {
        let visible = Array(scopedRequests.prefix(8))
        return TitledCard(
            "Waiting for review",
            count: CountNoun.request.phrase(scopedRequests.count)
        ) {
            Text("Local requests nobody has decided yet. None has changed an app.")
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.lg)
            ForEach(visible) { request in
                InfoRow(
                    request.title,
                    detail: "\(request.kind.displayName) · \(SnapshotTime.compact(request.createdAt))"
                ) {
                    SymbolTile(symbol: "tray.and.arrow.down", size: Size.discLarge)
                } trailing: {
                    // Opens the request's review sheet, so it carries the ellipsis.
                    Button("Review…") { onReviewRequest(request) }
                        .secondaryActionStyle()
                        .controlSize(.small)
                        .accessibilityLabel("Review \(request.title)")
                }
                if request.id != visible.last?.id { Hairline() }
            }
            if scopedRequests.count > visible.count {
                let more = scopedRequests.count - visible.count
                Text("\(more) more \(more == 1 ? "is" : "are") waiting. Review these to reveal the rest.")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(Space.xl)
            }
        }
    }

    private var receiptsCard: some View {
        TitledCard("Recent changes", count: scopedReceipts.isEmpty ? nil : "\(scopedReceipts.count)") {
            if scopedReceipts.count > recentReceipts.count {
                Button("See all", systemImage: "chevron.right") { navigate(.activity) }
                    .inlineActionStyle()
                    .labelStyle(.titleAndIcon)
            }
        } content: {
            if scopedReceipts.isEmpty {
                Text(client.map { "Nothing has been changed in \($0.rawValue) yet." } ?? "Nothing has been changed yet.")
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(recentReceipts) { receipt in
                    InfoRow(receipt.title, detail: receipt.verificationSummary) {
                        StatusGlyph(state: receipt.state, size: Size.glyphLarge)
                    } trailing: {
                        Text(SnapshotTime.standalone(receipt.createdAt))
                            .font(AgentFont.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if receipt.id != recentReceipts.last?.id { Hairline() }
                }
            }
        }
    }

    /// Where each app's tools go on this Mac, when that is not the app's own
    /// folder. Registering one moves nothing; it only says where a later
    /// install would write.
    private var linkedDestinationsCard: some View {
        TitledCard("Folders") {
            Button("Choose a folder…", systemImage: "folder.badge.plus") { isChoosingDestination = true }
                .inlineActionStyle()
                .disabled(workspace.deployment.isBusy)
        } content: {
            if workspace.deployment.linkedDestinations.isEmpty {
                Text("Each app uses its own folder. Point one somewhere else if you keep a folder in step yourself.")
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(workspace.deployment.linkedDestinations) { destination in
                    InfoRow(
                        "\(destination.surface.displayName) · \(destination.projectName ?? destination.scope.displayName)"
                    ) {
                        SymbolTile(symbol: "folder", size: Size.discLarge)
                    } trailing: {
                        HStack(spacing: Space.lg) {
                            LocationText(path: destination.path)
                            Button("Use the app's own folder") {
                                Task { await workspace.deployment.unlinkDestination(destination.id) }
                            }
                            .secondaryActionStyle()
                            .controlSize(.small)
                            .disabled(workspace.deployment.isBusy)
                        }
                    }
                    if destination.id != workspace.deployment.linkedDestinations.last?.id {
                        Hairline()
                    }
                }
            }
        }
    }

    // MARK: - Data

    /// What the last check found in one app, counted by name across every
    /// surface the app has. Found, not asked for.
    private func held(for app: ClientKind) -> AppTile.Held? {
        let mine = workspace.device.observations.filter { $0.surface.client == app }
        guard !mine.isEmpty else { return nil }
        // Agent Tooling's own connection, where this Mac set it up, is not
        // one of the app's holdings: it is how the app reaches this library.
        // One somebody made by hand under that name is theirs, and counts.
        let own =
            workspace.library.state.map {
                AgentToolingConnection.apps(on: workspace.store.deviceID, in: $0.snapshot.document).contains(app)
            } ?? false
        return AppTile.Held(
            skills: Set(mine.flatMap(\.discoveredSkills)).count,
            plugins: Set(mine.flatMap(\.discoveredPlugins)).count,
            connections: Set(mine.flatMap(\.discoveredMCPServers)).subtracting(own ? [AgentToolingConnection.declaredName] : []).count)
    }

    private func version(for app: ClientKind) -> String? {
        workspace.device.observations.first { $0.surface.client == app && $0.version?.isEmpty == false }?.version
    }

    private var lastChecked: Date? {
        workspace.device.observations.map(\.lastScannedAt).max()
    }

    /// When the check the library currently holds was made. It moves only once
    /// a check has been recorded and read back, which is the moment a plan over
    /// it means anything.
    private var scanStamp: Date? {
        workspace.library.state?.snapshot.device.observations.map(\.lastScannedAt).max()
    }

    private func scoped(_ items: [WorkspaceDeploymentItem]) -> [WorkspaceDeploymentItem] {
        Self.scoped(items, to: client)
    }

    /// A plan's steps as a page shows them: every app's, or only the steps for
    /// the one app the page is narrowed to.
    static func scoped(_ items: [WorkspaceDeploymentItem], to client: ClientKind?) -> [WorkspaceDeploymentItem] {
        items.filter { client == nil || $0.surface.client == client }
    }

    private func grouped(_ items: [WorkspaceDeploymentItem]) -> [ClientGroup] {
        enabledClients.compactMap { app in
            let mine = items.filter { $0.surface.client == app }
            return mine.isEmpty ? nil : ClientGroup(client: app, items: mine)
        }
    }

    /// The names, up to a few, and how many more there are.
    private func summary(of items: [WorkspaceDeploymentItem]) -> String {
        let names = items.map(\.displayName)
        let shown = names.prefix(4).joined(separator: ", ")
        let more = names.count - min(names.count, 4)
        return more == 0 ? shown : "\(shown) and \(more) more"
    }

    private var scopedRequests: [PendingAgentRequest] {
        requests.requests.filter { request in
            guard let client else { return true }
            return request.targets.contains(client)
        }
    }

    private var scopedReceipts: [OperationReceipt] {
        receipts.filter { receipt in
            guard let client else { return true }
            return receipt.targetSurfaces.contains { $0.client == client }
        }
    }

    private var recentReceipts: [OperationReceipt] {
        Array(
            scopedReceipts.sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt > $1.createdAt
            }.prefix(4))
    }

    private var problems: [String] {
        [
            workspace.deployment.errorMessage, workspace.device.errorMessage, requests.errorMessage,
        ]
        .compactMap { $0 }
    }

    /// Whether any managed app answered its last check without a runnable
    /// tool — the same predicate the finder uses, so the button is offered
    /// exactly when the finder would have work to do.
    private var hasMissingManagedTool: Bool {
        !workspace.device.missingManagedClients.isEmpty
    }

    private func loadReceipts() async {
        let store = workspace.store
        let reader = receiptReader
        receipts =
            (try? await Task.detached { try reader.recentReceipts(store: store, limit: 50) }.value) ?? []
    }
}

extension CountNoun {
    /// A local request in the review queue, counted in the line under the
    /// title and on its card.
    fileprivate static let request = CountNoun("request")
}

private struct ClientGroup: Identifiable {
    let client: ClientKind
    let items: [WorkspaceDeploymentItem]
    var id: ClientKind { client }
}

/// One app, once: its mark, its name, one clause, its verdict, and what is
/// waiting for it. The whole tile is the way to narrow the screen to it.
struct AppTile: View {
    /// What the last check found in the app, counted the way every screen
    /// counts an app's holdings: "2 skills · 0 plugins · 1 connection".
    typealias Held = LibraryCounts

    let client: ClientKind
    let verdict: ClientVerdict
    let version: String?
    let held: Held?
    /// The prepared plan's steps for this app.
    let waiting: [WorkspaceDeploymentItem]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(alignment: .top, spacing: Space.lg) {
                    ClientDisc(client: client, size: Size.discLarge)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(client.rawValue)
                            .font(AgentFont.bodySemibold)
                            .lineLimit(1)
                        Text(clause)
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.md)
                    StatusGlyph(state: verdict.state, size: Size.glyph)
                        .padding(.top, Space.xxs)
                }
                HStack(spacing: Space.md) {
                    Text(heldText)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Space.sm)
                    if !waiting.isEmpty {
                        Text(PlanReviewLabels.waitingCount(waiting.count, hasRemoval: waiting.contains(where: \.isRemoval)))
                            .font(AgentFont.captionSemibold)
                            .foregroundStyle(AgentTheme.selection)
                    }
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .standardPanel()
        .overlay {
            RoundedRectangle(cornerRadius: AgentTheme.panelCornerRadius, style: .continuous)
                .stroke(selected ? AgentTheme.selection : Color.clear, lineWidth: Hairline.ring)
        }
        .help(
            [selected ? "Show every app again" : "Show only \(client.rawValue)", verdict.detail]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        )
        .accessibilityLabel("\(client.rawValue), \(clause)")
        .accessibilityValue(verdict.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The tool's version and when it was last read, or why it could not be.
    private var clause: String {
        [version, verdict.text].compactMap { $0 }.joined(separator: " · ")
    }

    private var heldText: String {
        held?.summary ?? "Not checked yet"
    }
}

/// Which apps this Mac manages.
///
/// Unchecking one records a choice and nothing else: its software and its
/// configuration stay exactly where they are, and nothing is removed from it.
struct ManagedClientsPopover: View {
    let device: WorkspaceDeviceSession

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Apps you use").font(AgentFont.heading)
            Text(
                "Unchecked apps are hidden throughout Agent Tooling and excluded from checks and changes. Their software and configuration stay on this Mac."
            )
            .font(AgentFont.caption).foregroundStyle(.secondary)
            ForEach(device.availableClients) { client in
                Toggle(
                    isOn: Binding(
                        get: { device.isEnabled(client) },
                        set: { enabled in Task { await device.setEnabled(client, enabled) } })
                ) {
                    HStack(spacing: Space.lg) {
                        ClientBrandIcon(client: client, size: Size.tileSmall)
                        Text(client.rawValue)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Use \(client.rawValue)")
                .disabled(device.isChecking)
            }
            if device.enabledClients.isEmpty {
                Text("Select a client whenever you’re ready. Your local library remains available.")
                    .font(AgentFont.caption).foregroundStyle(.secondary)
            }
            if let message = device.errorMessage {
                Text(message).font(AgentFont.caption).foregroundStyle(AgentTheme.warning)
                    .wrapsLines()
            }
        }
        .padding(Space.xl)
    }
}

/// Choosing which destination goes somewhere other than its app's own folder.
struct WorkspaceLinkDestinationSheet: View {
    let session: WorkspaceDeploymentSession
    /// Only the apps this Mac manages are offered: pointing a folder at an app
    /// this Mac was told not to touch would record a destination for something
    /// nothing here will ever write to.
    let clients: [ClientKind]
    @Environment(\.dismiss) private var dismiss
    @State private var client: ClientKind = .codex
    @State private var folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Send an app's tools somewhere else").font(AgentFont.title)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(Space.xxl)
            Hairline()
            VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                Text(
                    "Agent Tooling normally writes into each app's own folder. Point one somewhere else and it writes there instead — into the folder you name, under each tool's own name."
                )
                .foregroundStyle(.secondary)
                Text(
                    "Nothing already in that folder is replaced. If a tool's name is already taken there, the install stops and says so rather than writing over it."
                )
                .font(AgentFont.body).foregroundStyle(.secondary)
                Picker("App", selection: $client) {
                    ForEach(clients) { value in Text(value.rawValue).tag(value) }
                }.frame(maxWidth: Size.fieldShort)
                HStack(spacing: Space.lg) {
                    Button("Choose folder…") { choose() }
                    Text(folder?.path ?? "No folder chosen").foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.padding(Space.xxl)
            Hairline()
            HStack {
                Text("This records where a later install would write. Nothing moves now.")
                    .font(AgentFont.body).foregroundStyle(.secondary)
                Spacer()
                Button("Use this folder") {
                    guard let folder else { return }
                    Task {
                        await session.linkDestination(
                            surface: client.defaultSurface, scope: .user,
                            projectID: nil, to: folder)
                        dismiss()
                    }
                }
                .primaryActionStyle()
                .disabled(folder == nil || session.isBusy)
            }.padding(Space.xxl)
        }
        .sheetSize(SheetSize.medium)
        .background(AgentTheme.contentBackground)
        .onAppear {
            // The stored default may be an app this Mac does not manage, which
            // would leave the picker showing a choice not in its own list.
            if !clients.contains(client), let first = clients.first { client = first }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.standardizedFileURL
    }
}
