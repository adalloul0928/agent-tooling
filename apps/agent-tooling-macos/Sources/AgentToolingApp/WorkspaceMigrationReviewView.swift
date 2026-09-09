import AgentToolingCore
import SwiftUI

/// A narrow pilot surface for reviewing a durable migration and choosing which
/// retained workspace opens next. It contains no legacy editor or native action.
struct WorkspaceMigrationReviewView: View {
    let session: WorkspaceMigrationReviewSession
    let onOpenLibrary: () -> Void
    let onReturnToLegacy: () -> Void

    @State private var refreshID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Migration review", context: toolbarContext) {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .disabled(session.isBusy)
            }
            Divider()
            content
            Divider()
            footer
        }
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 540)
        .task(id: refreshID) { await session.refresh() }
        .sheet(
            isPresented: Binding(
                get: { session.pendingSelection != nil },
                set: { if !$0 { session.cancelPendingSelection() } }
            )
        ) {
            if let selection = session.pendingSelection {
                WorkspaceMigrationSelectionConfirmation(
                    selection: selection,
                    isBusy: session.isBusy,
                    onConfirm: { Task { await session.applyPendingSelection() } },
                    onCancel: { session.cancelPendingSelection() }
                )
                .interactiveDismissDisabled(session.isBusy)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let selection = session.committedSelection {
            completion(selection)
        } else if let state = session.state {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if session.initializedEntry != nil, state.journalEntry.phase == .prepared {
                        AttentionBanner(
                            title: "Migration initialized",
                            message: "The reviewed migration was saved. Refresh to load its current status."
                        )
                    }
                    status(state)
                    ownership(state.reviewedSummary)
                    projects(state.journalEntry.record)
                    upstreamSources(state.journalEntry.record)
                    WorkspaceMigrationIncludedItems(rows: state.reviewedLibrary.rows)
                    details(state)
                    if let error = session.errorMessage {
                        AttentionBanner(title: "Review needs attention", message: error)
                    }
                }
                .padding(WorkspaceLayout.pageInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if session.isBusy {
            ProgressView("Loading migration review…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Migration review unavailable",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text(session.errorMessage ?? "Refresh to read the reviewed migration."))
        }
    }

    private func status(_ state: WorkspaceMigrationReviewState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(statusTitle(state), systemImage: statusSymbol(state))
                .font(.title3.weight(.semibold))
            Text(statusDetail(state))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private func ownership(_ summary: WorkspaceMigrationReviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What this migration keeps").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
                ownershipCount("Your tools", summary.centralPersonalCount)
                ownershipCount("Upstream tools", summary.centralUpstreamCount)
                ownershipCount("App-managed tools", summary.nativeOwnedCount)
                ownershipCount("Attached folders", summary.attachedAuthoringCount)
                ownershipCount("Tracked only", summary.trackedOnlyCount)
                ownershipCount("Assignments", summary.assignmentCount)
            }
            if summary.wholePluginChildCount > 0 {
                Label(
                    summary.wholePluginChildCount == 1
                        ? "1 tool stays bundled with its plugin."
                        : "\(summary.wholePluginChildCount) tools stay bundled with their plugins.",
                    systemImage: "puzzlepiece.extension"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private func ownershipCount(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AgentTheme.contentBackground.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func projects(_ record: WorkspaceMigrationRecord) -> some View {
        if !record.document.logicalProjects.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your projects").font(.headline)
                Text("Folder locations stay on this Mac.").foregroundStyle(.secondary)
                ForEach(record.document.logicalProjects, id: \.id) { project in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(project.name, systemImage: "folder").fontWeight(.medium)
                        if let root = record.device.projectRoots?.first(where: { $0.projectID == project.id }) {
                            Text(root.rootPath).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .standardPanel(cornerRadius: 14)
        }
    }

    @ViewBuilder
    private func upstreamSources(_ record: WorkspaceMigrationRecord) -> some View {
        if !record.document.subscriptions.isEmpty {
            DisclosureGroup("Upstream source details (\(record.document.subscriptions.count))") {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("The library keeps the selected folder’s complete contents and its repository update information.")
                        .foregroundStyle(.secondary)
                    ForEach(record.document.subscriptions, id: \.id) { subscription in
                        VStack(alignment: .leading, spacing: 5) {
                            if let artifact = record.document.artifacts.first(where: { $0.identity.id == subscription.artifactID }) {
                                Text(artifact.identity.displayName).fontWeight(.medium)
                            }
                            if let source = record.document.sources.first(where: { $0.id == subscription.sourceID }),
                               let repository = source.repositoryURL {
                                Text(repository).textSelection(.enabled)
                            }
                            Text("\(subscription.lock.requestedRef) · \(String(subscription.lock.approvedRevision.value.prefix(12)))")
                                .font(.callout).foregroundStyle(.secondary)
                            if let capture = record.manifest.sourceCaptures.first(where: { $0.artifactID == subscription.artifactID }) {
                                Label(capture.directoryPath, systemImage: "folder")
                                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(.top, 12)
            }
            .padding(18)
            .standardPanel(cornerRadius: 14)
        }
    }

    private func details(_ state: WorkspaceMigrationReviewState) -> some View {
        DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Attempt", state.journalEntry.record.manifest.attemptID.rawValue.uuidString.lowercased())
                detailRow("Checkpoint", state.journalEntry.record.manifest.checkpointSHA256)
                detailRow("Initial revision", state.journalEntry.record.manifest.initialRevisionID.rawValue.uuidString.lowercased())
                detailRow("Current revision", state.currentRevisionID?.rawValue.uuidString.lowercased() ?? "Not initialized")
                detailRow("Legacy database", state.journalEntry.record.manifest.legacyDatabasePath)
                detailRow("Container", session.location.containerRoot.path)
            }
            .padding(.top, 8)
        }
        .font(.callout)
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func completion(_ selection: WorkspaceAuthoritySelection) -> some View {
        VStack(spacing: 18) {
            Image(systemName: selection.choice == .versioned ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                .font(.system(size: 42)).foregroundStyle(AgentTheme.ok)
            Text(selection.choice == .versioned ? "Your library is ready" : "Previous library restored")
                .font(.title2.weight(.semibold))
            Text(selection.choice == .versioned
                 ? "The reviewed workspace choice was saved. Assignments are saved here; installation is reviewed separately."
                 : "The previous library was selected. Open it to continue there.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button(selection.choice == .versioned ? "Open library" : "Open previous library") {
                session.dismissCommittedSelection()
                if selection.choice == .versioned { onOpenLibrary() } else { onReturnToLegacy() }
            }
            .buttonStyle(.glassProminent).tint(AgentTheme.selection)
            if let error = session.errorMessage {
                AttentionBanner(title: "Saved with a refresh issue", message: error).frame(maxWidth: 560)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = session.errorMessage, session.state != nil, session.committedSelection == nil {
                Text(error).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(footerDetail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            actionButton
        }
        .padding(.horizontal, WorkspaceLayout.pageInset)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let state = session.state, session.committedSelection == nil {
            if state.journalEntry.phase == .prepared {
                Button("Initialize reviewed migration") { Task { await session.initializeReviewed() } }
                    .buttonStyle(.glassProminent)
                    .tint(AgentTheme.selection)
                    .disabled(session.isBusy || session.initializedEntry != nil)
            } else if state.authoritySelection?.choice == .versioned {
                HStack(spacing: 10) {
                    Button("Open library", action: onOpenLibrary)
                        .buttonStyle(.glassProminent)
                        .tint(AgentTheme.selection)
                        .disabled(session.isBusy)
                    Button("Review return to previous library") { Task { await session.prepareRollback() } }
                        .buttonStyle(.glass)
                        .disabled(session.isBusy)
                }
            } else if state.authoritySelection?.choice == .legacy {
                Button("Open previous library", action: onReturnToLegacy)
                    .buttonStyle(.glassProminent)
                    .tint(AgentTheme.selection)
                    .disabled(session.isBusy)
            } else {
                Button("Review migrated workspace") { Task { await session.prepareActivation() } }
                    .buttonStyle(.glassProminent)
                    .tint(AgentTheme.selection)
                    .disabled(session.isBusy || hasChangedSinceReview(state))
            }
        }
    }

    private var toolbarContext: String {
        guard let state = session.state else { return "Reviewed local migration" }
        return state.journalEntry.phase == .prepared ? "Ready to initialize" : "Reviewed local migration"
    }

    private var footerDetail: String {
        guard let state = session.state else { return "Review your library before choosing which version to use." }
        switch state.journalEntry.phase {
        case .prepared: return "Initialization checks the same reviewed migration before creating its first revision."
        case .initialized:
            if state.authoritySelection == nil, hasChangedSinceReview(state) {
                return "The migrated workspace changed after this review. Prepare a new review before selecting it."
            }
            return state.authoritySelection?.choice == .versioned
                ? "Assignments are saved here; installation is reviewed separately."
                : "Selecting a workspace remains a separate confirmed step."
        }
    }

    private func hasChangedSinceReview(_ state: WorkspaceMigrationReviewState) -> Bool {
        state.currentRevisionID != state.journalEntry.record.manifest.initialRevisionID
    }

    private func statusTitle(_ state: WorkspaceMigrationReviewState) -> String {
        if state.journalEntry.phase == .prepared { return "Ready to initialize" }
        switch state.authoritySelection?.choice {
        case .versioned: return "Migrated workspace selected"
        case .legacy: return "Previous library selected"
        case nil: return "Migration initialized"
        }
    }

    private func statusSymbol(_ state: WorkspaceMigrationReviewState) -> String {
        if state.journalEntry.phase == .prepared { return "clock.badge.checkmark" }
        return state.authoritySelection?.choice == .versioned ? "checkmark.circle.fill" : "archivebox.circle"
    }

    private func statusDetail(_ state: WorkspaceMigrationReviewState) -> String {
        if state.journalEntry.phase == .prepared {
            return "The reviewed record is durable. Initializing it creates the isolated workspace without selecting it."
        }
        if state.authoritySelection?.choice == .versioned {
            return "This Mac opens the migrated workspace. Assignments are saved here; installation is reviewed separately."
        }
        if state.authoritySelection?.choice == .legacy {
            return "The previous library remains selected on this Mac."
        }
        return "The isolated workspace is ready for a separate workspace-choice review."
    }
}

private struct WorkspaceMigrationIncludedItems: View {
    let rows: [WorkspaceLibraryReadModelRow]
    @State private var visibleCount = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Included items").font(.headline)
            ForEach(rows.prefix(visibleCount)) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.kind.librarySymbol)
                        .font(.title3).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.displayName).font(.body.weight(.medium))
                        Text(row.ownershipLabel).font(.callout).foregroundStyle(.secondary)
                        if row.childCount > 0 {
                            Text("Includes \(row.childCount) \(row.childCount == 1 ? "tool" : "tools")")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 20)
                    VStack(alignment: .trailing, spacing: 4) {
                        if row.requestedAssignments.isEmpty {
                            Text("No assignment changes")
                        } else {
                            ForEach(row.requestedAssignments) { assignment in
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("\(assignment.destination.surface.displayName) · \(assignment.destination.scope.displayName)")
                                    if let enabled = assignment.desiredEnabled {
                                        Text(enabled ? "Enabled in this setup" : "Disabled in this setup")
                                    }
                                }
                            }
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            if rows.count > visibleCount {
                Button("Show more (\(rows.count - visibleCount) remaining)") { visibleCount += 50 }
                    .buttonStyle(.glass)
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }
}

private struct WorkspaceMigrationSelectionConfirmation: View {
    let selection: WorkspaceAuthoritySelection
    let isBusy: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                SymbolTile(
                    symbol: selection.choice == .versioned ? "arrow.right.circle" : "arrow.uturn.backward.circle",
                    size: 36
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.choice == .versioned ? "Use migrated workspace?" : "Return to previous library?")
                        .font(.title3.weight(.semibold))
                    Text("Review this choice before saving it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(selection.choice == .versioned
                 ? "This saves the reviewed workspace choice. Assignments are saved in the migrated library; installation is reviewed separately."
                 : "This saves the previous library as the workspace to open. Neither library history is overwritten.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: onCancel).disabled(isBusy)
                Spacer()
                Button(selection.choice == .versioned ? "Use migrated workspace" : "Return to previous library", action: onConfirm)
                    .buttonStyle(.glassProminent).tint(AgentTheme.selection).disabled(isBusy)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(AgentTheme.contentBackground)
    }
}
