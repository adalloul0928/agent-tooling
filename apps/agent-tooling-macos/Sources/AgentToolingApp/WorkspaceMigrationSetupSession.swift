import AgentToolingCore
import Foundation
import Observation

@MainActor @Observable
final class WorkspaceMigrationSetupSession: Identifiable {
    let id = UUID()
    let legacyLocation: WorkspaceMigrationLegacyLocation
    private(set) var intake: WorkspaceMigrationIntake?
    private(set) var managedConnections: WorkspaceManagedMCPMigrationIntake?
    private(set) var upstreamIntake: WorkspaceMigrationUpstreamIntake?
    private(set) var nativePlacementIntake: WorkspaceMigrationNativePlacementIntake?
    private(set) var nativeProjectErrors: [String: String] = [:]
    private(set) var projectIntake: WorkspaceMigrationProjectIntake?
    private(set) var projectNames: [String: String] = [:]
    private(set) var projectMappingErrors: [String: String] = [:]
    private(set) var preview: WorkspaceMigrationCandidatePreparationPreview?
    private(set) var reviewSession: WorkspaceMigrationReviewSession?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private let workspaceID = WorkspaceObjectID()
    private let deviceID = WorkspaceObjectID()
    private let attemptID = WorkspaceObjectID()
    private var confirmedProjects: [String: WorkspaceMCPMigrationProject] = [:]
    private var projectIDs: [String: ArtifactID] = [:]
    private var upstreamSelections: [LegacyReferenceKey: String] = [:]
    private var upstreamReviewKeys = Set<LegacyReferenceKey>()
    private var nativeSelections: [String: String] = [:]
    private var nativeReviewKeys = Set<String>()
    private var additionalNativeProjects: [String: WorkspaceMCPMigrationProject] = [:]

    init(location: WorkspaceMigrationLegacyLocation) { legacyLocation = location }

    var hasUnresolvedNativePlacements: Bool {
        guard let nativePlacementIntake else { return true }
        return nativePlacementIntake.requirements.contains { nativePlacementIntake.selections[$0.id] == nil }
    }

    func selectNativePlacement(_ candidateID: String, for requirementID: String) async {
        guard !isBusy, reviewSession == nil,
              nativePlacementIntake?.requirements.contains(where: {
                  $0.id == requirementID && $0.candidates.contains(where: { $0.id == candidateID })
              }) == true else { return }
        nativeSelections[requirementID] = candidateID
        nativeReviewKeys.insert(requirementID)
        nativeProjectErrors[requirementID] = nil
        await inspect()
    }

    /// Adds a user-chosen folder as a candidate. A second, explicit selection
    /// binds the plugin's current observed scope to this project.
    func addNativeProject(root: URL, for requirementID: String) async {
        guard !isBusy, reviewSession == nil,
              let requirement = nativePlacementIntake?.requirements.first(where: { $0.id == requirementID }),
              requirement.observedScope == .project || requirement.observedScope == .localProject else { return }
        let path = root.path
        let name = root.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.isFileURL, path.hasPrefix("/"), path.count <= 8_192,
              root.standardizedFileURL.path == path,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Self.nativeProjectDirectoryExists(path),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            nativeProjectErrors[requirementID] = "Choose an existing project folder with a valid name."
            return
        }
        guard additionalNativeProjects[path] != nil || additionalNativeProjects.count < 64 else {
            nativeProjectErrors[requirementID] = "Review the project folders already added before adding more."
            return
        }
        if let existing = confirmedProjects[path] {
            additionalNativeProjects[path] = existing
        } else if additionalNativeProjects[path] == nil {
            let projectID = projectIDs[path] ?? ArtifactID()
            additionalNativeProjects[path] = .init(project: .init(id: projectID, name: name), rootPath: path)
        }
        nativeProjectErrors[requirementID] = nil
        await inspect()
    }

    func selectUpstreamFolder(_ evidenceID: String, for legacy: LegacyReferenceKey) async {
        guard !isBusy, reviewSession == nil,
              upstreamIntake?.requirements.contains(where: {
                  $0.legacy == legacy && $0.candidates.contains(where: { $0.id == evidenceID })
              }) == true else { return }
        upstreamSelections[legacy] = evidenceID
        upstreamReviewKeys.insert(legacy)
        await inspect()
    }

    var hasUnconfirmedProjectChanges: Bool {
        projectIntake?.requirements.contains { !projectIsConfirmed($0.id) } == true
    }

    func projectIsConfirmed(_ requirementID: String) -> Bool {
        guard let requirement = projectIntake?.requirements.first(where: { $0.id == requirementID }),
              requirement.canMap, let root = requirement.rootPath,
              let confirmed = confirmedProjects[root] else { return false }
        return confirmed.project.name == projectNames[requirementID]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setProjectName(_ name: String, for requirementID: String) {
        guard !isBusy, reviewSession == nil,
              projectIntake?.requirements.contains(where: { $0.id == requirementID && $0.canMap }) == true else { return }
        projectNames[requirementID] = name
        projectMappingErrors[requirementID] = nil
    }

    func confirmProject(_ requirementID: String) async {
        guard !isBusy, reviewSession == nil,
              let requirement = projectIntake?.requirements.first(where: { $0.id == requirementID }) else { return }
        guard requirement.canMap, let root = requirement.rootPath else {
            projectMappingErrors[requirementID] = "Review the saved project folder in your existing workspace first."
            return
        }
        let name = (projectNames[requirementID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            projectMappingErrors[requirementID] = "Enter a project name of up to 256 characters."
            return
        }
        let projectID = projectIDs[root] ?? ArtifactID()
        projectIDs[root] = projectID
        confirmedProjects[root] = .init(project: .init(id: projectID, name: name), rootPath: root)
        projectNames[requirementID] = name
        projectMappingErrors[requirementID] = nil
        await inspect()
    }

    func inspect() async {
        guard !isBusy, reviewSession == nil else { return }
        let previousNativeIntake = nativePlacementIntake
        isBusy = true
        errorMessage = nil
        preview = nil
        intake = nil
        managedConnections = nil
        upstreamIntake = nil
        nativePlacementIntake = nil
        projectIntake = nil
        defer { isBusy = false }
        do {
            let database = legacyLocation.legacyRoot.appending(path: "agent-tooling.sqlite")
            let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: database)
            let workspaceID = self.workspaceID
            let context = WorkspaceMigrationContext(workspaceID: workspaceID, deviceID: deviceID,
                revision: .init(writerID: deviceID))
            let existingProjects = Array(confirmedProjects.values)
            let sourceSelections = upstreamSelections
            let sourceReviewKeys = upstreamReviewKeys
            let placementSelections = nativeSelections
            let placementReviewKeys = nativeReviewKeys
            let extraProjects = Array(additionalNativeProjects.values)
            let worker = Task.detached {
                let intake = try WorkspaceMigrationIntake.review(checkpoint: checkpoint, workspaceID: workspaceID)
                let upstream = try WorkspaceMigrationUpstreamIntake.review(intake: intake, workspaceID: workspaceID,
                    selections: sourceSelections, requiringReview: sourceReviewKeys)
                let requirements = try WorkspaceMigrationProjectIntake.review(intake: upstream.intake, projects: [])
                let currentRoots = Set(requirements.requirements.filter(\.canMap).compactMap(\.rootPath))
                let projects = try WorkspaceMigrationProjectIntake.review(intake: upstream.intake,
                    projects: existingProjects.filter { currentRoots.contains($0.rootPath) })
                let managed = try WorkspaceManagedMCPMigrationIntake.review(intake: upstream.intake, context: context,
                    projects: projects.projects)
                let confirmedRoots = Set(projects.projects.map(\.rootPath))
                let allNativeProjects = projects.projects + extraProjects.filter { !confirmedRoots.contains($0.rootPath) }
                let invalidNativeRoots = Set(allNativeProjects.filter {
                    !Self.nativeProjectDirectoryExists($0.rootPath)
                }.map(\.rootPath))
                let availableProjects = allNativeProjects.filter { !invalidNativeRoots.contains($0.rootPath) }
                let native = try WorkspaceMigrationNativePlacementIntake.review(intake: managed.intake,
                    workspaceID: workspaceID, projects: availableProjects,
                    selections: placementSelections, requiringReview: placementReviewKeys)
                let selectedProjects = projects.projects + availableProjects.filter {
                    !confirmedRoots.contains($0.rootPath) && native.selectedProjectIDs.contains($0.project.id)
                }
                return (managed: managed, projects: projects, upstream: upstream,
                        native: native, selectedProjects: selectedProjects, invalidNativeRoots: invalidNativeRoots)
            }
            let captured = try await withTaskCancellationHandler { try await worker.value }
                onCancel: { worker.cancel() }
            try Task.checkCancellation()
            intake = captured.managed.intake
            managedConnections = captured.managed
            upstreamIntake = captured.upstream
            upstreamSelections = captured.upstream.selections
            upstreamReviewKeys = Set(captured.upstream.requirements.map(\.legacy))
            nativePlacementIntake = captured.native
            nativeSelections = captured.native.selections
            nativeReviewKeys = Set(captured.native.requirements.map(\.id))
            nativeProjectErrors = nativeProjectErrors.filter { nativeReviewKeys.contains($0.key) }
            additionalNativeProjects = additionalNativeProjects.filter {
                !captured.invalidNativeRoots.contains($0.key)
            }
            for requirement in previousNativeIntake?.requirements ?? [] where nativeReviewKeys.contains(requirement.id) {
                if requirement.candidates.contains(where: {
                    $0.id == previousNativeIntake?.selections[requirement.id]
                        && $0.rootPath.map(captured.invalidNativeRoots.contains) == true
                }) {
                    nativeProjectErrors[requirement.id] = "The selected project folder is no longer available. Choose an existing folder."
                }
            }
            if captured.native.requirements.isEmpty { additionalNativeProjects = [:] }
            projectIntake = captured.projects
            confirmedProjects = Dictionary(uniqueKeysWithValues: captured.projects.projects.map { ($0.rootPath, $0) })
            let currentRequirementIDs = Set(captured.projects.requirements.map(\.id))
            projectNames = projectNames.filter { currentRequirementIDs.contains($0.key) }
            projectMappingErrors = projectMappingErrors.filter { currentRequirementIDs.contains($0.key) }
            let currentRoots = Set(captured.projects.requirements.filter(\.canMap).compactMap(\.rootPath))
            projectIDs = projectIDs.filter { currentRoots.contains($0.key) }
            let request = WorkspaceMigrationCandidatePreparationRequest(
                attemptID: attemptID, checkpoint: checkpoint, legacyDatabaseURL: database,
                context: context, choices: captured.managed.intake.choices,
                managedMCPResolutions: captured.managed.resolutions,
                projects: captured.selectedProjects,
                configurationProjects: captured.projects.configurationProjects,
                nativePluginPlacements: captured.native.placements)
            let result = try await WorkspaceMigrationCandidatePreparationService().preview(request)
            try Task.checkCancellation()
            preview = result
        } catch is CancellationError {
            errorMessage = "Review was cancelled. Your existing setup has not changed."
        } catch {
            errorMessage = "The workspace could not be reviewed. Close this review and check the local library before trying again."
        }
    }

    /// Stores a reviewed candidate separately. Activation remains a second,
    /// explicit action in WorkspaceMigrationReviewView.
    func stage() async {
        guard !isBusy, reviewSession == nil, !hasUnconfirmedProjectChanges, !hasUnresolvedNativePlacements,
              intake?.issues.isEmpty == true,
              let preparation = preview?.preparation, preview?.canPrepare == true else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let selectedNativeRoots = nativePlacementIntake?.requirements.flatMap { requirement in
                requirement.candidates.filter {
                    $0.id == nativePlacementIntake?.selections[requirement.id]
                }.compactMap(\.rootPath)
            } ?? []
            let foldersAvailable = await Task.detached {
                selectedNativeRoots.allSatisfy(Self.nativeProjectDirectoryExists)
            }.value
            try Task.checkCancellation()
            guard foldersAvailable else {
                isBusy = false
                await inspect()
                return
            }
            let parent = legacyLocation.legacyRoot.appending(path: "workspace-migration-\(id.uuidString.lowercased())")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let location = WorkspaceMigrationReviewLocation(legacyRoot: legacyLocation.legacyRoot,
                containerRoot: parent.appending(path: "revisions"), checkpointRoot: parent.appending(path: "checkpoints"),
                contentRoot: parent.appending(path: "content"), workspaceID: workspaceID,
                deviceID: deviceID, attemptID: attemptID)
            for directory in [location.containerRoot, location.checkpointRoot, location.contentRoot] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            let service = WorkspaceMigrationService(
                store: try WorkspaceRevisionStore(containerRoot: location.containerRoot,
                    workspaceID: workspaceID, deviceID: deviceID),
                checkpoints: try WorkspaceLegacyCheckpointStore(directory: location.checkpointRoot),
                content: try CentralPackageContentStore(directory: location.contentRoot))
            // The durable descriptor is an explicit recovery handle; startup
            // still follows only the authority registry, never this directory.
            try location.encode().write(to: parent.appending(path: "review.json"), options: .withoutOverwriting)
            _ = try await service.stage(preparation)
            // Once staging succeeds, retain its receipt even if the next read
            // fails. Its descriptor is already available for recovery.
            reviewSession = WorkspaceMigrationReviewSession(
                service: try WorkspaceMigrationReviewService(location: location), location: location)
            await reviewSession?.refresh()
        } catch {
            errorMessage = "The reviewed candidate could not be saved. Your existing workspace is still active. Close this review and try again."
        }
    }

    private nonisolated static func nativeProjectDirectoryExists(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
