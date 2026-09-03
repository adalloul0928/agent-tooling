import Foundation

/// Collections and tags: reusable groupings a configuration can include,
/// and the filtering-only labels that sit beside them.
/// Split out of AppModel so the model file holds shared state rather than
/// every feature's behaviour.
extension AppModel {
    public func collection(id: String) -> ToolingCollection? {
        collections.first { $0.id == id }
    }

    /// Collections are shelves, so one item sitting on three of them is
    /// ordinary. Nothing here enforces a single owner.
    public func collections(containing item: ToolingItemReference) -> [ToolingCollection] {
        collections.filter { $0.contains(item) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func createCollection(name: String, summary: String = "") -> ToolingCollection? {
        guard ensureReadyForChange() else { return nil }
        let fields: ValidatedConfigurationFields
        let id: String
        do {
            fields = try ConfigurationValidator.validateProfile(name: name, summary: summary, scope: .user, projectRoot: nil)
            id = try WorkspaceLibrary.normalizedIdentifier(fields.name)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        guard !collections.contains(where: { $0.id == id }) else {
            lastError = "A collection with this identifier already exists. Choose a distinct name."
            return nil
        }
        let collection = ToolingCollection(id: id, name: fields.name, summary: fields.summary)
        var candidate = currentSnapshot()
        candidate.collections.append(collection)
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "\(collection.name) collection created",
                detail: "A collection is reusable material. Nothing is applied until a configuration includes it and you sync.",
                date: .now, state: .healthy), at: 0)
        return commit(candidate) ? collection : nil
    }

    @discardableResult
    public func updateCollection(id: String, name: String, summary: String) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        let fields: ValidatedConfigurationFields
        do {
            fields = try ConfigurationValidator.validateProfile(name: name, summary: summary, scope: .user, projectRoot: nil)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard
            !collections.contains(where: { candidate in
                candidate.id != id && candidate.name.localizedCaseInsensitiveCompare(fields.name) == .orderedSame
            })
        else {
            lastError = "Another collection already uses that name. Choose a distinct name."
            return false
        }
        var candidate = currentSnapshot()
        candidate.collections[index].name = fields.name
        candidate.collections[index].summary = fields.summary
        return commit(candidate)
    }

    /// Removing a shelf also removes it from every configuration that included
    /// it, so no configuration is left pointing at something that is gone.
    @discardableResult
    public func deleteCollection(id: String) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let collection = collections.first(where: { $0.id == id }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        var candidate = currentSnapshot()
        candidate.collections.removeAll { $0.id == id }
        for index in candidate.profiles.indices {
            candidate.profiles[index].includedCollections.removeAll { $0 == id }
        }
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "\(collection.name) collection removed",
                detail: "Desired state only. No skill, plugin, or MCP server was uninstalled.", date: .now, state: .healthy), at: 0)
        return commit(candidate)
    }

    @discardableResult
    public func setCollectionMembership(id: String, items: [ToolingItemReference]) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        guard items.count <= ConfigurationValidator.maximumDesiredStateItems else {
            lastError = "A collection can hold at most \(ConfigurationValidator.maximumDesiredStateItems) items."
            return false
        }
        var seen: Set<String> = []
        let deduplicated = items.filter { seen.insert($0.id).inserted }
        var candidate = currentSnapshot()
        candidate.collections[index].items = deduplicated.sorted { $0.id < $1.id }
        return commit(candidate)
    }

    @discardableResult
    public func setCollectionMembership(_ isMember: Bool, of id: String, for item: ToolingItemReference) -> Bool {
        guard let collection = collections.first(where: { $0.id == id }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        var items = collection.items
        if isMember {
            guard !items.contains(item) else { return true }
            items.append(item)
        } else {
            items.removeAll { $0 == item }
        }
        return setCollectionMembership(id: id, items: items)
    }

    /// Attaching and detaching is the whole interaction. It edits desired
    /// state; client files change only after a reviewed sync.
    @discardableResult
    public func setCollectionInclusion(_ isIncluded: Bool, of collectionID: String, inProfile profileID: String) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            lastError = "The selected configuration is no longer available."
            return false
        }
        guard profiles[index].scope != .managed else {
            lastError = "Managed configurations are read-only. Update the policy source and import it again."
            return false
        }
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        var included = Set(profiles[index].includedCollections)
        if isIncluded { included.insert(collectionID) } else { included.remove(collectionID) }
        guard included != Set(profiles[index].includedCollections) else { return true }
        let profileName = profiles[index].name
        var candidate = currentSnapshot()
        candidate.profiles[index].includedCollections = included.sorted()
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration,
                title: isIncluded
                    ? "\(collection.name) included in \(profileName)" : "\(collection.name) removed from \(profileName)",
                detail: "Desired state changed. Review and sync to apply it to Claude Code, Codex, or Gemini CLI.", date: .now,
                state: .healthy), at: 0)
        return commit(candidate)
    }

    public func isCollectionIncluded(_ collectionID: String, inProfile profileID: String) -> Bool {
        effectiveProfile(for: profileID)?.includedCollections.contains(collectionID) ?? false
    }

    /// How much of a shelf a configuration already covers directly. This is
    /// what lets the menu show a partial count instead of a checkmark when a
    /// configuration happens to require part of a collection without
    /// including the collection itself.
    public func collectionCoverage(_ collectionID: String, inProfile profileID: String) -> (covered: Int, total: Int) {
        guard let collection = collections.first(where: { $0.id == collectionID }),
            let profile = effectiveProfile(for: profileID)
        else { return (0, 0) }
        let plugins = Set(profile.enabledPlugins)
        let mcps = Set(profile.requiredMCPs)
        let skills = Set(profile.requiredSkills)
        let covered = collection.items.count { item in
            switch item.kind {
            case .skill: skills.contains(item.identifier)
            case .plugin: plugins.contains(item.identifier)
            case .mcpServer: mcps.contains(item.identifier)
            }
        }
        return (covered, collection.items.count)
    }

    public func itemsTagged(_ tag: String) -> [ToolingItemReference] {
        tagAssignments.filter { assignment in assignment.tags.contains { ToolingTag.matches($0, tag) } }.map(\.item)
    }

    /// Replaces the tag list on a selection. Tags are multi-valued and
    /// normalized on the way in, so one word typed three ways stays one tag.
    @discardableResult
    public func setTags(_ tags: [String], for items: [ToolingItemReference]) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard !items.isEmpty else { return true }
        let normalized = ToolingTag.normalizedList(tags)
        guard normalized.count <= ToolingTag.maximumTagsPerItem else {
            lastError = "An item can carry at most \(ToolingTag.maximumTagsPerItem) tags."
            return false
        }
        var candidate = currentSnapshot()
        for item in items {
            candidate.tagAssignments.removeAll { $0.item == item }
            if !normalized.isEmpty {
                candidate.tagAssignments.append(TagAssignment(item: item, tags: normalized))
            }
        }
        candidate.tagAssignments.sort { $0.id < $1.id }
        return commit(candidate)
    }

    /// Adds and removes tags across a selection without disturbing tags an
    /// item already carries that were not part of the edit.
    @discardableResult
    public func applyTagEdits(adding added: [String], removing removed: [String], to items: [ToolingItemReference]) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard !items.isEmpty, !(added.isEmpty && removed.isEmpty) else { return true }
        let toAdd = ToolingTag.normalizedList(added)
        let toRemove = ToolingTag.normalizedList(removed)
        var candidate = currentSnapshot()
        for item in items {
            let existing = candidate.tagAssignments.first { $0.item == item }?.tags ?? []
            let kept = existing.filter { tag in !toRemove.contains { ToolingTag.matches($0, tag) } }
            let merged = ToolingTag.normalizedList(kept + toAdd)
            guard merged.count <= ToolingTag.maximumTagsPerItem else {
                lastError = "An item can carry at most \(ToolingTag.maximumTagsPerItem) tags."
                return false
            }
            candidate.tagAssignments.removeAll { $0.item == item }
            if !merged.isEmpty {
                candidate.tagAssignments.append(TagAssignment(item: item, tags: merged))
            }
        }
        candidate.tagAssignments.sort { $0.id < $1.id }
        return commit(candidate)
    }

    /// Builds the shareable document. Redaction happens here rather than at the
    /// file boundary, so a Share Sheet payload carries the same guarantee.
    public func collectionExportDocument(id: String) throws -> CollectionExportDocument {
        guard let collection = collections.first(where: { $0.id == id }) else {
            throw CollectionExportError.unknownCollection
        }
        var tags: [ToolingItemReference: [String]] = [:]
        for assignment in tagAssignments { tags[assignment.item] = assignment.tags }
        return CollectionExporter.document(
            for: collection,
            skills: skills,
            plugins: plugins,
            mcpServers: mcpServers,
            tags: tags
        )
    }

    public func collectionExportData(id: String) throws -> Data {
        try CollectionExporter.encode(collectionExportDocument(id: id))
    }

    /// Writes the document and records a receipt naming the file, so an export
    /// is visible in Activity like every other side effect.
    @discardableResult
    public func exportCollection(id: String, to url: URL) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let collection = collections.first(where: { $0.id == id }) else {
            lastError = CollectionExportError.unknownCollection.localizedDescription
            return false
        }
        do {
            let data = try collectionExportData(id: id)
            try data.write(to: url, options: [.atomic])
            var candidate = currentSnapshot()
            candidate.activities.insert(
                ActivityReceipt(
                    kind: .publication, title: "\(collection.name) collection exported",
                    detail: CollectionExportDocument.securityNote, date: .now, state: .healthy,
                    affectedPaths: [url.path(percentEncoded: false)]), at: 0)
            return commit(candidate)
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
