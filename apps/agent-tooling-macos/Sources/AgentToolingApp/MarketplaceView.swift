import AgentToolingCore
import AppKit
import SwiftUI

struct MarketplaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @State private var selectedPackageID: String?
    @State private var query = ""
    @State private var componentFilter: MarketplaceComponentFilter = .all
    @State private var clientFilter: MarketplaceClientFilter = .all
    @State private var selectedSourceID: UUID?
    @State private var displayLimit = Self.pageSize

    private static let pageSize = 12

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Marketplace", context: "\(model.marketplacePackages.count) packages from \(model.sources.count) sources") {
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
                    packagePane.frame(
                        minWidth: 310, idealWidth: 390, maxWidth: 480, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                    detailPane.frame(
                        minWidth: 340, maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            applyExternalNavigation()
            selectFirstPackageAfterListUpdate(ifNeeded: selectedPackageID == nil)
        }
        .onChange(of: navigation.revision) { _, _ in applyExternalNavigation() }
        .onChange(of: visiblePackages.map(\.id)) { _, ids in
            let selectionIsInvalid = selectedPackageID == nil || !ids.contains(selectedPackageID ?? "")
            selectFirstPackageAfterListUpdate(ifNeeded: selectionIsInvalid)
        }
        .onChange(of: query) { _, _ in displayLimit = Self.pageSize }
        .onChange(of: componentFilter) { _, _ in displayLimit = Self.pageSize }
        .onChange(of: clientFilter) { _, _ in displayLimit = Self.pageSize }
        .onChange(of: selectedSourceID) { _, _ in displayLimit = Self.pageSize }
    }

    private func applyExternalNavigation() {
        guard let requestedID = navigation.requestedMarketplacePackageID,
            model.marketplacePackages.contains(where: { $0.id == requestedID })
        else { return }
        query = ""
        componentFilter = .all
        clientFilter = .all
        selectedSourceID = nil
        if let index = filteredPackages.firstIndex(where: { $0.id == requestedID }) {
            displayLimit = max(Self.pageSize, index + 1)
        }
        selectedPackageID = requestedID
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Sources") {
                Text("\(model.sources.count) available")
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

    private var packagePane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                TextField("Search packages", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search marketplace packages")
                HStack(spacing: 8) {
                    Picker("Component", selection: $componentFilter) {
                        ForEach(MarketplaceComponentFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Package component")
                    Picker("App", selection: $clientFilter) {
                        ForEach(MarketplaceClientFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Filter by app")
                    Spacer(minLength: 0)
                    Text(packageCountLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let source = selectedSource {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(AgentTheme.blue)
                        Text(source.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Button {
                            selectedSourceID = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Show every source")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(AgentTheme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(12)

            if filteredPackages.isEmpty {
                EmptyStateView(
                    symbol: hasActiveFilter ? "line.3.horizontal.decrease.circle" : "shippingbox",
                    title: hasActiveFilter ? "No matching packages" : "No packages found",
                    message: emptyPackageMessage,
                    actionTitle: hasActiveFilter ? "Clear Filters" : "Add Source",
                    isActionEnabled: hasActiveFilter || !model.isInteractionLocked
                ) {
                    if hasActiveFilter {
                        query = ""
                        componentFilter = .all
                        clientFilter = .all
                        selectedSourceID = nil
                    } else {
                        chooseSource()
                    }
                }
            } else {
                List(selection: $selectedPackageID) {
                    ForEach(visiblePackages) { package in
                        MarketplacePackageRow(package: package, selected: selectedPackageID == package.id)
                            .tag(package.id)
                            .listRowBackground(SelectionRowBackground(selected: selectedPackageID == package.id))
                            .accessibilityLabel(package.name)
                            .accessibilityValue(selectedPackageID == package.id ? "Selected" : "")
                    }
                    if visiblePackages.count < filteredPackages.count {
                        Button(showMoreLabel) {
                            displayLimit += Self.pageSize
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AgentTheme.blue)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .accessibilityHint("Loads the next marketplace results")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .paneMaterial()
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
                    }
                    Text(package.summary).font(.callout).foregroundStyle(.secondary)

                    GroupBox("Review") {
                        VStack(spacing: 0) {
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
                                    Text(credentials.joined(separator: ", "))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
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

                    if package.nativeInstalls.isEmpty {
                        Button("Review Source…", systemImage: "checklist") {
                            model.reviewMarketplacePackage(package.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isInteractionLocked)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Native install routes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                                }
                            }
                        }
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

    private var filteredPackages: [MarketplacePackage] {
        model.marketplacePackages.filter { package in
            componentFilter.matches(package)
                && clientFilter.matches(package)
                && matchesSelectedSource(package)
                && (query.isEmpty
                    || [package.name, package.publisher, package.summary, package.components.map(\.displayName).joined(separator: " ")]
                        .joined(separator: " ")
                        .localizedCaseInsensitiveContains(query))
        }
        .sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }

    private var selectedPackage: MarketplacePackage? { model.marketplacePackages.first { $0.id == selectedPackageID } }

    private var hasActiveFilter: Bool {
        !query.isEmpty || componentFilter != .all || clientFilter != .all || selectedSourceID != nil
    }

    private var emptyPackageMessage: String {
        guard hasActiveFilter else {
            return "Refresh native catalogs or add a local folder, checked-out Git repository, or Agent Plugin package."
        }
        if let source = selectedSource, componentFilter != .all {
            return
                "\(source.name) publishes no \(componentFilter.rawValue.lowercased()) packages. Native client catalogs list plugins; skills come from Agent Plugins folders and Git checkouts you add."
        }
        if let source = selectedSource {
            return "\(source.name) has nothing matching the current filters."
        }
        if componentFilter == .skills {
            return
                "No catalog here publishes standalone skills. Add a local folder or Git checkout containing Agent Plugins packages to see skills."
        }
        return "Try a different package name, publisher, component, or app."
    }

    private var selectedSource: ToolingSource? {
        guard let selectedSourceID else { return nil }
        return model.sources.first { $0.id == selectedSourceID }
    }

    /// Native catalogs do not carry a source identifier, so each package is
    /// matched back to the row that produced it by its catalog prefix.
    private func matchesSelectedSource(_ package: MarketplacePackage) -> Bool {
        guard let source = selectedSource else { return true }
        switch source.kind {
        case .localFolder, .gitRepository:
            return package.sourceID == source.id
        case .claudeMarketplace:
            return package.id.hasPrefix("claude:")
        case .openAIPluginDirectory:
            return package.id.hasPrefix("codex:")
        case .mcpRegistry:
            return package.id.hasPrefix("mcp-registry:")
        case .agentPlugins, .geminiExtensionGallery:
            return false
        }
    }

    /// A one-line inventory per source, so an empty component filter is
    /// explained by the catalog rather than looking like a failure.
    private func contentsSummary(for source: ToolingSource) -> String? {
        let packages = model.marketplacePackages.filter { package in
            switch source.kind {
            case .localFolder, .gitRepository: package.sourceID == source.id
            case .claudeMarketplace: package.id.hasPrefix("claude:")
            case .openAIPluginDirectory: package.id.hasPrefix("codex:")
            case .mcpRegistry: package.id.hasPrefix("mcp-registry:")
            case .agentPlugins, .geminiExtensionGallery: false
            }
        }
        guard !packages.isEmpty else { return nil }
        let counts: [(String, Int)] = [
            ("skill", packages.filter { $0.components.contains(.skill) }.count),
            ("plugin", packages.filter { $0.components.contains(.plugin) }.count),
            ("MCP server", packages.filter { $0.components.contains(.mcpServer) }.count),
        ]
        let parts = counts.filter { $0.1 > 0 }.map { "\($0.1) \($0.0)\($0.1 == 1 ? "" : "s")" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var visiblePackages: [MarketplacePackage] {
        Array(filteredPackages.prefix(displayLimit))
    }

    private var packageCountLabel: String {
        visiblePackages.count == filteredPackages.count
            ? "\(filteredPackages.count)"
            : "\(visiblePackages.count) of \(filteredPackages.count)"
    }

    private var showMoreLabel: String {
        let remaining = filteredPackages.count - visiblePackages.count
        return "Show \(min(Self.pageSize, remaining)) more"
    }

    private var sortedSources: [ToolingSource] {
        model.sources.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id.uuidString < $1.id.uuidString : nameOrder == .orderedAscending
        }
    }

    /// SwiftUI's macOS List is backed by NSTableView. Deferring selection until
    /// the current update completes avoids mutating its selection from inside a
    /// table delegate callback when filters or catalog results change.
    private func selectFirstPackageAfterListUpdate(ifNeeded: Bool) {
        guard ifNeeded else { return }
        let firstID = visiblePackages.first?.id
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
    let source: ToolingSource
    let symbol: String
    var contents: String?
    var selected = false
    var onSelect: (() -> Void)?
    @State private var isConfirmingRemoval = false

    var body: some View {
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
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(selected ? "Shows every source again" : "Shows only packages from this source")
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

private struct MarketplacePackageRow: View {
    let package: MarketplacePackage
    let selected: Bool

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
            if package.isInstalled {
                ClientMarks(present: Set(package.installedClients), size: 13)
            } else {
                Text("\(package.components.count) component\(package.components.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
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
