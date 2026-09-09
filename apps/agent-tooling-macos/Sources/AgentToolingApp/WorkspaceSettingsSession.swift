import AgentToolingCore
import Foundation
import Observation

/// Reads what each installed app will actually use, for this Mac and optionally
/// one project, and makes the narrow set of recorded, writable settings
/// editable.
///
/// Reading is the default and most of the surface. An edit is only offered when
/// three separate things agree: the compatibility register records the setting
/// as writable with a source and a version range, the resolver says this app
/// could actually write the layer that decides it, and the file is JSON this
/// build can rewrite without destroying what else is in it. Anything else is
/// shown and explained, never quietly made editable.
@MainActor @Observable
final class WorkspaceSettingsSession {
    struct Surface: Identifiable {
        let id: TargetSurface
        let title: String
        let configuration: EffectiveConfiguration?
        let errorMessage: String?
    }

    /// One reviewed change, ready to be shown before anything is written.
    struct PendingEdit: Identifiable {
        let id = UUID()
        let surface: TargetSurface
        let surfaceTitle: String
        let row: EffectiveConfigurationRow
        let layer: ConfigurationLayerKind
        let sourcePath: String
        /// The file as it was when this was prepared. A file that moved on is
        /// never overwritten.
        let fingerprint: String?
    }

    /// Standing instructions and agent definitions, read from the locations
    /// each vendor documents. Read-only: what any of them says is prose written
    /// for an agent, and summarising one would be inventing a claim.
    private(set) var instructions: AgentInstructionInventory.Result?
    private(set) var surfaces: [Surface] = []
    private(set) var isBusy = false
    private(set) var selectedProjectID: ArtifactID?
    private(set) var pendingEdit: PendingEdit?
    private(set) var editMessage: String?
    private(set) var lastReceipt: ConfigurationEditReceipt?

    private let homeRoot: URL
    private let library: WorkspaceLibrarySession
    /// Where an organization's policy file is on this Mac.
    ///
    /// Taken from the vendor's own page, not guessed: inventing a path would
    /// mean reporting "no policy" for a Mac that has one, and then showing a
    /// setting as editable that a policy actually decides. `nil` means no
    /// location is recorded for this platform, and the screen says so rather
    /// than implying the absence was checked.
    private let managedPolicyPath: URL?

    /// `managedPolicyPath` defaults to the location the vendor documents. A
    /// test passes its own; passing `.some(nil)` says this Mac's policy location
    /// is genuinely unknown, which the screen then states rather than implying
    /// it checked.
    init(
        homeRoot: URL,
        library: WorkspaceLibrarySession,
        managedPolicyPath: URL?? = .none
    ) {
        self.homeRoot = homeRoot
        self.library = library
        self.managedPolicyPath = managedPolicyPath
            ?? ConfigurationLayerReader.managedPolicyPath(for: .claudeCode)
    }

    /// True when nothing told this app where an organization policy would be,
    /// so one cannot be ruled out.
    var managedPolicyUnknown: Bool { managedPolicyPath == nil }

    var projects: [WorkspaceLibraryProjectReadModel] { library.state?.library.projects ?? [] }

    /// Whether this exact setting can be changed from here, and nothing wider.
    func isEditable(_ row: EffectiveConfigurationRow, surface: TargetSurface) -> Bool {
        guard ConfigurationCompatibilityRegister.isWritable(surface: surface, key: row.key),
              let writable = row.writableLayer,
              let contribution = row.contributions.first(where: { $0.layer == writable }),
              let path = contribution.sourcePath, path.hasSuffix(".json") else { return false }
        // A list combined from several files is not one value to replace.
        return row.rule == .replace
    }

    /// Prepares a change without writing it, recording the file as it is now.
    func beginEdit(_ row: EffectiveConfigurationRow, surface: Surface) {
        guard !isBusy, isEditable(row, surface: surface.id),
              let writable = row.writableLayer,
              let path = row.contributions.first(where: { $0.layer == writable })?.sourcePath else { return }
        editMessage = nil
        lastReceipt = nil
        pendingEdit = .init(surface: surface.id, surfaceTitle: surface.title, row: row,
                            layer: writable, sourcePath: path,
                            fingerprint: try? ConfigurationEditor().fingerprint(of: path))
    }

    func discardEdit() {
        guard !isBusy else { return }
        pendingEdit = nil
        editMessage = nil
    }

    /// Writes the reviewed change, then re-reads to say what the app will use.
    func applyEdit(_ value: ConfigurationValue) async {
        guard !isBusy, let edit = pendingEdit else { return }
        isBusy = true
        editMessage = nil
        defer { isBusy = false }
        let versions = Dictionary(
            (library.state?.snapshot.device.capabilityEvidence ?? []).compactMap { evidence in
                evidence.installedClientVersion.map { (evidence.surface, $0) }
            }, uniquingKeysWith: { first, _ in first })
        let command = ConfigurationEdit(key: edit.row.key, layer: edit.layer,
                                        sourcePath: edit.sourcePath, newValue: value,
                                        expectedFingerprint: edit.fingerprint)
        do {
            let editor = ConfigurationEditor()
            guard let configuration = surfaces.first(where: { $0.id == edit.surface })?.configuration else {
                editMessage = "That app's settings could not be read again. Nothing was changed."
                return
            }
            try editor.validate(command, against: configuration)
            switch edit.surface {
            case .claudeCode:
                lastReceipt = try editor.apply(command, adapter: ClaudeCodeConfigurationAdapter(),
                                               installedClientVersion: versions[.claudeCode])
            default:
                // Only Claude Code has a JSON layer this build rewrites. Codex
                // keeps comments and formatting in TOML that cannot be
                // reproduced faithfully, so it is read-only by design.
                editMessage = "This app's settings file is not one Agent Tooling can rewrite safely."
                return
            }
            pendingEdit = nil
        } catch {
            editMessage = Self.editMessage(for: error)
        }
        await reload()
    }

    func select(project id: ArtifactID?) {
        selectedProjectID = id
        Task { await refresh() }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await reload()
    }

    /// Re-reads without taking the busy guard, so an action can finish by
    /// showing what is true now rather than what was true before it ran.
    private func reload() async {
        let projectRoot = selectedProjectID.flatMap { id in
            library.state?.snapshot.device.projectRoots?.first { $0.projectID == id }
        }.map { URL(fileURLWithPath: $0.rootPath) }
        let home = homeRoot
        let policy = managedPolicyPath
        // Version evidence comes from what this device actually observed; an
        // unknown version claims no vendor-specific layout.
        let versions = Dictionary(
            (library.state?.snapshot.device.capabilityEvidence ?? []).compactMap { evidence in
                evidence.installedClientVersion.map { (evidence.surface, $0) }
            }, uniquingKeysWith: { first, _ in first })

        let scannedHome = home
        let scannedProject = projectRoot
        instructions = await Task.detached {
            AgentInstructionInventory.scan(homeRoot: scannedHome, projectRoot: scannedProject)
        }.value
        surfaces = await Task.detached {
            let reader = ConfigurationLayerReader()
            var results: [Surface] = []
            do {
                let layers = try reader.claudeCodeLayers(homeRoot: home, projectRoot: projectRoot,
                                                        managedPolicyPath: policy)
                results.append(.init(id: .claudeCode, title: "Claude Code",
                    configuration: EffectiveConfigurationResolver.resolve(
                        adapter: ClaudeCodeConfigurationAdapter(),
                        installedClientVersion: versions[.claudeCode], layers: layers),
                    errorMessage: nil))
            } catch {
                results.append(.init(id: .claudeCode, title: "Claude Code", configuration: nil,
                    errorMessage: Self.describe(error)))
            }
            do {
                let adapter = CodexConfigurationAdapter(installedClientVersion: versions[.codexCLI])
                let layers = try reader.codexLayers(homeRoot: home, adapter: adapter)
                results.append(.init(id: .codexCLI, title: "Codex",
                    configuration: EffectiveConfigurationResolver.resolve(
                        adapter: adapter, installedClientVersion: versions[.codexCLI], layers: layers),
                    errorMessage: nil))
            } catch {
                results.append(.init(id: .codexCLI, title: "Codex", configuration: nil,
                    errorMessage: Self.describe(error)))
            }
            return results
        }.value
    }

    private nonisolated static func editMessage(for error: any Error) -> String {
        switch error {
        case ConfigurationEditError.fileChangedSinceReview:
            "That file changed since you opened it. Nothing was written — look at it again."
        case ConfigurationEditError.constrainedByHigherLayer,
             ConfigurationEditError.layerNotWritable:
            "Something with more say than this file decides that setting, so changing it here would not take effect."
        case ConfigurationEditError.unsupportedSetting:
            "Agent Tooling does not know that setting well enough to change it."
        case ConfigurationEditError.unsupportedFormat:
            "That file is not in a form Agent Tooling can rewrite without risking the rest of it."
        case ConfigurationEditError.notEffectiveAfterWrite:
            "The file was written, but the app would still not use that value. Nothing further was attempted; your original is beside it as a backup."
        case ConfigurationEditError.backupFailed:
            "A backup of your file could not be written first, so nothing was changed."
        case ConfigurationEditError.valueRejected:
            "That value is not one this setting accepts."
        default:
            "That setting could not be changed. Nothing was written."
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case ConfigurationLayerReadError.fileTooLarge:
            "One of this app's settings files is too large to read safely."
        case ConfigurationLayerReadError.unreadable:
            "One of this app's settings files could not be read. It was left exactly as it is."
        default:
            "This app's settings could not be read on this Mac."
        }
    }
}
