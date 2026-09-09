import AgentToolingCore
import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var reviewWorkspaceMigration: () -> Void = {}
}

struct WorkspaceMigrationSetupView: View {
    let session: WorkspaceMigrationSetupSession
    let onCancel: () -> Void
    let onAuthorityChanged: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let review = session.reviewSession {
                WorkspaceMigrationReviewView(session: review,
                    onOpenLibrary: onAuthorityChanged, onReturnToLegacy: onAuthorityChanged)
                if let error = session.errorMessage {
                    Text(error).foregroundStyle(.secondary).padding()
                }
                if review.state?.authoritySelection == nil, review.committedSelection == nil {
                    Divider()
                    HStack {
                        Button("Return to existing workspace", action: onCancel)
                            .disabled(review.isBusy || review.pendingSelection != nil)
                        Spacer()
                    }.padding()
                }
            } else {
                PageToolbar(title: "Review your library", context: "Prepare for central library management") {}
                Divider()
                if session.isBusy {
                    ProgressView("Checking your existing tools and their sources…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    contents
                }
                Divider()
                HStack {
                    Button("Cancel", action: onCancel).disabled(session.isBusy)
                    Spacer()
                    if session.preview != nil {
                        Button("Check again") { Task { await session.inspect() } }.disabled(session.isBusy)
                    }
                    Button("Save migration review") { Task { await session.stage() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy || session.hasUnconfirmedProjectChanges || session.hasUnresolvedNativePlacements
                            || session.preview?.canPrepare != true || session.intake?.issues.isEmpty != true)
                }.padding(20)
            }
        }
        .frame(width: 920, height: 700)
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled()
        .task { if session.preview == nil { await session.inspect() } }
    }

    private var contents: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep each tool connected to its source")
                        .font(.title2.weight(.semibold))
                    Text("Owned skills move into the central library. Verified upstream skills keep their update information. Plugins stay together in their apps. Managed connections keep their current setup, and other tools remain tracked.")
                        .font(.body).foregroundStyle(.secondary)
                    Text("This check reads your current setup. Saving a review prepares a separate workspace; you choose when to switch.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = session.errorMessage {
                    AttentionBanner(title: "Review needs attention", message: error)
                }
                if session.upstreamIntake?.requirements.isEmpty == false {
                    upstreamFolders
                }
                if session.projectIntake?.requirements.isEmpty == false {
                    projectMappings
                }
                if session.nativePlacementIntake?.requirements.isEmpty == false {
                    nativePlacements
                }
                if !remainingIntakeIssues.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Source details needed").font(.headline)
                        Text("This preview cannot migrate these source or placement records yet. Keep using your existing workspace while those mappings are added; no tools will be omitted.")
                            .foregroundStyle(.secondary)
                        ForEach(Array(remainingIntakeIssues.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.displayName).fontWeight(.medium)
                                Text(explanation(issue)).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                }
                if let preview = session.preview {
                    if !preview.items.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Text("Your tools").font(.headline)
                            if session.managedConnections?.resolutions.isEmpty == false {
                                Text("Connection addresses, commands, and credential requirements stay on this Mac. No connections are started or reconfigured.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(preview.items.filter { $0.parentLegacy == nil }, id: \.artifactID) { item in
                                HStack(spacing: 14) {
                                    Image(systemName: symbol(item.kind))
                                        .font(.title3).foregroundStyle(.secondary).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.displayName).fontWeight(.medium)
                                        if item.bundledChildCount > 0 {
                                            Text("Includes \(item.bundledChildCount) bundled \(item.bundledChildCount == 1 ? "tool" : "tools")")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 20)
                                    Text(item.kind == .mcpServer && item.selectedChoice == .centralPersonal
                                         ? "Managed connection · This Mac" : ownership(item.selectedChoice))
                                        .foregroundStyle(.secondary)
                                }.padding(.vertical, 7)
                                Divider()
                            }
                        }
                    }
                    if !preview.issues.isEmpty {
                        DisclosureGroup("\(preview.issues.count) validation details") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(validationGroups(preview.issues), id: \.detail) { group in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(group.detail).font(.callout)
                                        if !group.names.isEmpty {
                                            Text(group.names.joined(separator: ", "))
                                                .font(.callout).foregroundStyle(.secondary)
                                        }
                                        if group.count > 1 {
                                            Text("\(group.count) affected items").font(.callout).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }.padding(.top, 12)
                        }
                    }
                }
            }.padding(28)
        }
    }

    private var remainingIntakeIssues: [WorkspaceMigrationIntakeIssue] {
        let projectKeys = Set((session.projectIntake?.requirements ?? []).flatMap(\.items).map(\.legacy))
        let upstreamKeys = Set((session.upstreamIntake?.requirements ?? []).map(\.legacy))
        return (session.intake?.issues ?? []).filter { issue in
            if issue.reason == .upstreamInstallation, upstreamKeys.contains(issue.legacy) { return false }
            guard projectKeys.contains(issue.legacy) else { return true }
            return session.managedConnections?.issues.first(where: { $0.legacy == issue.legacy })?.reason != .needsProjectMapping
        }
    }

    private var upstreamFolders: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose the starting version").font(.title3.weight(.semibold))
                Text("These skills have more than one recorded installation, or their source details need another look. Choose which folder to bring into the library. Each skill keeps its repository and upstream updates.")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.upstreamIntake?.requirements ?? [], id: \.id) { requirement in
                VStack(alignment: .leading, spacing: 14) {
                    Label(requirement.displayName, systemImage: "arrow.triangle.branch")
                        .font(.body.weight(.semibold))
                    if let repository = requirement.repositoryURL,
                       let ref = requirement.requestedRef,
                       let revision = requirement.installedRevision {
                        let packagePath = requirement.packageRelativePath ?? ""
                        VStack(alignment: .leading, spacing: 4) {
                            Text(repository).textSelection(.enabled)
                            Text("\(ref) · \(packagePath.isEmpty ? "Repository root" : packagePath) · \(String(revision.value.prefix(12)))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if requirement.candidates.isEmpty {
                        Text("A saved folder, fingerprint, or installed revision is missing or invalid. Review this skill’s source in your existing workspace, then check again.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(requirement.candidates, id: \.id) { candidate in
                            let selected = session.upstreamIntake?.selections[requirement.legacy] == candidate.id
                            Button {
                                Task { await session.selectUpstreamFolder(candidate.id, for: requirement.legacy) }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected ? AgentTheme.selection : .secondary)
                                    Text(candidate.directoryPath)
                                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                    if selected { Text("Selected").foregroundStyle(.secondary) }
                                }.padding(12).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(AgentTheme.contentBackground, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Use \(candidate.directoryPath) for \(requirement.displayName)")
                            .accessibilityValue(selected ? "Selected" : "Not selected")
                        }
                    }
                }
                .padding(18)
                .standardPanel(cornerRadius: 14)
                .disabled(session.isBusy)
            }
        }
    }

    private var nativePlacements: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose where your plugins belong").font(.title3.weight(.semibold))
                Text("Confirm the project for each app’s existing plugin assignment. Its bundled tools and native updates stay together.")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.nativePlacementIntake?.requirements ?? [], id: \.id) { requirement in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Label(requirement.displayName, systemImage: "puzzlepiece.extension")
                            .font(.body.weight(.semibold))
                        Spacer()
                        Text(requirement.client.rawValue).foregroundStyle(.secondary)
                    }
                    if let scope = requirement.observedScope {
                        Text("Existing scope: \(scope.displayName)").foregroundStyle(.secondary)
                    }
                    if requirement.observedScope == nil {
                        Text("The saved app installation is incomplete or has conflicting placement information. Check this plugin in its app, then check again.")
                            .foregroundStyle(.secondary)
                    } else {
                        if requirement.candidates.isEmpty {
                            Text("Confirm a project above or choose its folder below, then select it for this plugin.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(requirement.candidates, id: \.id) { candidate in
                            let selected = session.nativePlacementIntake?.selections[requirement.id] == candidate.id
                            Button {
                                Task { await session.selectNativePlacement(candidate.id, for: requirement.id) }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected ? AgentTheme.selection : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.projectName ?? "This Mac").fontWeight(.medium)
                                        if let root = candidate.rootPath {
                                            Text(root).foregroundStyle(.secondary)
                                        }
                                    }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                    if selected { Text("Selected").foregroundStyle(.secondary) }
                                }.padding(12).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(AgentTheme.contentBackground, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Use \(candidate.projectName ?? "This Mac") for \(requirement.displayName) in \(requirement.client.rawValue)")
                            .accessibilityValue(selected ? "Selected" : "Not selected")
                        }
                        if requirement.observedScope == .project || requirement.observedScope == .localProject {
                            Button("Choose project folder…", systemImage: "folder.badge.plus") {
                                chooseNativeProject(for: requirement.id)
                            }.buttonStyle(.glass)
                        }
                    }
                    if let error = session.nativeProjectErrors[requirement.id] {
                        Text(error).foregroundStyle(.secondary)
                    }
                }.padding(18).standardPanel(cornerRadius: 14).disabled(session.isBusy)
            }
        }
    }

    private func chooseNativeProject(for requirementID: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose the plugin’s project folder"
        panel.prompt = "Add project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK, let root = panel.url else { return }
            Task { @MainActor in await session.addNativeProject(root: root.standardizedFileURL, for: requirementID) }
        }
    }

    private var projectMappings: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keep your projects together").font(.title3.weight(.semibold))
                Text("Name each saved folder once. Its connections and configurations will use that project, keeping their existing scopes.")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.projectIntake?.requirements ?? [], id: \.id) { requirement in
                VStack(alignment: .leading, spacing: 14) {
                    Label(requirement.rootPath ?? "No project folder saved", systemImage: "folder")
                        .font(.body.weight(.medium)).textSelection(.enabled).lineLimit(3)
                    DisclosureGroup("\(requirement.items.count) \(requirement.items.count == 1 ? "item" : "items") in this folder") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(requirement.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.displayName)
                                        Text(item.legacy.domain == .configuration ? "Configuration" : "MCP connection")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 16)
                                    Text(item.scope.displayName).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.top, 10)
                    }
                    if requirement.canMap {
                        HStack(spacing: 12) {
                            TextField("Project name", text: Binding(
                                get: { session.projectNames[requirement.id] ?? "" },
                                set: { session.setProjectName($0, for: requirement.id) }))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Project name for \(requirement.rootPath ?? "saved folder")")
                            if session.projectIsConfirmed(requirement.id) {
                                Label("Confirmed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Use this project") { Task { await session.confirmProject(requirement.id) } }
                                    .buttonStyle(.glass)
                            }
                        }
                    } else {
                        Text("This saved folder is missing or invalid. Review it in your existing workspace, then check again.")
                            .foregroundStyle(.secondary)
                    }
                    if let error = session.projectMappingErrors[requirement.id] {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .standardPanel(cornerRadius: 14)
                .disabled(session.isBusy)
            }
        }
    }

    private func validationGroups(_ issues: [WorkspaceMigrationCandidatePreparationIssue]) -> [ValidationGroup] {
        let packages = session.intake?.snapshot.marketplacePackages ?? []
        let items = session.preview?.items ?? []
        return Dictionary(grouping: issues, by: \.detail).map { detail, matches in
            let names = matches.compactMap { issue -> String? in
                if let packageID = issue.marketplacePackageID { return packages.first { $0.id == packageID }?.name }
                if let legacy = issue.legacy { return items.first { $0.legacy == legacy }?.displayName }
                return nil
            }
            return ValidationGroup(detail: detail, names: Array(Set(names)).sorted(), count: matches.count)
        }.sorted { $0.detail < $1.detail }
    }

    private struct ValidationGroup {
        let detail: String
        let names: [String]
        let count: Int
    }

    private func explanation(_ issue: WorkspaceMigrationIntakeIssue) -> String {
        if let connection = session.managedConnections?.issues.first(where: { $0.legacy == issue.legacy }) {
            switch connection.reason {
            case .invalidDefinition: return "Its saved address or command could not be carried over. Review the connection settings first."
            case .invalidAuthentication: return "Its authentication method needs review before migration."
            case .invalidCredentials: return "Its credential requirements need review. Only credential names can be carried over."
            case .invalidScope: return "Its saved scope and folder need review."
            case .ambiguousClients: return "Its app assignments contain conflicting entries."
            case .needsProjectMapping: return "Choose the matching project before carrying over this connection."
            case .invalidIdentity: return "Its saved identity conflicts with another connection record."
            }
        }
        return switch issue.reason {
        case .nativeRoute: "Its native app installation could not be identified from the last check."
        case .pluginContents: "Its complete package contents need a source mapping. Bundled tools will stay inside the plugin."
        case .upstreamInstallation: "Its installed folder and revision need to be resolved before preserving upstream updates."
        case .managedConnection: "Its connection settings and machine-specific requirements need a migration mapping."
        }
    }

    private func ownership(_ choice: WorkspaceMigrationInventoryChoiceKind?) -> String {
        switch choice {
        case .centralPersonal: "Your library"
        case .centralUpstream: "Upstream updates"
        case .attachedAuthoring: "Authoring folder"
        case .trackedOnly: "Tracked"
        case .nativePackage: "Managed by its app"
        case nil: "Needs review"
        }
    }

    private func symbol(_ kind: ArtifactKind) -> String {
        switch kind {
        case .skill: "doc.text"
        case .nativePlugin, .package: "puzzlepiece.extension"
        case .mcpServer: "server.rack"
        case .preset: "square.stack"
        case .logicalProject: "folder"
        }
    }
}
