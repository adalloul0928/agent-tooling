import AgentToolingCore
import AppKit
import SwiftUI

struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    var navigate: ((AppSection) -> Void)?
    @State private var query = ""
    @State private var scope: SkillScope = .all
    @State private var selectedID = ""
    @State private var skillBeingEdited: Skill?
    @State private var codexCreatorPresented = false
    @State private var pendingCodexRequestID: UUID?
    @State private var installAfterCreator: CodexSkillInstallHandoff?
    @State private var displayLimit = Self.pageSize

    private static let pageSize = 12

    init(navigate: ((AppSection) -> Void)? = nil) {
        self.navigate = navigate
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Skills") {
                Button {
                    navigate?(.insights)
                } label: {
                    Label("Find opportunities", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Scans recent work for useful skills, plugins, and MCP servers")
                Button {
                    openCodexCreator()
                } label: {
                    Label("New skill…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isInteractionLocked)
            }

            GeometryReader { proxy in
                HSplitView {
                    collectionPane
                        .frame(
                            minWidth: 340, idealWidth: 410, maxWidth: 500, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                            alignment: .topLeading)
                    detailPane
                        .frame(
                            minWidth: 540, maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                            alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $skillBeingEdited) { skill in
            SkillEditorSheet(existingSkill: skill) { draft in
                if let updated = model.updateSkill(id: skill.id, from: draft) {
                    selectedID = updated.id
                    return true
                }
                return false
            }
            .environment(model)
        }
        .sheet(
            isPresented: $codexCreatorPresented,
            onDismiss: {
                pendingCodexRequestID = nil
                let handoff = installAfterCreator
                installAfterCreator = nil
                DispatchQueue.main.async {
                    if let handoff {
                        model.planInstall(
                            skillID: handoff.skillID,
                            targets: handoff.targets,
                            includeFreshSessionCanary: true
                        )
                    }
                    applyExternalNavigation()
                }
            }
        ) {
            CodexSkillCreatorSheet(pendingRequestID: pendingCodexRequestID) { skill, targets in
                selectedID = skill.id
                installAfterCreator = CodexSkillInstallHandoff(skillID: skill.id, targets: targets)
            }
            .environment(model)
        }
        .onAppear {
            selectFirstVisibleSkillIfNeeded()
            applyExternalNavigation()
        }
        .onChange(of: navigation.revision) { _, _ in applyExternalNavigation() }
        .onChange(of: model.skills) { _, _ in selectFirstVisibleSkillIfNeeded() }
        .onChange(of: visibleSkills.map(\.id)) { _, _ in selectFirstVisibleSkillIfNeeded() }
        .onChange(of: query) { _, _ in displayLimit = Self.pageSize }
        .onChange(of: scope) { _, _ in displayLimit = Self.pageSize }
    }

    private var collectionPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search skills", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search skills")
                Picker("Scope", selection: $scope) {
                    ForEach(SkillScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
                }
                .labelsHidden()
                .accessibilityLabel("Skill scope")
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
            .padding(12)

            if filteredSkills.isEmpty {
                EmptyStateView(
                    symbol: query.isEmpty ? "doc.text" : "doc.text.magnifyingglass",
                    title: emptyStateTitle,
                    message: emptyStateMessage,
                    actionTitle: emptyStateActionTitle,
                    isActionEnabled: !model.skills.isEmpty || !model.isInteractionLocked
                ) {
                    performEmptyStateAction()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(groupedSkills, id: \.0) { group, skills in
                            Section {
                                ForEach(skills) { skill in
                                    Button {
                                        selectedID = skill.id
                                    } label: {
                                        SkillCollectionRow(skill: skill, selected: skill.id == selectedID)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(skill.displayName)
                                    .accessibilityValue(skill.id == selectedID ? "Selected" : "")
                                }
                            } header: {
                                HStack {
                                    Text(group)
                                    Spacer()
                                    Text("\(skills.count)")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 13)
                                .frame(height: 32)
                                .background(AgentTheme.controlBackground.opacity(0.45))
                            }
                        }
                        if visibleSkills.count < filteredSkills.count {
                            Button(showMoreLabel) {
                                displayLimit += Self.pageSize
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AgentTheme.blue)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .accessibilityHint("Loads the next skills")
                        }
                    }
                }
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var detailPane: some View {
        if let skill = selectedSkill {
            SkillDetailView(skill: skill, onEdit: { skillBeingEdited = skill }, onInstall: { model.planInstall(skillID: skill.id) })
        } else {
            EmptyStateView(
                symbol: "doc.text", title: "Select a skill",
                message: "Choose a skill to inspect its triggers, clients, source, and validation history.")
        }
    }

    private var filteredSkills: [Skill] {
        model.skills.filter { skill in
            (scope == .all || skill.owned)
                && (query.isEmpty
                    || [skill.name, skill.displayName, skill.summary, skill.bundle].joined(separator: " ").localizedCaseInsensitiveContains(
                        query))
        }
    }

    private var groupedSkills: [(String, [Skill])] {
        var groups: [String: [Skill]] = [:]
        for skill in visibleSkills {
            groups[groupName(for: skill), default: []].append(skill)
        }
        return groups.map { group, skills in
            (group, skills.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private var selectedSkill: Skill? { model.skills.first { $0.id == selectedID } }

    private var visibleSkills: [Skill] {
        Array(filteredSkills.prefix(displayLimit))
    }

    private var showMoreLabel: String {
        let remaining = filteredSkills.count - visibleSkills.count
        return "Show \(min(Self.pageSize, remaining)) more"
    }

    private func selectFirstVisibleSkillIfNeeded() {
        guard !visibleSkills.contains(where: { $0.id == selectedID }) else { return }
        selectedID = groupedSkills.first?.1.first?.id ?? ""
    }

    private func displayName(for value: String) -> String {
        value.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.capitalized }.joined(separator: " ")
    }

    private func groupName(for skill: Skill) -> String {
        if skill.owned { return "Managed · \(displayName(for: skill.bundle))" }
        if skill.bundle == "Local installation" { return "Standalone" }
        let bundleName =
            skill.bundle.split(separator: "@", maxSplits: 1).first
            .map(String.init) ?? skill.bundle
        return displayName(for: bundleName)
    }

    private var emptyStateTitle: String {
        if !query.isEmpty { return "No matching skills" }
        return model.skills.isEmpty ? "No skills yet" : "No managed skills"
    }

    private var emptyStateMessage: String {
        if !query.isEmpty { return "Try a different search term." }
        return model.skills.isEmpty
            ? "Create a reusable workflow or check setup again to discover installed skills."
            : "Switch to All to browse installed vendor and standalone skills."
    }

    private var emptyStateActionTitle: String {
        if !query.isEmpty { return "Clear Search" }
        return model.skills.isEmpty ? "Create Skill" : "Show All"
    }

    private func performEmptyStateAction() {
        if !query.isEmpty {
            query = ""
        } else if model.skills.isEmpty {
            openCodexCreator()
        } else {
            scope = .all
        }
    }

    private func openCodexCreator(requestID: UUID? = nil) {
        installAfterCreator = nil
        pendingCodexRequestID = requestID
        codexCreatorPresented = true
    }

    private func applyExternalNavigation() {
        if let skillID = navigation.requestedSkillID,
            model.skills.contains(where: { $0.id == skillID })
        {
            scope = .all
            query = ""
            displayLimit = max(Self.pageSize, model.skills.firstIndex(where: { $0.id == skillID }).map { $0 + 1 } ?? Self.pageSize)
            selectedID = skillID
        }
        if !codexCreatorPresented, let requestID = navigation.requestedSkillCreationID {
            navigation.consumeSkillCreationRequest(requestID)
            openCodexCreator(requestID: requestID)
        }
    }
}

private struct CodexSkillInstallHandoff {
    var skillID: String
    var targets: Set<ClientKind>
}

private enum SkillScope: String, CaseIterable, Identifiable {
    case owned = "Managed"
    case all = "All"
    var id: String { rawValue }
}

private struct SkillCollectionRow: View {
    let skill: Skill
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            SymbolTile(symbol: skill.owned ? symbol : "shippingbox", size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if installedClients.isEmpty {
                Text("Not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    ForEach(installedClients) { client in
                        ClientBrandIcon(client: client, size: 14)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Installed in \(installedClients.map(\.rawValue).joined(separator: ", "))")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 66)
        .background {
            if selected { AgentTheme.blue.opacity(0.13) }
        }
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(AgentTheme.blue).frame(width: 3) }
        }
        .contentShape(Rectangle())
    }

    private var installedClients: [ClientKind] {
        skill.clients.filter(\.reportsLocalPresence).map(\.client)
    }

    private var symbol: String {
        switch skill.name {
        case "sync-agent-tooling": "arrow.triangle.2.circlepath"
        case "skill-forge": "doc.badge.plus"
        case "mcp-preflight": "network"
        case "worktree-bootstrap": "folder"
        case "workflow-sync-test": "checkmark"
        case "obsidian-vault": "square.and.pencil"
        default: "doc.text"
        }
    }
}

private struct SkillDetailView: View {
    @Environment(AppModel.self) private var model
    let skill: Skill
    let onEdit: () -> Void
    let onInstall: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 13) {
                    SymbolTile(symbol: "doc.text", size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.displayName).font(.title2.weight(.semibold))
                        Text(skill.owned ? "Managed by Agent Tooling" : skill.bundle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if skill.owned, skill.authoringOrigin != .codexGenerated {
                        Button("Edit…", systemImage: "pencil", action: onEdit)
                            .buttonStyle(.bordered)
                            .disabled(model.isInteractionLocked)
                    }
                    if skill.owned {
                        Button("Review Install…", systemImage: "arrow.down.circle") { onInstall() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isInteractionLocked)
                    }
                }

                Text(skill.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                GroupBox("Availability") { ClientStatusRows(clients: skill.clients) }

                if !skill.triggers.isEmpty || !skill.negativeTrigger.isEmpty {
                    GroupBox("When it appears") {
                        VStack(spacing: 0) {
                            if !skill.triggers.isEmpty {
                                LabeledValueRow("Triggers") {
                                    VStack(alignment: .trailing, spacing: 5) {
                                        ForEach(skill.triggers, id: \.self) { trigger in
                                            Text(trigger)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            if !skill.triggers.isEmpty && !skill.negativeTrigger.isEmpty { Divider() }
                            if !skill.negativeTrigger.isEmpty {
                                LabeledValueRow("Doesn’t appear for") {
                                    Text(skill.negativeTrigger).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                GroupBox("Source") {
                    VStack(spacing: 0) {
                        LabeledValueRow("Bundle") { Text(skill.bundle).fontWeight(.medium) }
                        Divider()
                        ForEach(skill.files, id: \.self) { file in
                            LabeledValueRow(file.hasSuffix("SKILL.md") ? "Definition" : "Bundled file") {
                                CompactPathText(path: file)
                            }
                            if file != skill.files.last { Divider() }
                        }
                    }
                }

                GroupBox("Verification") {
                    HStack {
                        Image(systemName: skill.validationCount > 0 ? "checkmark.seal" : "hourglass")
                            .foregroundStyle(.secondary)
                        Text(
                            skill.validationCount > 0
                                ? "\(skill.validationCount) definition check\(skill.validationCount == 1 ? "" : "s") passed"
                                : "This installed source has not been validated by the managed-library checker."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(5)
                }

                if skill.owned {
                    Button("Reveal Source in Finder", systemImage: "folder") {
                        let source = URL(fileURLWithPath: model.workspacePath)
                            .appending(path: "library/packages/\(skill.bundle)/skills/\(skill.id)", directoryHint: .isDirectory)
                        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                            model.presentError(
                                "The managed source for \(skill.displayName) is no longer available. Check setup again to refresh local state."
                            )
                            return
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([source])
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Reveal \(skill.displayName) source in Finder")
                    .disabled(model.isInteractionLocked)
                }
            }
            .padding(22)
        }
    }
}

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = cursorX == 0 ? size.width : cursorX + spacing + size.width
            if cursorX > 0, nextWidth > maximumWidth {
                cursorY += rowHeight + spacing
                cursorX = size.width
                rowHeight = size.height
            } else {
                cursorX = nextWidth
                rowHeight = max(rowHeight, size.height)
            }
            measuredWidth = max(measuredWidth, cursorX)
        }
        return CGSize(width: proposal.width.map { min($0, measuredWidth) } ?? measuredWidth, height: cursorY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: cursorX, y: cursorY), anchor: .topLeading, proposal: .unspecified)
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
