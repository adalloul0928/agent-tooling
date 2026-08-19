import AgentToolingCore
import AppKit
import SwiftUI

struct MarketplaceView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedPackageID: String?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Marketplace") {
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
                        minWidth: 270, idealWidth: 320, maxWidth: 380, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                    packagePane.frame(
                        minWidth: 440, idealWidth: 540, maxWidth: 680, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                    detailPane.frame(
                        minWidth: 360, maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selectedPackageID == nil { selectedPackageID = filteredPackages.first?.id }
        }
        .onChange(of: filteredPackages.map(\.id)) { _, ids in
            if selectedPackageID == nil || !ids.contains(selectedPackageID ?? "") { selectedPackageID = ids.first }
        }
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Sources") {
                Text("\(model.sources.count) available")
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sortedSources) { source in
                        MarketplaceSourceRow(source: source, symbol: symbol(for: source.kind))
                        if source.id != sortedSources.last?.id { Divider().opacity(0.30) }
                    }
                }
                .padding(.horizontal, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Native catalogs stay native", systemImage: "checkmark.shield")
                    .font(.caption.weight(.semibold))
                Text(
                    "Imported packages are inspected locally. Claude and Codex remain install authorities for their catalogs; Gemini extensions stay in Gemini’s gallery and CLI flow."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(13)
        }
        .paneMaterial()
    }

    private var packagePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search packages", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search marketplace packages")
                Text("\(filteredPackages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            if filteredPackages.isEmpty {
                EmptyStateView(
                    symbol: query.isEmpty ? "shippingbox" : "shippingbox.and.arrow.backward",
                    title: query.isEmpty ? "No packages found" : "No matching packages",
                    message: query.isEmpty
                        ? "Refresh native catalogs or add a local folder, checked-out Git repository, or Agent Plugin package."
                        : "Try a different package name, publisher, or component.",
                    actionTitle: query.isEmpty ? "Add Source" : "Clear Search",
                    isActionEnabled: !query.isEmpty || !model.isInteractionLocked
                ) {
                    if query.isEmpty { chooseSource() } else { query = "" }
                }
            } else {
                List(filteredPackages, selection: $selectedPackageID) { package in
                    MarketplacePackageRow(package: package)
                        .tag(package.id)
                        .listRowBackground(selectedPackageID == package.id ? AgentTheme.blue.opacity(0.13) : Color.clear)
                        .accessibilityLabel(package.name)
                        .accessibilityValue(selectedPackageID == package.id ? "Selected" : "")
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
                        SymbolTile(symbol: "shippingbox", size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.name).font(.title2.weight(.semibold))
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
                            Divider()
                            LabeledValueRow("Trust") { Text(package.trustSummary).foregroundStyle(.secondary) }
                            Divider()
                            LabeledValueRow("License") { Text(package.license ?? "Not declared").foregroundStyle(.secondary) }
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
                                    Text(package.location).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
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
            query.isEmpty
                || [package.name, package.publisher, package.summary, package.components.map(\.displayName).joined(separator: " ")].joined(
                    separator: " "
                ).localizedCaseInsensitiveContains(query)
        }
        .sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }

    private var selectedPackage: MarketplacePackage? { model.marketplacePackages.first { $0.id == selectedPackageID } }

    private var sortedSources: [ToolingSource] {
        model.sources.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id.uuidString < $1.id.uuidString : nameOrder == .orderedAscending
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

private struct MarketplaceSourceRow: View {
    @Environment(AppModel.self) private var model
    let source: ToolingSource
    let symbol: String
    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolTile(symbol: symbol, size: 31)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(source.kind.displayName).font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 11) {
            SymbolTile(symbol: package.hasExecutableContent ? "shippingbox.fill" : "shippingbox", size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(package.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(package.supportedClients.map(\.rawValue).sorted().joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(
                    package.installedClients.isEmpty
                        ? "\(package.components.count) component\(package.components.count == 1 ? "" : "s")"
                        : "Installed in \(package.installedClients.map(\.rawValue).sorted().joined(separator: ", "))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
