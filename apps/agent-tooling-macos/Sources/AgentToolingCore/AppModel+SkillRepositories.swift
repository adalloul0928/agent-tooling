import Foundation

extension AppModel {
    @discardableResult
    public func linkSkillRepository(skillID: String, repositoryURL: String, ref: String = "HEAD", subdirectory: String = "") async -> Bool {
        guard ensureReadyForChange() else { return false }
        isCheckingSkillRepository = true
        defer { isCheckingSkillRepository = false }
        do {
            let installations = try repositoryInstallations(skillID)
            let fingerprints = try await repositoryFingerprints(installations)
            guard Set(try repositoryInstallations(skillID).map(\.path)) == Set(installations.map(\.path)) else {
                throw SkillRepositoryError.changedInstallation
            }
            let binding = try SkillRepositoryBinding(
                repositoryURL: repositoryURL, ref: ref, subdirectory: subdirectory, installedFingerprints: fingerprints)
            guard let index = skills.firstIndex(where: { $0.id == skillID }) else { throw SkillRepositoryError.unsupportedInstallation }
            var snapshot = currentSnapshot()
            snapshot.skills[index].repositoryBinding = binding
            return commit(snapshot)
        } catch {
            presentError(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    public func unlinkSkillRepository(skillID: String) -> Bool {
        guard ensureReadyForChange(), let index = skills.firstIndex(where: { $0.id == skillID }) else { return false }
        var snapshot = currentSnapshot()
        snapshot.skills[index].repositoryBinding = nil
        return commit(snapshot)
    }

    public func skillRepositoryUpdateAvailability(_ skillID: String) -> UpdateAvailability {
        guard let binding = skills.first(where: { $0.id == skillID })?.repositoryBinding else {
            return .unknown(reason: "Link this standalone skill's GitHub repository to check its upstream source.")
        }
        guard targetObservations.contains(where: { $0.skillMetadata[skillID] != nil }) else {
            return .sourceMissing(
                reason:
                    "The linked skill was not found in the latest local scan. Its repository link is kept for when the installation returns."
            )
        }
        if let error = binding.lastCheckError { return .checkFailed(reason: error) }
        guard let latest = binding.lastCheckedRevision, let fingerprint = binding.lastCheckedFingerprint else {
            return .notChecked(reason: "The repository is linked. Its upstream files have not been checked yet.")
        }
        if !binding.installedFingerprints.isEmpty, binding.installedFingerprints.values.allSatisfy({ $0 == fingerprint }) {
            return .upToDate(revision: latest)
        }
        return .updateAvailable(installed: binding.installedRevision ?? "an unverified revision", available: latest)
    }

    @discardableResult
    public func checkSkillRepositoryUpdate(skillID: String) async -> Bool {
        guard ensureReadyForChange(), let index = skills.firstIndex(where: { $0.id == skillID }),
            var binding = skills[index].repositoryBinding
        else { return false }
        isCheckingSkillRepository = true
        defer { isCheckingSkillRepository = false }
        let service = SkillRepositoryService(cacheURL: store.cacheURL, runner: runner)
        do {
            let installations = try repositoryInstallations(skillID)
            try await verifyRepositoryBaseline(binding, installations: installations)
            let checkout = try await service.fetch(binding)
            defer { service.discard(checkout) }
            try await verifyRepositoryName(checkout.frontmatter.name, installations: installations)
            try await verifyRepositoryBaseline(binding, installations: installations)
            binding.lastCheckedRevision = checkout.revision
            binding.lastCheckedFingerprint = checkout.fingerprint
            binding.lastCheckedAt = .now
            binding.lastCheckError = nil
            if binding.installedFingerprints.values.allSatisfy({ $0 == checkout.fingerprint }) {
                binding.installedRevision = checkout.revision
            }
            var snapshot = currentSnapshot()
            snapshot.skills[index].repositoryBinding = binding
            return commit(snapshot)
        } catch {
            binding.lastCheckError = String(SensitiveValueRedactor.redact(error.localizedDescription).prefix(2_048))
            binding.lastCheckedAt = .now
            var snapshot = currentSnapshot()
            snapshot.skills[index].repositoryBinding = binding
            _ = commit(snapshot)
            presentError(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    public func planSkillRepositoryUpdate(skillID: String) async -> Bool {
        guard ensureReadyForChange(), let skill = skills.first(where: { $0.id == skillID }),
            let binding = skill.repositoryBinding
        else { return false }
        isCheckingSkillRepository = true
        defer { isCheckingSkillRepository = false }
        let service = SkillRepositoryService(cacheURL: store.cacheURL, runner: runner)
        var staging: URL?
        do {
            let installations = try repositoryInstallations(skillID)
            try await verifyRepositoryBaseline(binding, installations: installations)
            for installation in installations { try requireUpdatableRepositoryInstallation(installation.path, skill: skill) }
            let checkout = try await service.fetch(binding)
            defer { service.discard(checkout) }
            try await verifyRepositoryName(checkout.frontmatter.name, installations: installations)
            try await verifyRepositoryBaseline(binding, installations: installations)
            let stageRoot = store.libraryURL.appending(path: ".repository-update-\(UUID().uuidString)")
            staging = stageRoot
            try SkillRepositoryService.createPrivateDirectory(stageRoot)
            let stagedSkill = stageRoot.appending(path: "skill")
            let stagedFingerprint = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: checkout.skillURL, to: stagedSkill)
                return try DirectoryFingerprint.sha256(of: stagedSkill)
            }.value
            guard stagedFingerprint == checkout.fingerprint else { throw SkillRepositoryError.unsafeTree }
            var steps = installations.map { installation in
                OperationStep(
                    kind: .copyDirectory,
                    title: "Update \(skill.displayName) in \(installation.clients.map(\.rawValue).sorted().joined(separator: ", "))",
                    detail:
                        "Replace this existing installed copy with the reviewed GitHub revision. Its path and app availability settings stay in place.",
                    sourcePath: stagedSkill.path, sourceFingerprint: checkout.fingerprint,
                    destinationPath: installation.path, destinationFingerprint: binding.installedFingerprints[installation.path],
                    projectRootPath: skill.projectRoot, stopsOnFailure: true)
            }
            steps.append(
                OperationStep(
                    kind: .scan, title: "Check updated installations", detail: "Refresh the existing client records.", isReversible: false))
            let plan = OperationPlan(
                kind: .installSkill, title: "Update \(skill.displayName) from GitHub",
                summary:
                    "Review revision \(checkout.revision) from \(binding.repositoryURL). The existing standalone installations are updated after approval; native enabled or disabled settings are preserved.",
                targetSurfaces: Array(Set(installations.flatMap { $0.clients.map { surface(for: $0) } })).sorted {
                    $0.rawValue < $1.rawValue
                },
                scope: skill.projectRoot == nil ? .user : .project, steps: steps)
            pendingSkillRepositoryUpdate = SkillRepositoryUpdate(
                skillID: skillID, plan: plan, stagingURL: stageRoot, revision: checkout.revision, fingerprint: checkout.fingerprint)
            pendingPlan = plan
            return true
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            presentError(error.localizedDescription)
            return false
        }
    }

    func completeSkillRepositoryUpdate(plan: OperationPlan, receipt: OperationReceipt) {
        guard let update = pendingSkillRepositoryUpdate, update.plan.id == plan.id, receipt.planID == plan.id else { return }
        defer { discardSkillRepositoryUpdate() }
        guard let index = skills.firstIndex(where: { $0.id == update.skillID }), var binding = skills[index].repositoryBinding else {
            return
        }
        let copies = plan.steps.filter { $0.kind == .copyDirectory }
        var completed = 0
        for step in copies where receipt.results.contains(where: { $0.stepID == step.id && $0.status == .succeeded }) {
            guard let path = step.destinationPath else { continue }
            binding.installedFingerprints[path] = update.fingerprint
            completed += 1
        }
        binding.installedRevision = completed == copies.count ? update.revision : nil
        binding.lastCheckedRevision = update.revision
        binding.lastCheckedFingerprint = update.fingerprint
        binding.lastCheckedAt = .now
        binding.lastCheckError =
            completed == copies.count ? nil : "The update did not complete for every installed copy. Check its receipt before trying again."
        skills[index].repositoryBinding = binding
    }

    func discardSkillRepositoryUpdate() {
        guard let update = pendingSkillRepositoryUpdate else { return }
        try? FileManager.default.removeItem(at: update.stagingURL)
        pendingSkillRepositoryUpdate = nil
    }

    private struct RepositoryInstallation: Sendable {
        let path: String
        let clients: Set<ClientKind>
    }

    private func repositoryInstallations(_ skillID: String) throws -> [RepositoryInstallation] {
        guard let skill = skills.first(where: { $0.id == skillID }), !skill.owned else {
            throw SkillRepositoryError.unsupportedInstallation
        }
        var paths: [String: Set<ClientKind>] = [:]
        for observation in targetObservations {
            guard let metadata = observation.skillMetadata[skillID], let client = observation.surface.client else { continue }
            guard metadata.providerPluginID == nil else { throw SkillRepositoryError.unsupportedInstallation }
            var observedPath = metadata.path
            while observedPath.hasSuffix("/"), observedPath.count > 1 { observedPath.removeLast() }
            let url = URL(fileURLWithPath: observedPath).standardizedFileURL
            guard url.path == observedPath, url.path == url.resolvingSymlinksInPath().path,
                BoundedFileAccess.isRegularFile(url.appending(path: "SKILL.md"))
            else { throw SkillRepositoryError.unsupportedInstallation }
            paths[url.path, default: []].insert(client)
        }
        guard !paths.isEmpty else { throw SkillRepositoryError.unsupportedInstallation }
        return paths.sorted { $0.key < $1.key }.map { RepositoryInstallation(path: $0.key, clients: $0.value) }
    }

    private func repositoryFingerprints(_ installations: [RepositoryInstallation]) async throws -> [String: String] {
        try await Task.detached(priority: .userInitiated) {
            try Dictionary(
                uniqueKeysWithValues: installations.map {
                    ($0.path, try DirectoryFingerprint.sha256(of: URL(fileURLWithPath: $0.path)))
                })
        }.value
    }

    private func verifyRepositoryBaseline(_ binding: SkillRepositoryBinding, installations: [RepositoryInstallation]) async throws {
        guard Set(binding.installedFingerprints.keys) == Set(installations.map(\.path)) else {
            throw SkillRepositoryError.changedInstallation
        }
        guard try await repositoryFingerprints(installations) == binding.installedFingerprints else {
            throw SkillRepositoryError.changedInstallation
        }
    }

    private func verifyRepositoryName(_ name: String, installations: [RepositoryInstallation]) async throws {
        try await Task.detached(priority: .userInitiated) {
            for installation in installations {
                let markdown = try BoundedFileAccess.readUTF8(at: URL(fileURLWithPath: installation.path).appending(path: "SKILL.md"))
                guard try SkillFrontmatter.parse(markdown).name == name else { throw SkillRepositoryError.nameMismatch }
            }
        }.value
    }

    private func requireUpdatableRepositoryInstallation(_ path: String, skill: Skill) throws {
        let destination = URL(fileURLWithPath: path)
        let anchors = [homeURL] + (skill.projectRoot.map { [URL(fileURLWithPath: $0)] } ?? [])
        let roots = anchors.flatMap { root in
            [".claude/skills", ".agents/skills", ".codex/skills", ".gemini/skills"].map { root.appending(path: $0) }
        }
        guard roots.contains(where: { $0.standardizedFileURL.path == destination.deletingLastPathComponent().standardizedFileURL.path }),
            OperationCommandPolicy.isSafeMCPIdentifier(destination.lastPathComponent)
        else { throw SkillRepositoryError.unsupportedInstallation }
    }
}
