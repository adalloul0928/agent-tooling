import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// One list of the folders a command is looked for in by name. Every child
/// this app starts gets it as its `PATH`, the audit counts a server reachable
/// by it, and the client-tool locator checks it, so none of them can find a
/// command the others cannot.
@Suite("One search path for commands")
struct ProcessSearchPathTests {
    /// When two folders hold the same name the earlier one wins, so the
    /// folders a child always searched keep their places and order, and the
    /// ones added follow them.
    @Test func theFoldersAChildAlwaysSearchedKeepTheirOrderAndTheAddedOnesFollow() {
        let path = ProcessCommandRunner.searchPath(home: "/Users/example")

        #expect(
            Array(path.prefix(11)) == [
                "/Users/example/.local/bin",
                "/Users/example/.cargo/bin",
                "/Users/example/.volta/bin",
                "/Users/example/.bun/bin",
                "/Users/example/Library/pnpm",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ])
        for folder in [".npm-global/bin", ".local/share/mise/shims", ".asdf/shims", "bin"] {
            #expect(path.dropFirst(11).contains("/Users/example/\(folder)"), "\(folder)")
        }
        #expect(Set(path).count == path.count, "no folder is listed twice")
    }

    /// Audit and live tests must agree on command availability.
    @Test func everyFolderTheAuditSearchesIsOneALiveTestSearches() throws {
        let home = try TemporaryFolder("process-search-path").url
        defer { try? FileManager.default.removeItem(at: home) }
        let homePath = ProcessCommandRunner.plainPath(of: home) + "/"
        let folders = SetupAuditor.defaultSearchPath(homeURL: home).filter {
            $0.path(percentEncoded: false).hasPrefix(homePath)
        }
        #expect(folders.count == 9)

        for (index, folder) in folders.enumerated() {
            let name = "fixture-server-\(index)"
            let file = folder.appending(path: name, directoryHint: .notDirectory)
            try write(file, "#!/bin/echo\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))

            #expect(SetupAuditor(homeURL: home).commandIsReachable(name), "\(folder.path(percentEncoded: false))")
            let target = try MCPTestConnectionPolicy.resolveStdio([name], homeURL: home)
            #expect(target == .stdio(executableURL: file.standardizedFileURL, arguments: []))
        }
    }

    /// The locator shares command roots but retains its install precedence.
    @Test func theLocatorChecksTheFoldersAChildSearchesWithItsOwnFirst() {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let roots = ClientExecutableLocator.fixedRoots(homeURL: home).map { ProcessCommandRunner.plainPath(of: $0) }
        let shared = ProcessCommandRunner.searchPath(home: "/Users/example")

        #expect(roots.count == shared.count)
        #expect(Set(roots) == Set(shared))
        #expect(
            Array(roots.prefix(5)) == [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/Users/example/.local/bin",
                "/Users/example/.bun/bin",
                "/Users/example/.npm-global/bin",
            ])
        #expect(Array(roots.dropFirst(5)) == shared.filter { !roots.prefix(5).contains($0) })
    }
}
