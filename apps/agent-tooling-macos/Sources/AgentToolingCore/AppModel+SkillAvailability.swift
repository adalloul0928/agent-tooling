import Foundation

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
        do {
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let destination = homeURL.appending(path: client == .claude ? ".claude/skills/\(skill.id)" : ".agents/skills/\(skill.id)")
            pendingPlan = OperationPlan(
                kind: .installSkill, title: "Add \(skill.displayName) to \(client.rawValue)",
                summary:
                    "Copy this standalone skill into this Mac's user-level skill folder. Its source remains maintained elsewhere; future source edits are not automatically synchronized.",
                targetSurfaces: [surface(for: client)], scope: .user,
                steps: [
                    OperationStep(
                        kind: .copyDirectory, title: "Install standalone skill",
                        detail: "Copy the reviewed source into \(client.rawValue).",
                        sourcePath: source.path, sourceFingerprint: try DirectoryFingerprint.sha256(of: source),
                        destinationPath: destination.path),
                    OperationStep(kind: .scan, title: "Check installation", detail: "Refresh local skill discovery.", isReversible: false),
                ])
        } catch { presentError(error.localizedDescription) }
    }

    public func installSkillPlugin(_ skillID: String, client: ClientKind) async {
        guard requireEnabledClients([client]) else { return }
        if skillMarketplacePackage(skillID, client: client) == nil { await refreshMarketplace() }
        if skillMarketplacePackage(skillID, client: client) == nil, client == .codex,
            let plugin = skillPluginID(skillID), OperationCommandPolicy.isSafePluginIdentifier(plugin),
            let marketplace = plugin.split(separator: "@", maxSplits: 1).last, plugin.contains("@")
        {
            do {
                let result = try await runner.run(
                    executable: "codex", arguments: ["plugin", "list", "--marketplace", String(marketplace), "--available", "--json"],
                    currentDirectory: nil)
                if result.status == 0 {
                    let packages = MarketplaceService().packagesFromCodexCatalogJSON(result.standardOutput)
                    marketplacePackages = MarketplaceService().deduplicatedPackages(marketplacePackages + packages)
                }
            } catch {
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
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw SkillAvailability.Failure.unsupported("The native settings path is a symlink. Manage availability in the client instead.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else {
            throw SkillAvailability.Failure.unsupported("The native settings file is too large to edit here.")
        }
        return data
    }

    public func isSkillEnabled(_ skillID: String, client: ClientKind) -> Bool? {
        _ = skillAvailabilityRevision
        do {
            let (url, key, id) = try availabilityInput(skillID, client: client)
            let data = try readAvailabilityFile(url)
            if key == "codex" { return try SkillAvailability.codex(String(decoding: data, as: UTF8.self), path: id, enabled: nil).0 }
            return try SkillAvailability.json(data, key: key, identifier: id, enabled: nil).0
        } catch { return nil }
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
            skillAvailabilityRevision += 1
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
