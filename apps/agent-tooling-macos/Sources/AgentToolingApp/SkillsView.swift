import AgentToolingCore
import AppKit
import SwiftUI

struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var scope: SkillScope = .all
    @State private var selectedID = ""
    @State private var editorMode: SkillEditorMode?

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Skills") {
                Button {
                    editorMode = .new
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
        .sheet(item: $editorMode) { mode in
            SkillEditorSheet(mode: mode, existingSkill: mode == .edit ? selectedSkill : nil) { draft in
                if mode == .new {
                    if let created = model.createSkill(from: draft) {
                        selectedID = created.id
                        return true
                    }
                } else if let selectedSkill, let updated = model.updateSkill(id: selectedSkill.id, from: draft) {
                    selectedID = updated.id
                    return true
                }
                return false
            }
            .environment(model)
        }
        .onAppear { selectFirstVisibleSkillIfNeeded() }
        .onChange(of: model.skills) { _, _ in selectFirstVisibleSkillIfNeeded() }
        .onChange(of: filteredSkills.map(\.id)) { _, _ in selectFirstVisibleSkillIfNeeded() }
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
                    }
                }
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var detailPane: some View {
        if let skill = selectedSkill {
            SkillDetailView(skill: skill, onEdit: { editorMode = .edit }, onInstall: { model.planInstall(skillID: skill.id) })
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
        for skill in filteredSkills {
            groups[groupName(for: skill), default: []].append(skill)
        }
        return groups.map { group, skills in
            (group, skills.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private var selectedSkill: Skill? { model.skills.first { $0.id == selectedID } }

    private func selectFirstVisibleSkillIfNeeded() {
        guard !filteredSkills.contains(where: { $0.id == selectedID }) else { return }
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
            editorMode = .new
        } else {
            scope = .all
        }
    }
}

private enum SkillScope: String, CaseIterable, Identifiable {
    case owned = "Managed"
    case all = "All"
    var id: String { rawValue }
}

enum SkillEditorMode: String, Identifiable {
    case new
    case edit
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
            Text(availability)
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    private var availability: String {
        guard !skill.clients.isEmpty else { return "Not installed" }
        return "\(skill.clients.filter(\.reportsLocalPresence).count) of \(skill.clients.count)"
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
                    if skill.owned {
                        Button("Edit…", systemImage: "pencil", action: onEdit)
                            .buttonStyle(.bordered)
                            .disabled(model.isInteractionLocked)
                        Button("Review Install…", systemImage: "arrow.down.circle") { onInstall() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isInteractionLocked)
                    }
                }

                Text(skill.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                GroupBox("Availability") { ClientStatusRows(clients: skill.clients) }

                GroupBox("When it appears") {
                    VStack(spacing: 0) {
                        LabeledValueRow("Triggers") {
                            if skill.triggers.isEmpty {
                                Text("Not inferred from this installed source").foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .trailing, spacing: 5) {
                                    ForEach(skill.triggers, id: \.self) { trigger in
                                        Text(trigger)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Divider()
                        LabeledValueRow("Doesn’t appear for") {
                            Text(skill.negativeTrigger.isEmpty ? "Not provided" : skill.negativeTrigger)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("Source") {
                    VStack(spacing: 0) {
                        LabeledValueRow("Bundle") { Text(skill.bundle).fontWeight(.medium) }
                        Divider()
                        ForEach(skill.files, id: \.self) { file in
                            LabeledValueRow(file.hasSuffix("SKILL.md") ? "Definition" : "Bundled file") {
                                Text(file).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
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
