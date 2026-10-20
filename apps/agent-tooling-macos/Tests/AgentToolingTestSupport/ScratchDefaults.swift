import Foundation

/// A defaults suite for one test that leaves nothing in
/// `~/Library/Preferences`.
///
/// A suite named any ordinary way keeps its file in the person's own
/// preferences folder, and `removePersistentDomain(forName:)` empties that
/// file but leaves it there, so every run of a suite that made one left
/// another plist behind. This one is named by an absolute path inside a
/// scratch folder, so its file is written there, and `remove()` takes the
/// domain and the file away. Pass `suite` wherever a suite name goes,
/// `--defaults-suite` included.
public struct ScratchDefaults: @unchecked Sendable {
    /// The folder the suite's file lives in.
    public let folder: URL
    /// The suite's name: a path inside `folder`.
    public let suite: String
    public let defaults: UserDefaults
    /// Whether the suite made `folder`, and so takes it away with it.
    private let ownsFolder: Bool

    /// A suite in a scratch folder of its own, which `remove()` takes away.
    public init(_ label: String) throws {
        let folder = try TemporaryFolder("defaults-\(label)").url
        let suite = folder.appending(path: "\(label)-preferences").path(percentEncoded: false)
        guard let defaults = Self.defaults(named: suite) else {
            try? FileManager.default.removeItem(at: folder)
            throw CocoaError(.fileWriteUnknown)
        }
        self.init(folder: folder, suite: suite, defaults: defaults, ownsFolder: true)
    }

    /// A suite whose file lives in `folder`, a scratch folder the caller
    /// keeps (a fixture's own), so the suite goes when that folder does.
    /// Each suite made this way has a name of its own, so several can share
    /// the folder.
    public init(_ label: String, in folder: URL) throws {
        let suite = folder.appending(path: "\(label)-\(UUID().uuidString)").path(percentEncoded: false)
        guard let defaults = Self.defaults(named: suite) else { throw CocoaError(.fileWriteUnknown) }
        self.init(folder: folder, suite: suite, defaults: defaults, ownsFolder: false)
    }

    private init(folder: URL, suite: String, defaults: UserDefaults, ownsFolder: Bool) {
        self.folder = folder
        self.suite = suite
        self.defaults = defaults
        self.ownsFolder = ownsFolder
    }

    /// The one place a test makes a suite.
    private static func defaults(named suite: String) -> UserDefaults? {
        UserDefaults(suiteName: suite)
    }

    /// The suite's own file, where its preferences are written.
    public var file: URL { URL(filePath: suite + ".plist") }

    /// Forgets the suite's values and removes its file, and its folder when
    /// the suite made that.
    public func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: ownsFolder ? folder : file)
    }

    /// The person's own preferences folder, where an ordinary suite's file
    /// would have gone.
    public static var preferencesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences", directoryHint: .isDirectory)
    }
}
