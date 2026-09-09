import Foundation

extension AppModel {
    /// A local preference change. Discovery and installation remain separate.
    @discardableResult
    public func setOnboardingClients(_ clients: Set<ClientKind>) -> Bool {
        guard ensureReadyForChange() else { return false }
        var candidate = currentSnapshot()
        candidate.preferences.enabledClients = clients
        guard commit(candidate) else { return false }
        onboardingCopyIssues = []
        onboardingCopyIssuePreviewID = nil
        projects = []
        hasDiscoveredProjects = false
        return true
    }

    public var onboardingCandidates: [OnboardingCandidate] { onboardingInventory.candidates }

    public var onboardingInventory: OnboardingInventory {
        let observations = visibleTargetObservations.sorted { $0.surface.displayName < $1.surface.displayName }
        let skills = visibleSkills
        let plugins = visiblePlugins
        let servers = visibleMCPServers
        let metadata = observations.reduce(into: [String: ObservedSkillMetadata]()) { result, observation in
            for (id, value) in observation.skillMetadata where result[id] == nil { result[id] = value }
        }
        let pluginClients = Dictionary(grouping: plugins, by: \.id).mapValues {
            Set($0.flatMap { onboardingClients(from: $0.clients, managed: false) })
        }
        let skillClients = Dictionary(grouping: skills, by: \.id).mapValues {
            Set($0.flatMap { onboardingClients(from: $0.clients, managed: $0.owned) })
        }
        let serverClients = Dictionary(grouping: servers, by: \.id).mapValues {
            Set($0.flatMap { onboardingClients(from: $0.clients, managed: $0.isManagedDefinition) })
        }
        var providers: [String: Set<String>] = [:]
        var relationships: [String: [String: Set<ClientKind>]] = [:]
        func register(_ provider: String, kind: ToolingItemKind, id: String, client: ClientKind) {
            let itemID = "\(kind.rawValue):\(id)"
            // Remember ownership even when the parent is missing from discovery;
            // an incomplete bundle must never become a standalone copy candidate.
            providers[itemID, default: []].insert(provider)
            let actualClients = kind == .skill ? skillClients[id] : serverClients[id]
            guard actualClients?.contains(client) == true, pluginClients[provider]?.contains(client) == true else { return }
            relationships[provider, default: [:]][itemID, default: []].insert(client)
        }
        for observation in observations {
            guard let client = observation.surface.client else { continue }
            for (id, skill) in observation.skillMetadata {
                if let provider = skill.providerPluginID { register(provider, kind: .skill, id: id, client: client) }
            }
            for (id, server) in observation.mcpMetadata where pluginClients[server.source] != nil {
                // Match the complete native identifier, never a display name,
                // path fragment, or marketplace suffix.
                register(server.source, kind: .mcpServer, id: id, client: client)
            }
            for (provider, plugin) in observation.pluginMetadata {
                for id in plugin.skillIDs {
                    let explicitProvider = observation.skillMetadata[id]?.providerPluginID
                    guard explicitProvider == nil || explicitProvider == provider else { continue }
                    register(provider, kind: .skill, id: id, client: client)
                }
                for id in plugin.mcpServerIDs {
                    let explicitProvider = observation.mcpMetadata[id]?.source
                    if let explicitProvider, pluginClients[explicitProvider] != nil, explicitProvider != provider { continue }
                    register(provider, kind: .mcpServer, id: id, client: client)
                }
            }
        }
        // Older snapshots may have the bundle contents only on Plugin. Use
        // this fallback only where no per-client ownership record contradicts it.
        for plugin in plugins {
            for id in plugin.skills {
                for client in pluginClients[plugin.id, default: []].intersection(skillClients[id, default: []]) {
                    let hasObservedOwnership = observations.contains {
                        $0.surface.client == client
                            && ($0.skillMetadata[id] != nil || $0.pluginMetadata[plugin.id] != nil)
                    }
                    // A standalone metadata record (nil provider) is evidence
                    // too. A bundle list merged from another client cannot
                    // override it or an observed empty plugin contents list.
                    guard !hasObservedOwnership else { continue }
                    register(plugin.id, kind: .skill, id: id, client: client)
                }
            }
        }
        var result = skills.map { skill in
            let source = metadata[skill.id]
            let owners = providers["skill:\(skill.id)", default: []]
            let disposition: OnboardingDisposition =
                !owners.isEmpty ? .nativePlugin : skill.owned ? .managed : source != nil ? .copyAvailable : .unavailable
            let guidance: String
            switch disposition {
            case .managed: guidance = "Already in your library. Keep its current app assignments."
            case .copyAvailable: guidance = "Track its current installation. Its source remains responsible for the original files."
            case .nativePlugin: guidance = "Included with its plugin. Files and updates stay together."
            default: guidance = "Track its current installation. Its source folder needs review before making a personal copy."
            }
            return OnboardingCandidate(
                itemID: skill.id, kind: .skill, name: skill.displayName, summary: skill.summary,
                disposition: disposition, clients: onboardingClients(from: skill.clients, managed: skill.owned), guidance: guidance,
                sourcePath: source?.path, providerPluginID: nil, providerPluginIDs: owners,
                repositoryBinding: skill.repositoryBinding
            )
        }
        result += plugins.map { plugin in
            OnboardingCandidate(
                itemID: plugin.id, kind: .plugin, name: plugin.name, summary: plugin.summary,
                disposition: .nativePlugin, clients: onboardingClients(from: plugin.clients, managed: false),
                guidance: "Keep this plugin and its included tools together.",
                sourcePath: nil, providerPluginID: nil
            )
        }
        result += servers.map { server in
            let owners = providers["mcpServer:\(server.id)", default: []]
            return OnboardingCandidate(
                itemID: server.id, kind: .mcpServer, name: server.name, summary: server.summary,
                disposition: !owners.isEmpty ? .nativePlugin : server.isManagedDefinition ? .managed : .nativeMCP,
                clients: onboardingClients(from: server.clients, managed: server.isManagedDefinition),
                guidance: !owners.isEmpty
                    ? "Included with its plugin. Its connection stays in the app."
                    : server.isManagedDefinition
                        ? "Keep your managed definition and its current app assignments."
                        : "Keep this connection in your setup. Credentials stay in the app.",
                sourcePath: nil, providerPluginID: nil, providerPluginIDs: owners
            )
        }
        result.sort {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return OnboardingInventory(candidates: result, dependencyClients: relationships)
    }

    /// Builds the configuration review without saving metadata or client files.
    public func previewOnboarding(_ selection: OnboardingSelection) -> OnboardingPreview? {
        guard ensureReadyForChange() else { return nil }
        return makeOnboardingPreview(selection, allowCompletedCopies: false)
    }

    /// A name edit must not silently refresh the user-reviewed inventory or
    /// replace its target contract with newly discovered assignments.
    public func renameOnboardingPreview(_ preview: OnboardingPreview, to name: String) -> OnboardingPreview? {
        guard ensureReadyForChange(), validateOnboardingPreview(preview, allowCompletedCopies: true) else { return nil }
        var selection = preview.selection
        selection.configurationName = name
        return makeOnboardingPreview(selection, allowCompletedCopies: true)
    }

    /// Uses the normal, fingerprint-bound operation review for full-folder copies.
    /// A rejected entry stops this wizard batch rather than quietly reducing it.
    @discardableResult
    public func planOnboardingSkillAdoption(_ preview: OnboardingPreview) -> Bool {
        onboardingCopyIssues = []
        onboardingCopyIssuePreviewID = preview.id
        lastError = nil
        guard ensureReadyForChange(), validateOnboardingPreview(preview, allowCompletedCopies: false) else { return false }
        guard !preview.copySkillIDs.isEmpty else { return true }
        planSkillAdoption(skillIDs: preview.copySkillIDs)
        guard let adoption = pendingSkillAdoption else {
            // The wizard presents structured issues inline, without also
            // opening the app-wide error alert for the same rejected batch.
            if !onboardingCopyIssues.isEmpty { lastError = nil }
            return false
        }
        guard adoption.rejections.isEmpty, Set(adoption.sourceSkillIDs.keys) == preview.copySkillIDs else {
            onboardingCopyIssues = adoption.rejections
            discardPendingPlan()
            if adoption.rejections.isEmpty {
                presentError("Some selected skills could not be prepared. Scan again and review your selection.")
            } else {
                lastError = nil
            }
            return false
        }
        return true
    }

    /// Explicitly skip only the rejected choices from the exact review that
    /// produced them. Never silently shrink an import or remove native files.
    public func skippingOnboardingCopyIssues(_ preview: OnboardingPreview) -> OnboardingPreview? {
        guard ensureReadyForChange(), onboardingCopyIssuePreviewID == preview.id,
            !onboardingCopyIssues.isEmpty,
            validateOnboardingPreview(preview, allowCompletedCopies: true)
        else { return nil }
        let skipped = Set(onboardingCopyIssues.map(\.id))
        guard skipped.isSubset(of: preview.copySkillIDs) else {
            presentError("The import review changed. Review your selected skills again.")
            return nil
        }
        var selection = preview.selection
        selection.copySkillIDs.subtract(skipped)
        // Keep the source-managed skills selected. Only the optional copies
        // failed; recording existing installations needs no file mutation.
        guard let updated = makeOnboardingPreview(selection, allowCompletedCopies: true) else { return nil }
        onboardingCopyIssues = []
        onboardingCopyIssuePreviewID = nil
        lastError = nil
        return updated
    }

    public func clearOnboardingCopyIssues() {
        onboardingCopyIssues = []
        onboardingCopyIssuePreviewID = nil
    }

    /// A content/ownership check can reject a prepared copy after its metadata
    /// passed. Return those exact choices to the wizard for explicit skipping;
    /// this does not change the scanner policy or authorize any operation.
    @discardableResult
    public func recordOnboardingBlockedCopies(_ review: OperationPlanSafetyReview, for preview: OnboardingPreview) -> Bool {
        guard let adoption = pendingSkillAdoption,
            adoption.plan.id == review.planID, pendingPlan?.id == review.planID,
            onboardingCopyIssuePreviewID == preview.id,
            review.hasBlockedSteps
        else { return false }
        var issues: [SkillAdoptionRejection] = []
        for blocked in review.blockedSteps {
            guard let step = adoption.plan.steps.first(where: { $0.id == blocked.stepID }),
                let skill = adoption.skills.first(where: {
                    step.sourcePath
                        == adoption.stagedLibraryURL.appending(path: $0.bundle, directoryHint: .isDirectory).path(percentEncoded: false)
                }),
                let originalID = adoption.sourceSkillIDs.keys.first(where: { adoption.sourceSkillIDs[$0] == skill.id }),
                preview.copySkillIDs.contains(originalID)
            else { return false }
            let notes = blocked.contentRisk?.coverageNotes.prefix(3).joined(separator: " ") ?? ""
            let reason = notes.isEmpty ? blocked.blockReason ?? "This copy needs another review." : notes
            issues.append(.init(id: originalID, displayName: skill.displayName, reason: reason))
        }
        onboardingCopyIssues = issues
        lastError = nil
        return true
    }

    /// Completes only after each requested copy actually entered the library.
    /// The configuration and its activity receipt are committed atomically.
    public func finishOnboarding(_ preview: OnboardingPreview) -> OnboardingCompletion? {
        guard ensureReadyForChange(), validateOnboardingPreview(preview, allowCompletedCopies: true) else { return nil }
        guard
            preview.copySkillIDs.allSatisfy({ id in
                let managedID = onboardingAdoptedSkillIDs[id] ?? id
                return skills.contains { $0.id == managedID && $0.owned }
            })
        else {
            presentError("Review and finish the selected skill copies before saving this setup.")
            return nil
        }
        let selected = preview.candidates
        func savedItem(_ item: ToolingItemReference) -> ToolingItemReference {
            guard item.kind == .skill, preview.copySkillIDs.contains(item.identifier),
                let managedID = onboardingAdoptedSkillIDs[item.identifier]
            else { return item }
            return .init(kind: .skill, identifier: managedID)
        }
        let savedBindings = preview.targetBindings.map {
            OnboardingTargetBinding(item: savedItem($0.item), client: $0.client, enabled: $0.enabled)
        }.sorted { $0.id < $1.id }
        let disabledItems = Set(
            selected.filter { item in
                let placements = preview.targetBindings.filter { $0.item == item.item }
                return !placements.isEmpty && placements.allSatisfy { $0.enabled == false }
            }.map(\.id))
        let profile = ToolingProfile(
            id: preview.configurationID,
            name: preview.selection.configurationName.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: "Your selected tools and their existing app assignments on this Mac.",
            checks: [
                ProfileCheck(
                    id: "onboarding", name: "Setup recorded",
                    detail: "Native plugins and MCP servers retain their own installers and credentials. Review client changes separately.",
                    state: .healthy
                )
            ],
            enabledPlugins: selected.filter { $0.kind == .plugin && !disabledItems.contains($0.id) }.map(\.itemID).sorted(),
            requiredMCPs: selected.filter { $0.kind == .mcpServer && !disabledItems.contains($0.id) }.map(\.itemID).sorted(),
            requiredSkills: selected.filter { $0.kind == .skill }.map { savedItem($0.item).identifier }.sorted(),
            targetBindings: savedBindings
        )
        var candidate = currentSnapshot()
        candidate.profiles.append(profile)
        candidate.activeProfileID = profile.id
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "\(profile.name) setup completed",
                detail:
                    "Recorded \(selected.count) selected tools and their existing app assignments. \(preview.copySkillIDs.count) skills copied to the managed library. No client configuration or account authorization changed.",
                date: .now, state: .healthy, affectedPaths: [store.databaseURL.path(percentEncoded: false)]
            ), at: 0
        )
        guard commit(candidate) else { return nil }
        return OnboardingCompletion(
            configurationID: profile.id, configurationName: profile.name, copiedSkillCount: preview.copySkillIDs.count,
            managedSkillCount: preview.managedSkillCount, trackedItemCount: preview.nativeItemCount
        )
    }

    /// Nil means a legacy configuration without an explicit target contract.
    /// An empty set deliberately skips unselected items in a captured setup.
    func onboardingSyncTargets(for skill: Skill) -> Set<ClientKind>? {
        guard let bindings = onboardingTargetBindings else { return nil }
        guard effectiveProfile(for: activeProfileID)?.requiredSkills.contains(skill.id) == true else { return [] }
        // A bundled child may be recorded in requiredSkills, but its plugin's
        // native installer owns delivery. Never create a standalone duplicate.
        let hasNativeOwner =
            visibleTargetObservations.contains { observation in
                observation.skillMetadata[skill.id]?.providerPluginID != nil
                    || observation.pluginMetadata.values.contains { $0.skillIDs.contains(skill.id) }
            } || visiblePlugins.contains { $0.skills.contains(skill.id) }
        guard !hasNativeOwner else { return [] }
        return Set(
            bindings.filter {
                $0.item.kind == .skill && $0.item.identifier == skill.id && $0.enabled == true
            }.map(\.client)
        ).intersection(enabledClients)
    }

    var onboardingTargetBindings: [OnboardingTargetBinding]? {
        var cursor = activeProfile
        var visited: Set<String> = []
        while let profile = cursor, visited.insert(profile.id).inserted {
            if let bindings = profile.targetBindings { return bindings }
            cursor = profile.inheritedFrom.flatMap { id in profiles.first { $0.id == id } }
        }
        return nil
    }

    private func makeOnboardingPreview(_ selection: OnboardingSelection, allowCompletedCopies: Bool) -> OnboardingPreview? {
        let fields: ValidatedConfigurationFields
        let configurationID: String
        do {
            fields = try ConfigurationValidator.validateProfile(
                name: selection.configurationName, summary: "", scope: .user, projectRoot: nil)
            configurationID = try WorkspaceLibrary.normalizedIdentifier(fields.name)
        } catch {
            presentError(error.localizedDescription)
            return nil
        }
        guard
            !profiles.contains(where: { $0.id == configurationID || $0.name.localizedCaseInsensitiveCompare(fields.name) == .orderedSame })
        else {
            presentError("A configuration already uses that name. Choose a distinct name for this setup.")
            return nil
        }
        let inventory = onboardingInventory
        let knownIDs = Set(inventory.candidates.map(\.id))
        guard selection.itemIDs.isSubset(of: knownIDs) else {
            presentError("Some selected tools are no longer in the inventory. Scan again and review your selection.")
            return nil
        }
        let expanded = inventory.expandedSelection(selection)
        let selected = inventory.selectedCandidates(for: selection)
        for item in selected where item.kind == .skill && selection.copySkillIDs.contains(item.itemID) {
            if let managedID = onboardingAdoptedSkillIDs[item.itemID], managedID != item.itemID,
                selected.contains(where: { $0.kind == .skill && $0.itemID == managedID && $0.disposition == .managed })
            {
                presentError("\(item.name) is already included as \(managedID). Select its managed copy once in the Skills step.")
                return nil
            }
        }
        guard selected.count <= ConfigurationValidator.maximumDesiredStateItems else {
            presentError("Choose at most \(ConfigurationValidator.maximumDesiredStateItems) tools for one configuration.")
            return nil
        }
        let copyable = Set(
            selected.filter {
                $0.canCopy || (allowCompletedCopies && $0.kind == .skill && $0.disposition == .managed && $0.providerPluginIDs.isEmpty)
            }.map(\.itemID))
        guard selection.copySkillIDs.isSubset(of: copyable) else {
            presentError("Only selected standalone skills with a discovered source can be copied. Keep bundled skills with their plugin.")
            return nil
        }
        // A review and its final validation must use current native preferences,
        // even when another app changed them while this app stayed foreground.
        // Parse each settings file once here; render-time lookups remain cached.
        let availability = SkillAvailabilitySnapshot.read(
            inputs: SkillAvailabilitySnapshot.inputs(
                skills: skills, observations: targetObservations, enabledClients: enabledClients, homeURL: homeURL))
        let bindings = selected.flatMap { item in
            inventory.clients(for: item, selection: expanded).map { client in
                let observations = visibleTargetObservations.filter { $0.surface.client == client }
                let enabled: Bool?
                switch item.kind {
                case .plugin: enabled = observations.compactMap { $0.pluginMetadata[item.itemID]?.enabled }.first
                case .mcpServer: enabled = observations.compactMap { $0.mcpMetadata[item.itemID]?.enabled }.first
                case .skill:
                    // A renamed managed copy has no native configuration of
                    // its own yet. Continue reading the original installation's
                    // availability instead of assuming the new path is enabled.
                    let hasCanonicalInstallation = observations.contains { $0.skillMetadata[item.itemID] != nil }
                    let originalID =
                        hasCanonicalInstallation
                        ? nil
                        : onboardingAdoptedSkillIDs.keys.sorted().first {
                            onboardingAdoptedSkillIDs[$0] == item.itemID
                        }
                    enabled = availability.values[SkillAvailabilityKey(skillID: originalID ?? item.itemID, client: client)]
                }
                let providers = item.providerPluginIDs.filter {
                    expanded.itemIDs.contains("plugin:\($0)") && inventory.dependencyClients[$0]?[item.id]?.contains(client) == true
                }
                let effectiveEnabled: Bool?
                if providers.isEmpty || enabled == false {
                    effectiveEnabled = enabled
                } else {
                    let parentStates: [Bool?] = providers.map { provider in
                        observations.compactMap { $0.pluginMetadata[provider]?.enabled }.first
                    }
                    if parentStates.contains(true) {
                        effectiveEnabled = enabled
                    } else if parentStates.allSatisfy({ $0 == false }) {
                        effectiveEnabled = false
                    } else {
                        effectiveEnabled = nil
                    }
                }
                return OnboardingTargetBinding(item: item.item, client: client, enabled: effectiveEnabled)
            }
        }.sorted { $0.id < $1.id }
        var warnings: [String] = []
        if !selection.copySkillIDs.isEmpty {
            warnings.append(
                "Personal copies are independently maintained. Updates from the original source will not change those copies."
            )
        }
        let managedOrCopied = Set(
            selected.filter {
                $0.kind == .skill && ($0.disposition == .managed || selection.copySkillIDs.contains($0.itemID))
            }.map(\.itemID))
        if bindings.contains(where: { $0.item.kind == .skill && managedOrCopied.contains($0.item.identifier) && $0.enabled == nil }) {
            warnings.append(
                "Some skill availability could not be checked. Those app assignments are recorded but excluded from sync. Use Library to review their installation separately."
            )
        }
        if selected.contains(where: { $0.canCopy && $0.clients.count > 1 && selection.copySkillIDs.contains($0.itemID) }) {
            warnings.append(
                "A skill found in multiple apps uses the source folder shown in this review. Other client copies are preserved.")
        }
        if selected.isEmpty {
            warnings.append("This creates an empty configuration. Add tools from Library or Discover whenever you are ready.")
        }
        return OnboardingPreview(
            id: UUID(), selection: selection, configurationID: configurationID,
            candidates: selected, targetBindings: bindings, warnings: warnings
        )
    }

    private func validateOnboardingPreview(_ preview: OnboardingPreview, allowCompletedCopies: Bool) -> Bool {
        guard let current = makeOnboardingPreview(preview.selection, allowCompletedCopies: allowCompletedCopies) else { return false }
        guard current.configurationID == preview.configurationID, current.targetBindings == preview.targetBindings else {
            presentError("App assignments changed after this review. Go back and review the setup again.")
            return false
        }
        let previous = Dictionary(uniqueKeysWithValues: preview.candidates.map { ($0.id, $0) })
        guard Set(current.candidates.map(\.id)) == Set(previous.keys) else {
            presentError("Plugin contents changed after this review. Go back and review the setup again.")
            return false
        }
        for item in current.candidates {
            guard let old = previous[item.id] else { return false }
            if allowCompletedCopies && preview.copySkillIDs.contains(item.itemID) && item.disposition == .managed { continue }
            guard item == old else {
                presentError("The inventory changed after this review. Go back and review the setup again.")
                return false
            }
        }
        return true
    }

    private func onboardingClients(from states: [ClientState], managed: Bool) -> [ClientKind] {
        // InventoryCompiler emits explicit absent rows for other apps. These
        // are display placeholders, never placement or installation intent.
        states.filter {
            $0.reportsLocalPresence || (managed && $0.isInstalled == nil && $0.state == .pending)
        }.map(\.client)
    }
}
