import Foundation

/// A self-cleaning temporary directory for tests.
///
/// Reproduces the fixture-root idiom repeated across the suites:
/// `FileManager.default.temporaryDirectory.resolvingSymlinksInPath()`
/// `.appending(path: "<prefix>-\(UUID())")`, created with the restrictive
/// `0o700` permissions the fixtures use. The caller removes it. The symlink
/// resolution matters because some tests compare against a resolved path, so the
/// shape must stay identical; the `0o700` creation matches the dominant form so
/// migrated sites keep writing the same bytes with the same mode.
public struct TemporaryFolder {
    public let url: URL

    /// Builds and creates a unique directory `<prefix>-<uuid>` under the system
    /// temporary directory, with `0o700` permissions and intermediate
    /// directories.
    public init(_ prefix: String) throws {
        url = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: "\(prefix)-\(UUID())")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
