import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// The words the Skills, Projects and Activity screens build from data rather
/// than write out: what they call a library item, and how they count one.
/// The app names the library item a "connection" and an installed item a
/// "copy" everywhere else, and one of anything reads in the singular.
@Suite("Skills, Projects and Activity wording")
struct SkillsProjectsActivityWordingTests {
    private func component(_ id: String, kind: ComponentKind) -> ProjectComponentRecord {
        ProjectComponentRecord(
            id: id, name: id, kind: kind, client: .claude, sharing: .committed,
            sourceRelativePath: ".mcp.json", sourcePath: nil)
    }

    private func folder(
        skills: Int = 0, connections: Int = 0, plugins: Int = 0, branch: String? = nil, detached: Bool = false
    ) -> DiscoveredProject {
        DiscoveredProject(
            path: "/tmp/found", name: "found", gitBranch: branch, isDetachedHead: detached,
            skills: (0..<skills).map { component("skill-\($0)", kind: .skill) },
            mcpServers: (0..<connections).map { component("connection-\($0)", kind: .mcpServer) },
            plugins: (0..<plugins).map { component("plugin-\($0)", kind: .plugin) })
    }

    @Test("A found folder counts its connections as connections, one in the singular")
    func foundFolderNamesConnections() {
        #expect(folder(connections: 1).foundFolderSummary == "1 connection")
        #expect(folder(connections: 2).foundFolderSummary == "2 connections")
        #expect(!folder(connections: 3).foundFolderSummary.contains("server"))
    }

    @Test("A found folder lists each kind it holds, in the singular for one")
    func foundFolderCountsEachKind() {
        #expect(
            folder(skills: 1, connections: 1, plugins: 1, branch: "main").foundFolderSummary
                == "1 skill · 1 connection · 1 plugin · on main")
        #expect(folder(skills: 2, plugins: 3).foundFolderSummary == "2 skills · 3 plugins")
        #expect(folder(skills: 1, branch: "4f2a9c1", detached: true).foundFolderSummary == "1 skill · at 4f2a9c1")
    }

    @Test("A found folder with nothing of the library's says so rather than reading as empty")
    func foundFolderWithNothingSaysSo() {
        #expect(folder().foundFolderSummary == "No agent files")
        #expect(folder(branch: "main").foundFolderSummary == "No agent files · on main")
    }

    @Test("Drift names installed copies, and one copy in the singular")
    func driftNamesInstalledCopies() {
        #expect(InstallDriftNotice.title(count: 1) == "1 installed copy differs from what you reviewed")
        #expect(InstallDriftNotice.title(count: 2) == "2 installed copies differ from what you reviewed")
        #expect(!InstallDriftNotice.title(count: 2).contains("package"))
    }
}
