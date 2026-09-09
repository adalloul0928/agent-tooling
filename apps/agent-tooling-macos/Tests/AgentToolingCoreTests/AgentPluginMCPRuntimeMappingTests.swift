import Foundation
import Testing

@testable import AgentToolingCore

/// AP5 conformance: what a package's declared connections actually become for
/// one app on this Mac. Parsing says a declaration is well-formed; this decides
/// whether any app can use it, and says so when none can.
@Suite("Agent plugin MCP runtime mapping")
struct AgentPluginMCPRuntimeMappingTests {
    @Test func theTwoClientVariablesAreFilledInAndAlwaysWin() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = fixture.resolve(["server": .stdio(.init(
            command: "./bin/run",
            arguments: ["--root", "${PLUGIN_ROOT}/config", "--state", "${PLUGIN_DATA}"],
            environment: ["CACHE": "${PLUGIN_DATA}/cache", "MODE": "quiet"],
            currentDirectory: "${PLUGIN_DATA}"))])

        #expect(result.refused.isEmpty, "\(result.refused)")
        let server = try #require(result.resolved.first)
        #expect(server.executable == fixture.packageRoot.appending(path: "bin/run").path)
        #expect(server.arguments == ["--root", fixture.packageRoot.appending(path: "config").path,
                                     "--state", fixture.dataRoot.path])
        #expect(server.environment["CACHE"] == fixture.dataRoot.appending(path: "cache").path)
        #expect(server.environment["MODE"] == "quiet")
        // The client owns these two, and nothing declared can shadow them.
        #expect(server.environment["PLUGIN_ROOT"] == fixture.packageRoot.path)
        #expect(server.environment["PLUGIN_DATA"] == fixture.dataRoot.path)
        #expect(server.workingDirectory == fixture.dataRoot.path)
    }

    @Test func dataOutlivesThePackageItBelongsTo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // The point of the two roots being different: content is replaced on
        // update, data is not. They must never resolve to the same folder.
        let result = fixture.resolve(["server": .stdio(.init(command: "run"))])

        let server = try #require(result.resolved.first)
        #expect(server.environment["PLUGIN_ROOT"] != server.environment["PLUGIN_DATA"])
        #expect(FileManager.default.fileExists(atPath: fixture.dataRoot.path))
    }

    @Test func aVariableThisBuildDoesNotDefineIsRefusedRatherThanPassedThrough() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for declaration in [
            AgentPluginMCPServer.stdio(.init(command: "run", arguments: ["${HOME}/x"])),
            .stdio(.init(command: "run", environment: ["TOKEN": "${SECRET}"])),
        ] {
            let result = fixture.resolve(["server": declaration])
            // Passing it through unexpanded would become a wrong path that
            // looks like a right one.
            #expect(result.resolved.isEmpty)
            #expect(result.refused.first?.reason == .unknownPlaceholder)
        }
    }

    @Test func aLinkInsideThePackagePointingOutOfItIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: outside.appending(path: "run"))
        try FileManager.default.createSymbolicLink(
            at: fixture.packageRoot.appending(path: "bin/escaped"),
            withDestinationURL: outside.appending(path: "run"))

        let result = fixture.resolve(["server": .stdio(.init(command: "./bin/escaped"))])

        // Containment is checked after the link is followed, which is the whole
        // reason a lexical check is not enough.
        #expect(result.resolved.isEmpty)
        #expect(result.refused.first?.reason == .escapesPackage)
    }

    @Test func aCwdThatClimbsOutOfItsRootIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let elsewhere = fixture.root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.dataRoot.appending(path: "link"), withDestinationURL: elsewhere)

        let result = fixture.resolve(["server": .stdio(.init(
            command: "run", currentDirectory: "${PLUGIN_DATA}/link"))])

        #expect(result.refused.first?.reason == .escapesPackage)
    }

    @Test func aBareCommandIsLeftForTheClientToResolve() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = fixture.resolve(["server": .stdio(.init(command: "npx", arguments: ["-y", "thing"]))])

        // This build does not search PATH and does not claim the file exists;
        // saying it did would be a promise it cannot keep.
        #expect(result.resolved.first?.executable == "npx")
        #expect(result.refused.isEmpty)
    }

    @Test func aPathThePackageNamesButDoesNotContainIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = fixture.resolve(["server": .stdio(.init(command: "./bin/absent"))])

        #expect(result.refused.first?.reason == .missingExecutable)
    }

    @Test func anAppThatDoesNotAcceptThisTransportIsToldSoRatherThanSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // This Mac recorded stdio support only.
        let result = fixture.resolve([
            "local": .stdio(.init(command: "run")),
            "remote": .streamableHTTP(.init(url: "https://example.com/mcp")),
        ])

        #expect(result.resolved.map(\.name) == ["local"])
        let refusal = try #require(result.refused.first)
        #expect(refusal.name == "remote")
        #expect(refusal.reason == .unsupportedTransport)
        // A silently missing server looks exactly like one never declared.
        #expect(!refusal.detail.isEmpty)
    }

    @Test func anAppWithNoRecordedMCPEvidenceGetsNothingAndIsToldWhy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = fixture.resolve(["server": .stdio(.init(command: "run"))], evidence: [])

        #expect(result.resolved.isEmpty)
        #expect(result.refused.map(\.reason) == [.noRecordedSupport])
    }

    @Test func oneBadServerDoesNotTakeItsSiblingsWithIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = fixture.resolve([
            "good": .stdio(.init(command: "run")),
            "bad": .stdio(.init(command: "run", arguments: ["${NOPE}"])),
            "alsoGood": .stdio(.init(command: "./bin/run")),
        ])

        #expect(result.resolved.map(\.name).sorted() == ["alsoGood", "good"])
        #expect(result.refused.map(\.name) == ["bad"])
    }

    @Test func aRemoteEndpointKeepsItsOwnAddressAndCarriesNoCredential() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = fixture.resolve(
            ["remote": .streamableHTTP(.init(url: "https://example.com/mcp",
                                            headers: ["X-Client": "agent-tooling"]))],
            evidence: [Fixture.evidence(transport: "streamable-http")])

        let server = try #require(result.resolved.first)
        #expect(server.endpoint == "https://example.com/mcp")
        #expect(server.headers == ["X-Client": "agent-tooling"])
        // Bound to the origin the declaration named. This build follows no
        // redirect for the package, so a header never travels to another host.
        #expect(server.executable == nil && server.workingDirectory == nil)
    }

    @Test func aMissingPackageOrDataFolderIsReportedNotGuessedAt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = AgentPluginMCPRuntimeMapper.resolve(
            servers: ["server": .stdio(.init(command: "run"))],
            packageRoot: fixture.root.appending(path: "gone"),
            dataRoot: fixture.dataRoot, surface: .codexCLI,
            evidence: [Fixture.evidence(transport: "stdio")])

        #expect(result.resolved.isEmpty)
        #expect(result.refused.map(\.reason) == [.missingRoot])
    }

    private struct Fixture {
        let root: URL
        let packageRoot: URL
        let dataRoot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "mcp-runtime-\(UUID())")
            packageRoot = root.appending(path: "package")
            dataRoot = root.appending(path: "data")
            for url in [packageRoot.appending(path: "bin"), packageRoot.appending(path: "config"),
                        dataRoot] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let executable = packageRoot.appending(path: "bin/run")
            try Data("#!/bin/sh\necho hi\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: executable.path)
        }

        static func evidence(transport: String) -> TargetCapabilityEvidence {
            .init(surface: .codexCLI, installedClientVersion: "1.0.0", adapterContractVersion: 1,
                  component: .mcpServer, transport: transport, scopes: [.user], support: .supported,
                  observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }

        func resolve(
            _ servers: [String: AgentPluginMCPServer],
            evidence: [TargetCapabilityEvidence] = [Fixture.evidence(transport: "stdio")]
        ) -> AgentPluginMCPRouteResult {
            AgentPluginMCPRuntimeMapper.resolve(
                servers: servers, packageRoot: packageRoot, dataRoot: dataRoot,
                surface: .codexCLI, evidence: evidence)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
