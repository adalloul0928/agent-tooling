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
    /// The library row Install is picking apps for, once a listing is in the
    /// library. Set by `install(_:client:)` and cleared when the picker closes.
    @State var installRequest: InstallRequest?
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
                Button("Sources…", systemImage: "shippingbox") { showingSources.toggle() }
                    .buttonStyle(.glass)
                    .help("Look at the catalogs, registries, and folders shown in Discover")
                    .popover(isPresented: $showingSources) { sourcePane.sheetSize(SheetSize.popover) }
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
                                .frame(minWidth: Size.listPaneMin, idealWidth: proxy.size.width * Proportion.listShare)
                            VStack(spacing: 0) {
                                InspectorHeader(title: "Package details") { showingDetails = false }
                                detailPane
                            }
                            .frame(minWidth: Size.detailPaneMin, idealWidth: proxy.size.width * Proportion.detailShare)
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
        // Install from Discover is the same picker the Library uses, opened on
        // the row the listing became. Choosing apps and writing is its job.
        .sheet(item: $installRequest) { request in
            WorkspaceAssignmentSheet(
                session: workspace.library, artifactIDs: [request.id], initialClients: request.clients)
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
        "\(CountNoun("package").phrase(session.packages.count)) from \(CountNoun("source").phrase(session.sources.count))"
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
                            if source.id != sortedSources.last?.id { Hairline() }
                        }
                    }
                    .padding(.horizontal, Space.sm)
                }
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                Label("Reviewed locally", systemImage: "checkmark.shield")
                    .font(AgentFont.captionSemibold)
                Text("Catalog installs stay with their native client. Added folders are inspected before review.")
                    .font(AgentFont.micro)
                    .foregroundStyle(.secondary)
            }
            .padding(Space.lg)
        }
        .paneMaterial()
    }

    func packagePane(packages: [MarketplacePackage]) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.lg) {
                    InventorySearchField(
                        placeholder: "Search, or describe what you need a skill for", text: $query
                    )
                    .onSubmit { Task { await session.search(query) } }
                    .help(
                        "Filters what is shown, and on Return asks every catalog — skills.sh answers a plain description with matching skills."
                    )
                    Text(resultCountDescription(packages.count))
                        .font(AgentFont.caption.monospacedDigit())
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
                        FlowLayout(spacing: Space.sm) {
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
                                .font(AgentFont.captionMedium)
                                .foregroundStyle(AgentTheme.selection)
                                .accessibilityLabel("Clear all marketplace filters")
                        }
                        .transition(.opacity.combined(with: .scale(scale: AgentMotion.appearScale, anchor: .topLeading)))
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
                            Button("Sources…", systemImage: "shippingbox") { showingSources = true }
                                .buttonStyle(.glass)
                                .help("Open the Sources list to see each catalog's status")
                        }
                    } else {
                        // Some catalogs answered and some did not. The grid
                        // below is real, so the shortfall is a quiet one-line
                        // note that points at the Sources list for the detail.
                        let unread = CountNoun("catalog").phrase(session.catalogFailures.count)
                        Button {
                            showingSources = true
                        } label: {
                            Text("\(unread) could not be read — Sources…")
                                .font(AgentFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open the Sources list to see which catalogs could not be read and why")
                        .accessibilityLabel("\(unread) could not be read. Open Sources for detail.")
                    }
                }
            }
            .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, WorkspaceLayout.contentTopInset)
            .hairlineBottom()

            if packages.isEmpty {
                EmptyStateView(
                    symbol: hasActiveFilter ? "line.3.horizontal.decrease.circle" : "shippingbox",
                    title: hasActiveFilter ? "No matching packages" : "No packages found",
                    message: emptyPackageMessage,
                    actionTitle: hasActiveFilter ? "Clear filters" : nil,
                    isActionEnabled: hasActiveFilter
                ) {
                    clearFilters()
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: showingDetails
                            ? [GridItem(.flexible())]
                            : [GridItem(.adaptive(minimum: Size.packageCardMinWidth, maximum: Size.packageCardMaxWidth))],
                        alignment: .leading, spacing: Space.xl
                    ) {
                        ForEach(packages) { package in
                            MarketplaceGalleryCard(
                                package: package, selected: showingDetails && selectedPackageID == package.id,
                                detail: [.recentlyUpdated, .installs].contains(sortOrder) ? rowDetail(for: package) : nil,
                                inLibrary: session.libraryMatch(for: package) != nil,
                                compact: showingDetails,
                                install: installAffordance(for: package),
                                busy: session.adoptingPackageID == package.id,
                                onInstall: { client in Task { await install(package, client: client) } }
                            ) {
                                selectedPackageID = package.id
                                showingDetails = true
                            }
                        }
                    }
                    .padding(.horizontal, showingDetails ? Space.lg : WorkspaceLayout.pageInset)
                    .padding(.top, WorkspaceLayout.contentTopInset)
                    .padding(.bottom, WorkspaceLayout.pageInset)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .paneMaterial()
    }

    // MARK: - Install

    /// What Install does for one listing: nothing to offer (no app on this Mac
    /// can take it), one press that knows where it goes, or a choice of app
    /// first because the listing installs through a client's own installer and
    /// more than one client here could take it.
    enum InstallAffordance: Equatable {
        case install(ClientKind?)
        case choose([ClientKind])
    }

    struct InstallRequest: Identifiable {
        let id: ArtifactID
        let clients: Set<ClientKind>
    }

    func installAffordance(for package: MarketplacePackage) -> InstallAffordance? {
        if session.libraryMatch(for: package) != nil { return .install(nil) }
        if WorkspaceMarketplaceSession.skillsShListing(package) != nil { return .install(nil) }
        if package.components.contains(.mcpServer),
            case .reviewed = ReviewedMarketplaceMCPServer.availability(for: package)
        {
            return .install(nil)
        }
        let routes = package.nativeInstalls
            .map(\.client)
            .filter { availableClients.contains($0) && session.adoptionRefusal(for: package, client: $0) == nil }
        switch routes.count {
        case 0: return nil
        case 1: return .install(routes[0])
        default: return .choose(routes.sorted { $0.rawValue < $1.rawValue })
        }
    }

    /// Puts the listing in the library if it is not there yet, then opens the
    /// picker on that row. The library write is the session's; the client
    /// writes are the picker's; nothing here touches a client.
    func install(_ package: MarketplacePackage, client: ClientKind?) async {
        if session.libraryMatch(for: package) == nil {
            if WorkspaceMarketplaceSession.skillsShListing(package) != nil {
                await session.adoptSkill(package)
            } else if package.components.contains(.mcpServer), package.nativeInstalls.isEmpty {
                await session.adoptMCPServer(package)
            } else if let client {
                await session.adopt(package, client: client)
            }
        }
        guard let match = session.libraryMatch(for: package) else { return }
        installRequest = InstallRequest(id: match.artifactID, clients: client.map { [$0] } ?? [])
    }
}
