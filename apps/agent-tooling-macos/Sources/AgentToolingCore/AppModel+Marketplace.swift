import Foundation

/// Catalog sources and the packages they publish.
/// Split out of AppModel so the model file holds shared state rather than
/// every feature's behaviour.
extension AppModel {
    public static func builtInMarketplaceProviders() -> [any MarketplaceProvider] {
        guard let provider = try? OfficialMCPRegistryProvider() else { return [] }
        return [provider]
    }

    /// Retains the exact catalog record attached to an insights recommendation
    /// so Marketplace can review it without repeating the search. This only
    /// updates local catalog metadata; it never prepares or executes an install.
    @discardableResult
    public func retainMarketplaceRecommendation(
        _ package: MarketplacePackage,
        expectedPackageID: String
    ) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard package.id == expectedPackageID else {
            presentError("The marketplace recommendation no longer matches its catalog package.")
            return false
        }

        // Installation state is observed from client scans and native catalogs,
        // never trusted from a persisted recommendation report.
        var retained = package
        retained.isInstalled = false
        retained.nativeInstalls = retained.nativeInstalls.map { route in
            var route = route
            route.isInstalled = false
            return route
        }

        var candidate = currentSnapshot()
        candidate.marketplacePackages = marketplace.deduplicatedPackages(
            candidate.marketplacePackages + [retained]
        )
        return commit(candidate)
    }

    public func addMarketplaceSource(at url: URL) {
        guard ensureReadyForChange() else { return }
        do {
            let source = try library.importRepositorySource(at: url)
            var candidate = currentSnapshot()
            candidate.sources.removeAll { $0.location == source.location }
            candidate.sources.append(source)
            guard commit(candidate) else { return }
            Task { await refreshMarketplace() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func removeMarketplaceSource(id: UUID) {
        guard ensureReadyForChange() else { return }
        guard let source = sources.first(where: { $0.id == id }) else {
            lastError = "The selected marketplace source is no longer available."
            return
        }
        guard [.localFolder, .gitRepository].contains(source.kind) else {
            lastError = "Built-in catalog references cannot be removed."
            return
        }
        var candidate = currentSnapshot()
        candidate.sources.removeAll { $0.id == id }
        candidate.marketplacePackages.removeAll { $0.sourceID == id }
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration,
                title: "\(source.name) source removed",
                detail: "The source reference and its cached listings were removed. No files were deleted.",
                date: .now,
                state: .healthy,
                affectedPaths: [source.location]
            ),
            at: 0
        )
        _ = commit(candidate)
    }

    /// Refreshes imported portable packages, reviewed remote providers, and the
    /// machine-readable catalogs exposed by installed Claude Code and Codex
    /// CLIs. Hosted HTML listings are never scraped; Gemini's gallery stays a
    /// native source link until it exposes a documented API.
    public func refreshMarketplace() async {
        guard ensureReadyForChange() else { return }
        isRefreshingMarketplace = true
        defer { isRefreshingMarketplace = false }
        var candidate = currentSnapshot()
        var packages: [MarketplacePackage] = []
        var failures: [String] = []
        for index in candidate.sources.indices {
            guard [.localFolder, .gitRepository].contains(candidate.sources[index].kind) else { continue }
            do {
                let inspected = try marketplace.inspect(candidate.sources[index])
                packages.append(contentsOf: inspected)
                candidate.sources[index].lastRefreshedAt = .now
                candidate.sources[index].trustSummary =
                    inspected.isEmpty
                    ? "No portable packages found"
                    : "\(inspected.count) package\(inspected.count == 1 ? "" : "s") discovered; review before installing"
            } catch {
                let diagnostic = SensitiveValueRedactor.redact(error.localizedDescription)
                candidate.sources[index].trustSummary = diagnostic
                failures.append("\(candidate.sources[index].name): \(diagnostic)")
            }
        }
        for provider in marketplaceProviders {
            do {
                let page = try await provider.search(MarketplaceQuery(limit: 100))
                packages.append(contentsOf: page.packages)
                updateNativeSource(
                    .mcpRegistry,
                    detail:
                        "\(page.packages.count) server\(page.packages.count == 1 ? "" : "s") loaded from \(provider.displayName); package execution still requires review",
                    in: &candidate.sources
                )
            } catch {
                let diagnostic = SensitiveValueRedactor.redact(error.localizedDescription)
                updateNativeSource(.mcpRegistry, detail: "Unavailable: \(diagnostic)", in: &candidate.sources)
                failures.append("\(provider.displayName): \(diagnostic)")
            }
        }
        let native = await MarketplaceService.discoverNativeCatalogs(runner: runner)
        packages.append(contentsOf: native.packages)
        updateNativeSource(.claudeMarketplace, detail: native.notes[.claude], in: &candidate.sources)
        updateNativeSource(.openAIPluginDirectory, detail: native.notes[.codex], in: &candidate.sources)
        failures.append(
            contentsOf: native.notes.compactMap { client, note in
                note.localizedCaseInsensitiveContains("unavailable") ? "\(client.rawValue): \(note)" : nil
            })
        if let index = candidate.sources.firstIndex(where: { $0.kind == .geminiExtensionGallery }) {
            candidate.sources[index].lastRefreshedAt = .now
            candidate.sources[index].trustSummary =
                "Browse Gemini's native gallery or install a reviewed Git/local extension; installed extensions are observed by the scanner."
        }
        candidate.marketplacePackages = marketplace.deduplicatedPackages(packages)
        let detail =
            candidate.marketplacePackages.isEmpty
            ? "No portable or native catalog packages were found. Add a local folder or check the installed client CLIs."
            : "Found \(candidate.marketplacePackages.count) reviewable package\(candidate.marketplacePackages.count == 1 ? "" : "s"). \(native.notes.values.sorted().joined(separator: " · "))"
        let failureDetail = boundedActivityDetail(failures.isEmpty ? detail : "\(detail) Issues: \(failures.joined(separator: " · "))")
        candidate.activities.insert(
            ActivityReceipt(
                kind: .validation, title: "Marketplace sources refreshed", detail: failureDetail, date: .now,
                state: failures.isEmpty ? .healthy : .attention), at: 0)
        candidate.activities = Array(candidate.activities.prefix(200))
        _ = commit(candidate)
    }

    public func reviewMarketplacePackage(_ id: String) {
        guard ensureReadyForChange() else { return }
        guard let package = marketplacePackages.first(where: { $0.id == id }) else {
            lastError = "The selected marketplace package is no longer available."
            return
        }
        let componentText = package.components.map(\.displayName).sorted().joined(separator: ", ")
        pendingPlan = OperationPlan(
            kind: .importSource,
            title: "Review \(package.name)",
            summary:
                "\(package.trustSummary). This package contains: \(componentText.isEmpty ? "no recognized portable components" : componentText).",
            targetSurfaces: package.supportedClients.compactMap { client in surface(for: client) },
            steps: [
                OperationStep(
                    kind: .manual, title: "Inspect package source",
                    detail:
                        "Review \(package.location), its license (\(package.license ?? "not declared")), scripts, hooks, and target compatibility before installation.",
                    requiresUserAction: true),
                OperationStep(
                    kind: .manual, title: "Choose an installation route",
                    detail: package.nativeInstalls.isEmpty
                        ? "This local package has no verified automatic installer yet. Keep it as a reviewed source; do not copy it into a client manually without checking its target-specific instructions."
                        : "Choose one of the verified target-specific install buttons after reviewing the source.", requiresUserAction: true
                ),
            ],
            requiresConfirmation: false
        )
    }

    public func planMarketplaceInstall(packageID: String, client: ClientKind, remove: Bool = false) {
        guard ensureReadyForChange() else { return }
        guard let package = marketplacePackages.first(where: { $0.id == packageID }),
            let route = package.nativeInstalls.first(where: { $0.client == client })
        else {
            lastError = "This package does not expose a verified native installer for \(client.rawValue)."
            return
        }
        if !remove,
            managedPolicies.contains(where: { $0.blockedPluginIDs.contains(package.name) || $0.blockedPluginIDs.contains(package.id) })
        {
            lastError = "A managed policy blocks installation of \(package.name). Review the policy source in Settings."
            return
        }
        let arguments: [String]
        if remove {
            guard let removal = route.removalArguments else {
                lastError = "This package does not expose a verified native removal command."
                return
            }
            arguments = removal
        } else {
            arguments = route.arguments
        }
        let action = remove ? "Remove" : "Install"
        let routeDetail =
            remove
            ? "Remove this exact plugin identifier through \(client.rawValue)'s native plugin manager."
            : route.detail
        let operationKind: OperationKind =
            package.components == [.mcpServer] ? .configureMCP : .installPlugin
        pendingPlan = OperationPlan(
            kind: operationKind,
            title: "\(action) \(package.name) in \(client.rawValue)",
            summary: "\(routeDetail) Authentication, connector consent, and target reloads remain under \(client.rawValue).",
            targetSurfaces: [surface(for: client)],
            scope: route.scope,
            steps: [
                OperationStep(
                    kind: .command, title: "\(action) through \(client.rawValue)", detail: routeDetail, executable: route.executable,
                    arguments: arguments),
                OperationStep(
                    kind: .scan, title: "Re-scan \(client.rawValue)",
                    detail: "Confirm local installation state. This does not prove remote authentication or a live connector.",
                    isReversible: false),
            ]
        )
    }

    private func updateNativeSource(_ kind: SourceKind, detail: String?, in sources: inout [ToolingSource]) {
        guard let index = sources.firstIndex(where: { $0.kind == kind }) else { return }
        sources[index].lastRefreshedAt = .now
        if let detail { sources[index].trustSummary = detail }
    }
}
