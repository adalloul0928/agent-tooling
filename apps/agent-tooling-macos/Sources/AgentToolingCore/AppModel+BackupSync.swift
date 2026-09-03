import Foundation

/// Backup, encrypted folder sync, managed policy, and diagnostics export:
/// everything that moves state off this Mac or brings it back.
/// Split out of AppModel so the model file holds shared state rather than
/// every feature's behaviour.
extension AppModel {
    @discardableResult
    public func exportDiagnostics(to destination: URL, appVersion: String) -> Bool {
        do {
            let exporter = DiagnosticBundleExporter(homeURL: homeURL)
            let manifest = exporter.manifest(
                snapshot: currentSnapshot(),
                appVersion: appVersion,
                errors: lastError.map { [$0] } ?? []
            )
            try exporter.export(manifest, to: destination)
            return true
        } catch {
            presentError("The support bundle could not be exported: \(error.localizedDescription)")
            return false
        }
    }

    public func prepareBackup() {
        guard ensureReadyForChange() else { return }
        do {
            pendingPlan = try backupService.exportPlan(snapshot: currentSnapshot())
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func inspectBackup(at url: URL) {
        guard ensureReadyForChange() else { return }
        do {
            let preview = try backupService.importPreview(at: url, current: currentSnapshot().portableDesiredState())
            backupImportPreview = preview
            if preview.conflicts.isEmpty {
                pendingRestoreSnapshot = preview.snapshot
                pendingPlan = preview.plan
            } else {
                var candidate = currentSnapshot()
                candidate.activities.insert(
                    ActivityReceipt(
                        kind: .validation, title: "Backup conflicts need review",
                        detail:
                            "\(preview.conflicts.count) desired-state conflict\(preview.conflicts.count == 1 ? "" : "s") found. Review them before accepting this backup.",
                        date: .now, state: .attention, affectedPaths: [url.path(percentEncoded: false)]), at: 0)
                _ = commit(candidate)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func acceptInspectedBackup() {
        guard ensureReadyForChange() else { return }
        guard let preview = backupImportPreview else {
            lastError = "Choose and inspect a backup before accepting it."
            return
        }
        pendingRestoreSnapshot = preview.snapshot
        var plan = preview.plan
        if !preview.conflicts.isEmpty {
            plan.summary +=
                " This restore accepts \(preview.conflicts.count) reviewed desired-state conflict\(preview.conflicts.count == 1 ? "" : "s")."
        }
        pendingPlan = plan
    }

    public func prepareEncryptedSync(to folder: URL) {
        guard ensureReadyForChange() else { return }
        do {
            pendingPlan = try encryptedSyncService.exportPlan(snapshot: currentSnapshot(), destinationFolder: folder)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func inspectEncryptedSync(at archive: URL) {
        guard ensureReadyForChange() else { return }
        do {
            let preview = try encryptedSyncService.importPreview(at: archive)
            encryptedSyncImportPreview = preview
            pendingEncryptedSyncSnapshot = preview.snapshot
            pendingPlan = preview.plan
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func reviewInspectedEncryptedSyncRestore() {
        guard ensureReadyForChange() else { return }
        guard let preview = encryptedSyncImportPreview else {
            lastError = "Choose and inspect an encrypted archive before restoring it."
            return
        }
        pendingEncryptedSyncSnapshot = preview.snapshot
        pendingPlan = preview.plan
    }

    public func encryptedSyncRecoveryKey() -> String? {
        do { return try encryptedSyncService.recoveryKey() } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func importEncryptedSyncRecoveryKey(_ value: String) -> Bool {
        guard ensureReadyForChange() else { return false }
        do {
            try encryptedSyncService.importRecoveryKey(value.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func importManagedPolicy(at url: URL) {
        guard ensureReadyForChange() else { return }
        do {
            let policy = try policyService.load(at: url)
            let prefix = "policy-\(policy.id)-"
            let remapped = try policy.profiles.map { profile in
                let remappedID = prefix + profile.id
                guard (try? WorkspaceLibrary.normalizedIdentifier(remappedID)) == remappedID else {
                    throw WorkspaceSnapshotValidationError.inconsistent(
                        "Managed policy \(policy.id) produces a configuration identifier longer than the supported portable limit."
                    )
                }
                return ToolingProfile(
                    id: remappedID,
                    name: "\(policy.name) · \(profile.name)",
                    summary: profile.summary,
                    inheritedFrom: profile.inheritedFrom.map { prefix + $0 },
                    scope: .managed,
                    projectRoot: profile.projectRoot,
                    checks: profile.checks,
                    enabledPlugins: profile.enabledPlugins,
                    requiredMCPs: profile.requiredMCPs
                )
            }
            var candidate = currentSnapshot()
            candidate.managedPolicies.removeAll { $0.id == policy.id }
            candidate.managedPolicies.append(policy)
            candidate.profiles.removeAll { $0.id.hasPrefix(prefix) }
            candidate.profiles.append(contentsOf: remapped)
            candidate.activities.insert(
                ActivityReceipt(
                    kind: .configuration, title: "\(policy.name) policy imported",
                    detail:
                        "\(remapped.count) managed profile\(remapped.count == 1 ? "" : "s") and \(policy.blockedPluginIDs.count) blocked plugin rule\(policy.blockedPluginIDs.count == 1 ? "" : "s") are active locally. The manifest source was explicitly selected.",
                    date: .now, state: .healthy, affectedPaths: [policy.sourcePath]), at: 0)
            try WorkspaceSnapshotValidator.validate(candidate, mode: .localState)
            try store.saveWorkspaceSnapshot(candidate)
            applyPersisted(candidate)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
