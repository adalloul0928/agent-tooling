import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The helper contracts: the connection's identity and the command each app
/// is given to add it, and which copies of Agent Tooling may register a
/// helper or are offered the move.
@Suite("Agent Tooling helper · contract")
struct AgentToolingHelperContractTests {
    private static let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"

    /// The commands the sample world's review shows, argument for argument;
    /// the path with a space in it stays one argument.
    @Test func eachAppIsGivenItsOwnAddCommandAtUserScope() {
        #expect(
            AgentToolingConnection.previewArguments(client: .claude, helperPath: Self.helper) == [
                "mcp", "add", "--transport", "stdio", "--scope", "user", "agent-tooling", "--", Self.helper,
            ])
        #expect(
            AgentToolingConnection.previewArguments(client: .codex, helperPath: Self.helper) == [
                "mcp", "add", "agent-tooling", "--", Self.helper,
            ])
        #expect(
            AgentToolingConnection.previewArguments(client: .gemini, helperPath: Self.helper) == [
                "mcp", "add", "--scope", "user", "--transport", "stdio", "agent-tooling", "--", Self.helper,
            ])
        #expect(
            AgentToolingConnection.previewArguments(client: .kiro, helperPath: Self.helper) == [
                "mcp", "add", "--name", "agent-tooling", "--command", Self.helper, "--scope", "global", "--force",
            ])
    }

    /// With nothing observed, nothing is known about any app: each is not
    /// checked yet, never not found.
    @Test func theConnectionIsKnownByOneName() {
        #expect(AgentToolingConnection.declaredName == "agent-tooling")
        #expect(AgentToolingConnection.displayName == "Agent Tooling")
        #expect(
            AgentToolingConnection.states(observations: [], helperPath: Self.helper) == [
                .codex: .notChecked, .claude: .notChecked, .gemini: .notChecked, .kiro: .notChecked,
            ])
    }

    /// Its own connection is the person's, under its name, with a command
    /// each Mac binds for itself; anything else is some other server.
    @Test func itsOwnConnectionIsRecognisedAndNothingElseIs() {
        let id = ArtifactID()
        func artifact(_ authority: ContentAuthority, name: String = "agent-tooling", kind: ArtifactKind = .mcpServer) -> ArtifactRecord {
            .init(identity: .init(id: id, kind: kind, displayName: "Agent Tooling"), authority: authority, declaredName: name)
        }
        let bound = [PortableMCPDefinitionRecord(artifactID: id, connection: .deviceBound(transport: .stdio))]
        let remote = [PortableMCPDefinitionRecord(artifactID: id, connection: .remoteHTTPS(url: "https://example.com/mcp"))]

        #expect(AgentToolingConnection.isOwnConnection(artifact(.centralPersonal), definitions: bound))
        #expect(!AgentToolingConnection.isOwnConnection(artifact(.trackedOnly), definitions: bound))
        #expect(!AgentToolingConnection.isOwnConnection(artifact(.centralPersonal, name: "agent-toolbox"), definitions: bound))
        #expect(!AgentToolingConnection.isOwnConnection(artifact(.centralPersonal, kind: .skill), definitions: bound))
        #expect(!AgentToolingConnection.isOwnConnection(artifact(.centralPersonal), definitions: remote))
        #expect(!AgentToolingConnection.isOwnConnection(artifact(.centralPersonal), definitions: []))
    }

    @Test func onlyACopyInApplicationsMayRegisterItsHelper() {
        let bundle = URL(filePath: "/Applications/Agent Tooling.app", directoryHint: .isDirectory)
        let helperURL = bundle.appending(path: "Contents/Helpers/agent-tooling-mcp")
        let applications = URL(filePath: "/Applications", directoryHint: .isDirectory)

        let installed = AgentToolingInstallation(
            bundleURL: bundle, location: .applications(applications), mcpHelperURL: helperURL, cliHelperURL: nil, isAdHocSigned: true)
        #expect(installed.registrableHelperPath == Self.helper, "an ad-hoc copy in Applications may register")
        #expect(!installed.offersMove)

        let noHelper = AgentToolingInstallation(
            bundleURL: bundle, location: .applications(applications), mcpHelperURL: nil, cliHelperURL: nil, isAdHocSigned: false)
        #expect(noHelper.registrableHelperPath == nil)

        for location in [
            AgentToolingInstallation.Location.diskImage(volumeName: "Agent Tooling", volumeURL: URL(filePath: "/Volumes/Agent Tooling")),
            .translocated(URL(filePath: "/private/var/folders/xy/AppTranslocation/1234/d")),
            .elsewhere(URL(filePath: "/Users/example/Downloads")),
            .developmentBuild,
        ] {
            let copy = AgentToolingInstallation(
                bundleURL: bundle, location: location, mcpHelperURL: helperURL, cliHelperURL: nil, isAdHocSigned: false)
            #expect(copy.registrableHelperPath == nil, "\(location)")
        }
    }

    @Test func theMoveIsOfferedOnlyToACopyThatWouldMoveSafely() {
        let bundle = URL(filePath: "/Volumes/Agent Tooling/Agent Tooling.app", directoryHint: .isDirectory)
        let helperURL = bundle.appending(path: "Contents/Helpers/agent-tooling-mcp")
        func offers(_ location: AgentToolingInstallation.Location, helper: Bool = true, adHoc: Bool = false) -> Bool {
            AgentToolingInstallation(
                bundleURL: bundle, location: location, mcpHelperURL: helper ? helperURL : nil, cliHelperURL: nil,
                isAdHocSigned: adHoc
            ).offersMove
        }
        let image = AgentToolingInstallation.Location.diskImage(
            volumeName: "Agent Tooling", volumeURL: URL(filePath: "/Volumes/Agent Tooling"))
        let downloads = AgentToolingInstallation.Location.elsewhere(URL(filePath: "/Users/example/Downloads"))

        #expect(offers(image))
        #expect(offers(image, adHoc: true), "an ad-hoc disk image still moves")
        #expect(!offers(image, helper: false))
        #expect(offers(.translocated(URL(filePath: "/private/var/folders/xy/AppTranslocation/1234/d"))))
        #expect(offers(downloads))
        #expect(!offers(downloads, adHoc: true), "a local build kept in a folder of its own stays there")
        #expect(!offers(.applications(URL(filePath: "/Applications"))))
        #expect(!offers(.developmentBuild))
    }

    /// A copy with no helper in it is a development build, so nothing offers
    /// it a move or registers its helper. (The inspection itself is pinned in
    /// `AgentToolingInstallationTests`.)
    @Test func aCopyWithNoHelperIsADevelopmentBuild() throws {
        let root = try TemporaryFolder("helper-contract").url
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appending(path: "Applications/Agent Tooling.app", directoryHint: .isDirectory)

        let inspected = AgentToolingInstallation.inspect(
            bundleURL: bundle, homeURL: root.appending(path: "Users/you"), rehearsal: nil)

        #expect(inspected.bundleURL == bundle)
        #expect(inspected.location == .developmentBuild)
        #expect(inspected.mcpHelperURL == nil)
        #expect(inspected.cliHelperURL == nil)
        #expect(!inspected.offersMove)
        #expect(inspected.registrableHelperPath == nil)
    }

    @Test func theLiveVolumeFactsReadAWritableFolder() throws {
        let facts = try #require(AgentToolingInstallation.VolumeFacts.live(FileManager.default.temporaryDirectory))
        #expect(!facts.isReadOnly)
    }
}
