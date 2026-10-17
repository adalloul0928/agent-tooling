import Foundation

/// Writes `text` to `url`, creating the parent directory first.
///
/// This is the write-a-file idiom the suites reimplement: create the enclosing
/// directory with intermediate directories, then write the UTF-8 bytes. Keeping
/// one copy means the cross-file reach-ins (one suite calling another's
/// `write`) become an explicit, supported dependency.
public func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
