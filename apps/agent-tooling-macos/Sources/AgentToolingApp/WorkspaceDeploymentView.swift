import AgentToolingCore
import AppKit
import SwiftUI

/// What would change in this Mac's apps, what would not and why, and the result
/// of actually doing it. Saving an assignment and installing it are shown as
/// two different things, because they are.
struct WorkspaceDeploymentView: View {
    let session: WorkspaceDeploymentSession
    @State private var refreshID = UUID()
    @State private var isLinking = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Install", context: context) {
                Button("Check again", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .labelStyle(.iconOnly).buttonStyle(.glass).disabled(session.isBusy)
                Button("Install these") { Task { await session.apply() } }
                    .buttonStyle(.glassProminent).tint(AgentTheme.selection)
                    .disabled(!session.canApply)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Install needs attention", message: message)
                    }
                    if !session.results.isEmpty { resultList }
                    if let plan = session.plan {
                        if plan.items.isEmpty && plan.exclusions.isEmpty {
                            ContentUnavailableView("Nothing to install", systemImage: "checkmark.circle",
                                description: Text("Your apps already match what you asked for."))
                        }
                        if !plan.items.isEmpty { pending(plan.items) }
                        if !plan.exclusions.isEmpty { excluded(plan.exclusions) }
                        linkedDestinations
                    } else if session.isBusy {
                        ProgressView("Checking your apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .task(id: refreshID) { await session.prepare() }
        .sheet(isPresented: $isLinking) {
            WorkspaceLinkDestinationSheet(session: session)
        }
    }

    /// Where each app's tools go on this Mac, when that is not the app's own
    /// folder. Registering one moves nothing; it says where a later install
    /// would write.
    private var linkedDestinations: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where these go on this Mac").font(.title3.weight(.semibold))
                Spacer()
                Button("Choose a folder…", systemImage: "folder.badge.plus") { isLinking = true }
                    .buttonStyle(.borderless).disabled(session.isBusy)
            }
            if session.linkedDestinations.isEmpty {
                Text("Everything goes into each app's own folder. You can point one somewhere else — a shared drive, or a folder you keep in step yourself.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Agent Tooling writes only into the folder you named, and only if nothing is already there under that tool's name. Anything already in it is left exactly as it is.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(session.linkedDestinations) { destination in
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(destination.surface.displayName) · \(destination.projectName ?? destination.scope.displayName)")
                                .fontWeight(.medium)
                            Text(destination.path).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                        }
                        Spacer(minLength: 12)
                        Button("Use the app's own folder") {
                            Task { await session.unlinkDestination(destination.id) }
                        }
                        .disabled(session.isBusy)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private var context: String {
        guard let plan = session.plan else { return "Checking what your apps need" }
        if plan.items.isEmpty { return "Your apps match what you asked for" }
        return plan.items.count == 1 ? "1 change ready" : "\(plan.items.count) changes ready"
    }

    private func pending(_ items: [WorkspaceDeploymentItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready to install").font(.title3.weight(.semibold))
            Text("Each app is handled on its own, and nothing else in its folder is touched.")
                .foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 14) {
                    Image(systemName: symbol(item.action))
                        .font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayName).fontWeight(.medium)
                        Text(describe(item)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(item.surface.displayName).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
                Divider()
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private func excluded(_ exclusions: [WorkspaceDeploymentExclusion]) -> some View {
        DisclosureGroup("\(exclusions.count) not being installed") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(exclusions.enumerated()), id: \.offset) { _, exclusion in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(exclusion.reason)).font(.callout).fontWeight(.medium)
                        Text(exclusion.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 10)
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What just happened").font(.title3.weight(.semibold))
            ForEach(session.results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title).fontWeight(.medium)
                    Text(summary(result)).font(.callout)
                        .foregroundStyle(result.failed == 0 ? .secondary : Color.red)
                    ForEach(Array(result.outputs.prefix(3).enumerated()), id: \.offset) { _, output in
                        Text(output).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Divider()
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private func summary(_ result: WorkspaceDeploymentSession.Result) -> String {
        if result.failed == 0 {
            return result.succeeded == 1 ? "1 installed." : "\(result.succeeded) installed."
        }
        return "\(result.succeeded) installed, \(result.failed) could not be. Nothing partial was left behind."
    }

    private func symbol(_ action: WorkspaceDeploymentAction) -> String {
        switch action {
        case .installContent: "arrow.down.circle"
        case .updateContent: "arrow.triangle.2.circlepath"
        case .installNativePackage: "puzzlepiece.extension"
        case .configureManagedConnection: "cable.connector"
        case .removeContent: "trash"
        }
    }

    private func describe(_ item: WorkspaceDeploymentItem) -> String {
        let place = item.scope == .project ? "in this project" : "for your account"
        switch item.action {
        case .installContent: return "Add \(place)"
        case .updateContent(let from, _):
            return from == nil ? "Replace what is there now, \(place)" : "Update to your approved version, \(place)"
        case .installNativePackage: return "Ask its app to install it, \(place)"
        case .configureManagedConnection: return "Set up this connection \(place)"
        case .removeContent:
            return "Remove the copy this app installed, \(place). Anything you changed is left alone."
        }
    }

    private func title(_ reason: WorkspaceDeploymentExclusionReason) -> String {
        switch reason {
        case .missingContent: "No verified copy in your library"
        case .trackedOwnership: "Recorded only"
        case .packageMember: "Comes with its package"
        case .missingNativeRoute: "No install route on this Mac"
        case .unsupportedByAdapter: "This app version cannot do it"
        case .needsAssignmentReview: "Needs review first"
        case .alreadyPresent: "Already there"
        }
    }
}

/// Choosing which destination goes somewhere other than its app's own folder.
private struct WorkspaceLinkDestinationSheet: View {
    let session: WorkspaceDeploymentSession
    @Environment(\.dismiss) private var dismiss
    @State private var client: ClientKind = .codex
    @State private var folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Send an app's tools somewhere else").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text("Agent Tooling normally writes into each app's own folder. Point one somewhere else and it writes there instead — into the folder you name, under each tool's own name.")
                    .foregroundStyle(.secondary)
                Text("Nothing already in that folder is replaced. If a tool's name is already taken there, the install stops and says so rather than writing over it.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("App", selection: $client) {
                    ForEach(ClientKind.allCases) { value in Text(value.rawValue).tag(value) }
                }.frame(maxWidth: 280)
                HStack(spacing: 12) {
                    Button("Choose folder…") { choose() }
                    Text(folder?.path ?? "No folder chosen").foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.padding(20)
            Divider()
            HStack {
                Text("This records where a later install would write. Nothing moves now.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Use this folder") {
                    guard let folder else { return }
                    Task {
                        await session.linkDestination(surface: surface, scope: .user,
                                                      projectID: nil, to: folder)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(folder == nil || session.isBusy)
            }.padding(20)
        }
        .frame(width: 580, height: 420)
        .background(AgentTheme.contentBackground)
    }

    private var surface: TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.standardizedFileURL
    }
}
