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
    @Environment(AppNavigationState.self) var navigation
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.availableClients) var availableClients
    // Inspector selection is transient, just like its presentation state.
    // Persistent filters restore the browsing context without reopening a panel.
    @State var selectedPackageID: String?
    @SceneStorage("agentTooling.marketplace.query") var query = ""
    @SceneStorage("agentTooling.marketplace.component") var componentFilter: MarketplaceComponentFilter = .all
    @SceneStorage("agentTooling.marketplace.client") var clientFilter: MarketplaceClientFilter = .all
    @SceneStorage("agentTooling.marketplace.provenance") var classificationFilter: MarketplaceClassificationFilter = .all
    /// A category the catalog filed listings under, or nil for any. Data-driven
    /// rather than a fixed enum: the choices are exactly the categories present
    /// in what the catalogs returned, so the menu only offers this filter when a
    /// listing actually carries a category.
    @SceneStorage("agentTooling.marketplace.category") var categoryFilter: String?
    @SceneStorage("agentTooling.marketplace.sort") var sortOrder: MarketplaceSortOrder = .relevance
    @SceneStorage("agentTooling.marketplace.source") var selectedSourceIDStorage: String?
    @State var showingSources = false
    @State var showingDetails = false

    var body: some View {
        let packages = filteredPackages

        VStack(spacing: 0) {
            PageToolbar(title: AppSection.marketplace.navigationTitle, context: toolbarContext) {
                Button("Sources", systemImage: "shippingbox") { showingSources.toggle() }
                    .buttonStyle(.glass)
                    .help("Look at the catalogs, registries, and folders shown in Discover")
                    .popover(isPresented: $showingSources) { sourcePane.frame(width: 340, height: 500) }
                AddCatalogSourceButton(workspace: workspace, catalogs: session)
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

    /// What an empty Sources list means. The catalogs every build knows about
    /// are listed even when this workspace has recorded none of its own, so an
    /// empty list means something specific and worth saying once.
    static let noRecordedSources =
        "This workspace records no catalogs of its own. Add a folder of packages, or a Git checkout of one, for Discover to read."

    var toolbarContext: String {
        let packageCount = session.packages.count
        let sourceCount = session.sources.count
        return "\(packageCount) package\(packageCount == 1 ? "" : "s") from \(sourceCount) source\(sourceCount == 1 ? "" : "s")"
    }

    func applyExternalNavigation() {
        guard let requestedID = navigation.requestedMarketplacePackageID else { return }
        defer { navigation.consumeMarketplacePackage(requestedID) }
        guard session.packages.contains(where: { $0.id == requestedID }) else { return }
        query = ""
        componentFilter = .all
        clientFilter = .all
        classificationFilter = .all
        categoryFilter = nil
        selectedSourceID = nil
        selectedPackageID = requestedID
        showingDetails = true
    }

    func validateRestoredMarketplaceState() {
        if let selectedSourceID,
            !session.sources.contains(where: { $0.id == selectedSourceID })
        {
            self.selectedSourceID = nil
        }
        let visibleIDs = Set(filteredPackages.map(\.id))
        if let selectedPackageID, !visibleIDs.contains(selectedPackageID) { self.selectedPackageID = nil }
    }

    var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Catalogs and folders") {
                Text("\(session.sources.count) available")
            }
            if session.sources.isEmpty {
                EmptyStateView(
                    symbol: "shippingbox", title: "No catalogs recorded",
                    message: Self.noRecordedSources)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sortedSources) { source in
                            MarketplaceSourceRow(
                                source: source,
                                symbol: symbol(for: source.kind),
                                contents: contentsSummary(for: source),
                                selected: selectedSourceID == source.id,
                                removal: isRecorded(source)
                                    ? RemoveCatalogSourceButton(
                                        workspace: workspace, catalogs: session, source: source)
                                    : nil
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

    func packagePane(packages: [MarketplacePackage]) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    InventorySearchField(
                        placeholder: "Search, or describe what you need a skill for", text: $query
                    )
                    .onSubmit { Task { await session.search(query) } }
                    .help(
                        "Filters what is shown, and on Return asks every catalog — skills.sh answers a plain description with matching skills."
                    )
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
                            if let categoryFilter {
                                ActiveFilterToken(title: categoryFilter.capitalized, accessibilityName: "category") {
                                    self.categoryFilter = nil
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

                if !session.catalogFailures.isEmpty {
                    if session.packages.isEmpty {
                        // Nothing came back from any source, and at least one
                        // said why. Lead with the reasons rather than an empty
                        // grid that reads as "there is nothing here".
                        AttentionBanner(
                            title: "Some catalogs could not be read",
                            message: session.catalogFailures.map { "\($0.name): \($0.reason)" }
                                .joined(separator: "\n")
                        ) {
                            Button("Sources", systemImage: "shippingbox") { showingSources = true }
                                .buttonStyle(.glass)
                                .help("Open the Sources list to see each catalog's status")
                        }
                    } else {
                        // Some catalogs answered and some did not. The grid
                        // below is real, so the shortfall is a quiet one-line
                        // note that points at the Sources list for the detail.
                        Button {
                            showingSources = true
                        } label: {
                            let count = session.catalogFailures.count
                            Text("\(count) catalog\(count == 1 ? "" : "s") could not be read — Sources")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open the Sources list to see which catalogs could not be read and why")
                        .accessibilityLabel(
                            "\(session.catalogFailures.count) catalogs could not be read. Open Sources for detail.")
                    }
                }
            }
            .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, WorkspaceLayout.contentTopInset)
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
                        alignment: .leading, spacing: 14
                    ) {
                        ForEach(packages) { package in
                            MarketplaceGalleryCard(
                                package: package, selected: showingDetails && selectedPackageID == package.id,
                                detail: [.recentlyUpdated, .installs].contains(sortOrder) ? rowDetail(for: package) : nil,
                                inLibrary: session.libraryMatch(for: package) != nil,
                                compact: showingDetails
                            ) {
                                selectedPackageID = package.id
                                showingDetails = true
                            }
                        }
                    }
                    .padding(.horizontal, showingDetails ? 12 : WorkspaceLayout.pageInset)
                    .padding(.top, WorkspaceLayout.contentTopInset)
                    .padding(.bottom, WorkspaceLayout.pageInset)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .paneMaterial()
    }

}
