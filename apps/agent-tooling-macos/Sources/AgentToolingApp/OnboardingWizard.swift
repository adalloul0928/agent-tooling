import AgentToolingCore
import SwiftUI

extension EnvironmentValues {
    @Entry var startOnboarding: () -> Void = {}
}

/// App-local setup state. Package and client writes remain in the core's
/// digest-bound plan review; this view never edits a client configuration.
struct OnboardingWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarding.completed.v1") private var completed = false
    @State private var step: OnboardingStep = .apps
    @State private var selectedClients: Set<ClientKind> = []
    @State private var selection = OnboardingSelection()
    @State private var inventory = OnboardingInventory(candidates: [])
    @State private var showingScanDetails = false
    @State private var inspectingPlugin: OnboardingCandidate?
    @State private var search = ""
    @State private var scanning = false
    @State private var error: String?
    @State private var preview: OnboardingPreview?
    @State private var completion: OnboardingCompletion?
    @State private var copiedDuringSetup: Set<String> = []
    @State private var showingCopyIssues = false
    @State private var personalCopyCandidate: OnboardingCandidate?
    @State private var repositoryLinkSkill: Skill?
    let onNavigate: (AppSection) -> Void

    init(
        step: OnboardingStep = .apps, selection: OnboardingSelection = .init(),
        preview: OnboardingPreview? = nil, completion: OnboardingCompletion? = nil,
        inventory: OnboardingInventory? = nil,
        onNavigate: @escaping (AppSection) -> Void
    ) {
        _step = State(initialValue: step)
        _selection = State(initialValue: selection)
        _preview = State(initialValue: preview)
        _completion = State(initialValue: completion)
        _inventory = State(initialValue: inventory ?? OnboardingInventory(candidates: []))
        self.onNavigate = onNavigate
    }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.system(size: 27, weight: .semibold))
                Text(step.subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
            if step.isSelection {
                selectionStep
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            switch step {
                            case .apps: appsStep
                            case .review: reviewStep
                            case .ready: readyStep
                            default: EmptyView()
                            }
                        }
                        .padding(.horizontal, 28).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("onboarding-step-top")
                    }.id(step)
                        .onChange(of: model.onboardingCopyIssues) { _, issues in
                            guard step == .review, !issues.isEmpty else { return }
                            showingCopyIssues = false
                            scroll.scrollTo("onboarding-step-top", anchor: .top)
                        }
                }
            }
            if let error, model.onboardingCopyIssues.isEmpty {
                AttentionBanner(title: "Setup needs another look", message: error)
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 700)
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled(scanning || model.isExecutingPlan || model.pendingPlan != nil)
        .onAppear {
            selectedClients = model.enabledClients
            if inventory.candidates.isEmpty { inventory = model.onboardingInventory }
        }
        .onChange(of: step) { _, _ in
            search = ""
            inspectingPlugin = nil
            personalCopyCandidate = nil
        }
        .popover(isPresented: $showingScanDetails) { scanDetails }
        .sheet(item: $repositoryLinkSkill, onDismiss: { refreshInventory() }) { skill in
            SkillRepositoryLinkSheet(skill: skill).environment(model)
        }
        .sheet(item: planBinding, onDismiss: recordCompletedCopies) { plan in
            PlanReviewSheet(
                plan: plan,
                onReviewBlockedCopies: { review in
                    if let preview { model.recordOnboardingBlockedCopies(review, for: preview) }
                }
            ).environment(model)
        }
        .confirmationDialog(
            "Make a personal copy?", isPresented: personalCopyPresented,
            titleVisibility: .visible, presenting: personalCopyCandidate
        ) { candidate in
            Button("Make personal copy") { selection.setPersonalCopy(candidate, enabled: true) }
            Button("Keep source version", role: .cancel) {}
        } message: { candidate in
            Text(
                "You’ll maintain your own version of \(candidate.name). Its original installation stays in place, and source updates won’t change your copy."
            )
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Set up Agent Tooling").font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(step == .ready ? "Setup complete" : "Step \(step.rawValue + 1) of 5 · \(step.label)")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<5) { index in
                    Capsule().fill(index <= step.rawValue ? AgentTheme.blue : Color.secondary.opacity(0.18))
                        .frame(width: 22, height: 4)
                }
            }.accessibilityHidden(true)

        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var appsStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 0) {
                ForEach(Array(ClientKind.allCases.enumerated()), id: \.element) { index, client in
                    if index > 0 { Divider().padding(.leading, 64) }
                    Toggle(isOn: clientBinding(client)) {
                        HStack(spacing: 14) {
                            ClientBrandIcon(client: client, size: 28)
                                .frame(width: 36, height: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(client.rawValue).font(.system(size: 16, weight: .semibold))
                                Text(clientScope(client)).font(.system(size: 14)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(18)
                    .accessibilityLabel("Include \(client.rawValue) in setup")
                }
            }
            .standardPanel(cornerRadius: 14)
            .disabled(scanning)

            VStack(alignment: .leading, spacing: 14) {
                setupExplanation(
                    "Find what you already have", symbol: "magnifyingglass",
                    detail: "Read the selected apps’ local skills, plugins, and MCP configuration.")
                setupExplanation(
                    "Keep plugins together", symbol: "puzzlepiece.extension",
                    detail: "Choose whole plugins first. Their skills and connections come with them.")
                setupExplanation(
                    "Track first, customize when you choose", symbol: "checklist",
                    detail: "Save your setup without moving files. Personal copies are a separate, optional choice.")
            }
            Text("This covers local agent setup. Cloud account connections and desktop-only settings remain in their own apps.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if scanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking the selected apps…").font(.system(size: 14))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var selectionStep: some View {
        let candidates = stepCandidates
        let visible = OnboardingListPolicy.filtered(candidates, search: search)
        let selectedCount = candidates.count { selection.itemIDs.contains($0.id) }
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                InventorySearchField(placeholder: "Search \(step.label.lowercased())", text: $search)
                Button(search.isEmpty ? "Select all" : "Select results") { setCandidates(visible, selected: true) }
                    .disabled(visible.isEmpty)
                Button("Clear") { setCandidates(visible, selected: false) }
                    .disabled(!visible.contains { selection.itemIDs.contains($0.id) })
            }
            .font(.system(size: 13)).buttonStyle(.plain)
            .padding(.horizontal, 28).padding(.bottom, 14)
            HStack(spacing: 8) {
                Text("\(selectedCount) of \(candidates.count) tracked")
                if step == .skills, !selection.copySkillIDs.isEmpty {
                    Text("· \(selection.copySkillIDs.count) personal copies")
                }
                if step == .plugins {
                    let bundled = selectedPluginChildren
                    if !bundled.isEmpty {
                        Text("· Includes \(bundled.count) bundled tools")
                    }
                }
                Spacer()
                if step == .plugins {
                    Button("Scan details", systemImage: "info.circle") { showingScanDetails = true }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(.horizontal, 28).padding(.bottom, 10)
            if visible.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No standalone \(step.label.lowercased()) to add" : "No matches",
                    systemImage: step.symbol,
                    description: Text(search.isEmpty ? "Continue to the next step. You can add more later." : "Try another name.")
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible) { candidate in
                    OnboardingChoiceRow(
                        candidate: candidate,
                        children: inventory.childrenByPluginID[candidate.itemID] ?? [],
                        isSelected: candidateBinding(candidate),
                        onInspect: { inspectingPlugin = candidate },
                        isPersonalCopy: selection.copySkillIDs.contains(candidate.itemID),
                        onMakePersonalCopy: { personalCopyCandidate = candidate },
                        onKeepSource: { selection.setPersonalCopy(candidate, enabled: false) },
                        onLinkRepository: { repositoryLinkSkill = model.skills.first { $0.id == candidate.itemID } }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                    .listRowBackground(AgentTheme.controlBackground)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .background(AgentTheme.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 28).padding(.bottom, 20)
                .id(step)
                .popover(item: $inspectingPlugin) { plugin in
                    pluginContents(plugin)
                }
            }
        }
    }

    private var scanDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What was scanned").font(.system(size: 18, weight: .semibold))
                ForEach(model.visibleTargetObservations) { observation in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(observation.surface.displayName).font(.system(size: 15, weight: .medium))
                        Text(
                            "\(observation.discoveredSkills.count) skills · \(observation.discoveredPlugins.count) plugins · \(observation.discoveredMCPServers.count) MCP servers"
                        )
                        ForEach(observation.notes, id: \.self) { Text($0) }
                        ForEach(observation.configurationPaths, id: \.self) { CompactPathText(path: $0) }
                    }.font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }.padding(22)
        }.frame(width: 440, height: 340)
    }

    private func pluginContents(_ plugin: OnboardingCandidate) -> some View {
        let children = inventory.childrenByPluginID[plugin.itemID] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            Text(plugin.name).font(.system(size: 18, weight: .semibold))
            Text(plugin.itemID).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Text("Included with this plugin").font(.system(size: 14)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(children) { child in
                        Label(child.name, systemImage: symbol(for: child.kind))
                            .font(.system(size: 14))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(22).frame(width: 360, height: min(360, CGFloat(children.count * 32 + 104)))
    }

    private var reviewStep: some View {
        let explicit = (preview?.candidates ?? inventory.candidates).filter { selection.itemIDs.contains($0.id) }
        let rows = OnboardingListPolicy.reviewRows(explicit)
        let bindings = Dictionary(grouping: preview?.targetBindings ?? [], by: { $0.item.id })
        return VStack(alignment: .leading, spacing: 18) {
            if !model.onboardingCopyIssues.isEmpty {
                OnboardingCopyIssuesView(
                    issues: model.onboardingCopyIssues,
                    sourcePaths: copyIssueSourcePaths,
                    isExpanded: $showingCopyIssues,
                    onSkip: skipCopyIssues
                )
                .disabled(model.isInteractionLocked)
            }
            HStack(spacing: 16) {
                Text("Configuration name").font(.system(size: 14, weight: .medium))
                TextField("My setup", text: $selection.configurationName)
                    .textFieldStyle(.roundedBorder).font(.system(size: 15))
                    .accessibilityLabel("Configuration name")
            }
            Text(reviewSummary)
                .font(.system(size: 14, weight: .medium))
            Text(
                "Your existing tools stay in their current apps. Plugins keep their bundled tools and native updates."
            )
            .font(.system(size: 14)).foregroundStyle(.secondary)
            if let preview {
                ForEach(preview.warnings, id: \.self) { warning in
                    Label {
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            LazyVStack(spacing: 0) {
                ForEach(rows) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: symbol(for: candidate.kind)).foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.name).font(.system(size: 15, weight: .medium))
                                if candidate.kind == .plugin {
                                    Text(OnboardingListPolicy.contentsSummary(inventory.childrenByPluginID[candidate.itemID] ?? []))
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                } else if candidate.kind == .skill {
                                    Text(
                                        selection.copySkillIDs.contains(candidate.itemID)
                                            ? "Personal copy requested"
                                            : candidate.disposition == .managed ? "Already in your library" : "Keep source version"
                                    )
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(
                                (bindings[candidate.item.id] ?? []).map {
                                    $0.client.rawValue + ($0.enabled == false ? " (disabled)" : "")
                                }.joined(separator: ", ")
                            )
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if selection.copySkillIDs.contains(candidate.itemID), let path = candidate.sourcePath {
                            HStack(spacing: 6) {
                                Text("Copy from").font(.system(size: 12)).foregroundStyle(.secondary)
                                CompactPathText(path: path)
                            }.padding(.leading, 34)
                        }
                    }.padding(14)
                    Divider().padding(.leading, 48)
                }
            }.standardPanel(cornerRadius: 12)

        }
    }

    @ViewBuilder
    private var readyStep: some View {
        if let completion {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36)).foregroundStyle(AgentTheme.ok)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(completion.configurationName).font(.system(size: 20, weight: .semibold))
                        Text(
                            "\(preview?.candidates.count ?? (completion.managedSkillCount + completion.trackedItemCount)) tools in this configuration"
                        )
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        if max(completion.copiedSkillCount, copiedDuringSetup.count) > 0 {
                            Text("\(max(completion.copiedSkillCount, copiedDuringSetup.count)) new skill copies saved to your library")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }.padding(22).standardPanel(cornerRadius: 14)
                Text(
                    "Your setup is tracked in one place. Existing tools keep their sources and update routes. Any personal copies are maintained separately in your library."
                )
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text("Make it yours").font(.system(size: 18, weight: .semibold))
                VStack(spacing: 0) {
                    nextStep(
                        "Review app changes", detail: "Compare your saved configuration with this Mac.",
                        symbol: "arrow.triangle.2.circlepath", destination: .syncCenter)
                    Divider().padding(.leading, 54)
                    nextStep(
                        "Set up a backup", detail: "Keep a local backup or choose an encrypted sync folder.", symbol: "externaldrive",
                        destination: .settings)
                    Divider().padding(.leading, 54)
                    nextStep(
                        "Find useful skills", detail: "Choose whether to review recent work in Insights.", symbol: "lightbulb",
                        destination: .insights)
                }.standardPanel(cornerRadius: 14)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step == .ready {
                Text("You can run setup again from Settings.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Button("Set up later") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(scanning || model.pendingPlan != nil)
            }
            Spacer()
            if step != .apps && step != .ready {
                Button("Back") {
                    error = nil
                    step = OnboardingStep(rawValue: step.rawValue - 1) ?? .apps
                }.buttonStyle(.glass).disabled(model.isInteractionLocked)
            }
            Button(primaryTitle, action: advance)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    scanning || model.isInteractionLocked
                        || (step == .review && selection.configurationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func advance() {
        error = nil
        switch step {
        case .apps:
            guard model.setOnboardingClients(selectedClients) else {
                error = model.lastError
                return
            }
            scanning = true
            Task { @MainActor in
                let scanned = await model.runDoctor()
                scanning = false
                guard scanned else {
                    error = model.lastError ?? "Couldn’t finish the local scan. Try again."
                    return
                }
                refreshInventory(pruneSelection: true)
                selection.configurationName = OnboardingListPolicy.availableName(
                    selection.configurationName, existing: model.profiles.map(\.name))
                step = .plugins
            }
        case .plugins: step = .skills
        case .skills: step = .connections
        case .connections:
            refreshReview()
            step = .review
        case .review:
            guard var reviewed = preview else {
                refreshReview()
                return
            }
            if selection.configurationName != reviewed.selection.configurationName {
                guard let renamed = model.renameOnboardingPreview(reviewed, to: selection.configurationName) else {
                    error = model.lastError
                    return
                }
                reviewed = renamed
                preview = renamed
            }
            if !copiesComplete {
                if !model.planOnboardingSkillAdoption(reviewed), model.onboardingCopyIssues.isEmpty {
                    error = model.lastError
                }
            } else {
                guard let saved = model.finishOnboarding(reviewed) else {
                    error = model.lastError
                    return
                }
                completion = saved
                completed = true
                step = .ready
            }
        case .ready: navigate(.skills)
        }
    }

    private func refreshInventory(pruneSelection: Bool = false) {
        inventory = model.onboardingInventory
        guard pruneSelection else { return }
        let validIDs = Set(inventory.plugins.map(\.id) + inventory.standaloneSkills.map(\.id) + inventory.standaloneServers.map(\.id))
        selection.itemIDs.formIntersection(validIDs)
        selection.copySkillIDs.formIntersection(Set(inventory.standaloneSkills.filter(\.canCopy).map(\.itemID)))
    }

    private func refreshReview() {
        model.clearOnboardingCopyIssues()
        error = nil
        recordCompletedCopies()
        selection = OnboardingDraftPolicy.afterCopyReview(
            selection, ownedSkillIDs: Set(model.skills.filter(\.owned).map(\.id)),
            adoptedSkillIDs: model.onboardingAdoptedSkillIDs)
        preview = model.previewOnboarding(selection)
        if preview == nil { error = model.lastError }
    }

    private func skipCopyIssues() {
        guard let preview, let remaining = model.skippingOnboardingCopyIssues(preview) else {
            if model.onboardingCopyIssues.isEmpty { error = model.lastError }
            return
        }
        selection = remaining.selection
        self.preview = remaining
        showingCopyIssues = false
        error = nil
        refreshInventory()
    }

    private var copyIssueSourcePaths: [String: String] {
        Dictionary(
            uniqueKeysWithValues: (preview?.candidates ?? []).compactMap { candidate in
                guard candidate.kind == .skill, let path = candidate.sourcePath else { return nil }
                return (candidate.itemID, path)
            })
    }

    private func recordCompletedCopies() {
        if let preview {
            let owned = Set(model.skills.filter(\.owned).map(\.id))
            copiedDuringSetup.formUnion(
                preview.copySkillIDs.filter { originalID in
                    owned.contains(model.onboardingAdoptedSkillIDs[originalID] ?? originalID)
                })
        }
        refreshInventory()
    }

    private var primaryTitle: String {
        switch step {
        case .apps: scanning ? "Checking…" : selectedClients.isEmpty ? "Continue with local library" : "Scan selected apps"
        case .plugins: "Continue to skills"
        case .skills: "Continue to connections"
        case .connections: "Review setup"
        case .review: preview == nil ? "Review setup" : copiesComplete ? "Save setup" : "Review personal copies…"
        case .ready: "Open library"
        }
    }

    private var copiesComplete: Bool {
        guard let preview else { return false }
        let owned = Set(model.skills.filter(\.owned).map(\.id))
        return preview.copySkillIDs.allSatisfy { originalID in
            owned.contains(model.onboardingAdoptedSkillIDs[originalID] ?? originalID)
        }
    }

    private var stepCandidates: [OnboardingCandidate] {
        switch step {
        case .plugins: inventory.plugins
        case .skills: inventory.standaloneSkills
        case .connections: inventory.standaloneServers
        default: []
        }
    }

    private var selectedPluginChildren: [OnboardingCandidate] {
        let selected = Set(inventory.plugins.filter { selection.itemIDs.contains($0.id) }.map(\.itemID))
        return inventory.candidates.filter { !$0.providerPluginIDs.isDisjoint(with: selected) }
    }

    private func setCandidates(_ candidates: [OnboardingCandidate], selected: Bool) {
        for candidate in candidates { setCandidate(candidate, selected: selected) }
    }

    private var planBinding: Binding<OperationPlan?> {
        Binding(get: { model.pendingPlan }, set: { if $0 == nil { model.discardPendingPlan() } })
    }
    private func clientBinding(_ client: ClientKind) -> Binding<Bool> {
        Binding(
            get: { selectedClients.contains(client) },
            set: { value in
                if value { selectedClients.insert(client) } else { selectedClients.remove(client) }
            })
    }
    private func candidateBinding(_ candidate: OnboardingCandidate) -> Binding<Bool> {
        Binding(
            get: { selection.itemIDs.contains(candidate.id) },
            set: { selected in
                setCandidate(candidate, selected: selected)
            })
    }
    private func setCandidate(_ candidate: OnboardingCandidate, selected: Bool) {
        selection.setTracked(candidate, selected: selected)
    }

    private var personalCopyPresented: Binding<Bool> {
        Binding(get: { personalCopyCandidate != nil }, set: { if !$0 { personalCopyCandidate = nil } })
    }

    private var reviewSummary: String {
        guard let preview else { return "Review your selected tools" }
        var counts = ["\(preview.nativeItemCount) tools tracked"]
        let existing = preview.managedSkillCount - preview.copySkillIDs.count
        if existing > 0 { counts.append("\(existing) already in your library") }
        counts.append("\(preview.copySkillIDs.count) personal copies")
        return counts.joined(separator: " · ")
    }
    private func clientScope(_ client: ClientKind) -> String {
        switch client {
        case .codex: "Agent configuration shared by Codex app and CLI"
        case .claude: "Claude Code skills, plugins, and MCP configuration"
        case .gemini: "Gemini CLI extensions and local configuration"
        }
    }
    private func symbol(for kind: ToolingItemKind) -> String {
        switch kind {
        case .skill: "doc.text"
        case .plugin: "puzzlepiece.extension"
        case .mcpServer: "server.rack"
        }
    }
    private func setupExplanation(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 26, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func nextStep(_ title: String, detail: String, symbol: String, destination: AppSection) -> some View {
        Button {
            navigate(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(detail).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
            }.padding(18).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func navigate(_ section: AppSection) {
        dismiss()
        onNavigate(section)
    }
}

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case apps, plugins, skills, connections, review, ready
    var id: Int { rawValue }
    var isSelection: Bool { self == .plugins || self == .skills || self == .connections }
    var symbol: String {
        switch self {
        case .plugins: "puzzlepiece.extension"
        case .connections: "server.rack"
        default: "doc.text"
        }
    }
    var label: String {
        switch self {
        case .apps: "Apps"
        case .plugins: "Plugins"
        case .skills: "Skills"
        case .connections: "Connections"
        case .review: "Review"
        case .ready: "Ready"
        }
    }
    var title: String {
        switch self {
        case .apps: "Find your existing setup"
        case .plugins: "Track your plugins"
        case .skills: "Track your skills"
        case .connections: "Track your connections"
        case .review: "Review your setup"
        case .ready: "Your workspace is ready"
        }
    }
    var subtitle: String {
        switch self {
        case .apps: "Choose the apps you use. We’ll find the tools already configured on this Mac."
        case .plugins: "Select a plugin to track its skills and connections together. Its installer still owns its files and updates."
        case .skills: "Selection keeps the source version. Use a skill’s menu to link its repository or make an optional personal copy."
        case .connections: "Track MCP servers configured outside plugins. Their settings and credentials stay in place."
        case .review: "Check your choices, then save them as a configuration."
        case .ready: "One place to see your setup and review what changes next."
        }
    }
}

enum OnboardingPresentationPolicy {
    static func shouldPresent(completed: Bool, presented: Bool, hasExistingSetup: Bool, anotherPresentationActive: Bool) -> Bool {
        !completed && !presented && !hasExistingSetup && !anotherPresentationActive
    }
}

enum OnboardingDraftPolicy {
    /// Re-reviewing a draft after successful copies should treat those items
    /// as managed skills, while keeping failed or cancelled copies pending.
    static func afterCopyReview(
        _ selection: OnboardingSelection, ownedSkillIDs: Set<String>, adoptedSkillIDs: [String: String] = [:]
    ) -> OnboardingSelection {
        var draft = selection
        for originalID in selection.copySkillIDs {
            let managedID = adoptedSkillIDs[originalID] ?? originalID
            guard ownedSkillIDs.contains(managedID) else { continue }
            draft.copySkillIDs.remove(originalID)
            if draft.itemIDs.remove("skill:\(originalID)") != nil {
                draft.itemIDs.insert("skill:\(managedID)")
            }
        }
        return draft
    }
}
