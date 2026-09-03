import Foundation

/// Creating, editing, adopting and installing skills.
/// Split out of AppModel so the model file holds shared state rather than
/// every feature's behaviour.
extension AppModel {
    @discardableResult
    public func createSkill(from draft: SkillDraft) -> Skill? {
        guard ensureReadyForChange() else { return nil }
        let previousSnapshot = currentSnapshot()
        var createdResult: CreatedSkill?
        do {
            let created = try library.createSkill(from: draft)
            createdResult = created
            var skill = created.skill
            skill.validationCount = try library.validateSkill(skill)
            skills.removeAll { $0.id == skill.id }
            skills.insert(skill, at: 0)
            activities.insert(
                ActivityReceipt(
                    kind: .configuration,
                    title: "\(skill.displayName) created locally",
                    detail: "Portable package saved in Agent Tooling's managed library. Review installation before changing any client.",
                    date: .now,
                    state: .healthy,
                    affectedPaths: [
                        created.skillURL.path(percentEncoded: false),
                        created.packageURL.appending(path: "plugin.json").path(percentEncoded: false),
                    ]
                ),
                at: 0
            )
            prepareInstallPlanAfterSaving(skill: skill, draft: draft)
            try persistOrThrow()
            return skill
        } catch {
            let persistenceError = error
            pendingPlan = nil
            applyPersisted(previousSnapshot)
            if let createdResult {
                do {
                    try library.rollbackCreation(createdResult)
                    lastError = persistenceError.localizedDescription
                } catch {
                    lastError = "Saving the new skill failed, and its package could not be removed safely: \(error.localizedDescription)"
                }
            } else {
                lastError = persistenceError.localizedDescription
            }
            return nil
        }
    }

    @discardableResult
    public func saveCodexSkillDraftRequest(_ request: CodexSkillDraftRequest) -> Bool {
        do {
            try store.saveCodexSkillDraftRequest(request)
            return true
        } catch {
            presentError("The Codex skill request could not be saved: \(error.localizedDescription)")
            return false
        }
    }

    public func loadCodexSkillDraftRequest(id: UUID) -> CodexSkillDraftRequest? {
        do {
            guard let request = try store.loadCodexSkillDraftRequest(id: id) else {
                presentError("The requested Codex skill draft is no longer available.")
                return nil
            }
            return request
        } catch {
            presentError("The Codex skill request could not be opened: \(error.localizedDescription)")
            return nil
        }
    }

    public func generateCodexSkillDraft(_ request: CodexSkillDraftRequest) async -> CodexSkillDraftResult? {
        guard ensureReadyForChange() else { return nil }
        guard saveCodexSkillDraftRequest(request) else { return nil }
        isGeneratingSkill = true
        defer { isGeneratingSkill = false }
        do {
            return try await codexSkillDraftService.createDraft(request)
        } catch is CancellationError {
            return nil
        } catch {
            presentError(error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    public func adoptCodexSkillDraft(_ result: CodexSkillDraftResult) async -> Skill? {
        guard ensureReadyForChange() else { return nil }
        let previousSnapshot = currentSnapshot()
        var createdResult: CreatedSkill?
        do {
            let created = try library.adoptCodexDraft(result)
            createdResult = created
            var skill = created.skill
            skill.validationCount = try library.validateSkill(skill)
            skills.removeAll { $0.id == skill.id }
            skills.insert(skill, at: 0)
            activities.insert(
                ActivityReceipt(
                    kind: .configuration,
                    title: "\(skill.displayName) generated with Codex",
                    detail: "The reviewed portable package was saved locally. Client installation still requires plan approval.",
                    date: .now,
                    state: .healthy,
                    affectedPaths: [created.skillURL.path(percentEncoded: false)]
                ),
                at: 0
            )
            try persistOrThrow()
            try? store.deleteCodexSkillDraftRequest(id: result.request.id)
            try? await codexSkillDraftService.discardDraft(result)
            return skill
        } catch {
            let persistenceError = error
            pendingPlan = nil
            applyPersisted(previousSnapshot)
            if let createdResult {
                do {
                    try library.rollbackCreation(createdResult)
                    lastError = persistenceError.localizedDescription
                } catch {
                    lastError =
                        "Saving the generated skill failed, and its package could not be removed safely: \(error.localizedDescription)"
                }
            } else {
                lastError = persistenceError.localizedDescription
            }
            return nil
        }
    }

    public func discardCodexSkillDraft(_ result: CodexSkillDraftResult) async {
        do {
            try await codexSkillDraftService.discardDraft(result)
            try store.deleteCodexSkillDraftRequest(id: result.request.id)
        } catch {
            presentError("The generated draft could not be discarded safely: \(error.localizedDescription)")
        }
    }

    public func discardCodexSkillDraftRequest(id: UUID) async {
        var cleanupError: Error?
        do {
            try await codexSkillDraftService.discardRequest(id: id)
        } catch {
            cleanupError = error
        }
        do {
            try store.deleteCodexSkillDraftRequest(id: id)
        } catch {
            cleanupError = cleanupError ?? error
        }
        if let cleanupError {
            presentError("The pending Codex skill request could not be removed: \(cleanupError.localizedDescription)")
        }
    }

    /// A discovered skill can be adopted once a scan has recorded where its
    /// files are. Without that path the app would have to guess a location, so
    /// the row is not offered for adoption until the next setup check.
    public func canAdoptSkill(id: String) -> Bool {
        guard let skill = skills.first(where: { $0.id == id }), !skill.owned else { return false }
        return observedSkillSourcePath(for: id) != nil
    }

    /// Builds one reviewable plan that copies the selected discovered skills
    /// into the managed library. Nothing is written until the plan is approved,
    /// and the clients keep their own copies either way.
    public func planSkillAdoption(skillIDs: Set<String>) {
        guard ensureReadyForChange() else { return }
        let sources = observedSkillSourcePaths()
        let candidates =
            skills
            .filter { skillIDs.contains($0.id) }
            .map { SkillAdoptionCandidate(skill: $0, sourcePath: sources[$0.id]) }
        guard !candidates.isEmpty else {
            lastError = "The selected skills are no longer available. Check setup again, then try adopting them."
            return
        }
        do {
            let adoption = try library.adoptionPlan(
                for: candidates,
                reservedIdentifiers: Set(skills.map(\.id)).subtracting(skillIDs)
            )
            pendingSkillAdoption = adoption
            pendingPlan = adoption.plan
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Records the adopted packages after the approved plan wrote them. The
    /// managed-library checker runs against the committed copy so a skill only
    /// reports validation it actually passed.
    func applyAdoptedSkills(_ adoption: SkillAdoption) {
        var adopted: [Skill] = []
        var unchecked: [String] = []
        for var skill in adoption.skills {
            do {
                skill.validationCount = try library.validateSkill(skill)
            } catch {
                skill.validationCount = 0
                unchecked.append(skill.displayName)
            }
            adopted.append(skill)
        }
        let adoptedIDs = Set(adopted.map(\.id))
        skills.removeAll { adoptedIDs.contains($0.id) }
        skills.insert(contentsOf: adopted, at: 0)

        var detail =
            "The managed library now owns \(adopted.count) portable package\(adopted.count == 1 ? "" : "s"). Each client keeps its own copy; installing from Agent Tooling replaces it with the managed source."
        if !unchecked.isEmpty {
            detail +=
                " Not validated by the managed-library checker: \(unchecked.prefix(5).joined(separator: ", "))."
        }
        if !adoption.rejections.isEmpty {
            detail += " Skipped: \(adoption.rejections.prefix(5).map { "\($0.displayName) — \($0.reason)" }.joined(separator: " "))"
        }
        activities.insert(
            ActivityReceipt(
                kind: .configuration,
                title: adopted.count == 1
                    ? "\(adopted.first?.displayName ?? "Skill") adopted into the managed library"
                    : "\(adopted.count) skills adopted into the managed library",
                detail: boundedActivityDetail(detail),
                date: .now,
                state: unchecked.isEmpty && adoption.rejections.isEmpty ? .healthy : .pending,
                affectedPaths: adopted.prefix(20).map { library.skillURL(for: $0).path(percentEncoded: false) }
            ),
            at: 0
        )
    }

    @discardableResult
    public func updateSkill(id: String, from draft: SkillDraft) -> Skill? {
        guard ensureReadyForChange() else { return nil }
        guard let existing = skills.first(where: { $0.id == id }) else {
            lastError = "The selected skill is no longer available."
            return nil
        }
        let previousSnapshot = currentSnapshot()
        var updateResult: CreatedSkill?
        do {
            let result = try library.updateSkill(existing, from: draft)
            updateResult = result
            var updated = result.skill
            updated.validationCount = try library.validateSkill(updated)
            skills.removeAll { $0.id == id }
            skills.insert(updated, at: 0)
            activities.insert(
                ActivityReceipt(
                    kind: .configuration, title: "\(updated.displayName) updated",
                    detail: "The managed source changed locally. Review the install plan before updating any client.", date: .now,
                    state: .healthy, affectedPaths: [result.skillURL.path(percentEncoded: false)]), at: 0)
            prepareInstallPlanAfterSaving(skill: updated, draft: draft)
            try persistOrThrow()
            if let warning = library.commitUpdate(result) {
                lastError = warning
            }
            return updated
        } catch {
            let persistenceError = error
            pendingPlan = nil
            applyPersisted(previousSnapshot)
            if let updateResult {
                do {
                    if let warning = try library.rollbackUpdate(updateResult) {
                        lastError = "\(persistenceError.localizedDescription) \(warning)"
                    } else {
                        lastError = persistenceError.localizedDescription
                    }
                } catch {
                    lastError =
                        "Saving the skill update failed, and restoring its previous package also failed: \(error.localizedDescription)"
                }
            } else {
                lastError = persistenceError.localizedDescription
            }
            return nil
        }
    }

    func mergeSkills(existing: [Skill], observed: [Skill]) -> [Skill] {
        // Preserve only skills authored in the managed library. Vendor and
        // standalone discoveries are rebuilt on every scan so removals and
        // scope changes are reflected immediately.
        var values: [String: Skill] = [:]
        for skill in existing where skill.owned { values[skill.id] = skill }
        for item in observed {
            guard var local = values[item.id], local.owned else {
                values[item.id] = item
                continue
            }
            local.clients = item.clients
            local.files = item.files.isEmpty ? local.files : item.files
            values[item.id] = local
        }
        return values.values.sorted { $0.id < $1.id }
    }

    /// Uses only what the last setup check actually observed. Client folder
    /// layouts differ per plugin, so a guessed path could copy the wrong tree.
    /// Surfaces are read in a stable order so the same skill observed by two
    /// clients always adopts the same copy.
    func observedSkillSourcePaths() -> [String: String] {
        var paths: [String: String] = [:]
        for observation in targetObservations.sorted(by: { $0.surface.displayName < $1.surface.displayName }) {
            for (id, metadata) in observation.skillMetadata where paths[id] == nil {
                paths[id] = metadata.path
            }
        }
        return paths
    }

    private func observedSkillSourcePath(for skillID: String) -> String? {
        observedSkillSourcePaths()[skillID]
    }
}
