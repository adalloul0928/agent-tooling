import Foundation
import Testing

@testable import AgentToolingCore

struct DiagnosticsTests {
    @Test func supportBundleContainsOnlyRedactedOperationalMetadata() throws {
        let startedAt = Date(timeIntervalSince1970: 10)
        let receipt = OperationReceipt(
            planID: UUID(),
            kind: .doctor,
            title: "Checked /Users/private/.codex/config.toml",
            state: .attention,
            targetSurfaces: [.codexCLI],
            results: [
                OperationStepResult(
                    stepID: UUID(),
                    status: .failed,
                    output:
                        "API_TOKEN=secret-value at /Users/private/.codex/config.toml; peer /Users/another-person/project; temp /private/var/folders/ab/cdef/T/file",
                    startedAt: startedAt,
                    finishedAt: startedAt
                )
            ],
            createdAt: startedAt,
            verificationSummary: "Review /Users/private/.codex/config.toml"
        )
        let observation = TargetObservation(
            surface: .codexCLI,
            installed: true,
            version: "codex 1.0",
            capabilities: TargetCapabilities(
                supportsPluginInstall: true,
                supportsProjectScope: true,
                supportsLocalMarketplace: true,
                supportsMCPAuthentication: true,
                supportsConnectorDiscovery: false,
                requiresNewSession: true,
                requiresRestart: false,
                supportsMachineReadableOutput: true
            ),
            notes: ["Loaded /Users/private/.codex/config.toml"]
        )
        let snapshot = WorkspaceSnapshot(
            operationReceipts: [receipt],
            targetObservations: [observation]
        )
        let exporter = DiagnosticBundleExporter(homeURL: URL(fileURLWithPath: "/Users/private"))

        let manifest = exporter.manifest(snapshot: snapshot, appVersion: "1.0")
        let data = try AgentToolingCoding.encoder(prettyPrinted: true).encode(manifest)
        let output = String(decoding: data, as: UTF8.self)

        #expect(output.contains("secret-value") == false)
        #expect(output.contains("/Users/private") == false)
        #expect(output.contains("/Users/another-person") == false)
        #expect(output.contains("/private/var/folders/ab/cdef") == false)
        #expect(output.contains("API_TOKEN=[redacted]"))
        #expect(manifest.clients.first?.notes.first == "Loaded ~/.codex/config.toml")
        #expect(manifest.validationSummary.attentionCount == 1)
    }

    @Test func supportBundleExportsAtomicallyWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-diagnostics-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(path: "support.json")
        let exporter = DiagnosticBundleExporter()
        let manifest = exporter.manifest(snapshot: WorkspaceSnapshot(), appVersion: "1.0")

        try exporter.export(manifest, to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
