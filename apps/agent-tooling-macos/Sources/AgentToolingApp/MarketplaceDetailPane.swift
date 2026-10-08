import AgentToolingCore
import AppKit
import SwiftUI

extension MarketplaceView {

    @ViewBuilder
    var detailPane: some View {
        if let package = selectedPackage {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    HStack(alignment: .top, spacing: Space.lg) {
                        ToolIdentityIcon(packageID: package.id, fallback: marketplaceKind(for: package), size: 44)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(package.presentationName).font(AgentFont.pageTitle)
                            Text("\(package.originLabel): \(package.originName)").font(AgentFont.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProvenanceBadge(verdict: MarketplaceProvenanceClassifier.classify(package))
                    }
                    Text(package.summary).font(AgentFont.body).foregroundStyle(.secondary)

                    if let match = session.libraryMatch(for: package) {
                        alreadyInLibrary(match, for: package)
                    } else {
                        installRoutes(for: package)
                    }

                    DisclosureGroup("Source and compatibility") {
                        VStack(spacing: 0) {
                            LabeledValueRow(package.originLabel) { Text(package.originName).foregroundStyle(.secondary) }
                            Hairline()
                            if !package.isNativeCatalogListing, package.publisher != package.sourceName {
                                LabeledValueRow("Publisher") { Text(package.publisher).foregroundStyle(.secondary) }
                                Hairline()
                            }
                            LabeledValueRow("Provenance") {
                                let verdict = MarketplaceProvenanceClassifier.classify(package)
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    ProvenanceBadge(verdict: verdict)
                                    Text(verdict.evidence)
                                        .font(AgentFont.caption)
                                        .foregroundStyle(.secondary)
                                        .wrapsLines()
                                }
                            }
                            Hairline()
                            LabeledValueRow("Contents") {
                                Text(
                                    package.components.map(\.displayName).sorted().joined(separator: ", ").nilIfEmpty
                                        ?? "No recognized components"
                                )
                                .foregroundStyle(.secondary)
                            }
                            if let category = package.category {
                                Hairline()
                                LabeledValueRow("Category") {
                                    Text("\(category.capitalized) — filed by \(package.sourceName)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Hairline()
                            LabeledValueRow("Available for") {
                                Text(
                                    package.supportedClients.map(\.rawValue).sorted().joined(separator: ", ").nilIfEmpty
                                        ?? "No verified target"
                                )
                                .foregroundStyle(.secondary)
                            }
                            Hairline()
                            LabeledValueRow("Local state") {
                                Text(localState(for: package))
                                    .foregroundStyle(.secondary)
                            }
                            if let installs = package.installCount {
                                Hairline()
                                LabeledValueRow("Installs") {
                                    Text("\(installs.formatted()) — reported by \(package.sourceName)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let command = skillsShInstallCommand(for: package) {
                                Hairline()
                                LabeledValueRow("Install command") {
                                    VStack(alignment: .trailing, spacing: Space.sm) {
                                        Text(command)
                                            .font(AgentFont.mono)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                        Button("Copy Command", systemImage: "doc.on.doc") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(command, forType: .string)
                                        }
                                        .secondaryActionStyle()
                                        .controlSize(.small)
                                        .help(
                                            "Copies the Skills CLI command. It runs in your terminal, outside this app — review the skill's repository first."
                                        )
                                    }
                                }
                            }
                            if let ownership = package.ownership {
                                Hairline()
                                LabeledValueRow("Ownership") {
                                    Text(ownership.displayName).foregroundStyle(.secondary)
                                }
                            }
                            if let updateStatus = package.updateStatus {
                                Hairline()
                                LabeledValueRow("Updates") {
                                    Text(updateStatus.displayName).foregroundStyle(.secondary)
                                }
                            }
                            Hairline()
                            LabeledValueRow("Trust") { Text(package.trustSummary).foregroundStyle(.secondary) }
                            Hairline()
                            LabeledValueRow("License") { Text(package.license ?? "Not declared").foregroundStyle(.secondary) }
                            if let revision = package.provenance?.lock?.revision ?? package.revision {
                                Hairline()
                                LabeledValueRow("Locked revision") {
                                    Text(revision).font(AgentFont.mono).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            if let digest = package.provenance?.lock?.digest {
                                Hairline()
                                LabeledValueRow("Digest") {
                                    Text(digest).font(AgentFont.mono).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            if let credentials = package.requestedCredentialNames, !credentials.isEmpty {
                                Hairline()
                                LabeledValueRow("Configuration names") {
                                    RequestedCredentialNames(names: credentials)
                                }
                            }
                            if let conflicts = package.conflicts, !conflicts.isEmpty {
                                Hairline()
                                LabeledValueRow("Review notes") {
                                    Text(conflicts.map(\.summary).joined(separator: "\n"))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Hairline()
                            LabeledValueRow("Executable content") {
                                Label(
                                    package.hasExecutableContent ? "Present — inspect before install" : "None detected",
                                    systemImage: package.hasExecutableContent ? "exclamationmark.triangle" : "checkmark"
                                )
                                .foregroundStyle(package.hasExecutableContent ? Color.primary : Color.secondary)
                            }
                            Hairline()
                            LabeledValueRow("Package location") {
                                VStack(alignment: .trailing, spacing: Space.sm) {
                                    if let pluginName = MarketplaceIdentityNaming(package.location).pluginTitle {
                                        Text(pluginName).foregroundStyle(.secondary)
                                    } else {
                                        LocationText(path: package.location)
                                    }
                                    if canOpen(package.location) {
                                        Button("Open Source", systemImage: "arrow.up.right.square") {
                                            open(package.location)
                                        }
                                        .secondaryActionStyle()
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }

                    DisclosureGroup("Metadata checks") {
                        VStack(spacing: 0) {
                            PackageGradeRows(verdicts: MarketplaceGrading.grades(for: package, reachability: reachability(for: package)))
                            Hairline()
                            Text(
                                "Every grade above measures one thing this Mac can check without running anything. Hover a line to read exactly what it measured; a line with nothing to measure stays \"Not graded\" rather than passing."
                            )
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                            .wrapsLines()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.xl)
                            .padding(.vertical, Space.lg)
                        }
                    }

                    if package.components.contains(.mcpServer) {
                        DeclaredToolsCard(tools: package.tools, sourceName: package.sourceName)
                    }

                }
                .padding(Space.xxxl)
            }
        } else {
            EmptyStateView(
                symbol: "shippingbox", title: "Select a package",
                message: "Imported packages receive a component, trust, and compatibility review before any install action.")
        }
    }

    /// The one thing Discover can still act on: a listing that is already in
    /// the library goes to the row that holds it. Revealing is not installing.
    func alreadyInLibrary(_ match: WorkspaceMarketplaceSession.LibraryMatch, for package: MarketplacePackage) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            StatusBadge(state: .healthy, text: "Already in your library as \(match.displayName)")
            Button("Show in Library", systemImage: "books.vertical") {
                // A server lives on the Connections tab; everything else that
                // can be matched here is a package on the Plugins tab.
                navigation.openItem(
                    match.itemID, in: package.components.contains(.mcpServer) ? .mcpServers : .plugins)
            }
            .primaryActionStyle()
            Text("Where this package is installed is decided on the Apps screen, not here.")
                .font(AgentFont.micro)
                .foregroundStyle(.secondary)
                .wrapsLines()
        }
    }

    /// Install routes state the scope the client would use in its own words,
    /// and offer the one act this screen performs: adding the package to the
    /// library.
    ///
    /// Adding is not installing, and the control says so rather than leaving a
    /// person to find out afterwards. A row that lands here is a library item
    /// with no assignment and no destination; what a client is asked to run is
    /// decided on Apps, from a reviewed plan, and nowhere else.
    ///
    /// An MCP-server listing is added once, through the same managed-MCP intake
    /// the Paste sheet uses, so it is never four dead per-client buttons: a
    /// server is not a per-client plugin. A plugin listing keeps its per-client
    /// buttons, but only for the clients this Mac manages, and a client that
    /// cannot act on the listing says why in a line under the buttons rather
    /// than only in a tooltip nobody hovers.
    @ViewBuilder
    func installRoutes(for package: MarketplacePackage) -> some View {
        if let availability = session.mcpAvailability(for: package) {
            mcpServerRoutes(for: package, availability: availability)
        } else {
            pluginRoutes(for: package)
        }
    }

    /// One button for an MCP-server listing with a reviewed route, or one plain
    /// sentence when it needs credentials or a manual install. The sentence
    /// points at the command/Copy UI below only when the detail pane renders
    /// one for this listing; a credentials-only registry listing has none.
    @ViewBuilder
    func mcpServerRoutes(
        for package: MarketplacePackage, availability: ReviewedMarketplaceMCPServer.Availability
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Native install route")
                .font(AgentFont.captionSemibold).foregroundStyle(.secondary)
            switch availability {
            case .reviewed:
                Button {
                    Task { await session.adoptMCPServer(package) }
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "tray.and.arrow.down")
                        Text("Add to Library")
                    }
                }
                .primaryActionStyle()
                .disabled(!session.canAdopt || session.isAdopting)
                .help(session.canAdopt ? WorkspaceMarketplaceSession.adoptionNote : WorkspaceMarketplaceSession.readOnlyNote)
            case .needsManualSetup:
                // Only promise a command below when the detail pane actually
                // renders one for this listing; a credentials-only registry
                // listing has no command row, so the sentence ends earlier.
                Text(
                    WorkspaceMarketplaceSession.mcpManualSetupNote
                        + (skillsShInstallCommand(for: package) != nil
                            ? WorkspaceMarketplaceSession.mcpManualSetupCommandClause : "")
                )
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
            adoptionMessage(for: package)
        }
    }

    /// Per-client buttons for a plugin listing, one for each client this Mac
    /// manages. A client that cannot act on the listing shows its refusal as a
    /// line under the buttons in the command's own words, not only in a tooltip.
    @ViewBuilder
    func pluginRoutes(for package: MarketplacePackage) -> some View {
        let scopes = Set(package.nativeInstalls.map(\.scope))
        let routes = package.nativeInstalls.filter { availableClients.contains($0.client) }
        VStack(alignment: .leading, spacing: Space.md) {
            Text(routes.isEmpty ? "No native install route" : "Native install routes")
                .font(AgentFont.captionSemibold).foregroundStyle(.secondary)
            if routes.isEmpty {
                Text(
                    package.nativeInstalls.isEmpty
                        ? "This listing publishes no verified installer for any app on this Mac."
                        : "None of the apps this Mac manages can install this listing."
                )
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
            }
            if scopes.count == 1, let scope = scopes.first {
                InstallScopeNote(scope: scope)
            }
            FlowLayout(spacing: Space.md) {
                ForEach(routes) { route in
                    let refusal = session.adoptionRefusal(for: package, client: route.client)
                    Button {
                        Task { await session.adopt(package, client: route.client) }
                    } label: {
                        HStack(spacing: Space.sm) {
                            ClientBrandIcon(client: route.client, size: Size.brandMark)
                            Text("Add to Library for \(route.client.rawValue)")
                        }
                    }
                    .primaryActionStyle()
                    .disabled(refusal != nil || !session.canAdopt || session.isAdopting)
                    .help(
                        refusal ?? (session.canAdopt ? nil : WorkspaceMarketplaceSession.readOnlyNote)
                            ?? ("\(route.detail) Scope: \(route.scope.marketplaceInstallTitle). "
                                + WorkspaceMarketplaceSession.adoptionNote))
                }
            }
            // A client that refused says so in a readable line, so a disabled
            // button is never disabled without a reason a person can see.
            ForEach(routes) { route in
                if let refusal = session.adoptionRefusal(for: package, client: route.client) {
                    Text("\(route.client.rawValue): \(refusal)")
                        .font(AgentFont.micro)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
                // Adding to the library records the intent; the install itself
                // runs later through the client, which refuses a plugin from a
                // marketplace it has not added. Saying so here, with the exact
                // command, beats a failure at apply time.
                if let addCommand = session.marketplaceAddCommand(for: package, client: route.client) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("\(route.client.rawValue) has not added this marketplace yet, so it cannot install this plugin until you run:")
                            .font(AgentFont.micro)
                            .foregroundStyle(AgentTheme.warning)
                        Text(addCommand)
                            .font(AgentFont.mono)
                            .textSelection(.enabled)
                    }
                    .wrapsLines()
                }
            }
            if scopes.count > 1 {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(routes) { route in
                        HStack(spacing: Space.sm) {
                            ClientBrandIcon(client: route.client, size: Size.glyphSmall)
                            Text("\(route.client.rawValue) · \(route.scope.marketplaceInstallTitle)")
                                .font(AgentFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            adoptionMessage(for: package)
        }
    }

    /// What the last attempt on this listing said, in the command's own words,
    /// and otherwise what pressing the button would do. A message left by
    /// another package is never shown here.
    func adoptionMessage(for package: MarketplacePackage) -> some View {
        Text(
            session.adoption?.packageID == package.id
                ? (session.adoption?.message ?? WorkspaceMarketplaceSession.adoptionNote)
                : WorkspaceMarketplaceSession.adoptionNote
        )
        .font(AgentFont.micro)
        .foregroundStyle(.secondary)
        .wrapsLines()
    }

    /// What the last refresh could say about the catalog behind a package.
    /// Grading uses this instead of guessing that silence means healthy.
    func reachability(for package: MarketplacePackage) -> SourceReachability {
        guard let source = session.sources.first(where: { matches($0, package) }) else { return .unknown }
        if source.trustSummary.localizedCaseInsensitiveContains("unavailable") {
            return .unreachable(source.trustSummary)
        }
        guard let refreshedAt = source.lastRefreshedAt else { return .unknown }
        return .reachable(refreshedAt)
    }

    /// The second line of a row's verdict column. It follows the sort, so a
    /// person ordering by update date can see the dates they are ordering by.
    func rowDetail(for package: MarketplacePackage) -> String {
        if sortOrder == .recentlyUpdated {
            guard let update = package.lastUpdate else { return "No update date" }
            return "Updated \(update.date.formatted(date: .abbreviated, time: .omitted))"
        }
        if sortOrder == .installs {
            guard let installs = package.installCount else { return "No install count" }
            return "\(installs.formatted()) installs (\(package.sourceName))"
        }
        return "\(package.components.count) component\(package.components.count == 1 ? "" : "s")"
    }

    /// The Skills CLI command for a skills.sh listing, rebuilt from the listing
    /// URL the provider recorded: `skills.sh/<owner>/<repo>/<skill>`. Shown for
    /// copying only — nothing here executes it.
    func skillsShInstallCommand(for package: MarketplacePackage) -> String? {
        guard package.catalogKind == .skillsShRegistry, let url = URL(string: package.location) else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        return SkillsShRegistryProvider.installCommand(source: "\(parts[0])/\(parts[1])", skillID: parts[2])
    }

}

/// One line stating the scope an install will use, in Claude Code's own
/// vocabulary, so the word on screen matches the word in the client.
private struct InstallScopeNote: View {
    let scope: ToolingScope

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "person.crop.square")
                .font(AgentFont.captionMedium)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Scope: \(scope.marketplaceInstallTitle)")
                    .font(AgentFont.captionMedium)
                Text(scope.marketplaceInstallDetail)
                    .font(AgentFont.micro)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension MarketplacePackage {
    var presentationName: String { MarketplaceIdentityNaming.pluginName(name, identifier: id) }

    // The native ingestors use marketplaceName for `publisher`; it is catalog
    // provenance, not a claim about who authored or verified the plugin.
    var isNativeCatalogListing: Bool { id.hasPrefix("codex:") || id.hasPrefix("claude:") }
    var originLabel: String { isNativeCatalogListing ? "Marketplace" : "Catalog" }
    var originName: String {
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
