import AgentToolingCore
import SwiftUI

/// The Macs sharing this library, in the window's corner. This Mac is the one
/// every screen shows; picking another opens its last published summary and
/// the one thing you can do for it from here: set intent, which it carries out
/// on its next pass. Nothing runs on another Mac from this one.
struct DeviceSwitcher: View {
    let workspace: WorkspaceLaunch.Workspace
    @State private var viewing: DeviceRecord?

    private var sync: WorkspaceSyncSession? { workspace.sync }

    var body: some View {
        if let sync, !sync.otherDevices.isEmpty {
            Menu {
                Section("This Mac") {
                    Label(sync.thisDevice?.name ?? "This Mac", systemImage: "desktopcomputer").disabled(true)
                }
                Section("Other Macs") {
                    ForEach(sync.otherDevices) { device in
                        Button {
                            viewing = device
                        } label: {
                            Label {
                                Text(device.name)
                                if let seen = sync.status(of: device.id)?.publishedAt ?? device.lastSeenAt {
                                    Text("Last seen \(SnapshotTime.compact(seen))")
                                }
                            } icon: {
                                Image(systemName: "laptopcomputer")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "laptopcomputer.and.iphone")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .help("Your other Macs: see what each one last reported, and assign tools to it.")
            .accessibilityLabel("Other Macs")
            .sheet(item: $viewing) { device in
                OtherMacSheet(workspace: workspace, device: device)
            }
        }
    }
}

/// One other Mac, as it last described itself. Everything here is as of the
/// time shown; the only live thing is this Mac's own library, which is where
/// an assignment made here lands for that Mac to pick up.
struct OtherMacSheet: View {
    let workspace: WorkspaceLaunch.Workspace
    let device: DeviceRecord
    @Environment(\.dismiss) private var dismiss
    @State private var isAssigning = false

    private var status: PublishedDeviceStatus? { workspace.sync?.status(of: device.id) }

    /// Items assigned to this Mac (by name or as every Mac) from the library.
    private var assigned: [WorkspaceLibraryReadModelRow] {
        let registry = workspace.library.state?.snapshot.document.deviceRegistry ?? []
        return (workspace.library.state?.library.rows ?? []).filter { row in
            row.requestedAssignments.contains { $0.desiredPresence && $0.destination.applies(to: device.id, registry: registry) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.lg) {
                SymbolTile(symbol: "laptopcomputer", size: Size.tileLarge)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(device.name).font(AgentFont.titleLarge)
                    Text(asOf).font(AgentFont.body).foregroundStyle(.secondary)
                }
                Spacer()
                if !device.receivesSharedAssignments {
                    StatusBadge(state: .pending, text: "Takes only what names it")
                }
            }
            .padding(.horizontal, Space.xxxl)
            .frame(height: Size.sheetBarHeight)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    if let status {
                        TitledCard("Apps on \(device.name)", count: "\(status.apps.count)") {
                            ForEach(Array(status.apps.enumerated()), id: \.offset) { index, app in
                                HStack(spacing: Space.lg) {
                                    if let client = app.surface.client {
                                        ClientBrandIcon(client: client, size: Size.tileSmall).frame(width: Size.tile, height: Size.tile)
                                    }
                                    VStack(alignment: .leading, spacing: Space.xxs) {
                                        Text(app.surface.displayName).font(AgentFont.bodyMedium)
                                        Text(app.installed
                                             ? "\(app.version ?? "Installed") · \(app.skillCount) skills · \(app.pluginCount) plugins · \(app.mcpServerCount) servers"
                                             : "Not found on that Mac")
                                            .font(AgentFont.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    StatusGlyph(state: app.installed ? .healthy : .pending, size: Size.glyph)
                                }
                                .padding(.horizontal, Space.xl).frame(minHeight: Size.rowHeight)
                                if index < status.apps.count - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                            }
                        }
                        if !status.pending.isEmpty {
                            TitledCard("Waiting on that Mac", count: "\(status.pending.count)") {
                                ForEach(Array(status.pending.enumerated()), id: \.offset) { index, name in
                                    HStack(spacing: Space.lg) {
                                        StatusGlyph(state: .pending, size: Size.glyph)
                                        Text(name).font(AgentFont.body)
                                        Spacer()
                                    }
                                    .padding(.horizontal, Space.xl).frame(minHeight: Size.compactRowHeight)
                                    if index < status.pending.count - 1 { Hairline() }
                                }
                                Hairline()
                                Text("Assigned, not installed there yet. That Mac installs by its own Updates policy when it next looks.")
                                    .font(AgentFont.caption).foregroundStyle(.tertiary).wrapsLines()
                                    .padding(.horizontal, Space.xl).padding(.vertical, Space.md)
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "Nothing reported yet", systemImage: "laptopcomputer.slash",
                            description: Text("\(device.name) has not published its state. It will on its next sync."))
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    TitledCard("Assigned to \(device.name)", count: "\(assigned.count)") {
                        if assigned.isEmpty {
                            Text("Nothing from the library is assigned to this Mac.")
                                .font(AgentFont.body).foregroundStyle(.secondary)
                                .padding(Space.xl).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(Array(assigned.enumerated()), id: \.element.artifactID) { index, row in
                                HStack(spacing: Space.lg) {
                                    KindTile(kind: row.kind == .mcpServer ? .mcpServer : (row.kind == .skill ? .skill : .plugin), size: Size.tileSmall)
                                    Text(row.displayName).font(AgentFont.body)
                                    Spacer()
                                }
                                .padding(.horizontal, Space.xl).frame(minHeight: Size.compactRowHeight)
                                if index < assigned.count - 1 { Hairline(indent: Hairline.afterLeading(Size.tileSmall)) }
                            }
                        }
                    }
                    Text("Nothing runs on \(device.name) from here. Assigning saves what it should have; it installs when it next syncs, by its own policy.")
                        .font(AgentFont.caption).foregroundStyle(.tertiary).wrapsLines()
                }
                .padding(Space.xxxl)
            }
            Hairline()
            HStack {
                Button("Close") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Assign to \(device.name)…", systemImage: "arrow.down.circle") { isAssigning = true }
                    .primaryActionStyle()
                    .disabled(workspace.library.access != .writable)
            }
            .padding(.horizontal, Space.xxxl)
            .frame(height: Size.sheetBarHeight)
        }
        .sheetSize(SheetSize.large)
        .background(AgentTheme.contentBackground)
        .sheet(isPresented: $isAssigning) {
            // The ordinary picker, scoped to that Mac. The chooser there starts
            // on the Library row the person picks; this is the shortest road
            // to "put X on the laptop" from the Studio.
            AssignToDeviceSheet(workspace: workspace, device: device)
        }
    }

    private var asOf: String {
        if let status { return "As of \(SnapshotTime.compact(status.publishedAt)) · \(status.name)'s own report" }
        if let seen = device.lastSeenAt { return "Last seen \(SnapshotTime.compact(seen)) · nothing reported yet" }
        return "Not seen since it joined"
    }
}

/// Pick a library item, then the picker opens for exactly one Mac.
private struct AssignToDeviceSheet: View {
    let workspace: WorkspaceLaunch.Workspace
    let device: DeviceRecord
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: ArtifactID?
    @State private var query = ""

    private var rows: [WorkspaceLibraryReadModelRow] {
        (workspace.library.state?.library.rows ?? [])
            .filter { $0.isAssignable && ($0.kind == .skill || $0.kind == .mcpServer || $0.kind == .nativePlugin) }
            .filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Assign to \(device.name)").font(AgentFont.title)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Space.xxxl).frame(height: Size.sheetBarHeight)
            Hairline()
            InventorySearchField(placeholder: "Search the library", text: $query)
                .padding(.horizontal, Space.xxxl).padding(.vertical, Space.lg)
            List(rows, selection: $chosen) { row in
                HStack(spacing: Space.lg) {
                    KindTile(kind: row.kind == .mcpServer ? .mcpServer : (row.kind == .skill ? .skill : .plugin), size: Size.tileSmall)
                    Text(row.displayName).font(AgentFont.body)
                    Spacer()
                }
                .tag(row.artifactID)
            }
            .collectionListChrome()
            Hairline()
            HStack {
                Text("Pick an item, then choose the apps on \(device.name) that should have it.")
                    .font(AgentFont.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose apps…") { picking = chosen.map(ChosenItem.init) }
                    .primaryActionStyle().disabled(chosen == nil).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.xxxl).frame(height: Size.sheetBarHeight)
        }
        .sheetSize(SheetSize.medium)
        .background(AgentTheme.contentBackground)
        .sheet(item: $picking) { item in
            WorkspaceAssignmentSheet(session: workspace.library, artifactIDs: [item.id], initialDevices: [device.id])
                .onDisappear { dismiss() }
        }
    }

    @State private var picking: ChosenItem?
    private struct ChosenItem: Identifiable { let id: ArtifactID }
}
