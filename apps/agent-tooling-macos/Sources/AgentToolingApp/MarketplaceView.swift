import AgentToolingCore
import AppKit
import SwiftUI

/// Discover: the catalogs, what they publish, and what this Mac can say about
/// each listing before anyone installs anything.
///
/// The screen is a browser and a review desk, and deliberately not an
/// installer. Every verdict on it — provenance, the three grades, the declared
/// tools — states what was measured and what was not, and the one thing it
/// refuses to state is whether a listing is installed: a catalog's own claim is
/// dropped on the way in, and "in your library" is answered from the workspace,
/// which is a record this app keeps itself.
struct MarketplaceView: View {
    let workspace: WorkspaceLaunch.Workspace
    let session: WorkspaceMarketplaceSession
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Inspector selection is transient, just like its presentation state.
    // Persistent filters restore the browsing context without reopening a panel.
    @State private var selectedPackageID: String?
    @SceneStorage("agentTooling.marketplace.query") private var query = ""
    @SceneStorage("agentTooling.marketplace.component") private var componentFilter: MarketplaceComponentFilter = .all
    @SceneStorage("agentTooling.marketplace.client") private var clientFilter: MarketplaceClientFilter = .all
    @SceneStorage("agentTooling.marketplace.provenance") private var classificationFilter: MarketplaceClassificationFilter = .all
    @SceneStorage("agentTooling.marketplace.sort") private var sortOrder: MarketplaceSortOrder = .relevance
    @SceneStorage("agentTooling.marketplace.source") private var selectedSourceIDStorage: String?
    @State private var showingSources = false
    @State private var showingDetails = false

    var body: some View {
        let packages = filteredPackages

        VStack(spacing: 0) {
            PageToolbar(title: AppSection.marketplace.navigationTitle, context: toolbarContext) {
                Button("Sources", systemImage: "shippingbox") { showingSources.toggle() }
                    .buttonStyle(.glass)
                    .help("Look at the catalogs, registries, and folders shown in Discover")
                    .popover(isPresented: $showingSources) { sourcePane.frame(width: 340, height: 500) }
                Button {
                    // Unreachable: the button never enables. Kept so the control
                    // is the same object it will be once the command exists.
                } label: {
                    Label("Add source…", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .disabled(true)
                .help(Self.addSourceUnavailable)
                Button {
                    Task { await session.refresh() }
                } label: {
                    Label(session.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(session.isRefreshing)
                .help(
                    session.canReachCatalog
                        ? "Ask every catalog again"
                        : WorkspaceMarketplaceSession.noProviderNote)
            }

            GeometryReader { proxy in
                Group {
                    if showingDetails, selectedPackage != nil {
                        HSplitView {
                            packagePane(packages: packages)
                                .frame(minWidth: 340, idealWidth: proxy.size.width * 0.55)
                            VStack(spacing: 0) {
                                InspectorHeader(title: "Package details") { showingDetails = false }
                                detailPane
                            }
                            .frame(minWidth: 410, idealWidth: proxy.size.width * 0.45)
                        }
                    } else {
                        packagePane(packages: packages)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .onAppear { if !workspace.device.isEnabled(clientFilter.client) { clientFilter = .all } }
        .onChange(of: workspace.device.enabledClients) { _, _ in
            if !workspace.device.isEnabled(clientFilter.client) { clientFilter = .all }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            applyExternalNavigation()
            validateRestoredMarketplaceState()
        }
        .onChange(of: navigation.revision) { _, _ in applyExternalNavigation() }
        .onChange(of: packages.map(\.id)) { _, ids in
            if let selectedPackageID, !ids.contains(selectedPackageID) {
                self.selectedPackageID = nil
                showingDetails = false
            }
        }
        .onExitCommand { showingDetails = false }
        .onChange(of: session.sources.map(\.id)) { _, ids in
            if let selectedSourceID, !ids.contains(selectedSourceID) {
                self.selectedSourceID = nil
            }
        }
    }

    /// Adding a catalog is not a command this build has. Stated in one place so
    /// the toolbar and the source list cannot disagree about why.
    private static let addSourceUnavailable =
        "Adding or removing a catalog source is not available in this build. The sources shown are the ones this workspace already records."

    private var toolbarContext: String {
        let packageCount = session.packages.count
        let sourceCount = session.sources.count
        return "\(packageCount) package\(packageCount == 1 ? "" : "s") from \(sourceCount) source\(sourceCount == 1 ? "" : "s")"
    }

    private func applyExternalNavigation() {
        guard let requestedID = navigation.requestedMarketplacePackageID else { return }
        defer { navigation.consumeMarketplacePackage(requestedID) }
        guard session.packages.contains(where: { $0.id == requestedID }) else { return }
        query = ""
        componentFilter = .all
        clientFilter = .all
        classificationFilter = .all
        selectedSourceID = nil
        selectedPackageID = requestedID
        showingDetails = true
    }

    private func validateRestoredMarketplaceState() {
        if let selectedSourceID,
            !session.sources.contains(where: { $0.id == selectedSourceID })
        {
            self.selectedSourceID = nil
        }
        let visibleIDs = Set(filteredPackages.map(\.id))
        if let selectedPackageID, !visibleIDs.contains(selectedPackageID) { self.selectedPackageID = nil }
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Catalogs and folders") {
                Text("\(session.sources.count) available")
            }
            if session.sources.isEmpty {
                EmptyStateView(
                    symbol: "shippingbox", title: "No catalogs recorded",
                    message:
                        "This workspace records no catalog sources. \(Self.addSourceUnavailable)")
            } else {
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
                    InventorySearchField(placeholder: "Search packages", text: $query)
                        .onSubmit { Task { await session.search(query) } }
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
                    stackedMarketplaceControls
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

                if let errorMessage = session.errorMessage {
                    AttentionBanner(title: "Some catalogs did not answer", message: errorMessage)
                }
            }
            .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, WorkspaceLayout.contentTopInset)
            .background(Color.primary.opacity(0.012))
            .overlay(alignment: .bottom) { Divider().opacity(0.35) }

            if packages.isEmpty {
                EmptyStateView(
                    symbol: hasActiveFilter ? "line.3.horizontal.decrease.circle" : "shippingbox",
                    title: hasActiveFilter ? "No matching packages" : "No packages found",
                    message: emptyPackageMessage,
                    actionTitle: hasActiveFilter ? "Clear Filters" : nil,
                    isActionEnabled: hasActiveFilter
                ) {
                    clearFilters()
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: showingDetails ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 360, maximum: 560))],
                        alignment: .leading, spacing: 8
                    ) {
                        ForEach(packages) { package in
                            MarketplaceGalleryCard(
                                package: package, selected: showingDetails && selectedPackageID == package.id,
                                detail: sortOrder == .recentlyUpdated ? rowDetail(for: package) : nil,
                                inLibrary: session.libraryMatch(for: package) != nil,
                                compact: showingDetails
                            ) {
                                selectedPackageID = package.id
                                showingDetails = true
                            }
                        }
                    }
                    .frame(maxWidth: 1_120)
                    .padding(.horizontal, showingDetails ? 12 : WorkspaceLayout.pageInset)
                    .padding(.top, WorkspaceLayout.contentTopInset)
                    .padding(.bottom, WorkspaceLayout.pageInset)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .paneMaterial()
    }

    private var wideMarketplaceControls: some View {
        HStack(spacing: 8) {
            componentSelector
                .fixedSize()
            marketplaceFilterMenu(compact: false)
            marketplaceSortMenu(compact: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactMarketplaceControls: some View {
        HStack(spacing: 8) {
            componentSelector
                .fixedSize()
            marketplaceFilterMenu(compact: true)
            marketplaceSortMenu(compact: true)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var stackedMarketplaceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            componentSelector.fixedSize()
            HStack(spacing: 8) {
                marketplaceFilterMenu(compact: false)
                marketplaceSortMenu(compact: false)
            }
        }
    }

    private var componentSelector: some View {
        WorkspaceSegmentedPicker("Package component", selection: $componentFilter) {
            ForEach(MarketplaceComponentFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
        }
    }

    private func marketplaceFilterMenu(compact: Bool) -> some View {
        let activeCount = (clientFilter == .all ? 0 : 1) + (classificationFilter == .all ? 0 : 1)
        return Menu {
            Menu("App") {
                ForEach(MarketplaceClientFilter.allCases.filter { workspace.device.isEnabled($0.client) }) { filter in
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
                badge: activeCount == 0 ? nil : activeCount
            )
        }
        .inventoryMenuStyle()
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
                title: compact ? nil : visibleSortName
            )
        }
        .inventoryMenuStyle()
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
                        ToolIdentityIcon(packageID: package.id, fallback: marketplaceKind(for: package), size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.presentationName).font(.system(size: 22, weight: .semibold))
                            Text("\(package.originLabel): \(package.originName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProvenanceBadge(verdict: MarketplaceProvenanceClassifier.classify(package))
                    }
                    Text(package.summary).font(.callout).foregroundStyle(.secondary)

                    if let match = session.libraryMatch(for: package) {
                        alreadyInLibrary(match)
                    } else {
                        installRoutes(for: package)
                    }

                    DisclosureGroup("Source and compatibility") {
                        VStack(spacing: 0) {
                            LabeledValueRow(package.originLabel) { Text(package.originName).foregroundStyle(.secondary) }
                            Divider()
                            if !package.isNativeCatalogListing, package.publisher != package.sourceName {
                                LabeledValueRow("Publisher") { Text(package.publisher).foregroundStyle(.secondary) }
                                Divider()
                            }
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
                                LabeledValueRow("Review notes") {
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
                            LabeledValueRow("Package location") {
                                VStack(alignment: .trailing, spacing: 6) {
                                    if let pluginName = MarketplaceIdentityNaming(package.location).pluginTitle {
                                        Text(pluginName).foregroundStyle(.secondary)
                                    } else {
                                        LocationText(path: package.location)
                                    }
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

                    DisclosureGroup("Metadata checks") {
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

                }
                .padding(22)
            }
        } else {
            EmptyStateView(
                symbol: "shippingbox", title: "Select a package",
                message: "Imported packages receive a component, trust, and compatibility review before any install action.")
        }
    }

    /// The one thing Discover can still act on: a listing that is already in
    /// the library goes to the row that holds it. Revealing is not installing.
    private func alreadyInLibrary(_ match: WorkspaceMarketplaceSession.LibraryMatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusBadge(state: .healthy, text: "Already in your library as \(match.displayName)")
            Button("Show in Library", systemImage: "books.vertical") {
                navigation.openItem(match.itemID, in: .plugins)
            }
            .buttonStyle(.borderedProminent)
            .tint(AgentTheme.selection)
            Text("Where this package is installed is decided on the Apps screen, not here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Install routes state the scope they would use in Claude's own words, and
    /// then say plainly that this build cannot run them.
    ///
    /// The routes stay on screen rather than being hidden behind the refusal:
    /// what a catalog would run, and with what scope, is exactly the thing a
    /// person came here to read. What is missing is the command that would put
    /// the package in the library, and only that is disabled.
    @ViewBuilder
    private func installRoutes(for package: MarketplacePackage) -> some View {
        let scopes = Set(package.nativeInstalls.map(\.scope))
        VStack(alignment: .leading, spacing: 8) {
            Text(package.nativeInstalls.isEmpty ? "No native install route" : "Native install routes")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if package.nativeInstalls.isEmpty {
                Text("This listing publishes no verified installer for any app on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if scopes.count == 1, let scope = scopes.first {
                InstallScopeNote(scope: scope)
            }
            FlowLayout(spacing: 8) {
                ForEach(package.nativeInstalls) { route in
                    Button {
                        // Unreachable: the button never enables.
                    } label: {
                        HStack(spacing: 7) {
                            ClientBrandIcon(client: route.client, size: 14)
                            Text("Install in \(route.client.rawValue)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .disabled(true)
                    .help(
                        "\(route.detail) Scope: \(route.scope.marketplaceInstallTitle). "
                            + WorkspaceMarketplaceSession.installUnavailable)
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
            Text(WorkspaceMarketplaceSession.installUnavailable)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the last refresh could say about the catalog behind a package.
    /// Grading uses this instead of guessing that silence means healthy.
    private func reachability(for package: MarketplacePackage) -> SourceReachability {
        guard let source = session.sources.first(where: { matches($0, package) }) else { return .unknown }
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
        let matches = session.packages.filter { package in
            componentFilter.matches(package)
                && clientFilter.matches(package)
                && classificationFilter.matches(package)
                && matchesSelectedSource(package)
                && (searchTerm.isEmpty
                    || [
                        package.presentationName, package.originName, package.publisher, package.summary,
                        package.components.map(\.displayName).joined(separator: " "),
                    ]
                    .joined(separator: " ")
                    .localizedCaseInsensitiveContains(searchTerm))
        }
        return MarketplaceSorting.sorted(matches, by: sortOrder, searchTerm: searchTerm)
    }

    private var selectedPackage: MarketplacePackage? { session.packages.first { $0.id == selectedPackageID } }

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
            guard session.canReachCatalog else { return WorkspaceMarketplaceSession.noProviderNote }
            return "Refresh the catalogs. Nothing this workspace records has published a package yet."
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
        return session.sources.first { $0.id == selectedSourceID }
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
        let packages = session.packages.filter { matches(source, $0) }
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
        session.sources.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id.uuidString < $1.id.uuidString : nameOrder == .orderedAscending
        }
    }

    /// What this Mac can defend about a listing, which is whether the workspace
    /// holds it. Installation is measured on the Apps screen and nowhere else,
    /// so no catalog's own claim about it reaches this line.
    private func localState(for package: MarketplacePackage) -> String {
        guard let match = session.libraryMatch(for: package) else {
            return "Not in your library"
        }
        return "In your library as \(match.displayName); where it is installed is decided on Apps"
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
            NSWorkspace.shared.open(url)
        } else if FileManager.default.fileExists(atPath: location) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location)])
        }
    }
}

private struct MarketplaceMenuButtonLabel: View {
    let systemImage: String
    var title: String?
    var badge: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            if let title {
                Text(title).lineLimit(1)
            }
            if let badge {
                Text(badge, format: .number)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: ToolingSource
    let symbol: String
    var contents: String?
    var selected = false
    var onSelect: (() -> Void)?

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

            // Where the source is, and nothing that changes it: removing a
            // source is not a command this build has.
            if !source.location.isEmpty {
                PathInfoButton(path: source.location)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AgentTheme.blue.opacity(0.14) : .clear)
        )
        .animation(reduceMotion ? nil : AgentMotion.quick, value: selected)
    }
}

extension MarketplacePackage {
    fileprivate var presentationName: String { MarketplaceIdentityNaming.pluginName(name, identifier: id) }

    // The native ingestors use marketplaceName for `publisher`; it is catalog
    // provenance, not a claim about who authored or verified the plugin.
    fileprivate var isNativeCatalogListing: Bool { id.hasPrefix("codex:") || id.hasPrefix("claude:") }
    fileprivate var originLabel: String { isNativeCatalogListing ? "Marketplace" : "Catalog" }
    fileprivate var originName: String {
        if isNativeCatalogListing {
            return MarketplaceIdentityNaming(id).marketplaceTitle ?? MarketplaceIdentityNaming.title(sourceName)
        }
        return sourceName
    }
}

/// A catalog identifier read for its two halves, so `foo@bar` is shown as the
/// package it names rather than as a raw identifier.
///
/// This is the naming half of the old `ConnectionSource`, which went with the
/// Connections screen. Only the parts Discover needs are here, and they are
/// file-private so restoring that screen elsewhere cannot collide with them.
private struct MarketplaceIdentityNaming {
    let plugin: String?
    let marketplace: String?

    init(_ raw: String) {
        let identifier: String
        if raw.hasPrefix("codex:") {
            identifier = String(raw.dropFirst("codex:".count))
        } else if raw.hasPrefix("claude:") {
            identifier = String(raw.dropFirst("claude:".count))
        } else {
            identifier = raw
        }
        let parts = identifier.split(separator: "@", omittingEmptySubsequences: false)
        let validID: (Substring) -> Bool = {
            !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
        if parts.count == 2, parts.allSatisfy(validID) {
            plugin = String(parts[0])
            marketplace = String(parts[1])
        } else {
            plugin = nil
            marketplace = nil
        }
    }

    var pluginTitle: String? { plugin.map(Self.title) }
    var marketplaceTitle: String? { marketplace.map(Self.title) }

    /// Keep a declared display name, removing the catalog suffix only when it
    /// is the item's own qualified identifier or its already-humanized form.
    static func pluginName(_ displayName: String, identifier: String) -> String {
        let identity = MarketplaceIdentityNaming(identifier)
        guard let plugin = identity.plugin, let marketplace = identity.marketplace else { return displayName }
        let displayedIdentity = MarketplaceIdentityNaming(displayName)
        if displayedIdentity.plugin == plugin, displayedIdentity.marketplace == marketplace {
            return title(plugin)
        }
        if displayName == "\(title(plugin))@\(title(marketplace))" {
            return title(plugin)
        }
        return displayName
    }

    static func title(_ id: String) -> String {
        let names = ["openai": "OpenAI", "github": "GitHub", "mcp": "MCP", "ios": "iOS", "cli": "CLI", "pdf": "PDF"]
        return id.split(separator: "-").map {
            names[$0.lowercased()] ?? ($0.prefix(1).uppercased() + $0.dropFirst())
        }.joined(separator: " ")
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

/// Purpose first, with app compatibility and a dated fact when sorting by recency.
private struct MarketplaceGalleryCard: View {
    let package: MarketplacePackage
    let selected: Bool
    let detail: String?
    /// Whether the workspace already holds this package. Never a catalog's own
    /// claim: a listing does not get to say what is in your library.
    let inLibrary: Bool
    let compact: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: compact ? 12 : 16) {
                ToolIdentityIcon(packageID: package.id, fallback: marketplaceKind(for: package), size: compact ? 36 : 44)
                VStack(alignment: .leading, spacing: 7) {
                    Text(package.presentationName).font(.system(size: compact ? 16 : 17, weight: .medium)).lineLimit(1).help(
                        package.presentationName)
                    Text(package.summary).font(.system(size: compact ? 14 : 15)).foregroundStyle(.secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                    HStack(spacing: 8) {
                        Text(detail ?? "From \(package.originName)")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        ForEach(package.supportedClients.sorted { $0.rawValue < $1.rawValue }) { client in
                            ClientBrandIcon(client: client, size: 15).help("Available for \(client.rawValue)")
                        }
                    }
                }
                Image(systemName: inLibrary ? "checkmark.circle" : "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(inLibrary ? "Already in your library; view details" : "View package details")
            }
            .padding(compact ? 12 : 18).frame(maxWidth: .infinity, minHeight: compact ? 116 : 138, alignment: .topLeading)
            .background(Color.primary.opacity(hovering || selected ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(AgentTheme.blue.opacity(selected ? 0.6 : 0), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(package.presentationName), from \(package.originName)")
        .accessibilityHint("Open package details and installation options")
    }
}

private func marketplaceKind(for package: MarketplacePackage) -> ToolingKind {
    if package.components.contains(.plugin) { return .plugin }
    if package.components.contains(.mcpServer) { return .mcpServer }
    if package.components.contains(.skill) { return .skill }
    return .source
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
