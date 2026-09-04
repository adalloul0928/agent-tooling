import AgentToolingCore
import AppKit
import SwiftUI

struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @Binding var request: ScreenRequest?
    @State private var selectedID = ""
    @State private var editingProfile: ToolingProfile?
    @State private var showingNewProfile = false

    init(request: Binding<ScreenRequest?> = .constant(nil)) {
        _request = request
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Configurations", context: "\(model.profiles.count) defined") {
                Button {
                    if let profile = selectedProfile { editingProfile = profile }
                } label: {
                    Label("Edit configuration…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .disabled(model.isInteractionLocked || selectedProfile == nil || selectedProfile?.scope == .managed)
                Button {
                    showingNewProfile = true
                } label: {
                    Label("New configuration…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isInteractionLocked)
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Checking…" : "Check setup", systemImage: "stethoscope")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInteractionLocked)
            }

            GeometryReader { proxy in
                HSplitView {
                    profileList.frame(
                        minWidth: 330, idealWidth: 390, maxWidth: 470, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                    profileDetail.frame(
                        minWidth: 560, maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editingProfile) { profile in
            ProfileEditorSheet(profile: profile)
                .environment(model)
        }
        .sheet(isPresented: $showingNewProfile) {
            NewProfileSheet { profile in
                selectedID = profile.id
            }
            .environment(model)
        }
        .onAppear {
            if !model.profiles.contains(where: { $0.id == selectedID }) {
                selectedID = model.activeProfileID
            }
            consumeRequest()
        }
        .onChange(of: model.profiles.map(\.id)) { _, ids in
            if !ids.contains(selectedID) {
                selectedID = ids.contains(model.activeProfileID) ? model.activeProfileID : orderedProfiles.first?.id ?? ""
            }
        }
        .onChange(of: request) { _, _ in consumeRequest() }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Configurations").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(model.profiles.count, format: .number).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(AgentTheme.controlBackground.opacity(0.45))

            if orderedProfiles.isEmpty {
                EmptyStateView(
                    symbol: "slider.horizontal.3",
                    title: "No configurations yet",
                    message: "Create a configuration to describe the tools a Mac or project should use.",
                    actionTitle: "New Configuration"
                ) {
                    showingNewProfile = true
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(orderedProfiles) { profile in
                            Button {
                                selectedID = profile.id
                            } label: {
                                ProfileCollectionRow(
                                    profile: profile,
                                    active: profile.id == model.activeProfileID,
                                    selected: profile.id == selectedID
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(profile.name)
                            .accessibilityValue(
                                profile.id == selectedID ? "Selected" : profile.id == model.activeProfileID ? "Current" : "")
                        }
                    }
                }
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var profileDetail: some View {
        if let profile = selectedProfile {
            ProfileDetailView(profile: profile).environment(model)
        } else {
            EmptyStateView(
                symbol: "slider.horizontal.3", title: "Select a configuration",
                message: "Configurations describe what should be installed, connected, and healthy for a workspace.")
        }
    }

    private var selectedProfile: ToolingProfile? { model.profiles.first { $0.id == selectedID } }

    private func consumeRequest() {
        guard let request else { return }
        defer { self.request = nil }
        guard case .selectProfile(let id) = request,
            model.profiles.contains(where: { $0.id == id })
        else { return }
        selectedID = id
    }

    private var orderedProfiles: [ToolingProfile] {
        model.profiles.sorted { lhs, rhs in
            if lhs.id == model.activeProfileID { return true }
            if rhs.id == model.activeProfileID { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

private struct ProfileCollectionRow: View {
    let profile: ToolingProfile
    let active: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            KindTile(kind: .profile, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .lineLimit(1)
                    if active {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(selected ? Color.white : AgentTheme.blue)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : AgentTheme.blue.opacity(0.12)))
                    }
                }
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(checkSummary)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 52)
        .rowSelection(selected)
        .contentShape(Rectangle())
    }

    private var checkSummary: String {
        guard !profile.checks.isEmpty else { return "No checks" }
        return "\(profile.passingChecks) of \(profile.checks.count) checks"
    }
}

private struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model
    let profile: ToolingProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    KindTile(kind: .profile, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name).font(.title3.weight(.semibold))
                        Text(profile.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if profile.id != model.activeProfileID {
                        Button {
                            model.applyProfile(id: profile.id)
                        } label: {
                            Label("Make Current", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isInteractionLocked)
                    } else {
                        Label("Current", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Details") {
                    VStack(spacing: 0) {
                        LabeledValueRow("Scope") {
                            Text(profile.scope.displayName).foregroundStyle(.secondary)
                        }
                        Divider()
                        LabeledValueRow("Project folder") {
                            if let projectRoot = profile.projectRoot {
                                LocationText(path: projectRoot)
                            } else {
                                Text("Not applicable").foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        LabeledValueRow("Inherits from") {
                            Text(parentName ?? "None").foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("Health checks") {
                    if profile.checks.isEmpty {
                        Text("Run Check setup to create health checks for this configuration.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(profile.checks) { check in
                                HStack(spacing: 11) {
                                    StatusGlyph(state: check.state, size: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(legacyCheckTitle(check)).font(.callout.weight(.medium))
                                        Text(
                                            legacyCheckDetail(check)
                                        ).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if check.manual {
                                        Text("Manual").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(12)
                                if check.id != profile.checks.last?.id { Divider() }
                            }
                        }
                    }
                }

                let effective = model.effectiveProfile(for: profile.id) ?? profile
                GroupBox("Included tools") {
                    if effective.enabledPlugins.isEmpty && effective.requiredMCPs.isEmpty {
                        Text("This configuration does not require any plugins or MCP servers.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        let rows =
                            effective.enabledPlugins.map { (kind: "Plugin", value: $0) }
                            + effective.requiredMCPs.map { (kind: "MCP server", value: $0) }
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                ProfileInventoryRow(kind: row.kind, value: row.value)
                                if index < rows.count - 1 { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private var parentName: String? {
        guard let parentID = profile.inheritedFrom else { return nil }
        return model.profiles.first(where: { $0.id == parentID })?.name ?? "Unavailable configuration"
    }

    private func legacyCheckTitle(_ check: ProfileCheck) -> String {
        ["Agent targets", "Observed targets"].contains(check.name) ? "App status" : check.name
    }

    private func legacyCheckDetail(_ check: ProfileCheck) -> String {
        ["Agent targets", "Observed targets"].contains(check.name)
            ? "Check Claude Code, Codex, and Gemini CLI on this Mac."
            : check.detail.replacingOccurrences(of: "Run Doctor", with: "Check setup")
    }
}

private struct ProfileInventoryRow: View {
    let kind: String
    let value: String
    var body: some View {
        HStack(spacing: 10) {
            KindTile(kind: kind == "Plugin" ? .plugin : .mcpServer, size: 22)
            Text(value).font(.callout)
            Spacer()
            Text(kind).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

private struct ProfileEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: ToolingProfile
    @State private var name: String
    @State private var summary: String
    @State private var selectedPlugins: Set<String>
    @State private var selectedMCPs: Set<String>
    @State private var scope: ToolingScope
    @State private var projectRoot: String

    init(profile: ToolingProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _summary = State(initialValue: profile.summary)
        _selectedPlugins = State(initialValue: Set(profile.enabledPlugins))
        _selectedMCPs = State(initialValue: Set(profile.requiredMCPs))
        _scope = State(initialValue: profile.scope)
        _projectRoot = State(initialValue: profile.projectRoot ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                KindTile(kind: .profile, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit configuration").font(.title3.weight(.semibold))
                    Text("Only portable settings are included; machine-local secrets stay excluded.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()

            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Configuration name")
                    TextField("Summary", text: $summary, axis: .vertical)
                        .accessibilityLabel("Configuration summary")
                    Picker("Scope", selection: $scope) {
                        ForEach(editableScopes) { scope in Text(scope.displayName).tag(scope) }
                    }
                    .accessibilityLabel("Configuration scope")
                    if scope == .project || scope == .localProject || scope == .workspace {
                        ProjectFolderField(path: $projectRoot)
                    }
                }
                Section("Plugins") {
                    if sortedPlugins.isEmpty {
                        Text("No installed plugins are available.").foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedPlugins) { plugin in
                            Toggle(plugin.name, isOn: membershipBinding(plugin.id, in: $selectedPlugins))
                                .accessibilityLabel("Enable \(plugin.name)")
                        }
                    }
                }
                Section("Required MCP servers") {
                    if sortedMCPServers.isEmpty {
                        Text("No MCP servers are available.").foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedMCPServers) { server in
                            Toggle(server.name, isOn: membershipBinding(server.id, in: $selectedMCPs))
                                .accessibilityLabel("Require \(server.name)")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button("Save Changes") {
                        if model.updateProfile(
                            id: profile.id, name: name, summary: summary, scope: scope, projectRoot: projectRoot,
                            enabledPlugins: selectedPlugins.sorted(), requiredMCPs: selectedMCPs.sorted())
                        {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil || model.isInteractionLocked)
                }
            }
            .padding(16)
        }
        .frame(width: 720, height: 650)
        .background(AgentTheme.contentBackground)
    }

    private func membershipBinding(_ value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { enabled in
                if enabled { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
            }
        )
    }

    private var editableScopes: [ToolingScope] { [.user, .project, .localProject, .workspace] }

    private var validationMessage: String? {
        do {
            _ = try ConfigurationValidator.validateProfile(name: name, summary: summary, scope: scope, projectRoot: projectRoot)
            _ = try ConfigurationValidator.normalizedDesiredStateIDs(Array(selectedPlugins), kind: "plugin")
            _ = try ConfigurationValidator.normalizedDesiredStateIDs(Array(selectedMCPs), kind: "MCP server")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var sortedPlugins: [Plugin] {
        model.plugins.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var sortedMCPServers: [MCPServer] {
        model.mcpServers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct NewProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let onCreated: (ToolingProfile) -> Void
    @State private var name = ""
    @State private var summary = ""
    @State private var scope: ToolingScope = .user
    @State private var projectRoot = ""
    @State private var inheritedFrom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New configuration").font(.title2.weight(.semibold))
                Text(
                    "Configurations hold desired state by scope. Making one current never writes client files until you review a separate plan."
                ).font(.callout).foregroundStyle(.secondary)
            }
            Form {
                TextField("Name", text: $name)
                    .accessibilityLabel("Configuration name")
                TextField("Summary", text: $summary)
                    .accessibilityLabel("Configuration summary")
                Picker("Scope", selection: $scope) {
                    ForEach(editableScopes) { scope in Text(scope.displayName).tag(scope) }
                }
                .accessibilityLabel("Configuration scope")
                if scope == .project || scope == .localProject || scope == .workspace {
                    ProjectFolderField(path: $projectRoot)
                }
                Picker("Inherit from", selection: $inheritedFrom) {
                    Text("No parent").tag("")
                    ForEach(sortedProfiles) { profile in Text(profile.name).tag(profile.id) }
                }
                .accessibilityLabel("Inherit from configuration")
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
                Button("Create Configuration") {
                    if let profile = model.createProfile(
                        name: name, summary: summary, scope: scope, projectRoot: projectRoot,
                        inheritedFrom: inheritedFrom.isEmpty ? nil : inheritedFrom)
                    {
                        onCreated(profile)
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

    private var editableScopes: [ToolingScope] { [.user, .project, .localProject, .workspace] }

    private var validationMessage: String? {
        do {
            _ = try ConfigurationValidator.validateProfile(name: name, summary: summary, scope: scope, projectRoot: projectRoot)
            if !inheritedFrom.isEmpty, !model.profiles.contains(where: { $0.id == inheritedFrom }) {
                return "Choose an available parent configuration."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var sortedProfiles: [ToolingProfile] {
        model.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct ProjectFolderField: View {
    @Binding var path: String

    var body: some View {
        HStack(spacing: 8) {
            TextField("Project folder", text: $path)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Project folder")
            Button("Choose…", action: chooseFolder)
                .buttonStyle(.bordered)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
        if !path.isEmpty, (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            panel.directoryURL = candidate
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        path = selected.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
