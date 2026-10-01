import AgentToolingCore
import AppKit
import SwiftUI

struct SkillDetailView: View {
    @Environment(AppNavigationState.self) private var navigation: AppNavigationState?
    @Environment(\.skillTrialOpening) private var trialOpening
    /// The client being opened in Terminal right now, if any.
    @State private var openingTrialIn: ClientKind?
    /// What the last try opened, or why it could not.
    @State private var trialNotice: TrialNotice?
    let skill: SkillEntry
    let workspace: WorkspaceLaunch.Workspace
    let content: SkillContentSession
    let inventory: SkillInventoryIndex
    let availableClients: [ClientKind]
    let onEditSource: () -> Void
    let onAssign: () -> Void
    let onExport: () -> Void
    let onOpenPlugin: (ArtifactID) -> Void

    private var upstream: SkillUpstreamBinding.Resolved? {
        SkillUpstreamBinding.resolve(skill, in: workspace.library.state?.snapshot.document)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                heading
                actions
                if let explanation = skill.assignmentExplanation {
                    Text(explanation)
                        .font(AgentFont.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary).font(AgentFont.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SkillRepositorySection(
                    skill: skill, binding: upstream?.binding, approvedRevision: upstream?.approvedRevision,
                    authoringPath: inventory.authoringPaths[skill.id], session: content, workspace: workspace)
                apps
                sourceFiles
            }
            .padding(Space.xxxl)
        }
    }

    private var heading: some View {
        HStack(spacing: Space.lg) {
            KindTile(kind: .skill, size: Size.tileLarge, ghost: !skill.isMaintainedHere)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(skill.displayName).font(AgentFont.pageTitle)
                HStack(spacing: Space.sm) {
                    Text(managementBadge)
                        .font(AgentFont.microMedium)
                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
                        .background(.quaternary, in: Capsule())
                    SkillInfoButton(text: managementNote, label: "About management")
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Who manages this skill, in the words the Managed column uses.
    private var managementBadge: String {
        switch skill.ownership {
        case .centralPersonal: "Yours"
        case .centralUpstream: "Yours · repository"
        case .attachedAuthoring: "Yours · linked folder"
        case .nativeOwned: skill.parentID == nil ? "Its app" : "Plugin"
        case .trackedOnly: "Unmanaged"
        }
    }

    private var managementNote: String {
        switch skill.ownership {
        case .centralPersonal, .centralUpstream, .attachedAuthoring:
            "The source is yours. Save an edit here, then review where the change should be used."
        case .nativeOwned:
            SkillManagement.byPlugin.explanation
        case .trackedOnly:
            SkillManagement.notByThisApp.explanation
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Space.md) {
            if skill.ownership == .centralPersonal, skill.hasCentralContent {
                Button("Edit Source…", systemImage: "doc.text", action: onEditSource)
                    .secondaryActionStyle()
                    .disabled(content.isBusy || !content.canWrite)
                    .accessibilityHint("Edits the complete SKILL.md while preserving scripts, references, and assets")
            }
            if skill.isAssignable {
                Button("Choose where to use it…", systemImage: "arrow.turn.up.right", action: onAssign)
                    .primaryActionStyle()
                    .disabled(workspace.library.isBusy || workspace.library.access != .writable)
                    .accessibilityHint("Saves where this skill should be used. Installing is reviewed on the Apps screen")
            }
            if skill.hasCentralContent {
                Button("Export…", systemImage: "square.and.arrow.up", action: onExport)
                    .secondaryActionStyle()
            }
            if skill.ownership == .attachedAuthoring {
                Button("Stop managing this folder", systemImage: "folder.badge.minus") {
                    Task { await workspace.authoring.detach(skill.id, named: skill.displayName) }
                }
                .secondaryActionStyle()
                .disabled(workspace.authoring.isBusy || !workspace.authoring.canWrite)
                .help("Removes the registration. Nothing in the folder is changed.")
            }
            if let parent = skill.parentID {
                Button("Show plugin", systemImage: "puzzlepiece.extension") { onOpenPlugin(parent) }
                    .secondaryActionStyle()
            }
        }
    }

    private var apps: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(availableClients.enumerated()), id: \.element) { index, client in
                    HStack(spacing: Space.lg) {
                        ClientBrandIcon(client: client, size: Size.tileSmall).frame(width: Size.tile)
                        Text(client.rawValue).font(AgentFont.bodyMedium)
                        Spacer()
                        // A verdict only where there is one. "This app does not
                        // have it" is the ordinary case for most skills, so it
                        // gets a word rather than a mark that reads as a fault.
                        if let state = state(for: client) {
                            StatusBadge(state: state, text: detail(for: client))
                        } else {
                            Text(detail(for: client)).font(AgentFont.caption).foregroundStyle(.secondary)
                        }
                        tryButton(for: client)
                    }
                    .padding(.horizontal, Space.sm).padding(.vertical, Space.md)
                    if index < availableClients.count - 1 { Hairline() }
                }
                if let trialNotice {
                    Hairline()
                    HStack(spacing: Space.md) {
                        Image(systemName: trialNotice.isError ? "exclamationmark.triangle" : "terminal")
                            .foregroundStyle(trialNotice.isError ? Color.red : Color.secondary)
                        Text(trialNotice.text)
                            .font(AgentFont.caption)
                            .foregroundStyle(trialNotice.isError ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { self.trialNotice = nil }
                            .inlineActionStyle().font(AgentFont.caption)
                    }
                    .padding(.horizontal, Space.sm).padding(.vertical, Space.md)
                }
                if navigation != nil, availableClients.contains(where: isAskedForButAbsent) {
                    Hairline()
                    HStack(spacing: Space.lg) {
                        Text("Asked for, but not installed yet.")
                            .font(AgentFont.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Install…", systemImage: "arrow.down.circle") {
                            navigation?.openScreenRequest(.reviewChanges)
                        }
                        .primaryActionStyle()
                        .accessibilityLabel("Install this skill from the Apps screen")
                    }
                    .padding(.horizontal, Space.sm).padding(.vertical, Space.md)
                }
                if availableClients.isEmpty {
                    Text("This Mac is not managing any apps.")
                        .font(AgentFont.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.sm)
                }
            }
            .padding(Space.sm)
        } label: {
            HStack(spacing: Space.sm) {
                Text("Apps")
                SkillInfoButton(
                    text:
                        "Found means the last check of this Mac saw this skill in that app. Asked for means somebody saved that choice here; installing it is a separate, reviewed step on the Apps screen. Try opens Terminal with that app running and the skill invoked, so you can see what it does.",
                    label: "About app availability")
            }
        }
    }

    // MARK: - Trying the skill

    /// Opens Terminal with `client` running and this skill invoked as its
    /// first message. Offered only where the last check found the skill: a
    /// client that does not have it would only say so.
    @ViewBuilder private func tryButton(for client: ClientKind) -> some View {
        let reason = cannotTryReason(in: client)
        Button {
            guard let name = skill.declaredName else { return }
            openingTrialIn = client
            trialNotice = nil
            let opening = trialOpening(workspace)
            Task { @MainActor in
                defer { openingTrialIn = nil }
                do {
                    let launch = try await opening.tryOut(skillName: name, in: client)
                    trialNotice = TrialNotice(
                        text: "Opened Terminal running \(launch.commandLine). Nothing here changed.", isError: false)
                } catch {
                    trialNotice = TrialNotice(
                        text: (error as? any LocalizedError)?.errorDescription ?? "Terminal could not be opened.",
                        isError: true)
                }
            }
        } label: {
            if openingTrialIn == client {
                ProgressView().controlSize(.mini)
            } else {
                Label("Try…", systemImage: "terminal")
            }
        }
        .secondaryActionStyle()
        .controlSize(.small)
        .disabled(reason != nil || openingTrialIn != nil)
        .help(reason ?? tryHelp(for: client))
        .accessibilityLabel("Try this skill in \(client.rawValue)")
        .accessibilityHint(reason ?? tryHelp(for: client))
    }

    private func tryHelp(for client: ClientKind) -> String {
        let invocation = skill.declaredName.flatMap { SkillTrialCommandShapes.invocationText(for: client, skillName: $0) }
        return "Opens Terminal running \(client.rawValue) with \(invocation ?? "this skill") as the first message."
    }

    /// Why this skill cannot be tried in `client` right now, or nil when it can.
    private func cannotTryReason(in client: ClientKind) -> String? {
        guard SkillTrialCommandShapes.isSupported(client) else {
            return "Trying a skill in \(client.rawValue) from here is not supported yet."
        }
        guard let name = skill.declaredName, SkillTrialCommandShapes.isValidSkillReference(name) else {
            return "This skill has no name a client could call."
        }
        guard inventory.observedClients[skill.id]?.contains(client) == true else {
            return skill.requestedClients.contains(client)
                ? "Install it in \(client.rawValue) first; the last check did not find it there."
                : "The last check did not find this skill in \(client.rawValue)."
        }
        guard trialOpening(workspace).canTry(in: client) else {
            return "\(client.rawValue)'s command-line tool was not found on this Mac."
        }
        return nil
    }

    private struct TrialNotice: Equatable {
        let text: String
        let isError: Bool
    }

    /// Found beats asked for: what is actually there is the stronger claim, and
    /// the two are never blended into one word. Nil is neither — an app that
    /// simply does not have this skill is not a problem to be flagged.
    private func state(for client: ClientKind) -> HealthState? {
        if inventory.observedClients[skill.id]?.contains(client) == true { return .healthy }
        return skill.requestedClients.contains(client) ? .pending : nil
    }

    private func isAskedForButAbsent(_ client: ClientKind) -> Bool {
        inventory.observedClients[skill.id]?.contains(client) != true && skill.requestedClients.contains(client)
    }

    private func detail(for client: ClientKind) -> String {
        let found = inventory.observedClients[skill.id]?.contains(client) == true
        let asked = skill.requestedClients.contains(client)
        switch (found, asked) {
        case (true, true): return "Found · asked for"
        case (true, false): return "Found here"
        case (false, true): return "Asked for, not found"
        case (false, false): return workspace.device.observations.isEmpty ? "Not checked yet" : "Not here"
        }
    }

    @ViewBuilder private var sourceFiles: some View {
        if content.isLoading {
            ProgressView("Reading the stored files…").controlSize(.small)
        } else if skill.hasCentralContent, content.loadedID != skill.id, let message = content.errorMessage {
            Text(message).font(AgentFont.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if content.loadedID == skill.id, !content.files.isEmpty {
            DisclosureGroup("Source files") {
                VStack(spacing: 0) {
                    ForEach(content.files, id: \.self) { file in
                        LabeledValueRow(file == "SKILL.md" ? "Definition" : "Bundled file") {
                            Text(file).font(AgentFont.mono)
                        }
                        if file != content.files.last { Hairline() }
                    }
                }
            }
        } else if let path = inventory.authoringPaths[skill.id] ?? inventory.observedPaths[skill.id] {
            LabeledValueRow(skill.ownership == .attachedAuthoring ? "Your folder" : "Found at") {
                LocationText(path: path)
            }
            .standardPanel()
        }
    }
}

struct SkillInfoButton: View {
    let text: String
    let label: String
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(text)
        .popover(isPresented: $presented) {
            Text(text).font(AgentFont.body).padding(Space.xl).frame(width: 290, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
