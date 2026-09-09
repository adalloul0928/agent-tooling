import AgentToolingCore
import Foundation
import Observation

/// Writing one item out as a plain folder, with an honest report of which of
/// this Mac's apps could actually use it.
///
/// The preview writes nothing, and the report is built from what this device
/// observed about each app — not from what the package hopes for. An
/// unsupported target is reported rather than quietly dropped from the export,
/// because the export is the same either way and the person is the one who
/// needs to know.
@MainActor @Observable
final class WorkspacePackageExportSession {
    private(set) var preview: WorkspacePackageExport?
    private(set) var artifactID: ArtifactID?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var writtenPath: String?

    private let library: WorkspaceLibrarySession
    private let contentStore: CentralPackageContentStore?
    private var tree: CapturedPackageTree?

    init(library: WorkspaceLibrarySession, contentStore: CentralPackageContentStore?) {
        self.library = library
        self.contentStore = contentStore
    }

    /// Reads the approved content and describes what an export would contain.
    func prepare(_ artifactID: ArtifactID) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        preview = nil
        tree = nil
        writtenPath = nil
        self.artifactID = artifactID
        defer { isBusy = false }
        guard let state = library.state,
              let artifact = state.snapshot.document.artifacts.first(where: { $0.identity.id == artifactID }) else {
            errorMessage = "That item is no longer in this workspace."
            return
        }
        guard let digest = artifact.contentDigest else {
            // Nothing to write: the workspace records that this exists, not
            // what it contains. Saying which is more use than an empty folder.
            errorMessage = "This workspace records this item but does not hold its content, so there is nothing to write out."
            return
        }
        guard let contentStore else {
            errorMessage = "This Mac's content library could not be opened."
            return
        }
        do {
            let tree = try await contentStore.read(digest)
            self.tree = tree
            preview = WorkspacePackageExporter.preview(
                artifact: artifact, tree: tree,
                targets: state.snapshot.device.capabilityEvidence,
                declaredTransports: Self.transports(for: artifact, in: state.snapshot.document))
        } catch {
            errorMessage = "That item's approved content could not be read on this Mac."
        }
    }

    func discard() {
        guard !isBusy else { return }
        preview = nil
        tree = nil
        artifactID = nil
        errorMessage = nil
        writtenPath = nil
    }

    /// Writes the package into a new folder the person chose.
    ///
    /// `WorkspacePackageExporter` refuses a folder that already holds
    /// something, so choosing an existing folder by mistake cannot overwrite
    /// what is in it.
    func write(to destination: URL) async {
        guard !isBusy, let tree, let name = preview?.declaredName else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let folder = destination.appending(path: name).standardizedFileURL
        do {
            try WorkspacePackageExporter.write(tree: tree, to: folder)
            writtenPath = folder.path
        } catch WorkspacePackageExportError.destinationNotEmpty {
            errorMessage = "There is already something at that name in the folder you chose. Nothing was written."
        } catch WorkspacePackageExportError.invalidDestination {
            errorMessage = "Choose a folder on this Mac to write the package into."
        } catch {
            errorMessage = "The package could not be written there. Nothing was changed."
        }
    }

    /// Connection types this package declares, so the report can say which of
    /// them an app does not accept.
    private static func transports(
        for artifact: ArtifactRecord, in document: PortableWorkspaceDocument
    ) -> [String] {
        guard artifact.identity.kind == .mcpServer,
              let definition = document.mcpDefinitions?.first(where: { $0.artifactID == artifact.identity.id })
        else { return [] }
        return [definition.connection.transport.rawValue]
    }
}
