import AgentToolingCore
import SwiftUI

/// Where a skill's next version would come from, beside the skill itself.
///
/// Checking a repository reads it and says what it found. Nothing in this
/// library changes until the separate review action is taken, and a skill whose
/// updates belong to somebody else says so rather than offering a button that
/// would do nothing.
struct SkillRepositorySection: View {
    let skill: SkillEntry
    let binding: SkillRepositoryBinding?
    let approvedRevision: SourceRevision?
    let authoringPath: String?
    let session: SkillContentSession
    /// The one store and the one service linking writes through. Following a
    /// repository is a command no session on this screen exposes.
    let workspace: WorkspaceLaunch.Workspace

    @Environment(\.skillUpstreamLinker) private var linker
    @State private var linking: SkillUpstreamLinkSession?

    var body: some View {
        GroupBox("Updates") {
            VStack(alignment: .leading, spacing: 12) {
                switch skill.ownership {
                case .centralUpstream: upstream
                case .attachedAuthoring: attached
                case .centralPersonal: personal
                case .nativeOwned, .trackedOnly: elsewhere
                }
                if session.isBusy, skill.ownership == .centralUpstream {
                    ProgressView("Checking repository…").controlSize(.small)
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $linking) { SkillUpstreamLinkSheet(skill: skill, session: $0) }
    }

    @ViewBuilder private var upstream: some View {
        Label("Following a repository", systemImage: "arrow.triangle.branch")
            .font(.system(size: 14, weight: .medium))
        if let binding {
            if let url = URL(string: binding.repositoryURL) {
                Link(binding.repositoryURL, destination: url)
                    .font(.system(size: 13)).lineLimit(2).truncationMode(.middle)
            }
            Text("\(binding.ref) · \(binding.subdirectory.isEmpty ? "Repository root" : binding.subdirectory)")
                .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            if let approvedRevision {
                Text("Approved at \(approvedRevision.value.prefix(12))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let status = session.upstreamStatus {
                Text(status.title).font(.system(size: 14, weight: .medium))
                Text(status.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Checked \(status.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("This library has not asked the repository what it publishes now.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = session.errorMessage {
                Text(message)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Check for updates", systemImage: "arrow.clockwise") {
                    Task { await session.checkUpstream(for: skill, binding: binding) }
                }
                .buttonStyle(.glass)
                if session.upstreamStatus?.isUpToDate == false {
                    Button("Review update…", systemImage: "arrow.down.circle") {
                        Task { await session.applyUpstream(for: skill) }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(AgentTheme.selection)
                    .disabled(!session.canWrite)
                }
                Spacer(minLength: 0)
            }
            .disabled(session.isBusy)
        } else {
            Text(
                "This skill follows a repository, but this workspace no longer records which one. Nothing can be checked until that is repaired."
            )
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var attached: some View {
        Label("You author this folder", systemImage: "folder.badge.gearshape")
            .font(.system(size: 14, weight: .medium))
        Text("Your own folder is the only copy. Nothing here updates it, and nothing writes into it.")
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let authoringPath {
            LocationText(path: authoringPath)
        }
    }

    /// A skill this library holds can also start following the repository that
    /// publishes it — but only while the version here is that repository's
    /// version, so the approved lock never describes bytes nobody has. A skill
    /// with local edits is told so rather than being offered a button that
    /// would refuse, and its edits are never touched.
    @ViewBuilder private var personal: some View {
        Label("Maintained in this library", systemImage: "books.vertical")
            .font(.system(size: 14, weight: .medium))
        Text("You hold this skill's source. Edit it here, then review where the change should be used.")
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if skill.hasCentralContent {
            HStack {
                Button("Follow a repository…", systemImage: "arrow.triangle.branch") {
                    linking = SkillUpstreamLinkSession(workspace: workspace, linker: linker)
                }
                .buttonStyle(.glass)
                .disabled(workspace.library.isBusy || workspace.library.access != .writable)
                .help("Records where this skill's next version comes from. Nothing is installed and nothing is fetched until you ask.")
                Spacer(minLength: 0)
            }
        } else {
            Text(LinkSkillUpstreamRefusal.missingContent.reason)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var elsewhere: some View {
        if let plugin = skill.parentPluginLabel {
            Label("Updates with its plugin", systemImage: "puzzlepiece.extension")
                .font(.system(size: 14, weight: .medium))
            Text("This skill stays with \(plugin). Manage the whole plugin in Library → Plugins.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Source unknown", systemImage: "questionmark.folder")
                .font(.system(size: 14, weight: .medium))
            Text(
                "This skill stays in the app it was found in. This workspace has no way to record a repository for a skill it does not hold, so there is nothing to check for updates."
            )
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The repository a followed skill was approved from, read back out of the
/// workspace rather than kept anywhere else.
enum SkillUpstreamBinding {
    struct Resolved {
        let binding: SkillRepositoryBinding
        let approvedRevision: SourceRevision
    }

    /// Nil for anything that is not following a repository, and for a followed
    /// skill whose recorded source no longer describes a repository this build
    /// would fetch — a binding that cannot be validated is not offered.
    static func resolve(_ skill: SkillEntry, in document: PortableWorkspaceDocument?) -> Resolved? {
        guard case .centralUpstream(let subscriptionID)? = skill.authority, let document else { return nil }
        guard let subscription = document.subscriptions.first(where: { $0.id == subscriptionID }),
            let source = document.sources.first(where: { $0.id == subscription.sourceID }),
            let repositoryURL = source.repositoryURL,
            let binding = try? SkillRepositoryBinding(
                repositoryURL: repositoryURL, ref: subscription.lock.requestedRef,
                subdirectory: subscription.lock.packageRelativePath == "." ? "" : subscription.lock.packageRelativePath)
        else { return nil }
        return Resolved(binding: binding, approvedRevision: subscription.lock.approvedRevision)
    }
}
