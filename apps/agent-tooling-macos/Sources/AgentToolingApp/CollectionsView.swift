import AgentToolingCore
import AppKit
import SwiftUI

/// Collections are reusable material a Configuration is built from — a shelf,
/// not a contract. A Configuration stays the one resolved, activatable thing;
/// a Collection only becomes real when a Configuration includes it, and even
/// then nothing is written until a sync is reviewed.
///
/// Two surfaces live here, and they are deliberately not merged: collections
/// apply, tags filter.
struct CollectionsView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case collections = "Collections"
        case tags = "Tags"

        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .collections
    @State private var selectedID = ""
    @State private var showingNewCollection = false
    @State private var editingCollection: ToolingCollection?

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Collections", context: toolbarContext) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Collections or tags")

                if mode == .collections {
                    Button {
                        if let collection = selectedCollection { editingCollection = collection }
                    } label: {
                        Label("Edit collection…", systemImage: ToolingKind.collection.symbol)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isInteractionLocked || selectedCollection == nil)

                    Button {
                        showingNewCollection = true
                    } label: {
                        Label("New collection…", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInteractionLocked)
                }
            }

            switch mode {
            case .collections: collectionsSplit
            case .tags: TaggedInventoryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingNewCollection) {
            NewCollectionSheet { collection in selectedID = collection.id }
                .environment(model)
        }
        .sheet(item: $editingCollection) { collection in
            CollectionEditorSheet(collection: collection)
                .environment(model)
        }
        .onAppear {
            if !model.collections.contains(where: { $0.id == selectedID }) {
                selectedID = ""
            }
        }
        .onChange(of: model.collections.map(\.id)) { _, ids in
            if !ids.contains(selectedID) { selectedID = "" }
        }
    }

    private var toolbarContext: String {
        switch mode {
        case .collections:
            model.collections.isEmpty ? "Reusable shelves for configurations" : "\(model.collections.count) defined"
        case .tags:
            model.allTags.isEmpty ? "Tags filter; they never change what is installed" : "\(model.allTags.count) in use"
        }
    }

    private var collectionsSplit: some View {
        BrowserDetailLayout(selection: $selectedID, title: "Collection details") {
                collectionList
            } detail: {
                collectionDetail
            }
    }

    private var collectionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Collections").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(model.collections.count, format: .number).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(AgentTheme.controlBackground.opacity(0.45))

            if orderedCollections.isEmpty {
                EmptyStateView(
                    symbol: ToolingKind.collection.symbol,
                    title: "No collections yet",
                    message:
                        "A collection groups whole skills, plugins, and MCP servers so a configuration can reuse them. "
                        + "Items can sit on as many collections as you like.",
                    actionTitle: "New Collection",
                    isActionEnabled: !model.isInteractionLocked
                ) {
                    showingNewCollection = true
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(orderedCollections) { collection in
                            Button {
                                selectedID = collection.id
                            } label: {
                                CollectionListRow(
                                    collection: collection,
                                    includedCount: includedConfigurationCount(collection.id),
                                    selected: collection.id == selectedID
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(collection.name)
                            .accessibilityValue(collection.id == selectedID ? "Selected" : "")
                        }
                    }
                }
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var collectionDetail: some View {
        if let collection = selectedCollection {
            CollectionDetailView(collection: collection)
                .id(collection.id)
                .environment(model)
        } else {
            EmptyStateView(
                symbol: ToolingKind.collection.symbol,
                title: "Select a collection",
                message: "Collections hold reusable material. Including one in a configuration changes desired state, never a client file."
            )
        }
    }

    private var selectedCollection: ToolingCollection? { model.collections.first { $0.id == selectedID } }

    private var orderedCollections: [ToolingCollection] {
        model.collections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func includedConfigurationCount(_ id: String) -> Int {
        model.profiles.count { $0.includedCollections.contains(id) }
    }
}

private struct CollectionListRow: View {
    let collection: ToolingCollection
    let includedCount: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            KindTile(kind: .collection, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(itemSummary)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 52)
        .rowSelection(selected)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if !collection.summary.isEmpty { return collection.summary }
        return includedCount == 0
            ? "Not included by any configuration"
            : "Included by \(includedCount) configuration\(includedCount == 1 ? "" : "s")"
    }

    private var itemSummary: String {
        collection.itemCount == 1 ? "1 item" : "\(collection.itemCount) items"
    }
}

// MARK: - Detail

private struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    let collection: ToolingCollection
    @State private var shareAnchor = ShareAnchor()
    @State private var showingDeleteConfirmation = false
    @State private var editingMembership = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                inclusionCard
                itemsCard
                sharingCard
            }
            .padding(22)
        }
        .sheet(isPresented: $editingMembership) {
            CollectionEditorSheet(collection: collection, focusMembership: true)
                .environment(model)
        }
        .confirmationDialog(
            "Remove “\(collection.name)”?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Collection", role: .destructive) {
                model.deleteCollection(id: collection.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The collection is removed from every configuration that includes it. "
                    + "No skill, plugin, or MCP server is uninstalled."
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            KindTile(kind: .collection, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.name).font(.title3.weight(.semibold))
                Text(collection.summary.isEmpty ? "Reusable material for configurations." : collection.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editingMembership = true
            } label: {
                Label("Edit membership…", systemImage: "checklist")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isInteractionLocked)
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Remove", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(model.isInteractionLocked)
            .help("Remove this collection")
        }
    }

    /// Rule of the model, stated on screen: there is no globally active
    /// collection. Being active belongs to a configuration, so attaching and
    /// detaching here is the whole interaction.
    private var inclusionCard: some View {
        GroupBox("Included by configurations") {
            VStack(alignment: .leading, spacing: 0) {
                SectionCaption(
                    text: "Including a collection changes desired state only. It never writes to Claude Code, Codex, or Gemini CLI "
                        + "on its own — review a sync to apply it."
                )
                .padding(.horizontal, 14)
                .padding(.top, 12)

                if model.profiles.isEmpty {
                    Text("Create a configuration first; a collection is only applied through one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(orderedProfiles) { profile in
                        Divider()
                        InclusionRow(profile: profile, collection: collection)
                            .environment(model)
                    }
                }
            }
        }
    }

    private var itemsCard: some View {
        GroupBox("Items") {
            if collection.items.isEmpty {
                Text("This collection is empty. Add whole skills, plugins, or MCP servers to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(ToolingItemKind.allCases) { kind in
                        let items = resolvedItems.filter { $0.kind == kind }
                        if !items.isEmpty {
                            SectionCaption(text: kind.pluralDisplayName)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                            ForEach(items) { item in
                                CollectionItemRow(item: item, homeCollectionID: collection.id)
                                    .environment(model)
                                if item.id != items.last?.id { Divider() }
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var sharingCard: some View {
        GroupBox("Share") {
            VStack(alignment: .leading, spacing: 12) {
                // The single most common misunderstanding about a shared group
                // is that it stays linked. Say otherwise, plainly, up front.
                Label(
                    "Export writes a one-time copy. The file is a snapshot, not a live link — later edits here never reach anyone "
                        + "you shared it with.",
                    systemImage: "doc.badge.arrow.up"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Label(CollectionExportDocument.securityNote, systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        export()
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isInteractionLocked)

                    Button {
                        share()
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isInteractionLocked)
                    .overlay(alignment: .bottom) {
                        ShareAnchorView(anchor: shareAnchor).frame(width: 1, height: 1)
                    }
                    Spacer()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var orderedProfiles: [ToolingProfile] {
        model.profiles.sorted { lhs, rhs in
            if lhs.id == model.activeProfileID { return true }
            if rhs.id == model.activeProfileID { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var resolvedItems: [InventoryItem] {
        collection.items.filter(model.isItemVisible).map { model.inventoryItem(for: $0) }
    }

    private func export() {
        guard
            let url = CollectionFileExport.chooseDestination(
                suggestedName: CollectionExporter.suggestedFileName(for: collection))
        else { return }
        model.exportCollection(id: collection.id, to: url)
    }

    private func share() {
        do {
            let data = try model.collectionExportData(id: collection.id)
            let url = try CollectionFileExport.stageForSharing(
                named: CollectionExporter.suggestedFileName(for: collection), data: data)
            shareAnchor.present([url])
        } catch {
            model.presentError(error.localizedDescription)
        }
    }
}

private struct InclusionRow: View {
    @Environment(AppModel.self) private var model
    let profile: ToolingProfile
    let collection: ToolingCollection

    var body: some View {
        HStack(spacing: 11) {
            KindTile(kind: .profile, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.callout)
                    if profile.id == model.activeProfileID {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AgentTheme.blue)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Capsule().fill(AgentTheme.blue.opacity(0.12)))
                    }
                }
                if let detail = coverageDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Include", isOn: inclusionBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(model.isInteractionLocked || profile.scope == .managed)
                .accessibilityLabel("Include \(collection.name) in \(profile.name)")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }

    private var inclusionBinding: Binding<Bool> {
        Binding(
            get: { profile.includedCollections.contains(collection.id) },
            set: { model.setCollectionInclusion($0, of: collection.id, inProfile: profile.id) }
        )
    }

    /// Inherited inclusion and partial overlap both matter here: a
    /// configuration can already require part of a shelf without including it.
    private var coverageDetail: String? {
        if profile.scope == .managed { return "Managed by policy; read-only." }
        if profile.includedCollections.contains(collection.id) { return nil }
        if model.isCollectionIncluded(collection.id, inProfile: profile.id) {
            return "Included through the configuration it inherits from."
        }
        let coverage = model.collectionCoverage(collection.id, inProfile: profile.id)
        guard coverage.covered > 0, coverage.total > 0 else { return nil }
        return "Already requires \(coverage.covered) of \(coverage.total) items directly."
    }
}

private struct CollectionItemRow: View {
    @Environment(AppModel.self) private var model
    let item: InventoryItem
    let homeCollectionID: String

    var body: some View {
        HStack(spacing: 11) {
            KindTile(kind: ToolingKind(item.kind), size: 22, ghost: item.isMissing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                let tags = model.tags(for: item.reference)
                let others = otherCollectionNames
                if !tags.isEmpty || !others.isEmpty {
                    HStack(spacing: 6) {
                        CollectionPills(names: others)
                        TagPills(tags: tags)
                    }
                }
            }
            Spacer(minLength: 12)
            Button {
                model.setCollectionMembership(false, of: homeCollectionID, for: item.reference)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isInteractionLocked)
            .help("Remove from this collection")
            .accessibilityLabel("Remove \(item.name) from this collection")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
    }

    /// Overlap made visible: the other shelves this item also sits on.
    private var otherCollectionNames: [String] {
        model.collections(containing: item.reference)
            .filter { $0.id != homeCollectionID }
            .map(\.name)
    }
}

// MARK: - Editors

private struct NewCollectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let onCreated: (ToolingCollection) -> Void
    @State private var name = ""
    @State private var summary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New collection").font(.title2.weight(.semibold))
                Text(
                    "A collection is reusable material, not a contract. Items can belong to as many collections as you like, "
                        + "and nothing is applied until a configuration includes it."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Form {
                TextField("Name", text: $name)
                    .accessibilityLabel("Collection name")
                TextField("Summary", text: $summary)
                    .accessibilityLabel("Collection summary")
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create Collection") {
                    if let collection = model.createCollection(name: name, summary: summary) {
                        onCreated(collection)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil || model.isInteractionLocked)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var validationMessage: String? {
        do {
            _ = try ConfigurationValidator.validateProfile(name: name, summary: summary, scope: .user, projectRoot: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Identity and membership in one sheet. Membership is a plain list of
/// toggles over whole skills, plugins, and MCP servers: grouping stops at the
/// package boundary, never the individual tools inside a server.
private struct CollectionEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let collection: ToolingCollection
    var focusMembership = false
    @State private var name: String
    @State private var summary: String
    @State private var members: Set<ToolingItemReference>
    @State private var search = ""

    init(collection: ToolingCollection, focusMembership: Bool = false) {
        self.collection = collection
        self.focusMembership = focusMembership
        _name = State(initialValue: collection.name)
        _summary = State(initialValue: collection.summary)
        _members = State(initialValue: Set(collection.items))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                KindTile(kind: .collection, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit collection").font(.title3.weight(.semibold))
                    Text("Membership is desired state. Saving here changes no client configuration.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()

            Form {
                if !focusMembership {
                    Section("Identity") {
                        TextField("Name", text: $name)
                            .accessibilityLabel("Collection name")
                        TextField("Summary", text: $summary, axis: .vertical)
                            .accessibilityLabel("Collection summary")
                    }
                }
                Section {
                    TextField("Filter items", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filter items")
                }
                ForEach(ToolingItemKind.allCases) { kind in
                    Section(kind.pluralDisplayName) {
                        let items = candidates(for: kind)
                        if items.isEmpty {
                            Text("No \(kind.pluralDisplayName.lowercased()) match.").foregroundStyle(.secondary)
                        } else {
                            ForEach(items) { item in
                                Toggle(isOn: membershipBinding(item.reference)) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name)
                                        let others = model.collections(containing: item.reference)
                                            .filter { $0.id != collection.id }
                                            .map(\.name)
                                        if !others.isEmpty {
                                            Text("Also in \(others.formatted(.list(type: .and)))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .accessibilityLabel("Include \(item.name) in \(collection.name)")
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(memberSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Save Changes") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isInteractionLocked)
            }
            .padding(16)
        }
        .frame(width: 720, height: 650)
        .background(AgentTheme.contentBackground)
    }

    private var memberSummary: String {
        members.isEmpty ? "No items selected" : "\(members.count) item\(members.count == 1 ? "" : "s") selected"
    }

    private func save() {
        if !focusMembership, !model.updateCollection(id: collection.id, name: name, summary: summary) { return }
        guard model.setCollectionMembership(id: collection.id, items: Array(members)) else { return }
        dismiss()
    }

    private func candidates(for kind: ToolingItemKind) -> [InventoryItem] {
        model.inventoryItems(of: kind).filter { item in
            search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
                || item.reference.identifier.localizedCaseInsensitiveContains(search)
        }
    }

    private func membershipBinding(_ reference: ToolingItemReference) -> Binding<Bool> {
        Binding(
            get: { members.contains(reference) },
            set: { included in
                if included { members.insert(reference) } else { members.remove(reference) }
            }
        )
    }
}

// MARK: - Tags

/// Tags filter. They are multi-valued, bulk-editable, and never change what is
/// installed; the Untagged pill keeps the unsorted pile one click away.
private struct TaggedInventoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTags: Set<String> = []
    @State private var untaggedOnly = false
    @State private var kindFilter: ToolingItemKind?
    @State private var selection: Set<String> = []
    @State private var editingTags = false
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filteredItems.isEmpty {
                EmptyStateView(
                    symbol: "tag",
                    title: emptyTitle,
                    message: "Tags are labels for finding things. Select rows and use Edit Tags to apply them in bulk."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredItems) { item in
                            Button {
                                toggleSelection(item.id)
                            } label: {
                                TaggedItemRow(
                                    item: item,
                                    tags: model.tags(for: item.reference),
                                    collections: model.collections(containing: item.reference).map(\.name),
                                    selected: selection.contains(item.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name)
                            .accessibilityValue(selection.contains(item.id) ? "Selected" : "")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $editingTags) {
            TagEditorSheet(items: selectedReferences)
                .environment(model)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Kind", selection: $kindFilter) {
                    Text("All").tag(ToolingItemKind?.none)
                    ForEach(ToolingItemKind.allCases) { kind in
                        Text(kind.pluralDisplayName).tag(ToolingItemKind?.some(kind))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
                .accessibilityLabel("Filter by kind")

                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Search items")

                Spacer()

                Text(selectionSummary).font(.caption).foregroundStyle(.secondary)
                Button {
                    editingTags = true
                } label: {
                    Label("Edit Tags…", systemImage: "tag")
                }
                .buttonStyle(.bordered)
                .disabled(selection.isEmpty || model.isInteractionLocked)
            }

            TagFilterBar(
                tags: model.allTags,
                untaggedCount: untaggedCount,
                selection: $selectedTags,
                untaggedOnly: $untaggedOnly
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var emptyTitle: String {
        untaggedOnly ? "Everything here is tagged" : selectedTags.isEmpty ? "Nothing to show" : "No items carry those tags"
    }

    private var selectionSummary: String {
        selection.isEmpty ? "Select rows to tag them" : "\(selection.count) selected"
    }

    private var allItems: [InventoryItem] {
        ToolingItemKind.allCases.flatMap { model.inventoryItems(of: $0) }
    }

    private var untaggedCount: Int {
        allItems.count { model.tags(for: $0.reference).isEmpty }
    }

    /// Filtering is a read. Nothing in this pipeline mutates state, which is
    /// the whole reason tags and collections stay separate concepts.
    private var filteredItems: [InventoryItem] {
        allItems.filter { item in
            if let kindFilter, item.kind != kindFilter { return false }
            if !search.isEmpty,
                !item.name.localizedCaseInsensitiveContains(search),
                !item.reference.identifier.localizedCaseInsensitiveContains(search)
            {
                return false
            }
            let tags = model.tags(for: item.reference)
            if untaggedOnly { return tags.isEmpty }
            guard !selectedTags.isEmpty else { return true }
            return selectedTags.allSatisfy { wanted in tags.contains { ToolingTag.matches($0, wanted) } }
        }
    }

    private var selectedReferences: [ToolingItemReference] {
        allItems.filter { selection.contains($0.id) }.map(\.reference)
    }

    private func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

private struct TaggedItemRow: View {
    let item: InventoryItem
    let tags: [String]
    let collections: [String]
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .accessibilityHidden(true)
            KindTile(kind: ToolingKind(item.kind), size: 24, ghost: item.isMissing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            CollectionPills(names: collections, selected: selected)
            TagPills(tags: tags, selected: selected)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 48)
        .rowSelection(selected)
        .contentShape(Rectangle())
    }
}

private struct TagEditorSheet: View {
    private enum TagState {
        case on
        case mixed
        case off
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [ToolingItemReference]
    @State private var overrides: [String: Bool] = [:]
    @State private var newTag = ""
    @State private var addedTags: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit tags").font(.title2.weight(.semibold))
                Text(
                    "Tags are for finding things. Applying them changes no configuration and installs nothing — "
                        + "\(items.count) item\(items.count == 1 ? "" : "s") selected."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(22)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("New tag", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addTypedTag)
                            .accessibilityLabel("New tag")
                        Button("Add", action: addTypedTag)
                            .buttonStyle(.bordered)
                            .disabled(ToolingTag.normalized(newTag) == nil)
                    }

                    if knownTags.isEmpty {
                        Text("No tags yet. Type one above to create it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(knownTags, id: \.self) { tag in
                            Button {
                                cycle(tag)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: symbol(for: state(of: tag)))
                                        .foregroundStyle(state(of: tag) == .off ? Color.secondary : AgentTheme.blue)
                                    Text(tag)
                                    Spacer()
                                    if state(of: tag) == .mixed {
                                        Text("Some").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(accessibilityValue(for: state(of: tag)))
                        }
                    }
                }
                .padding(22)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Apply Tags") { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isInteractionLocked || !hasChanges)
            }
            .padding(16)
        }
        .frame(width: 520, height: 520)
        .background(AgentTheme.contentBackground)
    }

    private var knownTags: [String] {
        ToolingTag.normalizedList(model.allTags + addedTags)
    }

    private var hasChanges: Bool {
        overrides.contains { key, value in value != (state(ignoringOverrideFor: key) == .on) }
    }

    private func state(of tag: String) -> TagState {
        if let override = overrides[tag] { return override ? .on : .off }
        return state(ignoringOverrideFor: tag)
    }

    private func state(ignoringOverrideFor tag: String) -> TagState {
        let carrying = items.count { reference in
            model.tags(for: reference).contains { ToolingTag.matches($0, tag) }
        }
        if carrying == 0 { return .off }
        return carrying == items.count ? .on : .mixed
    }

    private func symbol(for state: TagState) -> String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }

    private func accessibilityValue(for state: TagState) -> String {
        switch state {
        case .on: "On every selected item"
        case .mixed: "On some selected items"
        case .off: "Not applied"
        }
    }

    private func cycle(_ tag: String) {
        overrides[tag] = state(of: tag) != .on
    }

    private func addTypedTag() {
        guard let tag = ToolingTag.normalized(newTag) else { return }
        if !knownTags.contains(where: { ToolingTag.matches($0, tag) }) {
            addedTags.append(tag)
        }
        overrides[tag] = true
        newTag = ""
    }

    private func apply() {
        let adding = overrides.filter(\.value).map(\.key)
        let removing = overrides.filter { !$0.value }.map(\.key)
        if model.applyTagEdits(adding: adding, removing: removing, to: items) {
            dismiss()
        }
    }
}

// MARK: - Inventory bridge

/// One row of inventory, whatever kind it is. Collections and tags both need
/// the same three facts about an item, and neither should care which of the
/// three model arrays it came from.
struct InventoryItem: Identifiable, Hashable {
    let reference: ToolingItemReference
    let name: String
    let detail: String
    /// Named in a collection but absent from this Mac's inventory. Shown at
    /// reduced presence instead of being hidden, so a shelf never silently
    /// loses an entry.
    let isMissing: Bool

    var id: String { reference.id }
    var kind: ToolingItemKind { reference.kind }
}

extension AppModel {
    func inventoryItems(of kind: ToolingItemKind) -> [InventoryItem] {
        let items: [InventoryItem]
        switch kind {
        case .skill:
            items = visibleSkills.map {
                InventoryItem(
                    reference: ToolingItemReference(kind: .skill, identifier: $0.id),
                    name: $0.displayName.isEmpty ? $0.name : $0.displayName,
                    detail: $0.summary,
                    isMissing: false
                )
            }
        case .plugin:
            items = visiblePlugins.map {
                InventoryItem(
                    reference: ToolingItemReference(kind: .plugin, identifier: $0.id),
                    name: $0.name,
                    detail: $0.summary,
                    isMissing: false
                )
            }
        case .mcpServer:
            items = visibleMCPServers.map {
                InventoryItem(
                    reference: ToolingItemReference(kind: .mcpServer, identifier: $0.id),
                    name: $0.name,
                    detail: $0.summary,
                    isMissing: false
                )
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func inventoryItem(for reference: ToolingItemReference) -> InventoryItem {
        if let match = inventoryItems(of: reference.kind).first(where: { $0.reference == reference }) {
            return match
        }
        return InventoryItem(
            reference: reference,
            name: reference.identifier,
            detail: "Not present on this Mac",
            isMissing: true
        )
    }
}
