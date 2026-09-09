import Foundation
import Testing

@testable import AgentToolingCore

/// An export carries every byte and explains what each target can do with it.
/// Nothing is translated, repaired or dropped to make a package look portable.
@Suite("Workspace package export")
struct WorkspacePackageExportTests {
    @Test func everyFileResourceLinkAndEmptyDirectorySurvivesTheRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "package-export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "export")

        try WorkspacePackageExporter.write(tree: Self.tree, to: destination)

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: destination.appending(path: "SKILL.md").path))
        #expect(try Data(contentsOf: destination.appending(path: "references/notes.md"))
            == Data("reference\n".utf8))
        var isDirectory: ObjCBool = false
        #expect(manager.fileExists(atPath: destination.appending(path: "assets").path,
                                   isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "An empty directory must survive the export.")
        #expect(try manager.destinationOfSymbolicLink(atPath: destination.appending(path: "README").path)
            == "SKILL.md")
        let permissions = try manager.attributesOfItem(atPath: destination.appending(path: "scripts/run").path)
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        // An unknown vendor file is carried, not interpreted.
        #expect(manager.fileExists(atPath: destination.appending(path: "vendor.unknown").path))

        // Reading it back reproduces the same content identity.
        let recaptured = try await PackageTreeCapture().capture(directory: destination)
        #expect(recaptured.digest == Self.tree.digest)
    }

    @Test func anExistingNonEmptyDestinationIsRefusedRatherThanMergedInto() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "package-export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "export")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing\n".utf8).write(to: destination.appending(path: "keep.txt"))

        #expect(throws: WorkspacePackageExportError.destinationNotEmpty) {
            try WorkspacePackageExporter.write(tree: Self.tree, to: destination)
        }
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "keep.txt").path))
    }

    @Test func anUnsupportedTargetIsReportedRatherThanTheExportBeingChanged() throws {
        let export = WorkspacePackageExporter.preview(
            artifact: Self.skill, tree: Self.tree,
            targets: Self.evidence(surface: .codexCLI, components: [.skill], transports: [])
                + Self.evidence(surface: .geminiCLI, components: [.mcpServer], transports: []),
            declaredTransports: ["stdio"])

        let codexEntry = export.compatibility.first { $0.surface == .codexCLI }
        let codex = try #require(codexEntry)
        #expect(codex.notes.contains { $0.kind == .unsupportedTransport })
        #expect(!codex.isFullySupported)
        let geminiEntry = export.compatibility.first { $0.surface == .geminiCLI }
        let gemini = try #require(geminiEntry)
        #expect(gemini.notes.contains { $0.kind == .unsupportedComponent })
        // The package itself is unchanged by an unsupported target.
        #expect(export.relativePaths.contains("scripts/run"))
        #expect(export.fileCount == 4)
    }

    @Test func executableContentIsNamedAndAPackageCannotCarryAnEscapingLink() throws {
        let export = WorkspacePackageExporter.preview(
            artifact: Self.skill, tree: Self.tree,
            targets: Self.evidence(surface: .codexCLI, components: [.skill], transports: ["stdio"]))

        let report = try #require(export.compatibility.first)
        #expect(report.notes.contains { $0.kind == .executableContent && $0.relativePath == "scripts/run" })
        // Executable content is a warning for the reader, not an incompatibility.
        #expect(report.isFullySupported)

        // Content that leaves the package never reaches an export: the tree
        // contract refuses it, so nothing here has to detect it later.
        for target in ["../elsewhere", "/etc/hosts"] {
            #expect(throws: PackageTreeError.unsafeSymbolicLink) {
                _ = try CapturedPackageTree(entries: Self.tree.entries + [
                    .init(relativePath: "outside", kind: .symbolicLink(target: target)),
                ])
            }
        }
    }

    @Test func aNativelyOwnedPackageSaysItsOwnAppInstallsIt() {
        let plugin = ArtifactRecord(
            identity: .init(id: ArtifactID(), kind: .nativePlugin, displayName: "Browser"),
            authority: .nativeOwned, declaredName: "browser",
            nativeRoutes: [.init(client: .codex, externalPluginID: "browser")])
        let export = WorkspacePackageExporter.preview(
            artifact: plugin, tree: Self.tree,
            targets: Self.evidence(surface: .codexCLI, components: [.plugin], transports: []))

        #expect(export.compatibility.first?.notes.contains { $0.kind == .nativeAdapterDependency } == true)
    }

    private static var skill: ArtifactRecord {
        .init(identity: .init(id: ArtifactID(), kind: .skill, displayName: "Personal"),
              authority: .centralPersonal, declaredName: "personal", contentDigest: tree.digest)
    }

    private static let tree: CapturedPackageTree = {
        try! CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(
                bytes: Data("---\nname: personal\ndescription: Fixture\n---\n\n# Personal\n".utf8),
                executable: false)),
            .init(relativePath: "references", kind: .directory),
            .init(relativePath: "references/notes.md", kind: .file(
                bytes: Data("reference\n".utf8), executable: false)),
            .init(relativePath: "scripts", kind: .directory),
            .init(relativePath: "scripts/run", kind: .file(
                bytes: Data("#!/bin/sh\necho personal\n".utf8), executable: true)),
            .init(relativePath: "assets", kind: .directory),
            .init(relativePath: "vendor.unknown", kind: .file(
                bytes: Data("{\"vendor\":true}\n".utf8), executable: false)),
            .init(relativePath: "README", kind: .symbolicLink(target: "SKILL.md")),
        ])
    }()

    private static func evidence(
        surface: TargetSurface,
        components: [ComponentKind],
        transports: [String]
    ) -> [TargetCapabilityEvidence] {
        components.map {
            .init(surface: surface, installedClientVersion: "1.0.0", adapterContractVersion: 1,
                  component: $0, transport: $0 == .mcpServer ? transports.first : nil,
                  scopes: [.user], support: .supported,
                  observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }
}
