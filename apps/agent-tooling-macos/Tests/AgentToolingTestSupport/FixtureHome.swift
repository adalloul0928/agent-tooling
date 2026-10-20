import AgentToolingCore
import Foundation

/// A scratch home folder for a test that reads or runs an app's tools.
///
/// It plants runnable stand-ins for the apps' command-line tools and the
/// files those apps keep, and finds tools only inside itself: the locator's
/// fixed folders start with ones every process shares, such as
/// `/opt/homebrew/bin`, and a test must not find a tool the Mac running it
/// happens to have installed there.
public struct FixtureHome: Sendable {
    /// The temporary folder that holds the home, removed by `remove()`.
    public let root: URL
    /// The home folder itself, `<root>/home`, created with mode 0700.
    public let url: URL

    public init(_ prefix: String) throws {
        let root = try TemporaryFolder(prefix).url
        let url = root.appending(path: "home", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        self.root = root
        self.url = url
    }

    /// `relative` inside the home.
    public func appending(_ relative: String, directoryHint: URL.DirectoryHint = .inferFromPath) -> URL {
        url.appending(path: relative, directoryHint: directoryHint)
    }

    /// Plants `client`'s tool under its own name in `folder`, a home-relative
    /// folder the locator checks, as a runnable script. Returns where.
    @discardableResult
    public func installTool(_ client: ClientKind, in folder: String = ".local/bin", script: String = "#!/bin/sh\n") throws -> URL {
        let tool = appending(folder, directoryHint: .isDirectory).appending(path: ClientExecutableLocator.executableName(for: client))
        try write(tool, script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        return tool.standardizedFileURL
    }

    /// Writes `text` to the home-relative `relative`, creating its folders.
    public func plant(_ relative: String, _ text: String) throws {
        try write(appending(relative), text)
    }

    /// Plants a skill folder at the home-relative `folder`: a `SKILL.md` with
    /// `name` and `description` in its front matter, then `files` (relative
    /// to the folder) beside it. With `modifiedAt`, every file in it is dated
    /// then.
    public func plantSkill(
        _ folder: String, name: String, description: String, instructions: String = "Follow the steps.",
        files: [String: String] = [:], modifiedAt: Date? = nil
    ) throws {
        let directory = appending(folder, directoryHint: .isDirectory)
        try write(
            directory.appending(path: "SKILL.md"),
            "---\nname: \(name)\ndescription: \(description)\n---\n\n\(instructions)\n")
        for (relative, text) in files.sorted(by: { $0.key < $1.key }) {
            try write(directory.appending(path: relative), text)
        }
        guard let modifiedAt else { return }
        for relative in ["SKILL.md"] + files.keys.sorted() {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt], ofItemAtPath: directory.appending(path: relative).path(percentEncoded: false))
        }
    }

    /// Whether `folder` is inside this fixture. Pass it where a lookup takes
    /// a folder filter.
    public func owns(_ folder: URL) -> Bool {
        folder.standardizedFileURL.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false) + "/")
    }

    /// Where the locator would find `client`'s tool if this fixture were the
    /// whole Mac: the locator's own search and checks, kept to the folders
    /// inside the fixture, so the two can never disagree.
    public func locate(_ client: ClientKind) -> URL? {
        ClientExecutableLocator.locate(client, homeURL: url, searching: owns)
    }

    public func remove() { try? FileManager.default.removeItem(at: root) }
}
