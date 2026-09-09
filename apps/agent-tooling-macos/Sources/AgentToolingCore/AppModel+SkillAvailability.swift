import Foundation

struct DiscoveredSkillInstall: Sendable {
    let skillID: String
    let planID: UUID
    let sourcePath: String
    let fingerprint: String
    let stagingURL: URL

    var stagedSkillURL: URL { stagingURL.appending(path: "skill", directoryHint: .isDirectory) }
}

extension AppModel {
    public func skillPluginID(_ skillID: String, client: ClientKind? = nil) -> String? {
        visibleTargetObservations.filter { client == nil || $0.surface.client == client }
            .compactMap { $0.skillMetadata[skillID]?.providerPluginID }.sorted().first
    }

    public func skillMarketplacePackage(_ skillID: String, client: ClientKind) -> MarketplacePackage? {
        guard let pluginID = skillPluginID(skillID) else { return nil }
        return visibleMarketplacePackages.first { package in
            package.nativeInstalls.contains { route in
                route.client == client && route.arguments.contains(pluginID)
            }
        }
    }

    public func planDiscoveredSkillInstall(_ skillID: String, client: ClientKind) {
        guard requireEnabledClients([client]), ensureReadyForChange() else { return }
        guard skillPluginID(skillID) == nil,
            let skill = visibleSkills.first(where: { $0.id == skillID }),
            let path = observedSkillSourcePaths()[skillID],
            OperationCommandPolicy.isSafeMCPIdentifier(skill.id), [.claude, .codex].contains(client)
        else {
            presentError("This skill needs its native plugin installer or a reviewed custom copy.")
            return
        }
        var staging: URL?
        do {
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let destination = homeURL.appending(path: client == .claude ? ".claude/skills/\(skill.id)" : ".agents/skills/\(skill.id)")
            let fingerprint = try DirectoryFingerprint.sha256(of: source)
            if var binding = skill.repositoryBinding {
                guard binding.installedFingerprints[source.path] == fingerprint else {
                    throw SkillRepositoryError.changedInstallation
                }
                // Validate the eventual record before offering a copy that could not remain linked.
                binding.installedFingerprints[destination.path] = fingerprint
                try binding.validate()
            }
            let stageRoot = store.libraryURL.appending(path: ".discovered-install-\(UUID().uuidString)", directoryHint: .isDirectory)
            staging = stageRoot
            try SkillRepositoryService.createPrivateDirectory(stageRoot)
            let stagedSkill = stageRoot.appending(path: "skill", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: source, to: stagedSkill)
            guard try DirectoryFingerprint.sha256(of: stagedSkill) == fingerprint else {
                throw OperationEngineError.sourceChangedAfterReview
            }
            let plan = OperationPlan(
                kind: .installSkill, title: "Add \(skill.displayName) to \(client.rawValue)",
                summary:
                    skill.repositoryBinding == nil
                    ? "Copy this standalone skill into this Mac's user-level skill folder. Its source remains maintained elsewhere; future source edits are not automatically synchronized."
                    : "Add this standalone skill to this Mac's user-level skill folder. Both installations will follow the same GitHub repository, with future updates reviewed together.",
                targetSurfaces: [surface(for: client)], scope: .user,
                steps: [
                    OperationStep(
                        kind: .copyDirectory, title: "Install standalone skill",
                        detail: "Copy the reviewed source into \(client.rawValue).",
                        sourcePath: stagedSkill.path, sourceFingerprint: fingerprint,
                        destinationPath: destination.path),
                    OperationStep(kind: .scan, title: "Check installation", detail: "Refresh local skill discovery.", isReversible: false),
                ])
            pendingDiscoveredSkillInstall = DiscoveredSkillInstall(
                skillID: skill.id, planID: plan.id, sourcePath: source.path, fingerprint: fingerprint, stagingURL: stageRoot)
            pendingPlan = plan
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            presentError(error.localizedDescription)
        }
    }

    func completeDiscoveredSkillInstall(plan: OperationPlan, receipt: OperationReceipt) {
        guard let installation = pendingDiscoveredSkillInstall, installation.planID == plan.id,
            plan.kind == .installSkill, plan.scope == .user, receipt.planID == plan.id
        else { return }
        defer { discardDiscoveredSkillInstall() }
        let copies = plan.steps.filter { $0.kind == .copyDirectory }
        guard copies.count == 1, let copy = copies.first,
            copy.sourcePath == installation.stagedSkillURL.path, copy.sourceFingerprint == installation.fingerprint,
            let destinationPath = copy.destinationPath,
            receipt.results.contains(where: { $0.stepID == copy.id && $0.status == .succeeded }),
            let index = skills.firstIndex(where: { $0.id == installation.skillID && !$0.owned }),
            var binding = skills[index].repositoryBinding,
            binding.installedFingerprints[installation.sourcePath] == installation.fingerprint,
            skillPluginID(installation.skillID) == nil
        else { return }
        let expectedDestinations = [ClientKind.claude, .codex].filter { plan.targetSurfaces.contains(surface(for: $0)) }.map {
            homeURL.appending(path: $0 == .claude ? ".claude/skills/\(installation.skillID)" : ".agents/skills/\(installation.skillID)")
                .path
        }
        guard expectedDestinations.contains(destinationPath) else { return }
        // The engine verified this fingerprint before committing the successful copy.
        // Keep the reviewed baseline even if a later local edit changes the new installation.
        binding.installedFingerprints[destinationPath] = installation.fingerprint
        guard (try? binding.validate()) != nil else { return }
        skills[index].repositoryBinding = binding
    }

    func discardDiscoveredSkillInstall() {
        guard let installation = pendingDiscoveredSkillInstall else { return }
        try? FileManager.default.removeItem(at: installation.stagingURL)
        pendingDiscoveredSkillInstall = nil
    }

    public func installSkillPlugin(_ skillID: String, client: ClientKind) async {
        guard requireEnabledClients([client]), ensureReadyForChange() else { return }
        if skillMarketplacePackage(skillID, client: client) == nil {
            await refreshMarketplace()
            guard requireEnabledClients([client]), ensureReadyForChange() else { return }
        }
        if skillMarketplacePackage(skillID, client: client) == nil, client == .codex,
            let plugin = skillPluginID(skillID), OperationCommandPolicy.isSafePluginIdentifier(plugin),
            let marketplace = plugin.split(separator: "@", maxSplits: 1).last, plugin.contains("@")
        {
            isInstallingSkillPlugin = true
            do {
                let result = try await runner.run(
                    executable: "codex", arguments: ["plugin", "list", "--marketplace", String(marketplace), "--available", "--json"],
                    currentDirectory: nil)
                isInstallingSkillPlugin = false
                if result.status == 0 {
                    let packages = MarketplaceService().packagesFromCodexCatalogJSON(result.standardOutput)
                    marketplacePackages = MarketplaceService().deduplicatedPackages(marketplacePackages + packages)
                }
            } catch {
                isInstallingSkillPlugin = false
                presentError(error.localizedDescription)
                return
            }
        }
        guard let package = skillMarketplacePackage(skillID, client: client) else {
            presentError(
                "No verified \(client.rawValue) installer was found for this plugin. Add its marketplace in \(client.rawValue), refresh Marketplace, then try again."
            )
            return
        }
        if package.isInstalled {
            await runDoctor()
            return
        }
        guard ensureReadyForChange() else { return }
        planMarketplaceInstall(packageID: package.id, client: client)
    }

    private func availabilityInput(_ skillID: String, client: ClientKind) throws -> (URL, String, String) {
        guard let skill = visibleSkills.first(where: { $0.id == skillID }),
            skill.clients.contains(where: { $0.client == client && $0.reportsLocalPresence }),
            let metadata = visibleTargetObservations.filter({ $0.surface.client == client }).compactMap({ $0.skillMetadata[skillID] }).first
        else { throw SkillAvailability.Failure.unsupported("Check setup to locate this installed skill first.") }
        if client == .codex {
            return (
                homeURL.appending(path: ".codex/config.toml"), "codex", URL(fileURLWithPath: metadata.path).appending(path: "SKILL.md").path
            )
        }
        guard client == .claude else { throw SkillAvailability.Failure.unsupported("Skill toggles are supported for Claude and Codex.") }
        return (
            homeURL.appending(path: ".claude/settings.json"), metadata.providerPluginID == nil ? "skillOverrides" : "enabledPlugins",
            metadata.providerPluginID ?? skill.name
        )
    }

    private func readAvailabilityFile(_ url: URL) throws -> Data {
        try SkillAvailabilitySnapshot.readFile(url)
    }

    /// Unknown until native preferences have been refreshed. This lookup does
    /// not read or parse settings while SwiftUI is rendering an inspector.
    public func isSkillEnabled(_ skillID: String, client: ClientKind) -> Bool? {
        _ = skillAvailabilityRevision
        return skillAvailabilityCache.values[SkillAvailabilityKey(skillID: skillID, client: client)]
    }

    public func refreshSkillAvailability() async {
        skillAvailabilityGeneration += 1
        let generation = skillAvailabilityGeneration
        let inputs = SkillAvailabilitySnapshot.inputs(
            skills: skills, observations: targetObservations, enabledClients: enabledClients, homeURL: homeURL)
        skillAvailabilityRequestedInputs = inputs
        let refreshed = await Task.detached(priority: .utility) {
            SkillAvailabilitySnapshot.read(inputs: inputs)
        }.value
        guard generation == skillAvailabilityGeneration else { return }
        let changed = skillAvailabilityCache.values != refreshed.values
        skillAvailabilityCache = refreshed
        skillAvailabilityRequestedInputs = nil
        if changed { skillAvailabilityRevision += 1 }
    }

    func invalidateSkillAvailability() {
        let inputs = SkillAvailabilitySnapshot.inputs(
            skills: skills, observations: targetObservations, enabledClients: enabledClients, homeURL: homeURL)
        if inputs == skillAvailabilityCache.inputs {
            // A refresh for an intermediate inventory must not replace a
            // verified cache after the inventory returns to its original state.
            if let requested = skillAvailabilityRequestedInputs, requested != inputs {
                skillAvailabilityGeneration += 1
                skillAvailabilityRequestedInputs = nil
            }
            return
        }
        guard inputs != skillAvailabilityRequestedInputs else { return }
        skillAvailabilityGeneration += 1
        let generation = skillAvailabilityGeneration
        skillAvailabilityRequestedInputs = inputs
        let hadValues = !skillAvailabilityCache.values.isEmpty
        skillAvailabilityCache = SkillAvailabilitySnapshot()
        if hadValues { skillAvailabilityRevision += 1 }
        // Coalesce the synchronous assignments in a single persisted snapshot.
        Task { [weak self] in
            guard let self, generation == self.skillAvailabilityGeneration else { return }
            await self.refreshSkillAvailability()
        }
    }

    private func recordSkillAvailabilityChange(url: URL, setting: String, identifier: String, enabled: Bool) {
        // Invalidate any in-flight refresh before publishing the successful
        // write. A plugin toggle applies to every child sharing its identifier.
        skillAvailabilityGeneration += 1
        let inputs = SkillAvailabilitySnapshot.inputs(
            skills: skills, observations: targetObservations, enabledClients: enabledClients, homeURL: homeURL)
        for input in inputs where input.url == url && input.setting == setting && input.identifier == identifier {
            skillAvailabilityCache.values[input.key] = enabled
        }
        skillAvailabilityCache.inputs = inputs
        skillAvailabilityRequestedInputs = inputs
        skillAvailabilityRevision += 1
        let generation = skillAvailabilityGeneration
        Task { [weak self] in
            guard let self, generation == self.skillAvailabilityGeneration else { return }
            await self.refreshSkillAvailability()
        }
    }

    public func setSkillEnabled(_ skillID: String, client: ClientKind, enabled: Bool) {
        guard requireEnabledClients([client]), ensureReadyForChange() else { return }
        do {
            let (url, key, id) = try availabilityInput(skillID, client: client)
            let original = try readAvailabilityFile(url)
            let replacement: Data
            if key == "codex" {
                replacement = Data(
                    try SkillAvailability.codex(String(decoding: original, as: UTF8.self), path: id, enabled: enabled).1.utf8)
            } else {
                replacement = try SkillAvailability.json(original, key: key, identifier: id, enabled: enabled).1
            }
            let backup = store.cacheURL.appending(path: "skill-availability-backups/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.deletingLastPathComponent().path)
            try original.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard try readAvailabilityFile(url) == original else {
                throw SkillAvailability.Failure.unsupported("Settings changed during this update. Try again.")
            }
            let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
            try replacement.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            recordSkillAvailabilityChange(url: url, setting: key, identifier: id, enabled: enabled)
            activities.insert(
                ActivityReceipt(
                    kind: .configuration,
                    title: "\(enabled ? "Enabled" : "Disabled") \(key == "enabledPlugins" ? "plugin" : "skill") in \(client.rawValue)",
                    detail:
                        "Updated user-level availability for \(id). Restart the client to apply; project or organization settings may override this preference.",
                    date: .now, state: .healthy, affectedPaths: [url.path]), at: 0)
            try persistOrThrow()
        } catch { presentError(error.localizedDescription) }
    }
}
