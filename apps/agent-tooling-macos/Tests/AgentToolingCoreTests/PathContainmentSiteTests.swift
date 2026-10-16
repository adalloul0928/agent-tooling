import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The allow, write and delete guards that compare paths through
/// `PathContainment`, each checked at the boundary it guards: a sibling whose
/// name only extends the root's is not inside it, nothing is inside the
/// filesystem root, and a differently cased spelling is refused.
@Suite("Path containment at allow sites")
struct PathContainmentAllowSiteTests {
    // MARK: Skill draft delete guard

    @Test func theDraftDeleteGuardAcceptsARequestFolderDirectlyInsideTheStagingRoot() {
        let staging = URL(fileURLWithPath: "/drafts/staging", isDirectory: true)
        let request = staging.appending(path: "request-1234", directoryHint: .isDirectory)

        let removable = SkillDraftService.removableRequestDirectory(request, stagingRoot: staging)

        #expect(removable?.path(percentEncoded: false) == "/drafts/staging/request-1234/")
    }

    @Test func theDraftDeleteGuardRefusesEverythingOutsideThatLayout() {
        let staging = URL(fileURLWithPath: "/drafts/staging", isDirectory: true)
        let refused = [
            // Outside the staging root altogether.
            "/drafts/elsewhere/request-1234",
            // Siblings whose names only extend the staging root's.
            "/drafts/staging-old/request-1234",
            "/drafts/stagingrequest-1234",
            // Inside the root, but not a request folder directly inside it.
            "/drafts/staging/request-1234/draft",
            "/drafts/staging/other",
            "/drafts/staging",
            // Climbs out once standardized.
            "/drafts/staging/request-1234/../../victim",
        ]
        for path in refused {
            #expect(
                SkillDraftService.removableRequestDirectory(URL(fileURLWithPath: path), stagingRoot: staging) == nil,
                "\(path)")
        }
        #expect(
            SkillDraftService.removableRequestDirectory(
                URL(fileURLWithPath: "/request-1234"), stagingRoot: URL(fileURLWithPath: "/")) == nil)
    }

    /// The guard judges the standardized URL and hands back that same URL, so
    /// what is removed is what was checked. Spelled through a link and `..`,
    /// a request URL reaches a folder beside the link's target. Until that
    /// folder exists, standardizing removes the `..` as text and the guard
    /// hands back the folder inside the staging root, never the spelling the
    /// kernel would follow; once it exists, standardizing follows the link to
    /// it and the guard refuses.
    @Test func theDraftDeleteGuardHandsBackOnlyTheURLItChecked() throws {
        let fixture = try TemporaryFolder("path-containment-draft-guard").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let staging = fixture.appending(path: "staging", directoryHint: .isDirectory)
        let inner = fixture.appending(path: "elsewhere/inner", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: staging.appending(path: "link"), withDestinationURL: inner)
        let spelled = URL(fileURLWithPath: staging.appending(path: "link").path(percentEncoded: false) + "/../request-1234")

        let removable = SkillDraftService.removableRequestDirectory(spelled, stagingRoot: staging)
        #expect(removable?.path(percentEncoded: false) == staging.appending(path: "request-1234").path(percentEncoded: false))

        try FileManager.default.createDirectory(
            at: fixture.appending(path: "elsewhere/request-1234"), withIntermediateDirectories: true)
        #expect(SkillDraftService.removableRequestDirectory(spelled, stagingRoot: staging) == nil)
    }

    // MARK: Skill draft staging root

    @Test func aStagingRootBesideTheHomeFolderIsNotInsideIt() async throws {
        let fixture = try TemporaryFolder("path-containment-staging").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let home = FolderOverridingFileManager.home(under: fixture)

        let besideRefused = try await Self.stagingRootRefusal(
            at: fixture.appending(path: "home-old/staging", directoryHint: .isDirectory), fixture: fixture)
        let insideRefused = try await Self.stagingRootRefusal(
            at: home.appending(path: "staging", directoryHint: .isDirectory), fixture: fixture)

        #expect(besideRefused)
        // Accepted, so it gets as far as finding no conversation to continue.
        #expect(!insideRefused)
    }

    // MARK: Skill creator request folder

    @Test func aRequestFolderMustBeStrictlyInsideTheHomeFolderAsSpelled() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let name = "request-\(UUID().uuidString.lowercased())"

        #expect(SkillCreatorCommandShapes.isRequestDirectoryPath("/Users/me/drafts/\(name)", homeURL: home))
        // A sibling whose name only extends the home folder's.
        #expect(!SkillCreatorCommandShapes.isRequestDirectoryPath("/Users/meow/\(name)", homeURL: home))
        // Allow checks compare exactly, so another spelling is refused.
        #expect(!SkillCreatorCommandShapes.isRequestDirectoryPath("/users/me/drafts/\(name)", homeURL: home))
        // Nothing is inside the filesystem root, so a home of "/" admits nothing.
        #expect(!SkillCreatorCommandShapes.isRequestDirectoryPath("/drafts/\(name)", homeURL: URL(fileURLWithPath: "/")))
    }

    // MARK: First-run package members

    @Test func aPackageMemberIsAFolderStrictlyInsideThePackage() {
        #expect(WorkspaceFirstRun.relativeMemberDirectory("/p/pkg/skills/x/SKILL.md", packageRoot: "/p/pkg") == "skills/x")
        #expect(WorkspaceFirstRun.relativeMemberDirectory("/p/pkg-other/skills/x/SKILL.md", packageRoot: "/p/pkg") == nil)
        #expect(WorkspaceFirstRun.relativeMemberDirectory("/p/pkg/SKILL.md", packageRoot: "/p/pkg") == nil)
        // A package rooted at "/" claims nothing below it.
        #expect(WorkspaceFirstRun.relativeMemberDirectory("/p/pkg/skills/x/SKILL.md", packageRoot: "/") == nil)
    }

    // MARK: Plugin MCP paths

    @Test func aPluginCommandLinkedIntoASiblingOfThePackageIsSkipped() throws {
        let fixture = try TemporaryFolder("path-containment-mcp-models").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "package", directoryHint: .isDirectory)
        let sibling = fixture.appending(path: "package-sibling", directoryHint: .isDirectory)
        try write(root.appending(path: "bin/server"), "")
        try write(sibling.appending(path: "server"), "")
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "bin/beside"), withDestinationURL: sibling.appending(path: "server"))
        let data = Data(
            """
            {"$schema":"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json","mcpServers":{
            "inside":{"type":"stdio","command":"./bin/server"},
            "beside":{"type":"stdio","command":"./bin/beside"}}}
            """.utf8)

        let result = try AgentPluginMCPConfigurationLoader.load(data, packageRoot: root)

        #expect(result.servers.keys.sorted() == ["inside"])
        #expect(result.issues.map(\.serverName) == ["beside"])
    }

    @Test func aRuntimePathLinkedIntoASiblingOfThePackageEscapesIt() throws {
        let fixture = try TemporaryFolder("path-containment-mcp-runtime").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "package", directoryHint: .isDirectory)
        let data = fixture.appending(path: "data", directoryHint: .isDirectory)
        let sibling = fixture.appending(path: "package-sibling", directoryHint: .isDirectory)
        try write(sibling.appending(path: "run"), "#!/bin/sh\n")
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "bin/beside"), withDestinationURL: sibling.appending(path: "run"))
        let evidence = TargetCapabilityEvidence(
            surface: .codexCLI, installedClientVersion: "1.0.0", adapterContractVersion: 1,
            component: .mcpServer, transport: "stdio", scopes: [.user], support: .supported,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let result = AgentPluginMCPRuntimeMapper.resolve(
            servers: ["server": .stdio(.init(command: "./bin/beside"))], packageRoot: root, dataRoot: data,
            surface: .codexCLI, evidence: [evidence])

        #expect(result.resolved.isEmpty)
        #expect(result.refused.first?.reason == .escapesPackage)
    }

    // MARK: Replacement receipt count

    /// The count compares each enumerated item against its root, so a root
    /// spelled with `..`, or with the `/private` prefix a real path carries,
    /// must be normalized like the items or nothing matches and the receipt
    /// reports no removals.
    @Test func theRemovalCountMatchesItemsUnderAnyNormalSpellingOfTheRoot() throws {
        let fixture = try TemporaryFolder("path-containment-removals").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let destination = fixture.appending(path: "destination", directoryHint: .isDirectory)
        let source = fixture.appending(path: "source", directoryHint: .isDirectory)
        try write(destination.appending(path: "kept.md"), "kept")
        try write(destination.appending(path: "gone.md"), "gone")
        try write(destination.appending(path: "folder/also-gone.md"), "gone")
        try write(source.appending(path: "kept.md"), "kept")
        try FileManager.default.createDirectory(at: fixture.appending(path: "step"), withIntermediateDirectories: true)
        let reviewer = OperationPlanSafetyReviewer()

        var spellings = [destination, URL(fileURLWithPath: fixture.path(percentEncoded: false) + "/step/../destination")]
        let realSpelling = "/private" + destination.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: realSpelling) { spellings.append(URL(fileURLWithPath: realSpelling)) }
        for spelling in spellings {
            let count = reviewer.replacementRemovalCount(replacing: spelling, with: source)
            // gone.md, folder/ and folder/also-gone.md are not in the package.
            #expect(count.count == 3, "\(spelling.path(percentEncoded: false))")
            #expect(!count.isTruncated)
        }
    }

    // MARK: Helpers

    /// Whether a service staging at `stagingRoot` refuses it, as opposed to
    /// accepting it and then finding no conversation to continue. The home and
    /// temporary folders the service checks against are fixture folders.
    private static func stagingRootRefusal(at stagingRoot: URL, fixture: URL) async throws -> Bool {
        let service = SkillDraftService(
            stagingRootURL: stagingRoot, runner: UnreachedRunner(),
            skillCreatorURL: fixture.appending(path: "creator/SKILL.md"),
            homeURL: FolderOverridingFileManager.home(under: fixture),
            fileManager: try FolderOverridingFileManager(under: fixture))
        do {
            _ = try await service.continueConversation(requestID: UUID(), reply: "Carry on.")
            Issue.record("A conversation that was never started cannot be continued.")
            return false
        } catch SkillDraftError.unsafeStagingRoot {
            return true
        } catch SkillDraftError.noConversation {
            return false
        }
    }
}

/// A file manager whose home and temporary folders are fixture folders, so a
/// staging-root check can be judged without the real home folder.
private final class FolderOverridingFileManager: FileManager, @unchecked Sendable {
    let home: URL
    let temporary: URL

    static func home(under root: URL) -> URL { root.appending(path: "home", directoryHint: .isDirectory) }

    init(under root: URL) throws {
        home = Self.home(under: root)
        temporary = root.appending(path: "tmp", directoryHint: .isDirectory)
        super.init()
        for folder in [home, temporary, home.appending(path: "Library", directoryHint: .isDirectory)] {
            try createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override var homeDirectoryForCurrentUser: URL { home }
    override var temporaryDirectory: URL { temporary }
}

/// A runner the staging-root tests never reach: the root is judged first.
private struct UnreachedRunner: StandardInputCommandRunning {
    func run(executable: String, arguments: [String], standardInput: Data, currentDirectory: URL?) async throws -> CommandOutput {
        Issue.record("Nothing should run before the staging root is judged.")
        return CommandOutput(status: 1, standardOutput: "", standardError: "")
    }
}
