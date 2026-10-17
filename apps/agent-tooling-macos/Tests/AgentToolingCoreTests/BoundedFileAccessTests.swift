import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The bounded read that fingerprints and backups rely on: the bytes it
/// returns are the bytes of the file it sized, and a file that changed while
/// it was read is refused rather than returned new or torn.
@Suite("Bounded file access")
struct BoundedFileAccessTests {
    @Test func aFileLeftAloneIsReadAsItIs() throws {
        let fixture = try TemporaryFolder("bounded-file-access").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appending(path: "settings.json")
        try write(file, "aaaa")

        #expect(try BoundedFileAccess.readData(at: file, maximumBytes: 1_024) == Data("aaaa".utf8))
    }

    /// The same number of bytes written over the file in place leaves its
    /// size alone, so only its modification time says it changed. A URL keeps
    /// the values it fetched first, so the check must look at the file again.
    @Test func aSameSizeRewriteDuringTheReadIsRefused() throws {
        let fixture = try TemporaryFolder("bounded-file-access").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appending(path: "settings.json")
        try write(file, "aaaa")

        let refusal = #expect(throws: BoundedFileAccessError.self) {
            _ = try BoundedFileAccess.readData(
                at: file, maximumBytes: 1_024,
                afterReading: {
                    let handle = try FileHandle(forWritingTo: file)
                    try handle.write(contentsOf: Data("bbbb".utf8))
                    try handle.close()
                })
        }
        #expect(Self.isChangedWhileReading(refusal), "\(String(describing: refusal))")
    }

    /// A save that replaces the file with a new one of the same size leaves
    /// a different file at the path, which the check must see.
    @Test func aSameSizeReplacementDuringTheReadIsRefused() throws {
        let fixture = try TemporaryFolder("bounded-file-access").url
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appending(path: "settings.json")
        try write(file, "aaaa")

        let refusal = #expect(throws: BoundedFileAccessError.self) {
            _ = try BoundedFileAccess.readData(
                at: file, maximumBytes: 1_024,
                afterReading: { try "cccc".write(to: file, atomically: true, encoding: .utf8) })
        }
        #expect(Self.isChangedWhileReading(refusal), "\(String(describing: refusal))")
    }

    private static func isChangedWhileReading(_ error: BoundedFileAccessError?) -> Bool {
        if case .changedWhileReading = error { return true }
        return false
    }
}
