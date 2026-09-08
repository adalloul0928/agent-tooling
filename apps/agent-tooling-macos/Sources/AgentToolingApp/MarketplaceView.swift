import AgentToolingCore
import AppKit
import SwiftUI

struct MarketplaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var request: ScreenRequest?
    @SceneStorage("agentTooling.marketplace.selectedPackage") private var selectedPackageID: String?
    @SceneStorage("agentTooling.marketplace.query") private var query = ""
    @SceneStorage("agentTooling.marketplace.component") private var componentFilter: MarketplaceComponentFilter = .all
    @SceneStorage("agentTooling.marketplace.client") private var clientFilter: MarketplaceClientFilter = .all
    @SceneStorage("agentTooling.marketplace.provenance") private var classificationFilter: MarketplaceClassificationFilter = .all
    @SceneStorage("agentTooling.marketplace.sort") private var sortOrder: MarketplaceSortOrder = .relevance
    @SceneStorage("agentTooling.marketplace.source") private var selectedSourceIDStorage: String?

    init(request: Binding<ScreenRequest?> = .constant(nil)) {
        _request = request
    }

    var body: some View {
        let packages = filteredPackages

        VStack(spacing: 0) {
            PageToolbar(
                title: "Marketplace",
                context: "\(model.visibleMarketplacePackages.count) packages from \(model.visibleSources.count) sources"
            ) {
                Button {
                    chooseSource()
                } label: {
                    Label("Add source…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(model.isInteractionLocked)
                Button {
                    Task { await model.refreshMarketplace() }
                } label: {
                    Label(model.isRefreshingMarketplace ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInteractionLocked)
            }

            GeometryReader { proxy in
                HSplitView {
                    sourcePane.frame(
                        minWidth: 210, idealWidth: 250, maxWidth: 300, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                    packagePane(packages: packages).frame(
                        minWidth: 310, idealWidth: 390, maxWidth: 480, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                    detailPane.frame(
                        minWidth: 340, maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .onAppear { if !model.isClientEnabled(clientFilter.client) { clientFilter = .all } }
        .onChange(of: model.enabledClients) { _, _ in
            if !model.isClientEnabled(clientFilter.client) { clientFilter = .all }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            applyExternalNavigation()
            consumeRequest()
            validateRestoredMarketplaceState()
        }
        .onChange(of: navigation.revision) { _, _ in applyExternalNavigation() }
        .onChange(of: request) { _, _ in consumeRequest() }
        .onChange(of: packages.map(\.id)) { _, ids in
            let selectionIsInvalid = selectedPackageID == nil || !ids.contains(selectedPackageID ?? "")
            selectFirstPackageAfterListUpdate(ifNeeded: selectionIsInvalid)
        }
        .onChange(of: model.visibleSources.map(\.id)) { _, ids in
            if let selectedSourceID, !ids.contains(selectedSourceID) {
                self.selectedSourceID = nil
            }
        }
    }

    private func applyExternalNavigation() {
        guard let requestedID = navigation.requestedMarketplacePackageID else { return }
        defer { navigation.consumeMarketplacePackage(requestedID) }
        guard model.visibleMarketplacePackages.contains(where: { $0.id == requestedID }) else { return }
        query = ""
        componentFilter = .all
        clientFilter = .all
        classificationFilter = .all
        selectedSourceID = nil
        selectedPackageID = requestedID
    }

    private func consumeRequest() {
        guard let request else { return }
        defer { self.request = nil }
        guard case .selectMarketplaceSource(let id) = request,
            model.visibleSources.contains(where: { $0.id == id })
        else { return }
        query = ""
        componentFilter = .all
        clientFilter = .all
        classificationFilter = .all
        selectedSourceID = id
        selectedPackageID = nil
        selectFirstPackageAfterListUpdate(ifNeeded: true)
    }

    private func validateRestoredMarketplaceState() {
        if let selectedSourceID,
            !model.visibleSources.contains(where: { $0.id == selectedSourceID })
        {
            self.selectedSourceID = nil
        }
        let visibleIDs = Set(filteredPackages.map(\.id))
        selectFirstPackageAfterListUpdate(
            ifNeeded: selectedPackageID.map { !visibleIDs.contains($0) } ?? true
        )
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Sources") {
                Text("\(model.visibleSources.count) available")
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sortedSources) { source in
                        MarketplaceSourceRow(
                            source: source,
                            symbol: symbol(for: source.kind),
                            contents: contentsSummary(for: source),
                            selected: selectedSourceID == source.id
                        ) {
                            selectedSourceID = selectedSourceID == source.id ? nil : source.id
                        }
                        if source.id != sortedSources.last?.id { Divider().opacity(0.30) }
                    }
                }
                .padding(.horizontal, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Reviewed locally", systemImage: "checkmark.shield")
                    .font(.caption.weight(.semibold))
                Text("Catalog installs stay with their native client. Added folders are inspected before review.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(13)
        }
        .paneMaterial()
    }

    private func packagePane(packages: [MarketplacePackage]) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MarketplaceSearchField(text: $query)
                    Text(resultCountDescription(packages.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : AgentMotion.quick, value: packages.count)
                        .accessibilityLabel("\(resultCountDescription(packages.count)) in the marketplace")
                }

                ViewThatFits(in: .horizontal) {
                    wideMarketplaceControls
                    compactMarketplaceControls
                }

                Group {
                    if hasActiveTokenFilter {
                        FlowLayout(spacing: 6) {
                            if let source = selectedSource {
                                ActiveFilterToken(title: source.name, accessibilityName: "source") {
                                    selectedSourceID = nil
                                }
                            }
                            if clientFilter != .all {
                                ActiveFilterToken(title: clientFilter.rawValue, accessibilityName: "app") {
                                    clientFilter = .all
                                }
                            }
                            if classificationFilter != .all {
                                ActiveFilterToken(title: classificationFilter.rawValue, accessibilityName: "provenance") {
                                    classificationFilter = .all
                                }
                            }
                            Button("Clear all") { clearFilters() }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AgentTheme.blue)
                                .accessibilityLabel("Clear all marketplace filters")
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                    }
                }
                .animation(reduceMotion ? nil : AgentMotion.quick, value: hasActiveTokenFilter)
            }
            .padding(12)
            .background(Color.primary.opacity(0.012))
            .overlay(alignment: .bottom) { Divider().opacity(0.35) }

            if packages.isEmpty {
                EmptyStateView(
                    symbol: hasActiveFilter ? "line.3.horizontal.decrease.circle" : "shippingbox",
                    title: hasActiveFilter ? "No matching packages" : "No packages found",
                    message: emptyPackageMessage,
                    actionTitle: hasActiveFilter ? "Clear Filters" : "Add Source",
                    isActionEnabled: hasActiveFilter || !model.isInteractionLocked
                ) {
                    if hasActiveFilter {
                        clearFilters()
                    } else {
                        chooseSource()
                    }
                }
            } else {
                List(selection: $selectedPackageID) {
                    ForEach(packages) { package in
                        MarketplacePackageRow(
                            package: package,
                            selected: selectedPackageID == package.id,
                            verdict: MarketplaceProvenanceClassifier.classify(package),
                            detail: rowDetail(for: package)
                        )
                        .tag(package.id)
                        .listRowBackground(SelectionRowBackground(selected: selectedPackageID == package.id))
                        .accessibilityLabel("\(package.name), by \(package.publisher)")
                        .accessibilityValue(
                            [
                                package.components.map(\.displayName).sorted().joined(separator: ", "),
                                MarketplaceProvenanceClassifier.classify(package).classification.displayName,
                                localState(for: package),
                                selectedPackageID == package.id ? "Selected" : "",
                            ]
                            .filter { !$0.isEmpty }
                            .joined(separator: ", ")
                        )
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .paneMaterial()
    }

    private var wideMarketplaceControls: some View {
        HStack(spacing: 8) {
            componentSelector(segmentWidth: 45)
            marketplaceFilterMenu(compact: false)
            marketplaceSortMenu(compact: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactMarketplaceControls: some View {
        HStack(spacing: 8) {
            componentSelector(segmentWidth: nil)
                .frame(maxWidth: .infinity)
            marketplaceFilterMenu(compact: true)
            marketplaceSortMenu(compact: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func componentSelector(segmentWidth: CGFloat?) -> some View {
        SlidingSegmentedControl<MarketplaceComponentFilter>(
            selection: $componentFilter,
            items: MarketplaceComponentFilter.allCases.map { .init(value: $0, title: $0.rawValue) },
            accessibilityLabel: "Package component",
            segmentWidth: segmentWidth
        )
    }

    private func marketplaceFilterMenu(compact: Bool) -> some View {
        let activeCount = (clientFilter == .all ? 0 : 1) + (classificationFilter == .all ? 0 : 1)
        return Menu {
            Menu("App") {
                ForEach(MarketplaceClientFilter.allCases.filter { model.isClientEnabled($0.client) }) { filter in
                    Button {
                        clientFilter = filter
                    } label: {
                        if clientFilter == filter {
                            Label(filter.rawValue, systemImage: "checkmark")
                        } else {
                            Text(filter.rawValue)
                        }
                    }
                }
            }
            Menu("Provenance") {
                ForEach(MarketplaceClassificationFilter.allCases) { filter in
                    Button {
                        classificationFilter = filter
                    } label: {
                        if classificationFilter == filter {
                            Label(filter.rawValue, systemImage: "checkmark")
                        } else {
                            Text(filter.rawValue)
                        }
                    }
                }
            }
        } label: {
            MarketplaceMenuButtonLabel(
                systemImage: "line.3.horizontal.decrease",
                title: compact ? nil : "Filters",
                badge: activeCount == 0 ? nil : activeCount,
                active: activeCount > 0
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(activeCount == 0 ? "Filter packages by app or provenance" : "\(activeCount) filters active")
        .accessibilityLabel("Package filters")
        .accessibilityValue(activeCount == 0 ? "No app or provenance filter" : "\(activeCount) active")
    }

    private func marketplaceSortMenu(compact: Bool) -> some View {
        Menu {
            ForEach(MarketplaceSortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    let title = order == .relevance ? "Smart (name until searching)" : order.displayName
                    if sortOrder == order {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            MarketplaceMenuButtonLabel(
                systemImage: "arrow.up.arrow.down",
                title: compact ? nil : visibleSortName,
                active: sortOrder != .relevance
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(visibleSortName). \(sortOrder.measurement)")
        .accessibilityLabel("Sort packages")
        .accessibilityValue(visibleSortName)
    }

    private var visibleSortName: String {
        sortOrder == .relevance && normalizedQuery.isEmpty ? "Smart" : sortOrder.displayName
    }

    private func resultCountDescription(_ count: Int) -> String {
        "\(count) \(count == 1 ? "result" : "results")"
    }

    private var hasActiveTokenFilter: Bool {
        selectedSourceID != nil || clientFilter != .all || classificationFilter != .all
    }

    private func clearFilters() {
        query = ""
        componentFilter = .all
        clientFilter = .all
        classificationFilter = .all
        selectedSourceID = nil
    }

    @ViewBuilder
    private var detailPane: some View {
        if let package = selectedPackage {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        KindTile(kind: marketplaceKind(for: package), size: 40, ghost: !package.isInstalled)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.name).font(.title3.weight(.semibold))
                            Text(package.publisher).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProvenanceBadge(verdict: MarketplaceProvenanceClassifier.classify(package))
                    }
                    Text(package.summary).font(.callout).foregroundStyle(.secondary)

                    GroupBox("Review") {
                        VStack(spacing: 0) {
                            LabeledValueRow("Provenance") {
                                let verdict = MarketplaceProvenanceClassifier.classify(package)
                                VStack(alignment: .leading, spacing: 3) {
                                    ProvenanceBadge(verdict: verdict)
                                    Text(verdict.evidence)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Divider()
                            LabeledValueRow("Contents") {
                                Text(
                                    package.components.map(\.displayName).sorted().joined(separator: ", ").nilIfEmpty
                                        ?? "No recognized components"
                                )
                                .foregroundStyle(.secondary)
                            }
                            Divider()
                            LabeledValueRow("Available for") {
                                Text(
                                    package.supportedClients.map(\.rawValue).sorted().joined(separator: ", ").nilIfEmpty
                                        ?? "No verified target"
                                )
                                .foregroundStyle(.secondary)
                            }
                            Divider()
                            LabeledValueRow("Local state") {
                                Text(localState(for: package))
                                    .foregroundStyle(.secondary)
                            }
                            if let ownership = package.ownership {
                                Divider()
                                LabeledValueRow("Ownership") {
                                    Text(ownership.displayName).foregroundStyle(.secondary)
                                }
                            }
                            if let updateStatus = package.updateStatus {
                                Divider()
                                LabeledValueRow("Updates") {
                                    Text(updateStatus.displayName).foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            LabeledValueRow("Trust") { Text(package.trustSummary).foregroundStyle(.secondary) }
                            Divider()
                            LabeledValueRow("License") { Text(package.license ?? "Not declared").foregroundStyle(.secondary) }
                            if let revision = package.provenance?.lock?.revision ?? package.revision {
                                Divider()
                                LabeledValueRow("Locked revision") {
                                    Text(revision).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            if let digest = package.provenance?.lock?.digest {
                                Divider()
                                LabeledValueRow("Digest") {
                                    Text(digest).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            if let credentials = package.requestedCredentialNames, !credentials.isEmpty {
                                Divider()
                                LabeledValueRow("Configuration names") {
                                    RequestedCredentialNames(names: credentials)
                                }
                            }
                            if let conflicts = package.conflicts, !conflicts.isEmpty {
                                Divider()
                                LabeledValueRow("Conflicts") {
                                    Text(conflicts.map(\.summary).joined(separator: "\n"))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            LabeledValueRow("Executable content") {
                                Label(
                                    package.hasExecutableContent ? "Present — inspect before install" : "None detected",
                                    systemImage: package.hasExecutableContent ? "exclamationmark.triangle" : "checkmark"
                                )
                                .foregroundStyle(package.hasExecutableContent ? Color.primary : Color.secondary)
                            }
                            Divider()
                            LabeledValueRow("Source") {
                                VStack(alignment: .trailing, spacing: 6) {
                                    LocationText(path: package.location)
                                    if canOpen(package.location) {
                                        Button("Open Source", systemImage: "arrow.up.right.square") {
                                            open(package.location)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }

                    GroupBox("Grades") {
                        VStack(spacing: 0) {
                            PackageGradeRows(verdicts: MarketplaceGrading.grades(for: package, reachability: reachability(for: package)))
                            Divider()
                            Text(
                                "Every grade above measures one thing this Mac can check without running anything. Hover a line to read exactly what it measured; a line with nothing to measure stays \"Not graded\" rather than passing."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }

                    if package.components.contains(.mcpServer) {
                        DeclaredToolsCard(tools: package.tools, sourceName: package.sourceName)
                    }

                    if package.nativeInstalls.isEmpty {
                        Button("Review Source…", systemImage: "checklist") {
                            model.reviewMarketplacePackage(package.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isInteractionLocked)
                    } else {
                        installRoutes(for: package)
                    }
                }
                .padding(22)
            }
        } else {
            EmptyStateView(
                symbol: "shippingbox", title: "Select a package",
                message: "Imported packages receive a component, trust, and compatibility review before any install action.")
        }
    }

    /// Install routes state the scope they will use in Claude's own words. The
    /// app does not offer a scope it cannot execute: each vendor route carries
    /// one, and other scopes are chosen inside the client itself.
    @ViewBuilder
    private func installRoutes(for package: MarketplacePackage) -> some View {
        let scopes = Set(package.nativeInstalls.map(\.scope))
        VStack(alignment: .leading, spacing: 8) {
            Text("Native install routes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if scopes.count == 1, let scope = scopes.first {
                InstallScopeNote(scope: scope)
            }
            FlowLayout(spacing: 8) {
                ForEach(package.nativeInstalls) { route in
                    Button {
                        model.planMarketplaceInstall(
                            packageID: package.id, client: route.client, remove: route.reportsInstalled(in: package))
                    } label: {
                        HStack(spacing: 7) {
                            ClientBrandIcon(client: route.client, size: 14)
                            Text(route.isInstalledActionTitle(package: package))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInteractionLocked)
                    .help("\(route.detail) Scope: \(route.scope.marketplaceInstallTitle).")
                }
            }
            if scopes.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(package.nativeInstalls) { route in
                        HStack(spacing: 6) {
                            ClientBrandIcon(client: route.client, size: 12)
                            Text("\(route.client.rawValue) · \(route.scope.marketplaceInstallTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Agent Tooling runs each vendor route exactly as it is published. Another scope is chosen inside the client itself.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the last refresh could say about the catalog behind a package.
    /// Grading uses this instead of guessing that silence means healthy.
    private func reachability(for package: MarketplacePackage) -> SourceReachability {
        guard let source = model.visibleSources.first(where: { matches($0, package) }) else { return .unknown }
        if source.trustSummary.localizedCaseInsensitiveContains("unavailable") {
            return .unreachable(source.trustSummary)
        }
        guard let refreshedAt = source.lastRefreshedAt else { return .unknown }
        return .reachable(refreshedAt)
    }

    /// The second line of a row's verdict column. It follows the sort, so a
    /// person ordering by update date can see the dates they are ordering by.
    private func rowDetail(for package: MarketplacePackage) -> String {
        if sortOrder == .recentlyUpdated {
            guard let update = package.lastUpdate else { return "No update date" }
            return "Updated \(update.date.formatted(date: .abbreviated, time: .omitted))"
        }
        return "\(package.components.count) component\(package.components.count == 1 ? "" : "s")"
    }

    private var filteredPackages: [MarketplacePackage] {
        let searchTerm = normalizedQuery
        let matches = model.visibleMarketplacePackages.filter { package in
            componentFilter.matches(package)
                && clientFilter.matches(package)
                && classificationFilter.matches(package)
                && matchesSelectedSource(package)
                && (searchTerm.isEmpty
                    || [package.name, package.publisher, package.summary, package.components.map(\.displayName).joined(separator: " ")]
                        .joined(separator: " ")
                        .localizedCaseInsensitiveContains(searchTerm))
        }
        return MarketplaceSorting.sorted(matches, by: sortOrder, searchTerm: searchTerm)
    }

    private var selectedPackage: MarketplacePackage? { model.visibleMarketplacePackages.first { $0.id == selectedPackageID } }

    private var hasActiveFilter: Bool {
        !normalizedQuery.isEmpty || componentFilter != .all || clientFilter != .all || classificationFilter != .all
            || selectedSourceID != nil
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The empty state names the source and the filter that produced the
    /// emptiness, so nothing reads as a failure that is really a filter.
    private var emptyPackageMessage: String {
        guard hasActiveFilter else {
            return "Refresh native catalogs or add a local folder, checked-out Git repository, or Agent Plugin package."
        }
        if let source = selectedSource, componentFilter != .all {
            return
                "\(source.name) publishes no \(componentFilter.rawValue.lowercased()) packages. Native client catalogs list plugins; skills come from Agent Plugins folders and Git checkouts you add."
        }
        if let source = selectedSource, let classification = classificationFilter.classification {
            return "Nothing from \(source.name) is classified \(classification.displayName). \(classification.definition)"
        }
        if let source = selectedSource {
            return "\(source.name) has nothing matching the current filters."
        }
        if componentFilter == .skills {
            return
                "No catalog here publishes standalone skills. Add a local folder or Git checkout containing Agent Plugins packages to see skills."
        }
        if let classification = classificationFilter.classification {
            return "No package here is classified \(classification.displayName). \(classificationFilter.measurement)"
        }
        return "Try a different package name, publisher, component, app, or provenance."
    }

    private var selectedSource: ToolingSource? {
        guard let selectedSourceID else { return nil }
        return model.visibleSources.first { $0.id == selectedSourceID }
    }

    private var selectedSourceID: UUID? {
        get { selectedSourceIDStorage.flatMap(UUID.init(uuidString:)) }
        nonmutating set { selectedSourceIDStorage = newValue?.uuidString }
    }

    /// Native catalogs do not carry a source identifier, so each package is
    /// matched back to the row that produced it by its catalog prefix.
    private func matches(_ source: ToolingSource, _ package: MarketplacePackage) -> Bool {
        switch source.kind {
        case .localFolder, .gitRepository:
            package.sourceID == source.id
        case .claudeMarketplace:
            package.id.hasPrefix("claude:")
        case .openAIPluginDirectory:
            package.id.hasPrefix("codex:")
        case .mcpRegistry:
            package.id.hasPrefix("mcp-registry:")
        case .agentPlugins, .geminiExtensionGallery:
            false
        }
    }

    private func matchesSelectedSource(_ package: MarketplacePackage) -> Bool {
        guard let source = selectedSource else { return true }
        return matches(source, package)
    }

    /// A one-line inventory per source, so an empty component filter is
    /// explained by the catalog rather than looking like a failure.
    private func contentsSummary(for source: ToolingSource) -> String? {
        let packages = model.visibleMarketplacePackages.filter { matches(source, $0) }
        guard !packages.isEmpty else { return nil }
        let counts: [(String, Int)] = [
            ("skill", packages.filter { $0.components.contains(.skill) }.count),
            ("plugin", packages.filter { $0.components.contains(.plugin) }.count),
            ("MCP server", packages.filter { $0.components.contains(.mcpServer) }.count),
        ]
        let parts = counts.filter { $0.1 > 0 }.map { "\($0.1) \($0.0)\($0.1 == 1 ? "" : "s")" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var sortedSources: [ToolingSource] {
        model.visibleSources.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id.uuidString < $1.id.uuidString : nameOrder == .orderedAscending
        }
    }

    /// SwiftUI's macOS List is backed by NSTableView. Deferring selection until
    /// the current update completes avoids mutating its selection from inside a
    /// table delegate callback when filters or catalog results change.
    private func selectFirstPackageAfterListUpdate(ifNeeded: Bool) {
        guard ifNeeded else { return }
        let firstID = filteredPackages.first?.id
        Task { @MainActor in
            await Task.yield()
            selectedPackageID = firstID
        }
    }

    private func localState(for package: MarketplacePackage) -> String {
        let installedClients = package.installedClients
            .map(\.rawValue)
            .sorted()
        if !installedClients.isEmpty { return "Installed in \(installedClients.joined(separator: ", "))" }
        return package.isInstalled ? "Installed; client state unavailable" : "Not installed"
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Source"
        panel.canCreateDirectories = false
        if FileManager.default.fileExists(atPath: model.repositoryPath) {
            panel.directoryURL = URL(fileURLWithPath: model.repositoryPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.addMarketplaceSource(at: url)
        }
    }

    private func symbol(for kind: SourceKind) -> String {
        switch kind {
        case .localFolder: "folder"
        case .gitRepository: "arrow.triangle.branch"
        case .claudeMarketplace, .openAIPluginDirectory, .geminiExtensionGallery: "storefront"
        case .agentPlugins: "puzzlepiece.extension"
        case .mcpRegistry: "network"
        }
    }

    private func canOpen(_ location: String) -> Bool {
        if MarketplaceLocation.webURL(from: location) != nil { return true }
        return FileManager.default.fileExists(atPath: location)
    }

    private func open(_ location: String) {
        if let url = MarketplaceLocation.webURL(from: location) {
            if !NSWorkspace.shared.open(url) { model.presentError("macOS could not open the package source URL.") }
        } else if FileManager.default.fileExists(atPath: location) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location)])
        } else {
            model.presentError("The package source is no longer available. Refresh Marketplace to update this listing.")
        }
    }
}

private struct MarketplaceSearchField: View {
    @Binding var text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFocused ? AgentTheme.blue : Color.secondary)
                .accessibilityHidden(true)
            TextField("Search packages", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel("Search marketplace packages")
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .opacity(text.isEmpty ? 0 : 1)
            .allowsHitTesting(!text.isEmpty)
            .accessibilityHidden(text.isEmpty)
            .accessibilityLabel("Clear marketplace search")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(AgentTheme.controlBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isFocused ? AgentTheme.blue.opacity(0.72) : AgentTheme.separator.opacity(0.55), lineWidth: 0.75)
        }
        .animation(reduceMotion ? nil : AgentMotion.quick, value: isFocused)
        .animation(reduceMotion ? nil : AgentMotion.quick, value: text.isEmpty)
    }
}

private struct MarketplaceMenuButtonLabel: View {
    let systemImage: String
    var title: String?
    var badge: Int?
    var active = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            if let title {
                Text(title).lineLimit(1)
            }
            if let badge {
                Text(badge, format: .number)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(active ? AgentTheme.blue : Color.primary.opacity(0.07)))
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(active ? AgentTheme.blue : Color.primary)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? AgentTheme.blue.opacity(0.13) : Color.primary.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active ? AgentTheme.blue.opacity(0.28) : AgentTheme.separator.opacity(0.42), lineWidth: 0.5)
        }
    }
}

private struct ActiveFilterToken: View {
    let title: String
    let accessibilityName: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .leading)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(AgentTheme.blue)
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(AgentTheme.blue.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove \(accessibilityName) filter: \(title)")
        .accessibilityLabel("Remove \(accessibilityName) filter: \(title)")
    }
}

private enum MarketplaceClientFilter: String, CaseIterable, Identifiable {
    case all = "Any app"
    case claude = "Claude Code"
    case codex = "Codex"
    case gemini = "Gemini CLI"

    var id: String { rawValue }

    var client: ClientKind? {
        switch self {
        case .all: nil
        case .claude: .claude
        case .codex: .codex
        case .gemini: .gemini
        }
    }

    func matches(_ package: MarketplacePackage) -> Bool {
        guard let client else { return true }
        return package.supportedClients.contains(client) || package.nativeInstalls.contains { $0.client == client }
    }
}

private enum MarketplaceClassificationFilter: String, CaseIterable, Identifiable {
    case all = "Any provenance"
    case reference = "Reference"
    case official = "Official"
    case community = "Community"
    case unverified = "Unverified"

    var id: String { rawValue }

    var classification: PackageClassification? {
        switch self {
        case .all: nil
        case .reference: .reference
        case .official: .official
        case .community: .community
        case .unverified: .unverified
        }
    }

    var measurement: String {
        guard let classification else {
            return
                "Provenance says who a catalog verified, not whether a package is safe. Only the official MCP registry verifies a publisher at all."
        }
        return classification.definition
    }

    func matches(_ package: MarketplacePackage) -> Bool {
        guard let classification else { return true }
        return MarketplaceProvenanceClassifier.classify(package).classification == classification
    }
}

/// One line stating the scope an install will use, in Claude Code's own
/// vocabulary, so the word on screen matches the word in the client.
private struct InstallScopeNote: View {
    let scope: ToolingScope

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "person.crop.square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scope: \(scope.marketplaceInstallTitle)")
                    .font(.caption.weight(.medium))
                Text(scope.marketplaceInstallDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private enum MarketplaceComponentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case skills = "Skills"
    case plugins = "Plugins"
    case mcpServers = "MCP"

    var id: String { rawValue }

    func matches(_ package: MarketplacePackage) -> Bool {
        switch self {
        case .all: true
        case .skills: package.components.contains(.skill)
        case .plugins: package.components.contains(.plugin)
        case .mcpServers: package.components.contains(.mcpServer)
        }
    }
}

private struct MarketplaceSourceRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: ToolingSource
    let symbol: String
    var contents: String?
    var selected = false
    var onSelect: (() -> Void)?
    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onSelect?()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    SymbolTile(symbol: symbol, size: 31)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.callout.weight(.semibold)).lineLimit(1)
                        if let contents {
                            Text(contents).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(source.kind.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(source.trustSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if source.isOptionalBackup {
                            Text("Optional Git source")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help(selected ? "Show packages from every source" : "Show only packages from \(source.name)")
            .accessibilityLabel(source.name)
            .accessibilityValue(
                [
                    selected ? "Selected" : "",
                    contents ?? source.kind.displayName,
                    source.trustSummary,
                    source.isOptionalBackup ? "Optional Git source" : "",
                ]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            )
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(selected ? "Shows every source again" : "Shows only packages from this source")

            Menu {
                Button(MarketplaceLocation.webURL(from: source.location) == nil ? "Reveal in Finder" : "Open Website") { openSource() }
                if [.localFolder, .gitRepository].contains(source.kind) {
                    Divider()
                    Button("Remove Source…", role: .destructive) { isConfirmingRemoval = true }
                        .disabled(model.isInteractionLocked)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .help("Source actions")
            .accessibilityLabel("Actions for \(source.name)")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AgentTheme.blue.opacity(0.14) : .clear)
        )
        .animation(reduceMotion ? nil : AgentMotion.quick, value: selected)
        .confirmationDialog(
            "Remove \(source.name)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Source", role: .destructive) { model.removeMarketplaceSource(id: source.id) }
                .disabled(model.isInteractionLocked)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the source reference and its cached listings. It does not delete any files.")
        }
    }

    private func openSource() {
        if let url = MarketplaceLocation.webURL(from: source.location) {
            if !NSWorkspace.shared.open(url) { model.presentError("macOS could not open the marketplace source URL.") }
        } else if FileManager.default.fileExists(atPath: source.location) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.location)])
        } else {
            model.presentError("The source folder is no longer available. Remove it or choose the folder again.")
        }
    }

}

private extension NativeInstall {
    func isInstalledActionTitle(package: MarketplacePackage) -> String {
        "\(reportsInstalled(in: package) ? "Remove" : "Install") in \(client.rawValue)"
    }
}

private enum MarketplaceLocation {
    static func webURL(from value: String) -> URL? {
        guard let components = URLComponents(string: value),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            let url = components.url
        else { return nil }
        return url
    }
}

/// Tile, name, one clause, verdict. The verdict column carries the provenance
/// badge over whichever local fact matters most: where it is installed, or the
/// date the current sort is ordering by.
private struct MarketplacePackageRow: View {
    let package: MarketplacePackage
    let selected: Bool
    let verdict: PackageClassificationVerdict
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            KindTile(kind: marketplaceKind(for: package), size: 28, ghost: !package.isInstalled)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(package.publisher.isEmpty ? package.summary : "\(package.publisher) · \(package.summary)")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                ProvenanceBadge(verdict: verdict, tint: selected ? .white : nil)
                if package.isInstalled {
                    ClientMarks(present: Set(package.installedClients), size: 12)
                } else {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private func marketplaceKind(for package: MarketplacePackage) -> ToolingKind {
    if package.components.contains(.plugin) { return .plugin }
    if package.components.contains(.mcpServer) { return .mcpServer }
    if package.components.contains(.skill) { return .skill }
    return .source
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
