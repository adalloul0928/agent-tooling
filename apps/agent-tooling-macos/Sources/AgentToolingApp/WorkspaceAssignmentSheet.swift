import AgentToolingCore
import SwiftUI

/// Where should these go? One dialog: tick the apps, press Install.
///
/// Behind the button the whole pipeline runs — assign, plan, safety review,
/// approve, execute, receipt — but a person sees it only when the plan would
/// do something the button did not say (`OperationPlanRiskClassifier`). Then
/// the same sheet turns into the review, in place, with the reasons at the
/// top. Afterwards it says where the item went, with Undo.
///
/// This keeps the name every screen already presents, so Discover, the
/// Library, Projects, Presets and onboarding all get the one-step flow.
struct WorkspaceAssignmentSheet: View {
    let session: WorkspaceLibrarySession
    let artifactIDs: [ArtifactID]
    var presetID: ArtifactID?
    var initialProjectID: ArtifactID?
    /// Apps to tick before anyone touches a row. Defaults to the apps the
    /// person chose the last time, or none.
    var initialClients: Set<ClientKind> = []
    /// Macs to assign to, when the sheet is opened for specific Macs (from
    /// another Mac's summary). Empty means the default, every Mac.
    var initialDevices: Set<WorkspaceObjectID> = []

    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigationState.self) private var navigation: AppNavigationState?
    @Environment(\.availableClients) private var availableClients: [ClientKind]
    /// The sessions the pipeline needs. Published by the shell; a sheet drawn
    /// on its own (tests, previews) saves assignments and stops there, which
    /// is what the sheet always did.
    @Environment(\.installPipeline) private var pipeline: InstallPipeline?
    @AppStorage("install.lastClients") private var lastClientsStorage = ""

    @State private var selectedClients: Set<ClientKind>
    @State private var scope: ToolingScope
    @State private var selectedProjectID: ArtifactID?
    /// Which Macs a user-scope install is for. Every Mac is the default: the
    /// point of a shared library is that one decision reaches all of them.
    @State private var placement: InstallWhere = .everyMac
    @State private var chosenDevices: Set<WorkspaceObjectID> = []
    @State private var install: WorkspaceInstallSession?
    @State private var fallbackRequest: FallbackRequest?

    init(
        session: WorkspaceLibrarySession,
        artifactIDs: [ArtifactID],
        presetID: ArtifactID? = nil,
        initialProjectID: ArtifactID? = nil,
        initialClients: Set<ClientKind> = [],
        initialDevices: Set<WorkspaceObjectID> = [],
        installSession: WorkspaceInstallSession? = nil
    ) {
        self.session = session
        self.artifactIDs = artifactIDs
        self.presetID = presetID
        self.initialProjectID = initialProjectID
        self.initialClients = initialClients
        self.initialDevices = initialDevices
        _scope = State(initialValue: initialProjectID == nil ? .user : .project)
        _placement = State(initialValue: initialProjectID != nil ? .project : (initialDevices.isEmpty ? .everyMac : .chooseMacs))
        _chosenDevices = State(initialValue: initialDevices)
        _selectedProjectID = State(initialValue: initialProjectID)
        _selectedClients = State(initialValue: initialClients)
        _install = State(initialValue: installSession)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            Group {
                if session.state == nil, session.isBusy {
                    ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let state = session.state {
                    content(state.library)
                } else {
                    ContentUnavailableView(
                        "Library unavailable", systemImage: "books.vertical",
                        description: Text(session.errorMessage ?? "Refresh the workspace and try again."))
                }
            }
            Hairline()
            footer
        }
        .sheetSize(SheetSize.large)
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled(isBusy)
        .task(id: loadID) {
            if session.state == nil { await session.refresh() }
            if let pipeline, install == nil {
                install = WorkspaceInstallSession(
                    library: session, deployment: pipeline.deployment, device: pipeline.device, service: pipeline.service)
            }
            if selectedClients.isEmpty, initialClients.isEmpty {
                selectedClients = rememberedClients.intersection(selectableClients)
            }
        }
        .task(id: fallbackRequest) {
            // Without the pipeline (no shell), the sheet saves assignments the
            // way it always did: review, then save.
            guard let fallbackRequest else { return }
            switch fallbackRequest {
            case .review(let destinations):
                if let presetID {
                    await session.reviewPreset(presetID: presetID, destinations: destinations)
                } else {
                    await session.reviewAssignments(artifactIDs: artifactIDs, destinations: destinations)
                }
            case .save:
                await session.applyReviewedAssignments()
            }
            if !Task.isCancelled { self.fallbackRequest = nil }
        }
        .onDisappear {
            install?.reset()
            fallbackRequest = nil
            if session.review != nil, !session.isBusy { session.discardReview() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.lg) {
            SymbolTile(symbol: presetID == nil ? "arrow.down.circle" : "square.stack.3d.up", size: Size.tileLarge)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(headerTitle).font(AgentFont.titleLarge)
                Text(headerDetail).font(AgentFont.body).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, Space.xxxl)
        .frame(height: Size.sheetBarHeight)
    }

    private var headerTitle: String {
        switch install?.phase {
        case .reviewing: "Look before installing"
        case .finished(let outcome):
            if !outcome.installed.isEmpty { "Installed" } else if !outcome.failed.isEmpty { "Couldn’t install" } else { "Nothing to install" }
        case .undoing: "Undoing…"
        default: presetID == nil ? (artifactIDs.count == 1 ? "Install" : "Install \(artifactIDs.count) items") : "Follow preset"
        }
    }

    private var headerDetail: String {
        switch install?.phase {
        case .reviewing:
            return (install?.heldBack.isEmpty ?? true)
                ? "This would do more than the button said. Read it, then install."
                : "Part of this won’t run: it would overwrite files Agent Tooling did not put there."
        case .finished(let outcome): return outcome.summary
        case .preparing: return "Checking your apps…"
        case .installing: return "Installing…"
        case .undoing: return "Taking it back out…"
        case .choosing, .none:
            if pipeline == nil, session.lastReceipt != nil {
                return "Saved to your workspace. Open it from the Apps screen to install."
            }
            return "Choose the apps that should have \(presetID == nil && artifactIDs.count == 1 ? "it" : "them")."
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ library: WorkspaceLibraryReadModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxxl) {
                switch install?.phase {
                case .reviewing(let reasons):
                    reviewContent(reasons: reasons)
                case .finished(let outcome):
                    outcomeContent(outcome)
                default:
                    if pipeline == nil, let review = session.review {
                        fallbackReview(review)
                    } else if pipeline == nil, session.lastReceipt != nil {
                        fallbackSaved
                    } else {
                        chooser(library)
                    }
                }
                if let error = install?.errorMessage ?? (pipeline == nil ? session.errorMessage : nil) {
                    AttentionBanner(title: "Couldn’t install", message: error)
                }
            }
            .padding(Space.xxxl)
        }
    }

    private func chooser(_ library: WorkspaceLibraryReadModel) -> some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            itemsSummary(library)
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Apps").font(AgentFont.heading)
                    Spacer()
                    WorkspaceSegmentedPicker("Where", selection: $placement) {
                        if otherDevices.isEmpty {
                            Text("This Mac").tag(InstallWhere.everyMac)
                        } else {
                            Text("Every Mac").tag(InstallWhere.everyMac)
                            Text("This Mac only").tag(InstallWhere.thisMac)
                            Text("Choose Macs…").tag(InstallWhere.chooseMacs)
                        }
                        Text("One project").tag(InstallWhere.project)
                    }
                    .fixedSize()
                    .onChange(of: placement) { _, value in scope = value == .project ? .project : .user }
                }
                if placement == .chooseMacs {
                    deviceChooser
                }
                if availableClients.isEmpty {
                    Text("No apps are managed on this Mac. Choose apps on the Apps screen.")
                        .font(AgentFont.body).foregroundStyle(.secondary).wrapsLines()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.xl)
                        .standardPanel()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(availableClients.enumerated()), id: \.element) { index, client in
                            clientRow(client, library: library)
                            if index < availableClients.count - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                        }
                    }
                    .standardPanel()
                }
                if scope == .project {
                    HStack(spacing: Space.lg) {
                        Picker("Project", selection: $selectedProjectID) {
                            Text("Choose a project").tag(nil as ArtifactID?)
                            ForEach(library.projects) { project in
                                Text(projectHasFolder(project.id) ? project.name : "\(project.name) — no folder on this Mac")
                                    .tag(project.id as ArtifactID?)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: Size.fieldMedium, alignment: .leading)
                        if let selectedProjectID, !projectHasFolder(selectedProjectID) {
                            Text("Installing waits until this project has a folder on this Mac.")
                                .font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                        }
                    }
                } else {
                    Text(whereExplanation).font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                }
            }
        }
        .disabled(isBusy)
    }

    /// Macs this Mac knows about through the shared registry, besides itself.
    private var otherDevices: [DeviceRecord] {
        (session.state?.snapshot.document.deviceRegistry ?? [])
            .filter { $0.id != session.deviceID && !$0.isRetired }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var thisDeviceName: String {
        session.state?.snapshot.document.deviceRegistry.first { $0.id == session.deviceID }?.name ?? "This Mac"
    }

    private var whereExplanation: String {
        switch placement {
        case .everyMac:
            return otherDevices.isEmpty
                ? "For every project on this Mac. Other Macs that join this library get it too."
                : "For every project, on this Mac and \(otherDevices.count == 1 ? otherDevices[0].name : "\(otherDevices.count) other Macs"). A Mac set to take only what names it is left out."
        case .thisMac: return "For every project on this Mac. Other Macs are left out."
        case .chooseMacs: return "Only the Macs ticked above."
        case .project: return "For one project only."
        }
    }

    /// Checkboxes for this Mac and each other Mac. A limited Mac can be named
    /// here; that is the one way shared intent reaches it.
    private var deviceChooser: some View {
        VStack(spacing: 0) {
            deviceRow(id: session.deviceID, name: thisDeviceName, detail: "This Mac", limited: false)
            ForEach(otherDevices) { device in
                Hairline(indent: Hairline.afterLeading(Size.tile))
                deviceRow(id: device.id, name: device.name,
                          detail: device.lastSeenText,
                          limited: !device.receivesSharedAssignments)
            }
        }
        .standardPanel()
    }

    private func deviceRow(id: WorkspaceObjectID, name: String, detail: String, limited: Bool) -> some View {
        Button {
            if chosenDevices.contains(id) { chosenDevices.remove(id) } else { chosenDevices.insert(id) }
        } label: {
            HStack(spacing: Space.lg) {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: Size.tile)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(name).font(AgentFont.bodyMedium)
                    Text(limited ? "\(detail) · \(DeviceLabels.limitedMac)" : detail).font(AgentFont.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.lg)
                SelectionCheckbox(selected: chosenDevices.contains(id), enabled: true)
                    .foregroundStyle(chosenDevices.contains(id) ? AgentTheme.selection : Color.secondary)
            }
            .padding(.horizontal, Space.xl).frame(minHeight: Size.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One app: logo, name, what would happen there, and the tick.
    private func clientRow(_ client: ClientKind, library: WorkspaceLibraryReadModel) -> some View {
        let status = clientStatus(client, library: library)
        let selectable = status.selectable
        return Button {
            guard selectable, !isBusy else { return }
            if selectedClients.contains(client) { selectedClients.remove(client) } else { selectedClients.insert(client) }
        } label: {
            HStack(spacing: Space.lg) {
                ClientBrandIcon(client: client, size: Size.tileSmall).frame(width: Size.tile, height: Size.tile)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(client.rawValue).font(AgentFont.bodyMedium)
                    HStack(spacing: Space.sm) {
                        StatusGlyph(state: status.state, size: Size.glyphSmall)
                        Text(status.text).font(AgentFont.caption).foregroundStyle(.secondary)
                        if let path = status.path {
                            Text("·").font(AgentFont.caption).foregroundStyle(.tertiary)
                            Text(path).font(AgentFont.mono).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: Space.lg)
                SelectionCheckbox(selected: selectedClients.contains(client), enabled: selectable)
                    .foregroundStyle(selectedClients.contains(client) ? AgentTheme.selection : Color.secondary)
            }
            .padding(.horizontal, Space.xl)
            .frame(minHeight: Size.rowHeightTall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(selectable ? 1 : 0.55)
        .help(status.help ?? "")
        .accessibilityLabel("\(client.rawValue), \(status.text)")
        .accessibilityAddTraits(selectedClients.contains(client) ? [.isSelected] : [])
    }

    private struct ClientStatus {
        var state: HealthState
        var text: String
        var path: String?
        var help: String?
        var selectable: Bool
    }

    /// What installing here would mean, from facts the library and the last
    /// scan already hold. Nothing is measured on disk; the plan does that.
    private func clientStatus(_ client: ClientKind, library: WorkspaceLibraryReadModel) -> ClientStatus {
        let verdict = pipeline?.device.verdict(for: client)
        let detected = verdict?.state == .healthy
        guard kindsSupported(by: client) else {
            return .init(state: .unavailable, text: "Doesn’t take \(kindNoun)", help: "This app has no place for \(kindNoun).", selectable: false)
        }
        let rows = library.rows.filter { artifactIDs.contains($0.artifactID) }
        let alreadyAsked = !rows.isEmpty && rows.allSatisfy { row in
            row.requestedAssignments.contains { $0.destination.surface.client == client && $0.destination.scope == scope }
        }
        let path = scope == .user ? skillFolder(client) : nil
        if alreadyAsked {
            return .init(state: .healthy, text: "Already here", path: path,
                         help: "This app is already asked to have it. Installing again puts back anything missing.", selectable: true)
        }
        if detected {
            return .init(state: .healthy, text: "Found on this Mac", path: path, selectable: true)
        }
        return .init(state: .pending, text: "Not found on this Mac",
                     path: path, help: "It can still be set up; the files wait until the app is installed.", selectable: true)
    }

    private var kindNoun: String {
        let kinds = Set(session.state?.library.rows.filter { artifactIDs.contains($0.artifactID) }.map(\.kind) ?? [])
        if kinds == [.mcpServer] { return "connections" }
        if kinds == [.nativePlugin] || kinds == [.package] { return "plugins" }
        return "skills"
    }

    private func kindsSupported(by client: ClientKind) -> Bool {
        guard let surface = client.userSurface else { return false }
        let rows = session.state?.library.rows.filter { artifactIDs.contains($0.artifactID) } ?? []
        guard !rows.isEmpty else { return true }
        return rows.allSatisfy { row in
            switch row.kind {
            case .skill, .package: TargetSurfaceCapability.skillClient(for: surface) != nil
            case .mcpServer: TargetSurfaceCapability.managedMCPClient(for: surface) != nil
            case .nativePlugin: TargetSurfaceCapability.nativePluginClient(for: surface) != nil
            case .preset, .logicalProject: true
            }
        }
    }

    private var selectableClients: Set<ClientKind> {
        Set(availableClients.filter(kindsSupported(by:)))
    }

    private func skillFolder(_ client: ClientKind) -> String? {
        guard let pipeline,
              let url = try? NativeSkillDestination.directory(client: client, homeURL: pipeline.homeRoot, scope: .user, projectRoot: nil)
        else { return nil }
        let home = pipeline.homeRoot.path(percentEncoded: false).trimmingSuffix("/")
        let path = url.path(percentEncoded: false).trimmingSuffix("/")
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func itemsSummary(_ library: WorkspaceLibraryReadModel) -> some View {
        let items = summaries(in: library)
        return VStack(spacing: 0) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                HStack(spacing: Space.lg) {
                    KindTile(kind: ToolingKind(item.kind), size: Size.tile)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(item.name).font(AgentFont.bodyMedium)
                        Text(item.detail).font(AgentFont.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, Space.xl).frame(minHeight: Size.rowHeight)
                if index < min(3, items.count) - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
            }
            if items.count > 3 {
                Hairline()
                Text("and \(items.count - 3) more").font(AgentFont.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xl).frame(height: Size.compactRowHeight)
            }
        }
        .standardPanel()
    }

    // MARK: Review (in place)

    private func reviewContent(reasons: [OperationPlanRiskClassifier.Reason]) -> some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(reasons, id: \.self) { reason in
                    HStack(alignment: .top, spacing: Space.md) {
                        StatusGlyph(state: .attention, size: Size.glyph)
                        Text(reason.summary).font(AgentFont.body).wrapsLines()
                    }
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentTheme.warning.opacity(0.10), in: RoundedRectangle.card)
            .overlay { RoundedRectangle.card.strokeBorder(AgentTheme.warning.opacity(0.32), lineWidth: Hairline.width) }

            if let install, let plan = install.reviewPlan {
                let running = install.runnableReviewItems
                if !running.isEmpty {
                    TitledCard("What would happen", count: "\(running.count)") {
                        ForEach(Array(running.enumerated()), id: \.offset) { index, item in
                            planItemRow(item)
                            if index < running.count - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                        }
                    }
                }
                if !install.heldBack.isEmpty {
                    TitledCard("Left alone", count: "\(install.heldBack.count)") {
                        ForEach(Array(install.heldBack.enumerated()), id: \.offset) { index, item in
                            HStack(spacing: Space.lg) {
                                if let client = item.surface.client {
                                    ClientBrandIcon(client: client, size: Size.tileSmall).frame(width: Size.tile, height: Size.tile)
                                }
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text(item.displayName).font(AgentFont.bodyMedium)
                                    Text("\(item.surface.displayName) already has a copy Agent Tooling did not put there. It won’t be overwritten.")
                                        .font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                                }
                                Spacer(minLength: Space.lg)
                                if navigation != nil {
                                    Button("Open Checkup") { dismiss(); navigation?.open(.section(.checkup)) }
                                        .inlineActionStyle()
                                        .help("Adopt the existing copy into your library, or remove it, then install.")
                                }
                            }
                            .padding(.horizontal, Space.xl).padding(.vertical, Space.md)
                            if index < install.heldBack.count - 1 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                        }
                    }
                }
                if !plan.exclusions.isEmpty {
                    TitledCard("What would not", count: "\(plan.exclusions.count)") {
                        ForEach(Array(plan.exclusions.enumerated()), id: \.offset) { index, exclusion in
                            HStack(alignment: .top, spacing: Space.lg) {
                                StatusGlyph(state: .pending, size: Size.glyph)
                                Text(exclusion.detail).font(AgentFont.body).foregroundStyle(.secondary).wrapsLines()
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
                            if index < plan.exclusions.count - 1 { Hairline() }
                        }
                    }
                }
            }
        }
    }

    private func planItemRow(_ item: WorkspaceDeploymentItem) -> some View {
        HStack(spacing: Space.lg) {
            if let client = item.surface.client {
                ClientBrandIcon(client: client, size: Size.tileSmall).frame(width: Size.tile, height: Size.tile)
            } else {
                KindTile(kind: .library, size: Size.tile)
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(item.displayName).font(AgentFont.bodyMedium)
                Text(actionText(item)).font(AgentFont.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, Space.xl).frame(minHeight: Size.rowHeight)
    }

    private func actionText(_ item: WorkspaceDeploymentItem) -> String {
        let app = item.surface.displayName
        switch item.action {
        case .installContent: return "Install in \(app)"
        case .updateContent: return "Replace what \(app) has"
        case .removeContent: return "Remove from \(app)"
        case .installNativePackage: return "Ask \(app) to install it"
        case .configureManagedConnection: return "Add the connection to \(app)"
        }
    }

    // MARK: Outcome

    private func outcomeContent(_ outcome: WorkspaceInstallSession.InstallOutcome) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(spacing: 0) {
                ForEach(outcome.installed.sorted { $0.rawValue < $1.rawValue }, id: \.self) { client in
                    outcomeRow(client, state: .healthy, text: "Installed")
                    Hairline(indent: Hairline.afterLeading(Size.tile))
                }
                ForEach(outcome.failed.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { client in
                    HStack(alignment: .top, spacing: Space.lg) {
                        ClientBrandIcon(client: client, size: Size.tileSmall).frame(width: Size.tile, height: Size.tile)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            HStack(spacing: Space.sm) {
                                Text(client.rawValue).font(AgentFont.bodyMedium)
                                StatusBadge(state: .attention, text: "Failed")
                            }
                            Text(outcome.failed[client] ?? "").font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.xl).padding(.vertical, Space.md)
                    Hairline(indent: Hairline.afterLeading(Size.tile))
                }
                ForEach(outcome.skipped, id: \.self) { reason in
                    HStack(alignment: .top, spacing: Space.lg) {
                        StatusGlyph(state: .pending, size: Size.glyph)
                        Text(reason).font(AgentFont.body).foregroundStyle(.secondary).wrapsLines()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
                }
            }
            .standardPanel()
            if outcome.canUndo {
                Text("Undo takes it back out of the apps it was just put in, and nothing else.")
                    .font(AgentFont.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func outcomeRow(_ client: ClientKind, state: HealthState, text: String) -> some View {
        HStack(spacing: Space.lg) {
            ClientBrandIcon(client: client, size: Size.tileSmall).frame(width: Size.tile, height: Size.tile)
            Text(client.rawValue).font(AgentFont.bodyMedium)
            Spacer()
            StatusBadge(state: state, text: text)
        }
        .padding(.horizontal, Space.xl).frame(minHeight: Size.rowHeight)
    }

    // MARK: Fallback (no pipeline in the environment)

    private func fallbackReview(_ review: WorkspaceAssignmentReview) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Review assignments").font(AgentFont.heading)
            Text("Adds \(review.preview.additions.count), removes \(review.preview.removals.count). Saves these choices to your workspace; installing is a separate step.")
                .font(AgentFont.body).foregroundStyle(.secondary).wrapsLines()
        }
        .padding(Space.xl).frame(maxWidth: .infinity, alignment: .leading).standardPanel()
    }

    private var fallbackSaved: some View {
        ContentUnavailableView {
            Label("Assignments saved", systemImage: "checkmark.circle")
        } description: {
            Text("Saved to your workspace. Open it from the Apps screen to install.")
        }
        .frame(maxWidth: .infinity, minHeight: Size.emptyStateMinHeight)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.lg) {
            leadingButton
            Spacer()
            GlassEffectContainer(spacing: Space.md) { trailingButtons }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(nil as Color?)
        }
        .padding(.horizontal, Space.xxxl)
        .frame(height: Size.sheetBarHeight)
    }

    @ViewBuilder private var leadingButton: some View {
        switch install?.phase {
        case .reviewing:
            Button("Back") { install?.reset() }.buttonStyle(.glass).disabled(isBusy)
        case .finished(let outcome):
            if outcome.canUndo {
                Button("Undo") { Task { await install?.undo() } }.buttonStyle(.glass).disabled(isBusy)
            }
        default:
            if pipeline == nil, session.review != nil {
                Button("Back") { fallbackRequest = nil; session.discardReview() }.buttonStyle(.glass).disabled(isBusy)
            } else {
                Button(isFinished ? "Close" : "Cancel") { dismiss() }.buttonStyle(.glass).disabled(isBusy)
            }
        }
    }

    @ViewBuilder private var trailingButtons: some View {
        switch install?.phase {
        case .reviewing:
            let runnable = install?.runnableReviewItems.count ?? 0
            let heldBack = install?.heldBack.count ?? 0
            Button(heldBack == 0 ? "Install" : "Install the rest") { Task { await install?.approveReview() } }
                .primaryActionStyle().keyboardShortcut(.defaultAction)
                .disabled(isBusy || !isWritable || runnable == 0)
        case .finished(let outcome):
            if !outcome.installed.isEmpty, navigation != nil {
                Button("Show in Library") { dismiss(); navigation?.open(.section(.skills)) }
                    .buttonStyle(.glass)
            }
            Button("Done") { dismiss() }.primaryActionStyle().keyboardShortcut(.defaultAction).disabled(isBusy)
        case .preparing, .installing, .undoing:
            ProgressView().controlSize(.small).padding(.horizontal, Space.lg)
        default:
            if pipeline == nil {
                if session.review != nil {
                    Button("Save assignments") { fallbackRequest = .save }.primaryActionStyle().disabled(isBusy || !isWritable)
                } else if session.lastReceipt == nil {
                    Button("Review assignments") { fallbackRequest = .review(destinations) }
                        .primaryActionStyle().disabled(!canInstall || isBusy)
                }
            } else {
                Button(installTitle) { startInstall() }
                    .primaryActionStyle().keyboardShortcut(.defaultAction)
                    .disabled(!canInstall || isBusy || !isWritable)
            }
        }
    }

    private var installTitle: String {
        let count = selectedClients.count
        if count == 0 { return "Install" }
        if count == 1, let only = selectedClients.first { return "Install in \(only.rawValue)" }
        return "Install in \(count) apps"
    }

    private func startInstall() {
        guard let install else { return }
        lastClientsStorage = selectedClients.map(\.rawValue).sorted().joined(separator: "\n")
        Task { await install.install(artifactIDs: artifactIDs, presetID: presetID, destinations: destinations) }
    }

    // MARK: State

    private var isBusy: Bool { install?.isBusy ?? (session.isBusy || fallbackRequest != nil) }

    private var isFinished: Bool {
        if case .finished = install?.phase { return true }
        return pipeline == nil && session.lastReceipt != nil
    }

    private var canInstall: Bool {
        guard !selectedClients.isEmpty else { return false }
        if placement == .chooseMacs, chosenDevices.isEmpty { return false }
        if scope == .project {
            guard let selectedProjectID,
                  session.state?.library.projects.contains(where: { $0.id == selectedProjectID }) == true else { return false }
        }
        return true
    }

    private var isWritable: Bool {
        switch session.access {
        case .readOnly: false
        case .writable: true
        }
    }

    private var destinations: [PortableDestination] {
        // A project folder is one Mac's; a project install stays on this Mac.
        let deviceIDs: [WorkspaceObjectID]? = switch placement {
        case .everyMac: nil
        case .thisMac, .project: [session.deviceID]
        case .chooseMacs: chosenDevices.sorted()
        }
        return selectedClients.sorted { $0.rawValue < $1.rawValue }.compactMap { client in
            guard let surface = client.userSurface else { return nil }
            return .init(surface: surface, scope: scope,
                         logicalProjectID: scope == .project ? selectedProjectID : nil,
                         deviceIDs: deviceIDs)
        }
    }

    private var rememberedClients: Set<ClientKind> {
        Set(lastClientsStorage.split(separator: "\n").compactMap { ClientKind(rawValue: String($0)) })
    }

    private var loadID: String {
        "\(session.workspaceID.rawValue.uuidString.lowercased()):\(session.deviceID.rawValue.uuidString.lowercased())"
    }

    private func projectHasFolder(_ projectID: ArtifactID) -> Bool {
        session.state?.snapshot.device.projectRoots?.contains { $0.projectID == projectID } ?? false
    }

    private func summaries(in library: WorkspaceLibraryReadModel) -> [ItemSummary] {
        let ids: [ArtifactID]
        if let presetID, let preset = library.presets.first(where: { $0.id == presetID }) {
            ids = preset.memberArtifactIDs
        } else {
            ids = artifactIDs
        }
        let roots = Dictionary(uniqueKeysWithValues: library.rows.map { ($0.artifactID, $0) })
        let children = Dictionary(uniqueKeysWithValues: library.rows.flatMap(\.includedChildren).map { ($0.artifactID, $0) })
        return ids.compactMap { id in
            if let row = roots[id] {
                let bundled = row.childCount == 0 ? "" : " · Includes \(row.childCount) bundled item\(row.childCount == 1 ? "" : "s")"
                return .init(id: id, name: row.displayName, kind: row.kind, detail: "\(ownershipLabel(row.ownership))\(bundled)")
            }
            if let child = children[id] {
                return .init(id: id, name: child.displayName, kind: child.kind, detail: "Included with \(child.parentPluginLabel ?? "plugin")")
            }
            return nil
        }
    }


    private func ownershipLabel(_ ownership: WorkspaceLibraryOwnership) -> String {
        switch ownership {
        case .centralPersonal: "Personal library"
        case .centralUpstream: "Upstream linked"
        case .nativeOwned: "Native plugin"
        case .attachedAuthoring: "Attached authoring source"
        case .trackedOnly: "Unmanaged"
        }
    }

    private struct ItemSummary: Identifiable {
        let id: ArtifactID
        let name: String
        let kind: ArtifactKind
        let detail: String
    }

    private enum FallbackRequest: Hashable {
        case review([PortableDestination])
        case save
    }
}

/// Which Macs an install is for.
enum InstallWhere: Hashable {
    case everyMac, thisMac, chooseMacs, project
}

/// The sessions an install needs beyond the library: the planner/executor, the
/// device scan (for each app's status), and the service (for Undo's commits).
/// The shell publishes it; a sheet without it saves assignments and stops.
struct InstallPipeline {
    let deployment: WorkspaceDeploymentSession
    let device: WorkspaceDeviceSession
    let service: WorkspaceApplicationService
    let homeRoot: URL
}

extension EnvironmentValues {
    @Entry var installPipeline: InstallPipeline? = nil
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
