import AgentToolingCore
import SwiftUI

/// Source maintenance belongs beside the skill's installation controls. Linking
/// a source records provenance; only the separate review action changes files.
struct SkillRepositorySection: View {
    @Environment(AppModel.self) private var model
    let skill: Skill
    @State private var showingLink = false
    @State private var showingUnlink = false

    var body: some View {
        GroupBox("Updates") {
            VStack(alignment: .leading, spacing: 12) {
                if let pluginID = model.skillPluginID(skill.id) {
                    Label("Updates with its plugin", systemImage: "puzzlepiece.extension")
                        .font(.system(size: 14, weight: .medium))
                    Text(
                        "This skill stays with \(model.plugins.first(where: { $0.id == pluginID })?.name ?? ConnectionSource(pluginID).pluginTitle ?? pluginID). Manage the whole plugin in Library → Plugins."
                    )
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                } else if let binding = skill.repositoryBinding {
                    Label("Following repository", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .medium))
                    if let url = URL(string: binding.repositoryURL) {
                        Link(binding.repositoryURL, destination: url)
                            .font(.system(size: 13)).lineLimit(2).truncationMode(.middle)
                    }
                    Text("\(binding.ref) · \(binding.subdirectory.isEmpty ? "Repository root" : binding.subdirectory)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    let availability = model.skillRepositoryUpdateAvailability(skill.id)
                    Text(availability.title).font(.system(size: 14, weight: .medium))
                    Text(availability.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let checked = binding.lastCheckedAt {
                        Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Check for updates", systemImage: "arrow.clockwise") {
                            Task { await model.checkSkillRepositoryUpdate(skillID: skill.id) }
                        }.buttonStyle(.glass)
                        if !availability.isUpToDate {
                            Button("Review update…", systemImage: "arrow.down.circle") {
                                Task { await model.planSkillRepositoryUpdate(skillID: skill.id) }
                            }.buttonStyle(.glassProminent)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button("Stop following repository", role: .destructive) { showingUnlink = true }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("Repository actions")
                    }.disabled(model.isInteractionLocked)
                } else {
                    Label("Source unknown", systemImage: "questionmark.folder")
                        .font(.system(size: 14, weight: .medium))
                    Text(
                        "This skill stays in its current app. Link its public GitHub repository to check for updates and review changes before installing them."
                    )
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Link repository…", systemImage: "link") { showingLink = true }
                        .buttonStyle(.glass).disabled(model.isInteractionLocked)
                }
                if model.isCheckingSkillRepository {
                    ProgressView("Checking repository…").controlSize(.small)
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingLink) {
            SkillRepositoryLinkSheet(skill: skill).environment(model)
        }
        .confirmationDialog("Stop following this repository?", isPresented: $showingUnlink, titleVisibility: .visible) {
            Button("Stop following", role: .destructive) { _ = model.unlinkSkillRepository(skillID: skill.id) }
        } message: {
            Text("The skill stays installed. Its repository link and update history will be removed.")
        }
    }
}

struct SkillRepositoryLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let skill: Skill
    @State private var repositoryURL = ""
    @State private var reference = "HEAD"
    @State private var subdirectory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Link original repository", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 22, weight: .semibold))
                Text("Keep \(skill.displayName) connected to its public GitHub source.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                field("Repository URL", placeholder: "https://github.com/owner/repository", value: $repositoryURL)
                field("Branch, tag, or commit", placeholder: "HEAD", value: $reference)
                field("Skill folder in repository", placeholder: "skills/example-skill", value: $subdirectory)
                Text(
                    "Use the folder containing SKILL.md. Leave it empty if SKILL.md is at the repository root. HEAD follows the default branch."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(
                "Linking records the source and your current files. It does not replace them or create a personal copy. Check and review updates separately."
            )
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if model.isCheckingSkillRepository { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    .disabled(model.isCheckingSkillRepository)
                Button("Link repository") {
                    Task {
                        if await model.linkSkillRepository(
                            skillID: skill.id, repositoryURL: repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            ref: reference.trimmingCharacters(in: .whitespacesAndNewlines),
                            subdirectory: subdirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                        ) {
                            dismiss()
                        }
                    }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.isInteractionLocked || repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 550).background(AgentTheme.contentBackground)
    }

    private func field(_ title: String, placeholder: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder).font(.system(size: 14))
                .accessibilityLabel(title).disabled(model.isCheckingSkillRepository)
        }
    }
}
