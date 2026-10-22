import AgentToolingCore
import Foundation

/// Real-`git` fixtures shared by the sync suites.
///
/// `git` shells out to `/usr/bin/git` the way the duplicated fixture bodies did
/// — the sync tests need real refs and a real transport, which a stub cannot
/// provide. `enroll` enrolls a checkout and stamps it with the fixed fixture
/// identity so commits have a stable author.
public enum GitTestFixture {
    /// A `git` run that `checkingStatus` asked to succeed, and that did not.
    public struct CommandFailed: Error, Equatable {
        public let arguments: [String]
        public let status: Int32
    }

    /// Runs `git` with `arguments` in `directory`, discarding its output, and
    /// waits for it to finish. With `checkingStatus`, a run that ends with any
    /// status but 0 throws `CommandFailed`, for a fixture whose later steps
    /// would otherwise fail far from the cause.
    public static func git(_ arguments: [String], in directory: URL, checkingStatus: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard !checkingStatus || process.terminationStatus == 0 else {
            throw CommandFailed(arguments: arguments, status: process.terminationStatus)
        }
    }

    /// Enrolls a checkout against `remote` and sets the fixed fixture Git
    /// identity, so commits authored through the transport have a stable name
    /// and email.
    public static func enroll(remote: URL, checkout: URL) async throws -> GitWorkspaceTransport {
        let transport = try await GitWorkspaceTransport.enroll(remote: remote.path, checkout: checkout)
        try git(["config", "user.email", "fixture@example.com"], in: checkout)
        try git(["config", "user.name", "Fixture"], in: checkout)
        return transport
    }
}
