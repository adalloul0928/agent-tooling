import AgentToolingCore
import SwiftUI

/// The draft options a person sets before the first message: the name to
/// suggest, where the saved skill installs, and which apps it is offered to.
///
/// This is the sheet's own state, lifted out of the view so its rules — what a
/// valid project folder is, what the one-line summary says, what the first
/// request carries — can be read and tested on their own. The view still owns
/// the value; nothing here reaches back into it.
struct SkillCreatorOptions: Equatable {
    var proposedName = ""
    var scope: ToolingScope = .user
    var projectRoot = ""
    var targets: Set<ClientKind> = []

    /// A project folder is usable only when it is an absolute path to a real
    /// directory that is not the root and is within the length the library
    /// records. The same test the first-message validation makes.
    var projectFolderIsValid: Bool {
        var isDirectory: ObjCBool = false
        let path = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/")
            && path != "/"
            && path.count <= WorkspaceLibrary.maximumProjectPathLength
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// What the draft will be told about itself, until the person opens
    /// Options to change it: who names the skill, where it is saved, and which
    /// apps are offered it after review. Each fact has its own clause, so "on
    /// this Mac" reads as where the skill goes, not where its name is chosen.
    func summaryText(client: ClientKind) -> String {
        let name = proposedName.isEmpty ? "\(client.rawValue) names the skill." : "The skill is named \(proposedName)."
        // The home scope is "on this Mac" here, as on every other screen.
        let placement = scope == .project ? "in the project folder" : "on this Mac"
        let apps = targets.map(\.rawValue).sorted()
        let offered = apps.isEmpty ? "but not offered to any app yet" : "and offered to \(apps.formatted(.list(type: .and)))"
        return "\(name) After review, it is saved \(placement) \(offered). Change these under Options before the first message."
    }

    /// Why the first message cannot be sent yet, or nil when it can. After a
    /// conversation has started only the length still matters; the options are
    /// fixed once the draft is under way, so they are not re-checked.
    func validationMessage(
        isManagingClient: Bool, client: ClientKind, composerTooLong: Bool, hasConversation: Bool
    ) -> String? {
        if !isManagingClient {
            return "This Mac is not managing \(client.rawValue), so it cannot be asked to write a skill. Turn it on in Choose apps first."
        }
        if composerTooLong {
            return "Shorten the message before sending it."
        }
        if hasConversation { return nil }
        if !proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (try? WorkspaceLibrary.normalizedIdentifier(proposedName)) == nil
        {
            return "The suggested name must use lowercase letters, numbers, and single hyphens."
        }
        if scope == .project, !projectFolderIsValid {
            return "Choose an existing project folder under Options."
        }
        if targets.isEmpty {
            return "Choose at least one app under Options to offer this skill to."
        }
        return nil
    }

    /// The request the first turn carries. Project root travels only when the
    /// scope is a project; the instruction is the composer's text, set by the
    /// caller.
    func makeRequest(id: UUID, client: ClientKind, instruction: String) -> SkillDraftRequest {
        SkillDraftRequest(
            id: id,
            client: client,
            instruction: instruction,
            proposedName: proposedName.isEmpty ? nil : proposedName,
            scope: scope,
            projectRoot: scope == .project ? projectRoot : nil,
            targets: targets.sorted { $0.rawValue < $1.rawValue }
        )
    }
}

/// The one-line reminder of the draft options, on the opening guidance.
struct SkillCreatorOptionsSummary: View {
    let options: SkillCreatorOptions
    let client: ClientKind

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Draft options")
                .font(AgentFont.captionSemibold)
                .foregroundStyle(.secondary)
            Text(options.summaryText(client: client))
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.contentBackground.opacity(Opacity.insetGround), in: RoundedRectangle.control)
    }
}

/// The form that sets the draft options before the first message.
struct SkillCreatorOptionsForm: View {
    @Binding var options: SkillCreatorOptions
    let client: ClientKind
    let enabledClients: [ClientKind]
    let chooseProjectFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            configurationField(title: "Suggested name", detail: "Optional. Leave blank to let \(client.rawValue) choose.") {
                TextField("release-readiness", text: $options.proposedName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Suggested skill name")
            }
            configurationField(title: "Install scope", detail: "The destination, not where \(client.rawValue) runs.") {
                WorkspaceSegmentedPicker("Install scope", selection: $options.scope) {
                    Text(ToolingScope.user.displayName).tag(ToolingScope.user)
                    Text(ToolingScope.project.displayName).tag(ToolingScope.project)
                }
                .labelsHidden()
            }
            if options.scope == .project {
                configurationField(title: "Project folder", detail: "The selected folder must already exist.") {
                    HStack(spacing: Space.md) {
                        TextField("Choose a folder", text: $options.projectRoot)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Project folder")
                        Button("Choose…", action: chooseProjectFolder)
                    }
                }
            }
            configurationField(
                title: "Use after review",
                detail: "The apps offered when you choose where the saved skill is used."
            ) {
                if enabledClients.isEmpty {
                    Label(
                        "This Mac is not managing any apps yet, so there is nowhere to offer the saved skill.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                } else {
                    HStack(spacing: Space.xl) {
                        ForEach(enabledClients, id: \.self) { target in
                            Toggle(isOn: targetBinding(target)) {
                                HStack(spacing: Space.sm) {
                                    ClientBrandIcon(client: target, size: Size.brandMark)
                                        .frame(width: Size.chipHeight, height: Size.chipHeight)
                                    Text(target.rawValue)
                                        .font(AgentFont.caption)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
        .padding(Space.lg)
        .background(AgentTheme.contentBackground.opacity(Opacity.insetGround), in: RoundedRectangle.control)
    }

    private func targetBinding(_ target: ClientKind) -> Binding<Bool> {
        Binding(
            get: { options.targets.contains(target) },
            set: { enabled in
                if enabled {
                    options.targets.insert(target)
                } else {
                    options.targets.remove(target)
                }
            }
        )
    }

    private func configurationField<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(AgentFont.captionSemibold)
            Text(detail)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
            content()
        }
    }
}
